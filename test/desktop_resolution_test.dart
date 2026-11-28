import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/res_presets.dart';
import 'package:plana_app/features/generate/widgets/resolution_sheet.dart';
import 'support/desktop_capture.dart';

void main() {
  late AppStores stores;
  late ProviderContainer c;
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  setUp(() {
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });
  Finder key(String name) => find.byKey(ValueKey(name));
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    c.read(generateProvider.notifier).setSize(832, 1216);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light().copyWith(
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: SizedBox(
                  width: 320,
                  child: MediaQuery(
                    data: const MediaQueryData(size: Size(320, 700)),
                    child: Builder(
                      builder: (context) => TextButton(
                        onPressed: () => showResolutionSheet(context),
                        child: const Text('打开分辨率'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开分辨率'));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'resolution popover anchors above its button and applies presets',
    (tester) async {
      await mount(tester);
      expect(find.byType(BottomSheet), findsNothing);
      final surface = key('desktop-popover');
      final rect = tester.getRect(surface);
      expect(rect.width, 340);
      expect(rect.left, 12);
      expect(rect.bottom, lessThan(tester.getTopLeft(find.text('打开分辨率')).dy));
      expect(
        tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color?.a ??
            0,
        0,
      );
      await captureDesktop(tester, capture, 'windows16-resolution-presets');
      expect(key('resolution-confirm'), findsNothing);
      await tester.tap(find.text('横图').hitTestable());
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).params.width, 1216);
      expect(c.read(generateProvider).params.height, 832);
      expect(key('desktop-popover'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'manual dimensions truncate decimals before snapping, swap and validate',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'windows16-resolution-custom');
      await tester.enterText(key('resolution-width'), '863.9');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '832',
      );
      await tester.tap(key('resolution-width'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '896',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '832',
      );
      await tester.enterText(key('resolution-height'), '1024.8');
      // Confirm without submitting the text field must still use the draft.
      await tester.tap(key('resolution-confirm'));
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).params.width, 832);
      expect(c.read(generateProvider).params.height, 1024);
      await tester.tap(find.text('打开分辨率'));
      await tester.pumpAndSettle();
      await tester.enterText(key('resolution-width'), 'NaN');
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(key('resolution-confirm')).onPressed,
        isNull,
      );
      await tester.enterText(key('resolution-width'), '3072');
      await tester.enterText(key('resolution-height'), '3072');
      await tester.pumpAndSettle();
      expect(find.text('超出像素上限'), findsNothing);
      expect(find.text('超限'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(key('resolution-confirm')).onPressed,
        isNull,
      );
      await tester.enterText(key('resolution-width'), '832');
      await tester.enterText(key('resolution-height'), '1216');
      await tester.tap(find.byTooltip('交换宽高').hitTestable());
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '1216',
      );
      expect(
        tester.widget<TextField>(key('resolution-height')).controller!.text,
        '832',
      );
      tester.view.physicalSize = const Size(720, 500);
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('resolution-confirm'));
      await tester.tap(key('resolution-confirm'));
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).params.width, 1216);
      expect(c.read(generateProvider).params.height, 832);
      await finish(tester);
    },
  );

  testWidgets(
    'wheel steps the hovered dimension without scrolling or applying the panel',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      await tester.tap(key('resolution-width'));
      final panel = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: key('resolution-panel'),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final scrollOffset = panel.pixels;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(key('resolution-height')),
          scrollDelta: const Offset(0, -120),
        ),
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '832',
      );
      expect(
        tester.widget<TextField>(key('resolution-height')).controller!.text,
        '1280',
      );
      expect(panel.pixels, scrollOffset);
      expect(containerSize(c), (832, 1216));
      await tester.enterText(key('resolution-width'), '64');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '64',
      );
      await tester.enterText(key('resolution-width'), '3072');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '3072',
      );
      expect(
        tester.widget<FilledButton>(key('resolution-confirm')).onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(containerSize(c), (832, 1216));
      await finish(tester);
    },
  );

  testWidgets(
    'all preset tabs apply immediately and saved delete targets only the top corner',
    (tester) async {
      await tester.runAsync(() async {
        await c.read(resPresetsProvider.notifier).add(3072, 960);
        await c.read(resPresetsProvider.notifier).add(896, 1152);
      });
      await mount(tester);
      final builtinSize = tester.getSize(key('832x1216'));
      for (final (group, card, w, h) in [
        ('大图', '1472x1472', 1472, 1472),
        ('壁纸', '1920x1088', 1920, 1088),
        ('我的', '3072x960', 3072, 960),
      ]) {
        final before = containerSize(c);
        await tester.tap(find.text(group));
        await tester.pumpAndSettle();
        expect(containerSize(c), before);
        expect(key('resolution-confirm'), findsNothing);
        if (group == '我的') {
          final rect = tester.getRect(key(card));
          expect(rect.size, builtinSize);
          final trash = find.descendant(
            of: key(card),
            matching: find.byTooltip('删除尺寸预设'),
          );
          expect(tester.getTopRight(trash).dx, closeTo(rect.right, 4));
          expect(tester.getTopRight(trash).dy, closeTo(rect.top, 4));
          await captureDesktop(tester, capture, 'resolution-personal-cards');
          await tester.tap(
            find.descendant(
              of: key('896x1152'),
              matching: find.byTooltip('删除尺寸预设'),
            ),
          );
          await tester.pumpAndSettle();
          expect(containerSize(c), before);
          expect(key('896x1152'), findsNothing);
        }
        await tester.tap(key(card));
        await tester.pumpAndSettle();
        expect(key('resolution-panel'), findsNothing);
        expect(containerSize(c), (w, h));
        await tester.tap(find.text('打开分辨率'));
        await tester.pumpAndSettle();
      }
      expect(key('3072x960'), findsOneWidget);
      await tester.tap(find.byTooltip('删除尺寸预设'));
      await tester.pumpAndSettle();
      expect(find.text('我的'), findsNothing);
      expect(containerSize(c), (3072, 960));
      expect(key('resolution-width'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'compact custom grid sits above save, status and dimension controls',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      final grid = tester.getRect(key('resolution-canvas'));
      final save = tester.getRect(key('resolution-save-preset'));
      final status = tester.getRect(find.text('免费'));
      final width = tester.getRect(key('resolution-width'));
      final height = tester.getRect(key('resolution-height'));
      final apply = tester.getRect(key('resolution-confirm'));
      expect(grid.width, lessThanOrEqualTo(176));
      expect(grid.center.dx, closeTo(save.center.dx, 1));
      expect(grid.bottom, lessThan(save.top));
      expect(save.width, greaterThan(grid.width));
      expect(save.bottom, lessThan(status.top));
      expect(status.bottom, lessThan(width.top));
      expect(width.center.dy, closeTo(height.center.dy, 1));
      expect(height.right, lessThan(apply.left));
      expect(tester.getSize(key('resolution-panel')).height, lessThan(440));
      await tester.enterText(key('resolution-width'), '3072');
      await tester.enterText(key('resolution-height'), '3072');
      await tester.pumpAndSettle();
      expect(find.text('超限'), findsOneWidget);
      for (final label in ['缩到上限', '缩到免费']) {
        final match = find.widgetWithText(FilledButton, label);
        expect(
          find.descendant(of: match, matching: find.byIcon(Icons.compress)),
          findsOneWidget,
        );
        final shape = tester
            .widget<FilledButton>(match)
            .style!
            .shape!
            .resolve({});
        expect(
          (shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(10),
        );
      }
      await captureDesktop(tester, capture, 'resolution-fit-buttons');
      await tester.tap(find.text('缩到上限'));
      await tester.pumpAndSettle();
      expect(find.text('超限'), findsNothing);
      await tester.tap(find.text('缩到免费'));
      await tester.pumpAndSettle();
      expect(find.text('免费'), findsOneWidget);
      await tester.tapAt(
        grid.topLeft + Offset(grid.width * .5, grid.height * .25),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '1536',
      );
      expect(
        tester.widget<TextField>(key('resolution-height')).controller!.text,
        '768',
      );
      expect(containerSize(c), (832, 1216));
      await tester.tap(key('resolution-confirm'));
      await tester.pumpAndSettle();
      expect(containerSize(c), (1536, 768));
      await finish(tester);
    },
  );
  testWidgets('Escape and outside click discard unconfirmed dimensions', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('大图'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(key('desktop-popover'), findsNothing);
    expect(c.read(generateProvider).params.width, 832);
    await tester.tap(find.text('打开分辨率'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.enterText(key('resolution-width'), '1024');
    await tester.tapAt(const Offset(900, 50));
    await tester.pumpAndSettle();
    expect(key('desktop-popover'), findsNothing);
    expect(c.read(generateProvider).params.width, 832);
    await finish(tester);
  });
}

(int, int) containerSize(ProviderContainer container) {
  final p = container.read(generateProvider).params;
  return (p.width, p.height);
}
