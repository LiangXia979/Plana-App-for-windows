import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/auth/token_store.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/gen_settings.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/desktop_image_save.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/gallery/temporary_gallery_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/onboarding/desktop_guide_entry.dart';
import 'package:plana_app/features/onboarding/welcome_page.dart';
import 'package:plana_app/features/profile/network_settings_page.dart';

import 'support/pump_until.dart';
import 'support/desktop_capture.dart';

class _DirectoryPicker extends FilePicker {
  String? selection;
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => selection;
}

class _GuideSettings extends GenSettingsNotifier {
  Future<void> settled = Future.value();

  @override
  Future<void> patch(GenSettings Function(GenSettings) change) =>
      settled = super.patch(change);
}

void main() {
  late AppStores stores;
  late ProviderContainer container;
  bool disposed = false;
  final capture = GlobalKey();
  setUpAll(() async {
    FilePicker.platform = _DirectoryPicker();
    await loadDesktopCaptureFonts();
  });

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    FlutterSecureStorage.setMockInitialValues({});
    disposed = false;
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        genSettingsProvider.overrideWith(_GuideSettings.new),
      ],
    );
  });

  tearDown(() {
    if (!disposed) container.dispose();
    stores.flushNow();
    debugDefaultTargetPlatformOverride = null;
  });

  Finder key(String name) => find.byKey(ValueKey('desktop-welcome-$name'));
  Finder field(String hint) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == hint,
  );

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1000, 700),
    Size? paneSize,
    bool notify = true,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await stores.prefs.write(
        key: 'gen_settings',
        value: jsonEncode(GenSettings(genNotify: notify).toJson()),
      );
      await Future.wait([
        container.read(genSettingsProvider.future),
        container.read(authModeProvider.future),
        container.read(tokenProvider.future),
        container.read(botSessionProvider.future),
      ]);
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              final theme = ref.watch(themeSettingsProvider);
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: AppTheme.light(theme.seed.color).copyWith(
                  textTheme: AppTheme.light(
                    theme.seed.color,
                  ).textTheme.apply(fontFamily: 'Microsoft YaHei'),
                ),
                darkTheme: AppTheme.dark(theme.seed.color).copyWith(
                  textTheme: AppTheme.dark(
                    theme.seed.color,
                  ).textTheme.apply(fontFamily: 'Microsoft YaHei'),
                ),
                themeMode: theme.mode,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Align(
                    child: SizedBox(
                      width: paneSize?.width,
                      height: paneSize?.height,
                      child: Navigator(
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (context) => Scaffold(
                            body: Column(
                              children: [
                                const Text('原设置页'),
                                TextButton(
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          const WelcomePage(replay: true),
                                    ),
                                  ),
                                  child: const Text('重新查看引导'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新查看引导'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> access(WidgetTester tester) async {
    await tap(tester, key('next'));
    await tap(tester, key('next'));
    expect(find.text('生成接入方式'), findsOneWidget);
  }

  Future<void> settleSettings(WidgetTester tester) async {
    var done = false;
    unawaited(
      (container.read(genSettingsProvider.notifier) as _GuideSettings).settled
          .then((_) => done = true),
    );
    await pumpUntil(tester, () => done);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    disposed = true;
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      '${platform.name}: six steps, no notification prompt, completion returns',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final notify = platform == TargetPlatform.windows;
        await mount(tester, notify: notify);
        expect(find.text('欢迎使用 Plana'), findsOneWidget);
        expect(find.text('从图片继续创作'), findsOneWidget);
        expect(find.text('NovelAI 移动创作端'), findsNothing);
        expect(find.byType(PageView), findsNothing);
        await access(tester);
        await tap(tester, key('skip'));
        expect(find.text('跳过扩展'), findsOneWidget);
        await tap(tester, key('next'));
        expect(find.text('第 5 步，共 6 步 · 保存与图库'), findsOneWidget);
        await tap(tester, key('next'));
        expect(find.text('第 6 步，共 6 步 · 完成与速查'), findsOneWidget);
        expect(
          find.text('浏览使用手册'),
          platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
        );
        expect(find.text('设置完成'), findsOneWidget);
        expect(find.text('暂未配置'), findsOneWidget);
        expect(find.text('生成进度通知'), findsNothing);
        expect(find.text('开启通知'), findsNothing);
        expect(find.text('暂不开启'), findsNothing);
        await tap(tester, key('next'));
        expect(find.text('原设置页'), findsOneWidget);
        expect(find.byType(WelcomePage), findsNothing);
        expect(container.read(genSettingsProvider).value!.notifyPrimed, isTrue);
        expect(container.read(genSettingsProvider).value!.genNotify, notify);
        await settleSettings(tester);
        await tester.runAsync(() async {
          final saved = jsonDecode(
            (await stores.prefs.read(key: 'gen_settings'))!,
          );
          expect(saved['notifyPrimed'], isTrue);
          expect(saved['genNotify'], notify);
        });
        await finish(tester);
      },
    );
  }

  testWidgets('step navigation and dragging cannot bypass token or Bot setup', (
    tester,
  ) async {
    await mount(tester);
    expect(tester.widget<ListTile>(key('step-4')).enabled, isFalse);
    await tap(tester, key('step-4'));
    expect(find.text('第 1 步，共 6 步 · 欢迎'), findsOneWidget);
    await access(tester);
    expect(tester.widget<FilledButton>(key('next')).onPressed, isNull);
    expect(tester.widget<ListTile>(key('step-3')).enabled, isFalse);
    await tap(tester, key('step-3'));
    await tester.drag(key('content'), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 3 步，共 6 步 · 生成接入'), findsOneWidget);
    await tap(tester, find.text('用 Bot 账户生成'));
    await tap(tester, key('next'));
    expect(find.text('第 4 步，共 6 步 · Bot 授权与扩展'), findsOneWidget);
    expect(find.text('授权 Bot 以生成图片'), findsOneWidget);
    expect(find.textContaining('在下一步授权'), findsNothing);
    expect(tester.widget<FilledButton>(key('next')).onPressed, isNull);
    expect(key('skip'), findsNothing);
    expect(tester.widget<ListTile>(key('step-4')).enabled, isFalse);
    await tap(tester, key('step-4'));
    expect(find.text('第 4 步，共 6 步 · Bot 授权与扩展'), findsOneWidget);
    await tap(tester, key('back'));
    expect(find.text('第 3 步，共 6 步 · 生成接入'), findsOneWidget);
    await finish(tester);
  });

  testWidgets(
    'form drafts and theme survive back navigation and window resize',
    (tester) async {
      await mount(tester);
      await access(tester);
      await tap(tester, find.text('第三方'));
      await tester.enterText(
        field('https://example.com'),
        'https://relay.example',
      );
      await tester.enterText(field('接口 key'), 'draft-key');
      await tap(tester, key('step-1'));
      await tap(tester, find.text('深色'));
      await tap(tester, find.byTooltip('紫'));
      tester.view.physicalSize = const Size(480, 360);
      await tester.pumpAndSettle();
      expect(key('navigation'), findsNothing);
      await tap(tester, key('next'));
      expect(
        tester.widget<TextField>(field('接口 key')).controller!.text,
        'draft-key',
      );
      expect(
        tester.widget<TextField>(field('https://example.com')).controller!.text,
        'https://relay.example',
      );
      expect(container.read(themeSettingsProvider).mode, ThemeMode.dark);
      expect(container.read(themeSettingsProvider).seedKey, 'violet');
      await tap(tester, key('back'));
      expect(find.text('外观配色'), findsOneWidget);
      expect(
        tester
            .widget<SegmentedButton<ThemeMode>>(
              find.byType(SegmentedButton<ThemeMode>),
            )
            .selected,
        {ThemeMode.dark},
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'small pane uses its own width; fields scroll while footer stays accessible',
    (tester) async {
      await mount(
        tester,
        size: const Size(1280, 800),
        paneSize: const Size(480, 360),
        textScale: 1.3,
      );
      expect(key('navigation'), findsNothing);
      await access(tester);
      await tap(tester, find.text('第三方'));
      final footer = tester.getRect(key('footer'));
      final input = field('接口 key');
      await tester.ensureVisible(input);
      await tester.enterText(input, 'relay-key');
      await tester.ensureVisible(field('https://example.com'));
      await tester.enterText(
        field('https://example.com'),
        'https://relay.example/',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull,
      );
      await tap(tester, find.widgetWithText(FilledButton, '保存'));
      expect(tester.getRect(key('footer')).bottom, footer.bottom);
      expect(
        tester.getRect(key('footer')).contains(tester.getCenter(key('next'))),
        isTrue,
      );
      for (
        var i = 0;
        i < 200 &&
            (container.read(naiKeysStoreProvider).value?.isEmpty ?? true);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      final saved = container.read(naiKeysStoreProvider).value;
      expect(saved!.single.token, 'relay-key');
      expect(saved.single.endpoint, 'https://relay.example');
      expect(key('skip'), findsNothing);
      await tap(tester, key('next'));
      await tap(tester, key('next'));
      await tap(tester, key('next'));
      expect(find.textContaining('第三方 · '), findsOneWidget);
      await tap(tester, key('next'));
      expect(find.text('原设置页'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'replay reads saved preferences; folder cancellation, changing and clearing are distinct',
    (tester) async {
      final picker = _DirectoryPicker();
      final original = FilePicker.platform;
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = original);
      await tester.runAsync(() async {
        await container
            .read(desktopSaveDirectoryProvider.notifier)
            .select('D:/Art');
        await container.read(saveSettingsProvider.future);
        await container
            .read(saveSettingsProvider.notifier)
            .patch((x) => x.copyWith(format: SaveFormat.webp));
      });
      await mount(tester);
      await access(tester);
      await tap(tester, key('skip'));
      await tap(tester, key('next'));
      expect(find.text('D:/Art'), findsOneWidget);
      expect(
        tester
            .widget<SegmentedButton<SaveFormat>>(
              find.byType(SegmentedButton<SaveFormat>),
            )
            .selected,
        {SaveFormat.webp},
      );
      await tap(tester, find.text('选择文件夹'));
      expect(container.read(desktopSaveDirectoryProvider), 'D:/Art');
      picker.selection = 'D:/Illustrations';
      await tap(tester, find.text('选择文件夹'));
      await pumpUntil(
        tester,
        () => container.read(desktopSaveDirectoryProvider) == picker.selection,
      );
      await tap(tester, find.text('恢复未指定'));
      await pumpUntil(
        tester,
        () => container.read(desktopSaveDirectoryProvider) == null,
      );
      await tap(tester, find.text('JPG'));
      await pumpUntil(
        tester,
        () =>
            container.read(saveSettingsProvider).value?.format ==
            SaveFormat.jpg,
      );
      expect(find.textContaining('JPG 不保留'), findsOneWidget);
      await tap(tester, key('next'));
      expect(find.text('首次保存时选择 · JPG'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'current gallery and future canvas default are independent, survive replay and preserve the standard destination',
    (tester) async {
      await mount(tester);
      final workspace = container.read(canvasWorkspaceProvider.notifier);
      final first = container.read(canvasWorkspaceProvider).activeId;
      final other = workspace.create();
      workspace.select(first);
      container.read(desktopLibraryProvider.notifier).choose(null);
      await tester.pumpAndSettle();
      await access(tester);
      await tap(tester, key('skip'));
      await tap(tester, key('next'));
      await tap(tester, find.text('临时图库'));
      await pumpUntil(
        tester,
        () => container.read(temporaryOptionsProvider).canvases.contains(first),
      );
      expect(container.read(temporaryOptionsProvider).canvases, {first});
      expect(
        find.byKey(const ValueKey('desktop-guide-temp-detail')),
        findsOneWidget,
      );
      await tap(tester, find.text('新建画布也默认使用临时图库'));
      await tap(tester, find.text('标准图库'));
      expect(
        find.byKey(const ValueKey('desktop-guide-temp-detail')),
        findsNothing,
      );
      expect(container.read(temporaryOptionsProvider).canvases, isEmpty);
      expect(container.read(desktopLibraryProvider).choice, '');
      await tap(tester, key('next'));
      expect(find.textContaining('标准图库 · 全部作品 · 新画布默认临时图库'), findsOneWidget);
      await tap(tester, key('next'));
      final created = workspace.create();
      final duplicate = workspace.create(duplicate: true);
      final restored = workspace.createFrom(
        container.read(canvasWorkspaceProvider).active.prompts,
        from: '恢复',
      );
      container.invalidate(temporaryOptionsProvider);
      final options = container.read(temporaryOptionsProvider);
      expect(options.temporaryForNewCanvases, isTrue);
      expect(options.canvases, {created, duplicate, restored});
      expect(options.canvases.contains(other), isFalse);
      await finish(tester);
    },
  );

  testWidgets(
    'official proxy opens the real settings and returns to the same guide step',
    (tester) async {
      await mount(tester);
      await access(tester);
      await tap(tester, find.text('本机代理快速配置'));
      expect(
        tester
            .widget<NetworkSettingsPage>(find.byType(NetworkSettingsPage))
            .initiallyExpanded,
        isTrue,
      );
      await tap(tester, find.byType(BackButton));
      expect(find.text('第 3 步，共 6 步 · 生成接入'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets('manual opens from the last step and returns to that step', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const manual = MethodChannel('plana/user_manual');
    final root = stores.temporaryGallery.root.parent.path;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(paths, (call) async => root);
    messenger.setMockMethodCallHandler(manual, (call) async {
      calls.add(call.method);
      if (call.method == 'open') {
        expect((call.arguments as List).first.toString(), startsWith(root));
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(manual, null);
    });
    Future<Map> request(String method) async {
      final done = Completer<Map>();
      await messenger.handlePlatformMessage(
        manual.name,
        manual.codec.encodeMethodCall(
          MethodCall('request', jsonEncode({'id': 1, 'method': method})),
        ),
        (data) => done.complete(
          jsonDecode(manual.codec.decodeEnvelope(data!)) as Map,
        ),
      );
      return done.future;
    }

    await mount(tester);
    await access(tester);
    await tap(tester, key('skip'));
    await tap(tester, key('next'));
    await tap(tester, key('next'));
    await tap(tester, find.text('浏览使用手册'));
    await pumpUntil(tester, () => calls.contains('open'));
    final response = await pumpUntilComplete(tester, request('load'));
    expect(response['value']['returnToGuide'], isTrue);
    await pumpUntilComplete(tester, request('back'));
    expect(calls, ['open', 'close']);
    expect(find.text('第 6 步，共 6 步 · 完成与速查'), findsOneWidget);
    await finish(tester);
  });

  for (final action in ['open', 'dismiss', 'untouched', 'existing']) {
    testWidgets('creation entry $action and restart', (tester) async {
      final app = UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: const DesktopGuideEntry(active: true)),
        ),
      );
      if (action == 'existing') {
        await tester.runAsync(
          () => container.read(authModeProvider.notifier).set(AuthMode.token),
        );
      }
      await tester.pumpWidget(app);
      if (action != 'existing') {
        await pumpUntil(
          tester,
          () => find.text('打开使用引导').evaluate().isNotEmpty,
        );
        if (action == 'open') {
          await tap(tester, find.text('打开使用引导'));
          await access(tester);
          await tap(tester, key('skip'));
          await tap(tester, key('next'));
          await tap(tester, key('next'));
          expect(find.text('开始创作'), findsOneWidget);
          await tap(tester, key('next'));
          expect(find.byType(WelcomePage), findsNothing);
        } else if (action == 'dismiss') {
          await tap(tester, find.byIcon(Icons.close));
        }
      }
      if (action != 'untouched') {
        expect(find.text('打开使用引导'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      if (action == 'untouched') {
        await pumpUntil(
          tester,
          () => find.text('打开使用引导').evaluate().isNotEmpty,
        );
        expect(find.text('打开使用引导'), findsOneWidget);
      } else {
        expect(find.text('打开使用引导'), findsNothing);
      }
      await finish(tester);
    });
  }

  for (final scale in [1.0, 1.4]) {
    testWidgets('Windows welcome visual layout at scale $scale', (
      tester,
    ) async {
      await mount(tester, textScale: scale);
      await captureDesktop(
        tester,
        capture,
        'guide-welcome-${(scale * 100).round()}',
      );
      await access(tester);
      await captureDesktop(
        tester,
        capture,
        'guide-access-${(scale * 100).round()}',
      );
      await tap(tester, key('skip'));
      await tap(tester, key('next'));
      await captureDesktop(
        tester,
        capture,
        'guide-storage-${(scale * 100).round()}',
      );
      await tap(tester, key('next'));
      await captureDesktop(
        tester,
        capture,
        'guide-summary-${(scale * 100).round()}',
      );
      await finish(tester);
    });
  }

  for (final escape in [false, true]) {
    testWidgets(
      'replay can exit early via ${escape ? 'Escape' : 'return button'}',
      (tester) async {
        await mount(tester, notify: false);
        await tap(tester, key('next'));
        await tap(tester, find.text('深色'));
        if (escape) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        } else {
          await tap(tester, key('close'));
        }
        expect(find.text('原设置页'), findsOneWidget);
        expect(find.byType(WelcomePage), findsNothing);
        expect(
          container.read(genSettingsProvider).value!.notifyPrimed,
          isFalse,
        );
        expect(container.read(genSettingsProvider).value!.genNotify, isFalse);
        expect(container.read(themeSettingsProvider).mode, ThemeMode.dark);
        await finish(tester);
      },
    );
  }
}
