import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/platform/clipboard_image.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_gallery_page.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/gallery_page.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/desktop_canvas_gutters.dart';
import 'package:plana_app/features/gallery/widgets/film_strip.dart';
import 'package:plana_app/features/gallery/widgets/result_thumb.dart';
import 'package:plana_app/features/import/import_panel.dart';

import 'support/pump_until.dart';

class _Gallery extends GalleryNotifier {
  _Gallery(this.images);
  final List<ResultImage> images;
  @override
  GalleryState build() => GalleryState(
    results: images,
    trash: [
      TrashedImage(
        const ResultImage(id: 'deleted', width: 120, height: 240, seed: 0),
        DateTime.now().millisecondsSinceEpoch,
      ),
    ],
    selectedId: images.isEmpty ? null : images[1].id,
  );
}

void main() {
  late ProviderContainer container;
  late AppStores stores;
  late Uint8List bytes;
  var disposed = false;
  setUp(() {
    bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 120, height: 240)),
    );
    stores = AppStores.ephemeral();
    disposed = false;
  });
  tearDown(() {
    if (!disposed) container.dispose();
    stores.flushNow();
  });
  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> mount(WidgetTester tester, {bool empty = false}) async {
    final images = [
      if (!empty)
        for (var i = 0; i < 3; i++)
          ResultImage(
            id: 'image-$i',
            width: 120,
            height: 240,
            seed: i,
            bytes: bytes,
          ),
    ];
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryProvider.overrideWith(() => _Gallery(images)),
        galleryThumbProvider.overrideWith((ref, id) async => bytes),
      ],
    );
    container.read(desktopLibraryProvider.notifier).choose(null);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(
                  height: 44,
                  child: TextField(key: ValueKey('outside-prompt')),
                ),
                const Expanded(
                  child: GalleryPage(
                    desktop: true,
                    libraryControl: DesktopLibraryButton(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String? selected() => container.read(galleryProvider).selectedId;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    stores.flushNow();
    await pumpUntilComplete(tester, stores.gallery.idle);
    container.dispose();
    disposed = true;
  }

  testWidgets(
    'collapsed history expands from label and blank space but preserves picker',
    (tester) async {
      await mount(tester);
      final before = selected();
      await tester.tap(find.byTooltip('收起历史'));
      await tester.pumpAndSettle();
      expect(key('history-thumb-image-0'), findsNothing);
      await tester.tap(find.text('历史 · 3'));
      await tester.pumpAndSettle();
      expect(key('history-thumb-image-0'), findsOneWidget);

      await tester.tap(find.byTooltip('收起历史'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-library-picker'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(key('history-thumb-image-0'), findsNothing);
      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();

      final header = tester.getRect(key('desktop-history-header'));
      await tester.tapAt(Offset(header.right - 2, header.center.dy));
      await tester.pumpAndSettle();
      expect(key('history-thumb-image-0'), findsOneWidget);
      // Expanded whitespace is not a new accidental collapse target.
      await tester.tapAt(Offset(header.right - 2, header.center.dy));
      await tester.pumpAndSettle();
      expect(key('history-thumb-image-0'), findsOneWidget);
      expect(selected(), before);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'collapsed history highlights both edges even over the action buttons',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byTooltip('收起历史'));
      await tester.pumpAndSettle();
      final bar = key('canvas-bottom-actions');
      final rect = tester.getRect(bar);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.ancestor(of: bar, matching: find.byType(RepaintBoundary)).first,
      );
      Future<List<int>> edgeColors() async => (await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final rgba = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          int colorAt(double x) {
            final point = boundary.globalToLocal(Offset(x, rect.center.dy));
            final index = point.dy.floor() * image.width + point.dx.floor();
            return rgba.getUint32(4 * index);
          }

          return [colorAt(rect.left + 2), colorAt(rect.right - 2)];
        } finally {
          image.dispose();
        }
      }))!;

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final outside = rect.topCenter - const Offset(0, 10);
      await mouse.addPointer(location: outside);
      await tester.pumpAndSettle();
      final idle = await edgeColors();
      await mouse.moveTo(tester.getCenter(find.text('历史 · 3')));
      await tester.pumpAndSettle();
      final hover = await edgeColors();
      expect(hover.first, isNot(idle.first));
      expect(hover.last, hover.first);
      await mouse.moveTo(tester.getCenter(key('canvas-save-folder')));
      await tester.pumpAndSettle();
      expect(await edgeColors(), hover);
      expect(key('history-thumb-image-0'), findsNothing);
      await mouse.moveTo(outside);
      await tester.pumpAndSettle();
      expect(await edgeColors(), idle);
      await mouse.removePointer();
      await finish(tester);
    },
  );

  testWidgets(
    'the minimum desktop canvas keeps history and every action on one line',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await mount(tester);
      final y = tester.getCenter(key('desktop-library-picker')).dy;
      for (final id in [
        'desktop-history-browse',
        'canvas-save',
        'canvas-save-folder',
        'canvas-copy-image',
        'canvas-regenerate',
      ]) {
        expect(key(id).hitTestable(), findsOneWidget);
        expect(tester.getCenter(key(id)).dy, closeTo(y, 2));
      }
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'desktop history drop onto canvas opens import without mobile drop bands',
    (tester) async {
      await mount(tester);
      final before = selected();
      final thumb = key('history-thumb-image-0');
      final drag = await tester.startGesture(
        tester.getCenter(thumb),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, -100));
      await tester.pump();
      await drag.moveTo(tester.getCenter(find.byType(DesktopCanvasGutters)));
      await tester.pump();
      expect(find.text('拖到这里分享'), findsNothing);
      expect(find.text('拖到这里删除'), findsNothing);
      await drag.up();
      await tester.pump();
      // Metadata parsing runs in a real isolate; let it finish before waiting
      // for the loading indicator's animation to settle in fake time.
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byType(ImportImagePanel).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(find.byType(ImportImagePanel), findsOneWidget);
      expect(
        tester.widget<ImportImagePanel>(find.byType(ImportImagePanel)).bytes,
        bytes,
      );
      expect(selected(), before);
      expect(container.read(galleryProvider).results.length, 3);
      await finish(tester);
    },
  );

  testWidgets(
    'short, downward and returned history drags leave the image untouched',
    (tester) async {
      await mount(tester);
      final before = selected();
      for (final movements in [
        [const Offset(0, -25)],
        [const Offset(0, 40)],
        [const Offset(0, -100), const Offset(0, 100)],
      ]) {
        final drag = await tester.startGesture(
          tester.getCenter(key('history-thumb-image-0')),
          kind: PointerDeviceKind.mouse,
        );
        for (final delta in movements) {
          await drag.moveBy(delta);
          await tester.pump();
        }
        await drag.up();
        await tester.pumpAndSettle();
        expect(find.byType(ImportImagePanel), findsNothing);
        expect(selected(), before);
        expect(container.read(galleryProvider).results.length, 3);
      }
      await finish(tester);
    },
  );

  testWidgets(
    'history delete requires two clicks on the same red cross and resets on timeout or selection',
    (tester) async {
      await mount(tester);
      Color? cross(String id) => tester
          .widget<IconButton>(key('history-delete-$id'))
          .style!
          .foregroundColor!
          .resolve({});
      final normal = cross('image-0');
      await tester.tap(key('history-delete-image-0'));
      await tester.pump();
      expect(cross('image-0'), AppTheme.light().colorScheme.error);
      expect(container.read(galleryProvider).results.length, 3);
      await tester.pump(const Duration(seconds: 3));
      expect(cross('image-0'), normal);
      await tester.tap(key('history-delete-image-0'));
      await tester.pump();
      await tester.tap(key('history-thumb-image-2'));
      await tester.pumpAndSettle();
      expect(cross('image-0'), normal);
      await tester.tap(key('history-delete-image-0'));
      await tester.pump();
      await tester.tap(key('history-delete-image-0'));
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 100 && container.read(galleryProvider).results.length == 3;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(container.read(galleryProvider).results.map((r) => r.id), [
        'image-1',
        'image-2',
      ]);
      expect(cross('image-1'), normal);
      expect(find.byType(ImportImagePanel), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'blank gutters and history arrows change only the focused canvas and stop at boundaries',
    (tester) async {
      await mount(tester);
      expect(selected(), 'image-1');
      expect(find.text('查看当前图库'), findsNothing);
      expect(key('desktop-library-picker'), findsOneWidget);
      final headerRect = tester.getRect(key('desktop-library-picker'));
      final pickerRect = tester.getRect(key('desktop-history-browse'));
      final canvasRect = tester.getRect(find.byType(GalleryPage));
      final actions = [
        'canvas-save',
        'canvas-save-folder',
        'canvas-copy-image',
        'canvas-regenerate',
      ].map((id) => tester.getRect(key(id))).toList();
      expect(
        tester.getRect(find.text('历史 · 3')).right,
        lessThan(headerRect.left),
      );
      expect(headerRect.right, lessThanOrEqualTo(pickerRect.left));
      expect(pickerRect.right, lessThan(actions.first.left));
      for (var i = 0; i < actions.length; i++) {
        expect(actions[i].center.dy, closeTo(pickerRect.center.dy, 2));
        if (i > 0) {
          expect(actions[i].left, greaterThanOrEqualTo(actions[i - 1].right));
        }
      }
      expect(canvasRect.right - actions.last.right, lessThan(20));
      final stripRect = tester.getRect(find.byType(FilmStrip));
      expect(headerRect.bottom, lessThanOrEqualTo(stripRect.top));
      expect(stripRect.top - headerRect.bottom, lessThan(20));
      Future<void> clickGutter(String name) async {
        final rect = tester.getRect(key(name));
        await tester.tapAt(Offset(rect.center.dx, rect.top + 20));
        await tester.pumpAndSettle();
      }

      await clickGutter('canvas-next-gutter');
      expect(selected(), 'image-2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected(), 'image-2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(selected(), 'image-1');
      await clickGutter('canvas-previous-gutter');
      expect(selected(), 'image-0');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(selected(), 'image-0');
      await tester.tapAt(tester.getCenter(find.byType(DesktopCanvasGutters)));
      await tester.pumpAndSettle();
      expect(
        selected(),
        'image-0',
        reason: 'Clicking the image is not gutter navigation',
      );
      final thumb = find
          .descendant(
            of: find.byType(FilmStrip),
            matching: find.byType(ResultThumb),
          )
          .at(1);
      await tester.tap(thumb);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected(), 'image-2');
      await tester.enterText(key('outside-prompt'), 'prompt');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        selected(),
        'image-2',
        reason: 'Text cursor arrows must not navigate history',
      );
      await clickGutter('canvas-previous-gutter');
      expect(selected(), 'image-1');
      container.read(galleryZoomedProvider.notifier).set(true);
      await tester.pump();
      expect(find.byType(DesktopCanvasGutters), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(
        selected(),
        'image-1',
        reason: 'Zoomed canvas retains its pan controls',
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'Ctrl+C copies the selected canvas image and leaves text inputs alone',
    (tester) async {
      var copies = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopClipboard.channel, (call) async {
            if (call.method == 'write') {
              copies++;
              return true;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DesktopClipboard.channel, null),
      );
      await mount(tester);
      await tester.tap(key('history-thumb-image-1'));
      await tester.pump();
      Future<void> copy() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
      }

      await copy();
      expect(copies, 1);
      await tester.tap(key('outside-prompt'));
      await tester.enterText(key('outside-prompt'), 'do not copy image here');
      await copy();
      expect(copies, 1);
      await finish(tester);
    },
  );

  testWidgets(
    'empty desktop canvas still exposes the current library selector',
    (tester) async {
      await mount(tester, empty: true);
      expect(key('empty-gallery-trash'), findsNothing);
      expect(container.read(galleryProvider).trash, hasLength(1));
      expect(key('desktop-history-browse'), findsOneWidget);
      expect(key('desktop-library-picker'), findsOneWidget);
      await tester.tap(find.byTooltip('收起历史'));
      await tester.pumpAndSettle();
      await tester.tap(key('canvas-save'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('展开历史'), findsOneWidget);
      await tester.tap(key('desktop-library-picker'));
      await tester.pumpAndSettle();
      expect(key('desktop-library-dialog'), findsOneWidget);
      expect(find.text('查看当前图库'), findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
}
