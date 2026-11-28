import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/core/util/image_pick.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/import/import_panel.dart';
import 'package:plana_app/features/tools/tools_page.dart';
import 'package:plana_app/l10n/l10n.dart';

import 'support/desktop_capture.dart';

class _Files extends FilePicker {
  _Files(this.pair);
  final List<Uint8List> pair;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    for (final (i, bytes) in pair.indexed)
      PlatformFile(name: 'file-$i.png', bytes: bytes, size: bytes.length),
  ]);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final l = l10nNow;
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopModeProvider.overrideWithValue(true),
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        ],
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(const Color(0xFF00897B)).copyWith(
              textTheme: AppTheme.light(
                const Color(0xFF00897B),
              ).textTheme.apply(fontFamily: 'Microsoft YaHei'),
            ),
            home: const ToolsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.compareImages));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop tools use the window width and align their controls in the top row',
    (tester) async {
      await open(tester, const Size(1720, 900));
      final tabs = find.widgetWithText(SegmentedButton<int>, l.compareImages);
      final modes = find.widgetWithText(
        SegmentedButton<int>,
        l.desktopSingleImage,
      );
      final remove = find.widgetWithText(
        SegmentedButton<bool>,
        l.desktopRemoveLoRA,
      );
      final clear = find.widgetWithText(OutlinedButton, l.compareClear);

      Rect card(String title) => tester.getRect(
        find
            .ancestor(of: find.text(title), matching: find.byType(Material))
            .first,
      );
      for (final size in [
        const Size(1720, 900),
        const Size(2560, 1200),
        const Size(1060, 720),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        await tester.tap(find.text(l.imageMetadata));
        await tester.pumpAndSettle();
        final tabsRect = tester.getRect(tabs);
        final right = size.width - 16;
        expect(find.text(l.toolbox), findsNothing);
        expect(
          find.text(l.desktopReadAndEditGenerationSettingsThenExportThe),
          findsNothing,
        );
        expect(tabsRect.left, 16);
        expect(tabsRect.top, lessThanOrEqualTo(16));
        expect(tester.getRect(modes).right, closeTo(right, .1));
        expect(tester.getCenter(modes).dy, closeTo(tabsRect.center.dy, 1));
        expect(card('当前图片').left, 16);
        expect(card('当前图片').right, right);
        if (size.width == 1720) {
          await tester.tap(find.text('更多参数'));
          await tester.pumpAndSettle();
          await captureDesktop(tester, capture, 'toolbox-full-width-metadata');
          await tester.tap(find.text('更多参数'));
          await tester.pumpAndSettle();
        }

        await tester.tap(find.text(l.weightConverter));
        await tester.pumpAndSettle();
        expect(tester.getRect(tabs), tabsRect);
        expect(tester.getRect(remove).right, closeTo(right, .1));
        expect(tester.getCenter(remove).dy, closeTo(tabsRect.center.dy, 1));
        expect(
          tester.getCenter(find.text('SD → NAI')).dy,
          closeTo(tabsRect.center.dy, 2),
        );
        expect(card('SD 提示词').left, 16);
        expect(card('NAI 转换结果').right, right);
        if (size.width == 1720) {
          await captureDesktop(tester, capture, 'toolbox-full-width-weights');
        }

        await tester.tap(find.text(l.compareImages));
        await tester.pumpAndSettle();
        expect(tester.getRect(tabs), tabsRect);
        final swap = tester.getRect(
          find.widgetWithText(OutlinedButton, l.swapAB),
        );
        final clearRect = tester.getRect(clear);
        expect(swap.center.dy, clearRect.center.dy);
        expect(swap.right, lessThan(clearRect.left));
        expect(swap.left, greaterThan(tabsRect.right));
        expect(clearRect.center.dy, closeTo(tabsRect.center.dy, 1));
        expect(clearRect.right, closeTo(right, .1));
        if (size.width == 1720) {
          await captureDesktop(tester, capture, 'toolbox-full-width-compare');
        }
      }
      tester.view.physicalSize = const Size(540, 650);
      await tester.pumpAndSettle();
      for (final (tab, actions) in [
        (l.compareImages, clear),
        (l.weightConverter, remove),
        (l.imageMetadata, modes),
      ]) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        final actionRect = tester.getRect(actions);
        final tabRect = tester.getRect(tabs);
        expect(actionRect.overlaps(tabRect), isFalse);
        expect(actionRect.right, lessThanOrEqualTo(540 - 16 + .1));
        expect(actions.hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compare file pair at actual toolbox entry; swap, zoom, filter, copy and clear',
    (tester) async {
      await open(tester, const Size(1440, 850));
      final raw = Uint8List.fromList(
        img.encodePng(img.Image(width: 48, height: 96)),
      );
      final pair = (await tester.runAsync(
        () => Future.wait([
          writeImageMetadataPng(
            raw,
            comment: {
              'prompt': [
                'sky',
                '1.5::trees::',
                'grass',
                for (var i = 1; i <= 18; i++) 'leaf $i',
              ].join(', '),
              'uc': 'blur',
              'seed': 11,
            },
          ),
          writeImageMetadataPng(
            raw,
            comment: {
              'prompt': 'sky, 2::trees::, water',
              'uc': 'noise',
              'seed': 22,
            },
          ),
        ]),
      ))!;
      FilePicker.platform = _Files(pair);
      await tester.tap(find.text(l.compareOpenFile).first);
      final elapsed = Stopwatch()..start();
      while (find.text('file-1.png').evaluate().isEmpty &&
          elapsed.elapsed < const Duration(seconds: 20)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(find.text('file-1.png'), findsOneWidget);
      final a = find.byKey(const ValueKey('compare-drop-0'));
      final b = find.byKey(const ValueKey('compare-drop-1'));
      expect(tester.getTopLeft(a).dy, tester.getTopLeft(b).dy);
      expect(
        tester.getTopRight(b).dx,
        lessThan(tester.getTopLeft(find.text(l.compareAllChanges)).dx),
      );
      Iterable<InteractiveViewer> viewers() =>
          tester.widgetList<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(viewers().length, 2);
      expect(
        viewers().first.transformationController,
        same(viewers().last.transformationController),
      );
      expect(
        tester
            .widget<Image>(find.descendant(of: a, matching: find.byType(Image)))
            .fit,
        BoxFit.contain,
      );
      await tester.tap(find.text(l.compareCover));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Image>(find.descendant(of: a, matching: find.byType(Image)))
            .fit,
        BoxFit.cover,
      );
      await tester.tap(find.byTooltip(l.compareZoomIn));
      await tester.pump();
      expect(find.text('125%'), findsOneWidget);
      final onlyA = find.widgetWithText(ChoiceChip, l.onlyInA);
      final count = find.descendant(of: onlyA, matching: find.text('20'));
      expect(
        tester.getTopLeft(count).dx -
            tester.getTopRight(find.text(l.onlyInA)).dx,
        greaterThanOrEqualTo(12),
      );
      expect(tester.widget<Text>(count).semanticsLabel, l.differentN(20));
      expect(tester.widget<Text>(count).textAlign, TextAlign.end);
      void expectPlainCount() {
        final label = find.byWidget(tester.widget<ChoiceChip>(onlyA).label);
        expect(
          find.descendant(
            of: label,
            matching: find.byWidgetPredicate(
              (w) => w is Container && w.decoration is ShapeDecoration,
            ),
          ),
          findsNothing,
        );
      }

      expectPlainCount();
      await tester.tap(onlyA);
      await tester.pumpAndSettle();
      expectPlainCount();
      expect(find.textContaining('grass', findRichText: true), findsWidgets);
      expect(find.textContaining('water', findRichText: true), findsNothing);
      await tester.tap(find.text(l.swapAB));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Image>(find.descendant(of: a, matching: find.byType(Image)))
            .semanticLabel,
        'file-1.png',
      );
      await tester.tap(find.text(l.weightConverter));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.compareImages));
      await tester.pumpAndSettle();
      expect(find.text('file-1.png'), findsOneWidget);
      String? clipboard;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final report = find.text(l.compareCopyReport);
      await tester.ensureVisible(report);
      await tester.tap(report);
      await tester.pumpAndSettle();
      expect(clipboard, contains('water'));
      expect(clipboard, contains('2 → 1.5'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      final useA = find.text(l.compareUseSide('A'));
      await tester.ensureVisible(useA);
      await tester.tap(useA);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<ImportImagePanel>(find.byType(ImportImagePanel)).fileName,
        'file-1.png',
      );
      Navigator.of(tester.element(find.byType(ImportImagePanel))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('${l.comparePickGallery} · A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(l.pickFromGallery), findsOneWidget);
      await tester.tap(find.byTooltip(l.close).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.compareClear));
      await tester.pumpAndSettle();
      expect(find.text(l.compareEmpty), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow window keeps images next to each other, accepts plain images in the targeted slot',
    (tester) async {
      await open(tester, const Size(560, 720));
      final a = find.byKey(const ValueKey('compare-drop-0'));
      final b = find.byKey(const ValueKey('compare-drop-1'));
      expect(tester.getTopLeft(a).dy, tester.getTopLeft(b).dy);
      final file = PickedImage(
        'plain.png',
        Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 12))),
      );
      final onDrop = tester.widget<ImageDropRegion>(b).onDrop!;
      await tester.runAsync(
        () => onDrop(
          [file],
          ImageDropPayload.image(name: file.name, load: () async => file.bytes),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(l.noMetadataFor('B')), findsOneWidget);
      expect(
        find.descendant(of: b, matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: a, matching: find.byType(Image)),
        findsNothing,
      );
      await tester.tap(find.byTooltip('${l.remove} · B'));
      await tester.pumpAndSettle();
      expect(find.text('plain.png'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
