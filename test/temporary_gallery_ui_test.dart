import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/storage_lifecycle.dart';
import 'package:plana_app/features/desktop/desktop_gallery_page.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/gallery_page.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/desktop_image_save.dart';
import 'package:plana_app/features/gallery/temporary_gallery_actions.dart';
import 'package:plana_app/features/gallery/temporary_gallery_exit_dialog.dart';
import 'package:plana_app/features/gallery/temporary_gallery_state.dart';
import 'package:plana_app/features/profile/appearance_page.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesktopCaptureFonts);
  final capture = GlobalKey();
  late AppStores stores;
  late ProviderContainer c;
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));
  setUp(() {
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
  });
  Future<void> finish(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await pumpUntilComplete(t, stores.flushForExit());
    await pumpUntilComplete(t, stores.temporaryGallery.abandon());
    c.dispose();
    await t.pump(const Duration(seconds: 5));
    await t.runAsync(
      () => stores.prefs.supportDirectory.delete(recursive: true),
    );
  }

  Future<void> mount(WidgetTester t, Widget home) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1500, 950);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final theme = AppTheme.light(const Color(0xff00695c));
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            home: Scaffold(body: home),
          ),
        ),
      ),
    );
    await t.pump();
  }

  Future<void> generate(
    WidgetTester t,
    int seed, {
    String canvas = 'canvas1',
    String name = '默认画布',
  }) async {
    await pumpUntilComplete(
      t,
      c
          .read(galleryProvider.notifier)
          .addResultToGallery(
            target: GallerySaveTarget.temporary(canvas, name),
            seed: seed,
            width: 8,
            height: 8,
            bytes: png,
          ),
    );
  }

  testWidgets(
    'temporary batch selects across the initial history limit and scopes files to the source canvas',
    (t) async {
      Finder key(String id) => find.byKey(ValueKey(id));
      final options = c.read(temporaryOptionsProvider.notifier);
      options.choose('canvas1', true);
      await generate(t, 1);
      await generate(t, 2);
      await generate(t, 3);
      await generate(t, 99, canvas: 'other', name: '其他');
      final images = stores.temporaryGallery.images('canvas1');
      final first = images.first.id, last = images.last.id;
      await pumpUntilComplete(
        t,
        c.read(galleryProvider.notifier).retainTemporary(last, favorite: true),
      );
      options.update(initialHistory: 1);
      final folder = await t.runAsync(
        () => stores.prefs.supportDirectory.createTemp('batch-'),
      );
      await pumpUntilComplete(
        t,
        c.read(desktopSaveDirectoryProvider.notifier).select(folder!.path),
      );
      await mount(
        t,
        const GalleryPage(
          desktop: true,
          libraryControl: DesktopLibraryButton(),
        ),
      );
      await pumpUntil(
        t,
        () => key('temporary-batch-menu').evaluate().isNotEmpty,
      );
      Future<void> pick() async {
        final menu = key('temporary-batch-menu');
        await pumpUntil(t, () => t.widget<PopupMenuButton<bool>>(menu).enabled);
        await t.tap(menu);
        await t.pumpAndSettle();
        await t.tap(find.text('多选挑图批量处理…'));
        await t.pumpAndSettle();
      }

      await pick();
      expect(find.text('已选 2 / 3 张'), findsOneWidget);
      final displayed = stores.temporaryGallery.selected('canvas1');
      await t.tap(key('history-thumb-$first'));
      await t.pumpAndSettle();
      expect(stores.temporaryGallery.selected('canvas1'), displayed);
      expect(find.text('已选 1 / 3 张'), findsOneWidget);
      await captureDesktop(t, capture, 'temporary-batch-selection');
      await t.tap(key('temporary-batch-zip'));
      await pumpUntil(t, () => key('temporary-batch-bar').evaluate().isEmpty);
      expect(
        folder
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.zip'))
            .single
            .path,
        contains('精选'),
      );
      expect(stores.temporaryGallery.isPromoted(first), isFalse);
      await pick();
      await t.tap(find.text('全选'));
      await t.pumpAndSettle();
      expect(find.text('已选 3 / 3 张'), findsOneWidget);
      await t.tap(key('temporary-batch-target'));
      await t.pumpAndSettle();
      await t.tap(key('desktop-album-'));
      await t.pumpAndSettle();
      final target = key('temporary-batch-target');
      final file = key('temporary-batch-file'),
          zip = key('temporary-batch-zip');
      final label = find.descendant(of: target, matching: find.text('全部作品'));
      final roomyHeight = t.getSize(file).height;
      for (final width in [710.0, 385.0, 1500.0]) {
        t.view.physicalSize = Size(width, 850);
        await t.pumpAndSettle();
        final bar = t.getRect(key('temporary-batch-bar'));
        for (final f in [target, file, zip]) {
          expect(f.hitTestable(), findsOneWidget);
          expect(bar.contains(t.getRect(f).center), isTrue);
          expect(t.getRect(f).right, lessThanOrEqualTo(bar.right));
        }
        expect(t.getCenter(label).dx, closeTo(t.getCenter(target).dx, 1));
        if (width <= 710) {
          expect(t.getSize(file).height, lessThan(roomyHeight));
          expect(
            t.getSize(file).height,
            lessThanOrEqualTo(t.getSize(key('temporary-film-zip')).height + 1),
          );
        }
        if (width == 710) {
          await captureDesktop(t, capture, 'temporary-batch-compact');
        }
        expect(t.takeException(), isNull);
      }
      await t.tap(file);
      await pumpUntil(t, () => key('temporary-batch-bar').evaluate().isEmpty);
      expect(
        images.every((r) => stores.temporaryGallery.isFiled(r.id)),
        isTrue,
      );
      expect(
        c.read(galleryProvider).results.map((r) => r.id).toSet().length,
        3,
      );
      expect(
        stores.temporaryGallery.isPromoted(
          stores.temporaryGallery.images('other').single.id,
        ),
        isFalse,
      );
      await pick();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(key('temporary-batch-bar'), findsNothing);
      await generate(t, 4);
      await t.tap(key('temporary-batch-menu'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('1 张未收录'));
      await t.pumpAndSettle();
      await pumpUntil(
        t,
        () => stores.temporaryGallery
            .images('canvas1')
            .every((r) => stores.temporaryGallery.isFiled(r.id)),
      );
      expect(c.read(galleryProvider).results, hasLength(4));
      await pick();
      options.choose('canvas1', false);
      await t.pumpAndSettle();
      expect(key('temporary-batch-bar'), findsNothing);
      options.choose('canvas1', true);
      await t.pumpAndSettle();
      expect(key('temporary-batch-bar'), findsNothing);
      await finish(t);
    },
  );
  testWidgets(
    'creation picker, history limit, ZIP and the Saved switch use the real desktop controls',
    (t) async {
      await pumpUntilComplete(
        t,
        stores.prefs.write(key: 'hint_grid_longpress', value: '1'),
      );
      await mount(
        t,
        const GalleryPage(
          desktop: true,
          libraryControl: DesktopLibraryButton(),
        ),
      );
      await t.tap(find.byKey(const ValueKey('desktop-library-picker')));
      await t.pumpAndSettle();
      expect(find.text('临时图库'), findsOneWidget);
      await captureDesktop(t, capture, 'temporary-gallery-picker');
      await t.tap(find.byKey(const ValueKey('desktop-album-@temporary')));
      await pumpUntil(t, () => c.read(temporaryCanvasProvider) == 'canvas1');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('temporary-film-zip')), findsNothing);
      await generate(t, 1);
      await generate(t, 2);
      await generate(t, 3);
      await pumpUntil(t, () => find.text('历史 · 3').evaluate().isNotEmpty);
      expect(find.byKey(const ValueKey('temporary-film-zip')), findsOneWidget);
      Finder key(String id) => find.byKey(ValueKey(id));
      final buttons = [
        'desktop-library-picker',
        'temporary-film-zip',
        'temporary-film-star',
        'temporary-film-file',
        'canvas-save',
        'canvas-save-folder',
        'canvas-copy-image',
        'canvas-regenerate',
      ];
      for (final w in [1500.0, 610.0, 385.0]) {
        t.view.physicalSize = Size(w, 950);
        await t.pumpAndSettle();
        final rects = [for (final id in buttons) t.getRect(key(id))];
        for (int i = 1; i < rects.length; i++) {
          expect(rects[i].left, greaterThanOrEqualTo(rects[i - 1].right));
          expect(rects[i].center.dy, closeTo(rects[0].center.dy, 1));
        }
        expect(rects[1].left - rects[0].right, lessThan(14));
        if (w == 385) {
          await t.ensureVisible(key('canvas-regenerate'));
          expect(key('canvas-regenerate').hitTestable(), findsOneWidget);
          await t.ensureVisible(key('desktop-library-picker'));
          expect(key('desktop-library-picker').hitTestable(), findsOneWidget);
        }
        expect(t.takeException(), isNull);
      }
      t.view.physicalSize = const Size(1500, 950);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('收起历史'));
      await t.pumpAndSettle();
      expect(key('temporary-film-zip').hitTestable(), findsOneWidget);
      await t.tap(find.byTooltip('展开历史'));
      await t.pumpAndSettle();
      await captureDesktop(t, capture, 'polish-temporary-toolbar');
      c.read(temporaryOptionsProvider.notifier).update(initialHistory: 1);
      await t.pump();
      expect(find.text('历史 · 1 / 3'), findsOneWidget);
      await generate(t, 4);
      await pumpUntil(t, () => find.text('历史 · 2 / 4').evaluate().isNotEmpty);
      await t.ensureVisible(find.text('加载更多（+1）'));
      await t.tap(find.text('加载更多（+1）'));
      await t.pump();
      expect(find.text('历史 · 3 / 4'), findsOneWidget);
      final folder = await t.runAsync(
        () => stores.prefs.supportDirectory.createTemp('exports-'),
      );
      await pumpUntilComplete(
        t,
        c.read(desktopSaveDirectoryProvider.notifier).select(folder!.path),
      );
      await t.tap(find.byKey(const ValueKey('temporary-film-zip')));
      await pumpUntil(
        t,
        () => folder.listSync().whereType<File>().any(
          (f) => f.path.endsWith('.zip'),
        ),
      );
      await pumpUntil(t, () => find.text('正在打包 ZIP').evaluate().isEmpty);
      expect(c.read(galleryProvider).results, isEmpty);
      c.read(temporaryOptionsProvider.notifier).update(initialHistory: 30);
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      await mount(t, const AppearancePage());
      final saved = find.byKey(const ValueKey('appearance-saved-gallery'));
      await t.scrollUntilVisible(
        saved,
        420,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: saved, matching: find.byType(Switch)),
        findsOneWidget,
      );
      await Scrollable.ensureVisible(t.element(saved), alignment: .14);
      await t.pumpAndSettle();
      await captureDesktop(t, capture, 'temporary-gallery-settings');
      await t.tap(find.descendant(of: saved, matching: find.byType(Switch)));
      await t.pump();
      expect(c.read(temporaryOptionsProvider).collectSaved, isFalse);
      final newTemp = find.byKey(
        const ValueKey('appearance-new-canvas-temporary'),
      );
      await t.ensureVisible(newTemp);
      expect(c.read(temporaryOptionsProvider).temporaryForNewCanvases, isFalse);
      await t.tap(find.descendant(of: newTemp, matching: find.byType(Switch)));
      await t.pump();
      expect(c.read(temporaryOptionsProvider).temporaryForNewCanvases, isTrue);
      await t.tap(find.descendant(of: newTemp, matching: find.byType(Switch)));
      await t.pump();
      expect(c.read(temporaryOptionsProvider).temporaryForNewCanvases, isFalse);
      await t.ensureVisible(find.text('保留最近'));
      await t.tap(find.text('保留最近'));
      await t.pump();
      final keep = key('temporary-keep-count');
      Finder field(Finder row) =>
          find.descendant(of: row, matching: find.byType(TextField));
      await t.tap(find.descendant(of: keep, matching: find.text('50')));
      await t.pump();
      expect(c.read(temporaryOptionsProvider).keepRecent, 50);
      await t.tap(
        find.descendant(of: keep, matching: find.byIcon(Icons.remove)),
      );
      await t.pump();
      expect(c.read(temporaryOptionsProvider).keepRecent, 45);
      await t.enterText(field(keep), '37');
      await t.pump();
      await t.tap(find.text('全部清理'));
      await t.pump();
      expect(keep, findsNothing);
      await t.tap(find.text('保留最近'));
      await t.pump();
      expect(c.read(temporaryOptionsProvider).keepRecent, 37);
      final history = key('temporary-history-count');
      await t.ensureVisible(field(history));
      await t.enterText(field(history), '123');
      await t.pump();
      final modes = find
          .ancestor(
            of: find.text('自定义'),
            matching: find.byType(SegmentedButton<bool>),
          )
          .first;
      await t.tap(find.descendant(of: modes, matching: find.text('全部')));
      await t.pump();
      expect(c.read(temporaryOptionsProvider).initialHistory, 0);
      expect(history, findsNothing);
      await t.tap(find.text('自定义'));
      await t.pump();
      expect(c.read(temporaryOptionsProvider).initialHistory, 123);
      await t.tap(find.text('打包后清理'));
      await t.pump();
      expect(
        c.read(temporaryOptionsProvider).exitAction,
        TemporaryExitAction.zipThenClean,
      );
      await t.ensureVisible(find.text('退出时处理方式'));
      await captureDesktop(t, capture, 'polish-gallery-options');
      await pumpUntilComplete(t, stores.prefs.idle);
      c.invalidate(temporaryOptionsProvider);
      expect(
        c.read(temporaryOptionsProvider).exitAction,
        TemporaryExitAction.zipThenClean,
      );
      await finish(t);
    },
  );

  testWidgets(
    'deleting one canvas offers its own confirmation and preserves the other canvas',
    (t) async {
      late BuildContext host;
      await mount(
        t,
        Builder(
          builder: (context) {
            host = context;
            return const SizedBox();
          },
        ),
      );
      await generate(t, 1);
      await pumpUntilComplete(
        t,
        c
            .read(galleryProvider.notifier)
            .addResultToGallery(
              target: const GallerySaveTarget.temporary('canvas2', '画布二'),
              seed: 2,
              width: 8,
              height: 8,
              bytes: png,
            ),
      );
      c.read(temporaryOptionsProvider.notifier).update(keepRecent: 20);
      final decision = closeTemporaryGallery(host, canvas: 'canvas1');
      await pumpUntil(t, () => find.text('清理并删除画布').evaluate().isNotEmpty);
      expect(
        find.text('本次有 1 张未收录临时图将被清理。', findRichText: true),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      await t.tap(find.text('清理并删除画布'));
      expect(await pumpUntilComplete(t, decision), isTrue);
      expect(stores.temporaryGallery.images('canvas1'), isEmpty);
      expect(stores.temporaryGallery.images('canvas2').single.seed, 2);
      await finish(t);
    },
  );

  testWidgets(
    'system close cancels, packs all canvases or skips the prompt when nothing will be removed',
    (t) async {
      late BuildContext host;
      await mount(
        t,
        Builder(
          builder: (context) {
            host = context;
            return const SizedBox();
          },
        ),
      );
      final listener = createStorageLifecycleListener(
        stores,
        beforeExit: () => closeTemporaryGallery(host),
      );
      addTearDown(listener.dispose);
      Future<AppExitResponse> close() => binding.handleRequestAppExit();
      expect(await pumpUntilComplete(t, close()), AppExitResponse.exit);
      expect(find.byType(AlertDialog), findsNothing);
      await generate(t, 1);
      await generate(t, 2);
      var request = close();
      await pumpUntil(t, () => find.text('退出前处理临时图库').evaluate().isNotEmpty);
      expect(
        find.text('本次有 2 张未收录临时图将被清理。', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('2 张待清理'), findsNothing);
      expect(find.textContaining('0 张'), findsNothing);
      await t.tap(find.byType(CheckboxListTile));
      await t.pump();
      expect(find.textContaining('会记为'), findsOneWidget);
      await t.tap(find.text('返回创作'));
      expect(await pumpUntilComplete(t, request), AppExitResponse.cancel);
      expect(stores.temporaryGallery.images('canvas1').length, 2);
      expect(
        c.read(temporaryOptionsProvider).exitAction,
        TemporaryExitAction.ask,
      );
      await t.pumpAndSettle();
      final missing = Directory(
        '${stores.prefs.supportDirectory.path}/missing',
      );
      await pumpUntilComplete(
        t,
        c.read(desktopSaveDirectoryProvider.notifier).select(missing.path),
      );
      request = close();
      await pumpUntil(t, () => find.text('打包 ZIP 并退出').evaluate().isNotEmpty);
      await t.tap(find.byType(CheckboxListTile));
      await t.pump();
      await t.tap(find.text('打包 ZIP 并退出'));
      expect(await pumpUntilComplete(t, request), AppExitResponse.cancel);
      expect(stores.temporaryGallery.images('canvas1').length, 2);
      expect(
        c.read(temporaryOptionsProvider).exitAction,
        TemporaryExitAction.ask,
      );
      await t.pumpAndSettle();
      final folder = await t.runAsync(
        () => stores.prefs.supportDirectory.createTemp('exports-'),
      );
      await pumpUntilComplete(
        t,
        c.read(desktopSaveDirectoryProvider.notifier).select(folder!.path),
      );
      await pumpUntilComplete(
        t,
        c
            .read(galleryProvider.notifier)
            .addResultToGallery(
              target: const GallerySaveTarget.temporary('canvas2', '画布二'),
              seed: 3,
              width: 8,
              height: 8,
              bytes: png,
            ),
      );
      request = close();
      await pumpUntil(
        t,
        () => find.text('按画布打包 ZIP 并退出').evaluate().isNotEmpty,
      );
      expect(find.textContaining('画布二（1 张待清理）'), findsOneWidget);
      await t.tap(find.byType(CheckboxListTile));
      await t.pumpAndSettle();
      await t.tap(find.text('按画布打包 ZIP 并退出'));
      expect(await pumpUntilComplete(t, request), AppExitResponse.exit);
      expect(
        folder
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.zip'))
            .length,
        2,
      );
      expect(
        c.read(temporaryOptionsProvider).exitAction,
        TemporaryExitAction.zipThenClean,
      );
      expect(stores.temporaryGallery.canvases, isEmpty);
      expect(c.read(galleryProvider).results, isEmpty);
      await generate(t, 4);
      final retained = stores.temporaryGallery.images('canvas1').single;
      await pumpUntilComplete(
        t,
        c
            .read(galleryProvider.notifier)
            .retainTemporary(retained.id, favorite: true),
      );
      expect(await pumpUntilComplete(t, close()), AppExitResponse.exit);
      expect(find.byType(AlertDialog), findsNothing);
      expect(c.read(galleryProvider).results.single.id, retained.id);
      expect(folder.listSync().whereType<File>().length, 2);
      await generate(t, 5);
      await pumpUntilComplete(
        t,
        c.read(desktopSaveDirectoryProvider.notifier).select(missing.path),
      );
      expect(await pumpUntilComplete(t, close()), AppExitResponse.cancel);
      expect(stores.temporaryGallery.images('canvas1').single.seed, 5);
      await pumpUntilComplete(
        t,
        c.read(desktopSaveDirectoryProvider.notifier).select(folder.path),
      );
      expect(await pumpUntilComplete(t, close()), AppExitResponse.exit);
      expect(folder.listSync().whereType<File>().length, 3);
      expect(stores.temporaryGallery.canvases, isEmpty);
      await finish(t);
    },
  );
  testWidgets(
    'legacy options migrate and remembered cleanup applies only after confirmation',
    (t) async {
      await pumpUntilComplete(
        t,
        stores.prefs.write(
          key: 'temporary_gallery_options',
          value: '{"confirmExit":false,"keepRecent":2,"initialHistory":0}',
        ),
      );
      expect(
        c.read(temporaryOptionsProvider).exitAction,
        TemporaryExitAction.clean,
      );
      expect(c.read(temporaryOptionsProvider).lastKeepCount, 2);
      late BuildContext host;
      await mount(
        t,
        Builder(
          builder: (context) {
            host = context;
            return const SizedBox();
          },
        ),
      );
      for (int i = 0; i < 3; i++) {
        await generate(t, i);
      }
      expect(await pumpUntilComplete(t, closeTemporaryGallery(host)), isTrue);
      expect(find.byType(TemporaryGalleryExitDialog), findsNothing);
      await generate(t, 4);
      c
          .read(temporaryOptionsProvider.notifier)
          .update(keepRecent: 0, exitAction: TemporaryExitAction.ask);
      final close = closeTemporaryGallery(host);
      await pumpUntil(
        t,
        () => find.byType(CheckboxListTile).evaluate().isNotEmpty,
      );
      await t.tap(find.byType(CheckboxListTile));
      await t.pump();
      await t.tap(find.text('清理并退出'));
      expect(await pumpUntilComplete(t, close), isTrue);
      c.invalidate(temporaryOptionsProvider);
      expect(
        c.read(temporaryOptionsProvider).exitAction,
        TemporaryExitAction.clean,
      );
      expect(c.read(temporaryOptionsProvider).lastKeepCount, 2);
      await finish(t);
    },
  );
  testWidgets(
    'single and mixed close dialogs show the actual nonzero counts and current canvas names',
    (t) async {
      late BuildContext host;
      await mount(
        t,
        Builder(
          builder: (context) {
            host = context;
            return const SizedBox();
          },
        ),
      );
      await generate(t, 1);
      var close = closeTemporaryGallery(host);
      await pumpUntil(t, () => find.text('打包 ZIP 并退出').evaluate().isNotEmpty);
      expect(
        find.text('本次有 1 张未收录临时图将被清理。', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('1 张待清理'), findsNothing);
      await t.pumpAndSettle();
      await captureDesktop(t, capture, 'polish-single-exit');
      await t.tap(find.byType(CheckboxListTile));
      await t.pump();
      await t.tapAt(const Offset(4, 4));
      expect(await pumpUntilComplete(t, close), isFalse);
      await t.pumpAndSettle();
      expect(stores.temporaryGallery.closing, isFalse);
      expect(
        c.read(temporaryOptionsProvider).exitAction,
        TemporaryExitAction.ask,
      );
      final first = stores.temporaryGallery.images('canvas1').single;
      await pumpUntilComplete(
        t,
        c
            .read(galleryProvider.notifier)
            .retainTemporary(first.id, favorite: true),
      );
      final canvases = c.read(canvasWorkspaceProvider.notifier);
      final second = canvases.create();
      c.read(temporaryOptionsProvider.notifier).update(keepRecent: 1);
      for (int i = 2; i <= 3; i++) {
        await generate(t, i);
      }
      for (int i = 4; i <= 6; i++) {
        await generate(t, i, canvas: second, name: '旧名字');
      }
      canvases.rename(second, '森林');
      close = closeTemporaryGallery(host);
      await pumpUntil(
        t,
        () => find.text('按画布打包 ZIP 并退出').evaluate().isNotEmpty,
      );
      expect(find.text('3 张待清理'), findsOneWidget);
      expect(find.text('1 张已收录保留'), findsOneWidget);
      expect(find.text('2 张留到下次'), findsOneWidget);
      expect(find.textContaining('森林（2 张待清理）'), findsOneWidget);
      await t.tap(find.byType(CheckboxListTile));
      await t.pumpAndSettle();
      await captureDesktop(t, capture, 'polish-multiple-exit');
      t.view.physicalSize = const Size(345, 440);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.ensureVisible(find.text('返回创作'));
      await t.tap(find.text('返回创作'));
      expect(await pumpUntilComplete(t, close), isFalse);
      expect(
        c.read(temporaryOptionsProvider).exitAction,
        TemporaryExitAction.ask,
      );
      await finish(t);
    },
  );
}
