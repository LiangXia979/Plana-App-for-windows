import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/setting_row.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/rules_page.dart';
import 'package:plana_app/features/assistant/rules_preset_detail_page.dart';
import 'package:plana_app/features/assistant/widgets/settings_sheet.dart';
import 'package:plana_app/features/inspiration/external/oc_sources.dart';
import 'package:plana_app/features/inspiration/external/oc_catalog.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/profile/widgets/settings_ui.dart';
import 'package:flutter/services.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

void main() {
  late AppStores stores;
  late ProviderContainer c;
  var botAuthorized = false;
  final sources = <OcSource>[];
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    botAuthorized = false;
    sources.clear();
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        ocSourcesProvider.overrideWith((_) async => [...sources]),
        assistantBotAuthorizedProvider.overrideWith((ref) => botAuthorized),
        assistantEndpointProvider.overrideWithValue(
          const CustomEndpoint(
            id: 'synthetic',
            name: '合成接口',
            baseUrl: 'https://example.test',
            apiKey: '',
            model: 'synthetic',
            format: AgentApiFormat.openai,
          ),
        ),
      ],
    );
    await c.read(assistantSettingsProvider.future);
    await c.read(rulesLibraryProvider.future);
    await Future.wait(
      RulesFamily.values.map((f) => c.read(defaultRulesProvider(f).future)),
    );
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });

  Future<void> mount(
    WidgetTester tester,
    Widget page,
    double scale, {
    Size size = const Size(1000, 780),
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(
                fontFamily: 'Microsoft YaHei',
                fontFamilyFallback: const ['Microsoft YaHei'],
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: page,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  Future<void> dragCard(
    WidgetTester tester,
    Offset from,
    double distance, {
    Duration hold = const Duration(milliseconds: 550),
  }) async {
    final mouse = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(hold);
    for (var step = 1; step <= 10; step++) {
      await mouse.moveTo(from + Offset(0, distance * step / 10));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await mouse.up();
    await tester.pumpAndSettle();
  }

  testWidgets('规则状态随画布的绘图模型切换', (tester) async {
    final n = c.read(rulesLibraryProvider.notifier);
    await tester.runAsync(() async {
      await n.use(RulesFamily.nai45, 'default-semantic-nai45');
      await n.use(RulesFamily.nai5, 'default-semantic-lite-nai5');
    });
    c.read(generateProvider.notifier).setModel('NAI 4.5 Full');
    await mount(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => showAssistantSettings(context),
            child: const Text('打开设置'),
          ),
        ),
      ),
      1,
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('资料与规则'));
    await tester.pumpAndSettle();
    expect(find.text('语义分块'), findsOneWidget);
    c.read(generateProvider.notifier).setModel('NAI 5.0 Full');
    await tester.pumpAndSettle();
    expect(find.text('语义分块 · 轻量版'), findsOneWidget);
    await captureDesktop(tester, capture, 'rules-active-semantic-lite');
    tester.view.physicalSize = const Size(440, 640);
    final name = '我常用的规则预设' * 10;
    await tester.runAsync(
      () => n.add(
        name: name,
        author: '',
        models: {RulesFamily.nai5},
        rules: const [],
        enableFor: RulesFamily.nai5,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(name), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => n.use(RulesFamily.nai5, null));
    await tester.pumpAndSettle();
    expect(find.text('未启用'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('编辑内置语义预设产生副本，只替换正在启用的同一份原件', (tester) async {
    final n = c.read(rulesLibraryProvider.notifier);
    const full = 'default-semantic-nai5', lite = 'default-semantic-lite-nai5';
    await tester.runAsync(() => n.use(RulesFamily.nai5, full));
    for (final id in [lite, full]) {
      await mount(
        tester,
        RulesPresetDetailPage(key: ValueKey(id), presetId: id),
        1,
      );
      final toggle = find.byIcon(Icons.power_settings_new).first;
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final lib = c.read(rulesLibraryProvider).requireValue;
      final original = lib.bundled.singleWhere((p) => p.id == id);
      final copy = lib.presets.last;
      expect(copy.name, contains(original.name));
      expect(copy.rules.length, 15);
      expect(copy.rules.first.content, original.rules.first.content);
      expect(copy.rules.first.enabled, !original.rules.first.enabled);
      expect(lib.activeFor(RulesFamily.nai5)?.id, id == full ? copy.id : full);
    }
    await finish(tester);
  });

  testWidgets(
    'preset power buttons switch the entire preset without editing sections',
    (tester) async {
      const a = RulesFamily.nai45, b = RulesFamily.nai5;
      final n = c.read(rulesLibraryProvider.notifier);
      final joint = (await tester.runAsync(
        () => n.add(
          name: '两代',
          author: '',
          models: {a, b},
          rules: const [
            PresetRule(name: 'role', content: 'yes'),
            PresetRule(name: 'style', content: 'off', enabled: false),
          ],
        ),
      ))!;
      await mount(
        tester,
        const RulesPresetPage(),
        1,
        size: const Size(1000, 800),
      );
      RulesLibrary lib() => c.read(rulesLibraryProvider).requireValue;
      Future<void> press(String id) async {
        final icon = find.descendant(
          of: find.byKey(ValueKey(id)),
          matching: find.byIcon(Icons.power_settings_new),
        );
        await tester.ensureVisible(icon);
        await tester.tap(icon);
        await tester.pumpAndSettle();
        expect(find.byType(RulesPresetDetailPage), findsNothing);
      }

      await press(defaultPresetOf(b).id);
      expect(lib().activeFor(b), isNull);
      expect(lib().customRulesFor(b), isEmpty);
      expect(lib().activeFor(a)?.isDefault, true);
      await press(joint);
      expect(lib().enabledFor(joint), {a, b});
      await press('default-semantic-nai45');
      await press(joint);
      expect(lib().enabledFor('default-semantic-nai45'), {a});
      expect(lib().activeFor(b), isNull);
      expect(
        lib().presets
            .singleWhere((p) => p.id == joint)
            .rules
            .map((r) => r.enabled),
        [true, false],
      );
      expect(RulesLibrary.fromJson(lib().toJson()).activeFor(b), isNull);
      await press(defaultPresetOf(b).id);
      expect(lib().activeFor(b)?.isDefault, true);
      await finish(tester);
    },
  );

  testWidgets(
    'preset list cards reorder on mouse drag and open on a click',
    (tester) async {
      final n = c.read(rulesLibraryProvider.notifier);
      final first = (await tester.runAsync(
        () => n.add(
          name: '预设甲',
          author: '作者甲',
          models: {RulesFamily.nai45},
          rules: const [],
        ),
      ))!;
      final last = (await tester.runAsync(
        () => n.add(
          name: '预设乙',
          author: '作者乙',
          models: {RulesFamily.nai5},
          rules: const [],
        ),
      ))!;
      await tester.runAsync(() => n.use(RulesFamily.nai5, last));
      await mount(
        tester,
        const RulesPresetPage(),
        1,
        size: const Size(1404, 840),
      );
      List<String> order() => c
          .read(rulesLibraryProvider)
          .requireValue
          .all
          .map((p) => p.id)
          .toList();
      final builtin = [
        for (final f in RulesFamily.values) defaultPresetOf(f).id,
        for (final variant in ['semantic', 'semantic-lite'])
          for (final f in RulesFamily.values) 'default-$variant-${f.name}',
      ];
      final a = find.text('预设甲');
      final b = find.text('预设乙');
      final gap = tester.getCenter(b).dy - tester.getCenter(a).dy;
      final bottomCard = find.byKey(ValueKey(last));
      final blank = tester.getRect(bottomCard).center;
      await dragCard(tester, blank, -gap);
      expect(order(), [...builtin, last, first]);
      expect(tester.getCenter(b).dy, lessThan(tester.getCenter(a).dy));
      expect(find.byType(RulesPresetDetailPage), findsNothing);
      await captureDesktop(tester, capture, 'rules-presets-reordered');
      await dragCard(tester, tester.getCenter(b), gap, hold: Duration.zero);
      expect(order(), [...builtin, first, last]);
      final badge = find.descendant(
        of: bottomCard,
        matching: find.text('NAI 5'),
      );
      await dragCard(tester, tester.getCenter(badge), -2 * gap);
      expect(order(), [
        ...builtin.take(builtin.length - 1),
        last,
        builtin.last,
        first,
      ]);
      expect(
        c
            .read(rulesLibraryProvider)
            .requireValue
            .activeFor(RulesFamily.nai5)
            ?.id,
        last,
      );
      final delete = find.descendant(
        of: bottomCard,
        matching: find.byTooltip('删除'),
      );
      await dragCard(tester, tester.getCenter(delete), gap);
      expect(order(), [
        ...builtin.take(builtin.length - 1),
        last,
        builtin.last,
        first,
      ]);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(b);
      await tester.pumpAndSettle();
      expect(find.byType(RulesPresetDetailPage), findsOneWidget);
      await finish(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'preset name starts fully selected only when the dialog opens',
    (tester) async {
      await mount(tester, const RulesPresetPage(), 1);
      await tester.tap(find.byTooltip('新建预设'));
      await tester.pumpAndSettle();
      final nameRow = find.widgetWithText(SettingsRow, '预设名称');
      await tester.tap(nameRow);
      await tester.pumpAndSettle();
      EditableText field() =>
          tester.widget<EditableText>(find.byType(EditableText));
      void expectSelected(String text) {
        expect(field().focusNode.hasFocus, isTrue);
        expect(field().controller.text, text);
        expect(
          field().controller.selection,
          TextSelection(baseOffset: 0, extentOffset: text.length),
        );
      }

      expectSelected('新建预设');
      await captureDesktop(tester, capture, 'rules-preset-name-selected');
      final value = field().controller.value;
      tester.testTextInput.updateEditingValue(
        value.replaced(value.selection, '猫猫的预设'),
      );
      await tester.pump();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      await tester.tap(nameRow);
      await tester.pumpAndSettle();
      expectSelected('猫猫的预设');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(field().controller.selection.isCollapsed, isTrue);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        c.read(rulesLibraryProvider).requireValue.presets.single.name,
        '猫猫的预设',
      );
      await finish(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'new preset opens directly and each model choice is saved in place',
    (tester) async {
      await mount(tester, const RulesPresetPage(), 1);
      final add = find.byTooltip('新建预设');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(RulesPresetDetailPage), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      RulesLibrary library() => c.read(rulesLibraryProvider).requireValue;
      expect(library().presets, isEmpty);

      await tester.tap(add);
      await tester.pumpAndSettle();
      final enabledRow = find.widgetWithText(SettingsRow, '启用的模型');
      final supportedRow = find.widgetWithText(SettingsRow, '支持的模型');
      Finder option(RulesFamily f) =>
          find.widgetWithText(CheckboxMenuButton, rulesFamilyLabel(f));
      final first = option(RulesFamily.nai45);
      final second = option(RulesFamily.nai5);
      await tester.tap(enabledRow);
      await tester.pumpAndSettle();
      final field = tester.getRect(enabledRow);
      final menu = tester.getRect(first);
      expect(menu.top, greaterThanOrEqualTo(field.bottom));
      expect(menu.right, closeTo(field.right, 2));
      expect(menu.width, lessThan(220));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('确认'), findsNothing);
      await tester.tap(first);
      await tester.pumpAndSettle();
      final id = library().presets.single.id;
      expect(library().activeFor(RulesFamily.nai45)?.id, id);
      expect(tester.widget<CheckboxMenuButton>(first).value, isTrue);
      await tester.tap(second);
      await tester.pumpAndSettle();
      expect(library().activeFor(RulesFamily.nai5)?.id, id);
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(library().activeFor(RulesFamily.nai45), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(first, findsNothing);

      await tester.tap(supportedRow);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(first).top,
        greaterThanOrEqualTo(tester.getRect(supportedRow).bottom),
      );
      await tester.tap(second);
      await tester.pumpAndSettle();
      expect(library().presets.single.models, {RulesFamily.nai45});
      expect(library().activeFor(RulesFamily.nai5)?.isDefault, isTrue);
      expect(tester.widget<CheckboxMenuButton>(first).onChanged, isNull);
      await tester.tap(second);
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'rules-preset-model-menu');
      await tester.tapAt(const Offset(30, 30));
      await tester.pumpAndSettle();
      expect(first, findsNothing);
      await tester.tap(enabledRow);
      await tester.pumpAndSettle();
      await tester.tap(second);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('预设名称'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '双模型规则');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await pumpUntilComplete(tester, stores.prefs.idle);
      final prefs = await tester.runAsync(
        () => PrefsStore.open(
          stores.desktopOutput.root.parent,
          legacyRead: (_) async => null,
        ),
      );
      final restored = ProviderContainer(
        overrides: [prefsStoreProvider.overrideWithValue(prefs!)],
      );
      addTearDown(restored.dispose);
      final saved = (await tester.runAsync(
        () => restored.read(rulesLibraryProvider.future),
      ))!;
      expect(saved.presets.single.name, '双模型规则');
      expect(saved.presets.single.models, RulesFamily.values.toSet());
      expect(saved.activeFor(RulesFamily.nai5)?.id, id);
      expect(saved.activeFor(RulesFamily.nai45), isNull);
      expect(find.byType(SegmentedButton<RulesFamily>), findsNothing);
      final name = tester.getRect(find.text('双模型规则'));
      final badge = tester.getRect(find.text('NAI 4.5').last);
      final badge2 = tester.getRect(find.text('NAI 5').last);
      expect(badge.left, greaterThan(name.right));
      expect(badge.center.dy, closeTo(name.center.dy, 2));
      expect(badge2.left, greaterThan(badge.right));
      final builtinTag = tester.getRect(find.text('默认').first);
      final builtinModel = tester.getRect(find.text('NAI 4.5').first);
      expect(builtinModel.left, greaterThan(builtinTag.right));
      expect(builtinModel.center.dy, closeTo(builtinTag.center.dy, 2));
      await captureDesktop(tester, capture, 'rules-preset-inline-badges');
      await finish(tester);
    },
  );

  testWidgets('a local preset is editable in its own collapsible group', (
    tester,
  ) async {
    await mount(tester, const RulesPresetPage(), 1);
    await tester.tap(find.byTooltip('新建预设'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('破限'));
    await tester.pumpAndSettle();
    expect(find.text('启用的模型'), findsOneWidget);
    expect(find.textContaining('仅自定义 API'), findsOneWidget);
    final library = c.read(rulesLibraryProvider).requireValue;
    expect(library.presets.single.localOnly, true);
    await tester.pageBack();
    await tester.pumpAndSettle();
    final group = find.text('破限（1）');
    await tester.dragUntilVisible(
      group.hitTestable(),
      find.byKey(const ValueKey('rules-preset-groups')),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text(library.presets.single.name), findsOneWidget);
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(find.text(library.presets.single.name), findsNothing);
    await finish(tester);
  });

  testWidgets(
    'a first section saves a named draft and the menu opens below in a short window',
    (tester) async {
      await mount(
        tester,
        const RulesPresetPage(),
        1.4,
        size: const Size(540, 378),
      );
      await tester.tap(find.byTooltip('新建预设'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('添加一段').hitTestable(),
        find.byType(ReorderableListView),
        const Offset(0, -100),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加一段'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '首段');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '从正文创建');
      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();
      final preset = c.read(rulesLibraryProvider).requireValue.presets.single;
      expect(preset.name, '新建预设');
      expect(preset.rules.single.content, '从正文创建');
      final row = find.widgetWithText(SettingsRow, '启用的模型');
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      final option = find.byType(CheckboxMenuButton).first;
      expect(
        tester.getRect(option).top,
        greaterThanOrEqualTo(tester.getRect(row).bottom),
      );
      expect(
        tester.getRect(option).right,
        closeTo(tester.getRect(row).right, 2),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新建预设'));
      await tester.pumpAndSettle();
      expect(find.text('新建预设 2'), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(c.read(rulesLibraryProvider).requireValue.presets.length, 1);
      await finish(tester);
    },
  );

  testWidgets(
    'desktop sections drag from title and body while buttons keep their own actions',
    (tester) async {
      const sections = [
        PresetRule(name: '第一段', content: '甲'),
        PresetRule(name: '第二段', content: '乙'),
        PresetRule(name: '第三段', content: '丙'),
      ];
      final id = await tester.runAsync(
        () => c
            .read(rulesLibraryProvider.notifier)
            .add(
              name: '段落操作',
              author: '',
              models: {RulesFamily.nai5},
              rules: sections,
            ),
      );
      await mount(tester, RulesPresetDetailPage(presetId: id!), 1);
      List<PresetRule> rules() =>
          c.read(rulesLibraryProvider).requireValue.presets.single.rules;
      List<String> order() => rules().map((r) => r.name).toList();
      expect(find.byIcon(Icons.drag_handle), findsNothing);
      final title = find.text('第一段');
      final distance =
          tester.getCenter(find.text('第二段')).dy - tester.getCenter(title).dy;
      await dragCard(tester, tester.getCenter(title), distance + 8);
      expect(order(), ['第二段', '第一段', '第三段']);
      final body = tester.getCenter(title) + const Offset(220, 14);
      await dragCard(tester, body, -distance - 8);
      expect(order(), ['第一段', '第二段', '第三段']);
      final toggle = find.byIcon(Icons.power_settings_new).first;
      final delete = find.byIcon(Icons.delete_outline).first;
      await dragCard(tester, tester.getCenter(toggle), distance + 8);
      await dragCard(tester, tester.getCenter(delete), distance + 8);
      expect(order(), ['第一段', '第二段', '第三段']);
      expect(rules().first.enabled, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('取消'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(rules().first.enabled, isFalse);
      await tester.tapAt(tester.getCenter(title) + const Offset(220, 14));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.power_settings_new), findsNothing);
      await tester.enterText(find.byType(TextField), '修改后的内容');
      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();
      expect(rules().first.content, '修改后的内容');
      expect(rules().first.enabled, isFalse);
      await tester.tap(title);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '改名段落');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(rules().first.name, '改名段落');
      await finish(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final (name, scale, size, dark) in [
    ('normal', 1.0, const Size(1000, 780), false),
    ('large-dark', 1.4, const Size(880, 540), true),
    ('narrow', 1.4, const Size(440, 640), false),
  ]) {
    testWidgets('desktop import dropdown applies all three modes: $name', (
      tester,
    ) async {
      stores.assistant.initialCurrent = const [
        AssistantMsg(
          id: 'import-reply',
          role: MsgRole.ai,
          text: '',
          at: 1,
          draw: DrawProposal(positive: 'new scene', negative: 'new negative'),
        ),
      ];
      final original = GenerateState.initial().copyWith(
        prompt: 'old scene',
        promptRaw: '<#scene: old scene#>',
        negativePrompt: 'old negative',
        sections: const [
          PromptSection.main(),
          PromptSection(id: 'style', name: '画风', positive: 'watercolor'),
        ],
      );
      c
          .read(generateProvider.notifier)
          .applyCanvas(CanvasPrompts.of(original), force: true);
      final before = PromptSnapshot.of(c.read(generateProvider));
      final assistant = c.read(assistantProvider.notifier);
      await mount(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showAssistantSettings(context),
                child: const Text('助手设置'),
              ),
            ),
          ),
        ),
        scale,
        size: size,
        dark: dark,
      );
      await tester.tap(find.text('助手设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      final dropdown = find.byKey(const ValueKey('assistant-import-dropdown'));
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final field = tester.getRect(dropdown);
      final firstOption = tester.getRect(find.byType(MenuItemButton).first);
      expect(field.height, greaterThanOrEqualTo(44));
      expect(field.width, greaterThan(200));
      expect(firstOption.top, greaterThanOrEqualTo(field.bottom));
      expect(firstOption.left, closeTo(field.left, 2));
      expect(firstOption.width, closeTo(field.width, 2));
      await captureDesktop(tester, capture, 'assistant-import-$name-menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        c.read(assistantSettingsProvider).value!.importTo,
        SectionImport.aiSection,
      );
      expect(
        find.byKey(const ValueKey('desktop-assistant-settings')),
        findsOneWidget,
      );

      for (final mode in SectionImport.values) {
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        final option = find.byKey(
          ValueKey('assistant-import-dropdown-option-$mode'),
        );
        await tester.ensureVisible(option);
        await tester.pumpAndSettle();
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(c.read(assistantSettingsProvider).value!.importTo, mode);
        expect(
          find.descendant(
            of: dropdown,
            matching: find.text(sectionImportLabel(mode)),
          ),
          findsOneWidget,
        );
        expect(
          PromptSnapshot.of(c.read(generateProvider)).sameAs(before),
          isTrue,
        );
        final preview = assistant.previewSendState('import-reply')!;
        expect(assistant.applyProposal('import-reply'), isTrue);
        final imported = c.read(generateProvider);
        expect(imported.prompt, switch (mode) {
          SectionImport.newSection || SectionImport.aiSection => 'old scene',
          SectionImport.appendMain => 'old scene, new scene',
          _ => 'new scene',
        });
        expect(imported.negativePrompt, 'old negative');
        expect(imported.sections.length, switch (mode) {
          SectionImport.main || SectionImport.appendMain => 2,
          SectionImport.newSection || SectionImport.aiSection => 3,
          SectionImport.clear => 0,
        });
        if (mode != SectionImport.clear) {
          expect(imported.sections[1].positive, 'watercolor');
        }
        if (mode == SectionImport.newSection) {
          expect(imported.sections.last.positive, 'new scene');
          expect(imported.sections.last.name, 'AI');
        }
        expect(composeSections(imported).prompt, preview.prompt);
        expect(
          composeSections(imported).negativePrompt,
          preview.negativePrompt,
        );
        expect(assistant.undo('import-reply'), isTrue);
        expect(
          PromptSnapshot.of(c.read(generateProvider)).sameAs(before),
          isTrue,
        );
      }

      await captureDesktop(tester, capture, 'assistant-import-$name-selected');
      final negative = find.widgetWithText(SettingRow, '允许 AI 修改负面提示词');
      expect(
        c.read(assistantSettingsProvider).value!.allowEditNegative,
        isFalse,
      );
      await tester.ensureVisible(negative);
      await tester.tap(negative);
      await tester.pumpAndSettle();
      expect(
        c.read(assistantSettingsProvider).value!.allowEditNegative,
        isTrue,
      );
      await tester.tap(find.byTooltip('关闭助手设置'));
      await tester.pumpAndSettle();
      c.invalidate(assistantSettingsProvider);
      await tester.runAsync(() => c.read(assistantSettingsProvider.future));
      expect(
        c.read(assistantSettingsProvider).value!.importTo,
        SectionImport.clear,
      );
      expect(
        c.read(assistantSettingsProvider).value!.allowEditNegative,
        isTrue,
      );
      await finish(tester);
    });
  }

  testWidgets(
    'the open scope menu tracks libraries, retains checks and supports mouse priority ordering',
    (tester) async {
      botAuthorized = true;
      OcSource source(String label) => OcSource(
        Uri.parse('https://example.test/fixtures'),
        label,
        OcCatalog('', [], false, ''),
        false,
      );
      final fixture = source('角色库');
      await mount(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showAssistantSettings(context),
              child: const Text('打开设置'),
            ),
          ),
        ),
        1,
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('资料与规则'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('assistant-library-dropdown')),
      );
      await tester.pumpAndSettle();
      sources.add(fixture);
      c.invalidate(ocSourcesProvider);
      await tester.pumpAndSettle();
      final check = find.byKey(ValueKey('library-check-${fixture.id}'));
      expect(tester.widget<CheckboxListTile>(check).value, isFalse);
      await tester.tap(check);
      await tester.pumpAndSettle();
      final handle = find.byKey(ValueKey('library-handle-${fixture.id}'));
      await dragCard(tester, tester.getCenter(handle), -52);
      expect(
        c.read(assistantSettingsProvider).requireValue.libraries.active([
          fixture.id,
        ], botAuthorized: true),
        [fixture.id, LibrarySelection.local],
      );
      expect(find.text('角色库 › 本地库'), findsOneWidget);
      await captureDesktop(tester, capture, 'assistant-ordered-libraries');
      sources[0] = source('新库名');
      c.invalidate(ocSourcesProvider);
      await tester.pumpAndSettle();
      expect(find.text('新库名 › 本地库'), findsOneWidget);
      sources.clear();
      c.invalidate(ocSourcesProvider);
      await tester.pumpAndSettle();
      expect(check, findsNothing);
      expect(find.byKey(const ValueKey('library-pause')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭助手设置'));
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  for (final (name, scale, size, dark) in [
    ('normal', 1.0, const Size(1000, 780), false),
    ('large-dark', 1.4, const Size(880, 540), true),
    ('narrow', 1.4, const Size(440, 640), false),
  ]) {
    testWidgets(
      'library menu anchors below and preserves authorization: $name',
      (tester) async {
        await tester.runAsync(
          () => c
              .read(assistantSettingsProvider.notifier)
              .patch((s) => s.copyWith(libraryScope: LibraryScope.all)),
        );
        await mount(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showAssistantSettings(context),
                  child: const Text('助手设置'),
                ),
              ),
            ),
          ),
          scale,
          size: size,
          dark: dark,
        );
        await tester.tap(find.text('助手设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('资料与规则'));
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('assistant-library-dropdown'));
        expect(
          find.descendant(of: field, matching: find.text('本地库')),
          findsOneWidget,
        );
        await tester.tap(field);
        await tester.pumpAndSettle();
        final buttonRect = tester.getRect(field);
        final pause = find.byKey(const ValueKey('library-pause'));
        final public = find.byKey(const ValueKey('library-check-public'));
        final local = find.byKey(const ValueKey('library-check-local'));
        final first = tester.getRect(pause);
        expect(first.top, greaterThanOrEqualTo(buttonRect.bottom));
        expect(first.left, closeTo(buttonRect.left, 2));
        expect(first.width, closeTo(buttonRect.width, 2));
        expect(tester.widget<CheckboxListTile>(public).onChanged, isNull);
        expect(find.text('需要 Bot 授权'), findsOneWidget);
        await captureDesktop(tester, capture, 'assistant-library-$name-menu');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(pause, findsNothing);
        botAuthorized = true;
        c.invalidate(assistantBotAuthorizedProvider);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: field, matching: find.text('本地库 › 公共库')),
          findsOneWidget,
        );
        tester.widget<OutlinedButton>(field).focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(tester.widget<CheckboxListTile>(public).onChanged, isNotNull);
        await tester.tap(pause);
        await tester.pumpAndSettle();
        expect(tester.widget<CheckboxListTile>(local).onChanged, isNull);
        expect(tester.widget<CheckboxListTile>(public).value, isTrue);
        expect(
          tester
              .widget<ReorderableDragStartListener>(
                find.byKey(const ValueKey('library-handle-local')),
              )
              .enabled,
          isFalse,
        );
        await tester.tap(pause);
        await tester.pumpAndSettle();
        await tester.ensureVisible(public);
        await tester.tap(public);
        await tester.pumpAndSettle();
        expect(tester.widget<CheckboxListTile>(public).value, isFalse);
        expect(tester.widget<CheckboxListTile>(local).value, isTrue);
        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
        expect(pause, findsNothing);
        expect(
          find.byKey(const ValueKey('desktop-assistant-settings')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('关闭助手设置'));
        await tester.pumpAndSettle();
        c.invalidate(assistantSettingsProvider);
        await tester.runAsync(() => c.read(assistantSettingsProvider.future));
        expect(c.read(assistantSettingsProvider).value!.libraries.enabled, {
          LibrarySelection.local,
        });
        await finish(tester);
      },
    );
  }

  for (final scale in [1.0, 1.4]) {
    testWidgets('desktop OC and sidebar settings persist at scale $scale', (
      tester,
    ) async {
      await mount(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showAssistantSettings(context),
                child: const Text('助手设置'),
              ),
            ),
          ),
        ),
        scale,
      );
      await tester.tap(find.text('助手设置'));
      await tester.pumpAndSettle();
      expect(
        c.read(assistantSettingsProvider).value!.showSidebarImagePicker,
        isTrue,
      );
      final images = find.widgetWithText(SettingRow, '添加图片');
      await tester.ensureVisible(images);
      await tester.tap(images);
      await tester.pumpAndSettle();
      final oc = find.widgetWithText(SettingRow, 'OC 使用占位符');
      await tester.ensureVisible(oc);
      await tester.tap(oc);
      await tester.pumpAndSettle();
      await captureDesktop(
        tester,
        capture,
        'windows53-assistant-${(scale * 100).round()}',
      );
      expect(c.read(assistantSettingsProvider).value!.ocPlaceholders, isTrue);
      await tester.tap(find.byTooltip('关闭助手设置'));
      await tester.pumpAndSettle();
      c.invalidate(assistantSettingsProvider);
      await tester.runAsync(() => c.read(assistantSettingsProvider.future));
      expect(
        c.read(assistantSettingsProvider).value!.showSidebarImagePicker,
        isFalse,
      );
      expect(
        c.read(assistantSettingsProvider).value!.showSidebarHistoryPicker,
        isTrue,
      );
      expect(c.read(assistantSettingsProvider).value!.ocPlaceholders, isTrue);
      await finish(tester);
    });

    testWidgets(
      'full rule editor rejects invalid YAML and saves in place at scale $scale',
      (tester) async {
        final n = c.read(rulesLibraryProvider.notifier);
        final id = await tester.runAsync(
          () => n.add(
            name: '合成规则',
            author: '',
            models: {RulesFamily.nai5},
            rules: const [PresetRule(name: 'role', content: 'old rule')],
          ),
        );
        await tester.runAsync(() => n.use(RulesFamily.nai5, id!));
        await mount(tester, const RulesPresetPage(), scale);
        await tester.tap(find.byTooltip('编辑').last);
        await tester.pumpAndSettle();
        final editor = find.byWidgetPredicate(
          (w) => w is TextField && w.expands,
        );
        await tester.enterText(
          editor,
          'sections:\n  - name: role\n    content: a: b\n',
        );
        await tester.tap(find.byTooltip('保存'));
        await tester.pumpAndSettle();
        expect(editor, findsOneWidget);
        expect(c.read(rulesLibraryProvider).value!.presets.single.name, '合成规则');
        final valid = encodeRulesFile(
          name: '合成规则 · 已编辑',
          author: '本地测试',
          models: {RulesFamily.nai5},
          rules: const [PresetRule(name: 'role', content: '保持角色设定，并使用自然的构图。')],
        );
        await tester.enterText(editor, valid);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await captureDesktop(
          tester,
          capture,
          'windows53-rules-${(scale * 100).round()}',
        );
        await tester.tap(find.byTooltip('保存'));
        for (
          var i = 0;
          i < 100 &&
              c.read(rulesLibraryProvider).value!.presets.single.name == '合成规则';
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        final library = c.read(rulesLibraryProvider).value!;
        expect(library.presets.single.id, id);
        expect(library.presets.single.name, '合成规则 · 已编辑');
        expect(library.active[RulesFamily.nai5], id);
        expect(editor, findsNothing);
        await finish(tester);
      },
    );
  }
}
