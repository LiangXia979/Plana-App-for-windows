import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plana_app/core/ui/desktop_text_selection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/editor/widgets/annotated_field.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/editor/widgets/fold_inspector.dart';
import 'package:plana_app/features/editor/widgets/tag_panel.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/desktop_prompt_card.dart';
import 'support/desktop_capture.dart';

void main() {
  late AppStores stores;
  late ProviderContainer container;
  late GenerateNotifier gen;
  final capture = GlobalKey();
  const raw = '<#画风: 0.4::artist:jyt::, {blue eyes}, ~hat~#>, sunrise';
  setUpAll(loadDesktopCaptureFonts);

  setUp(() async {
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: jsonEncode(
        const EditorSettings(
          enableCompletion: false,
          showTranslation: false,
        ).toJson(),
      ),
    );
    container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    gen = container.read(generateProvider.notifier);
    gen.setPrompts(positive: outputOf(raw), positiveRaw: raw);
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  Future<void> mount(
    WidgetTester tester, {
    String? charId,
    String? sectionId,
    bool dark = false,
    double scale = 1,
    double width = 380,
    double topPadding = 0,
  }) async {
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: DesktopTextSelection(child: child!),
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.only(top: topPadding),
                      child: DesktopPromptCard(
                        charId: charId,
                        sectionId: sectionId,
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
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Finder foldHit() => find.byWidgetPredicate(
    (widget) =>
        widget is GestureDetector &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('fold-hit-'),
  );
  Future<void> inspect(WidgetTester tester) async {
    await tester.tap(foldHit().first);
    await tester.pump();
    expect(
      find.byType(FoldInspector),
      findsOneWidget,
      reason: 'Inspection must not wait for the double-click timeout',
    );
    await tester.pumpAndSettle();
    expect(find.byType(FoldInspector), findsOneWidget);
  }

  Finder bodyField({bool positive = true}) {
    final large = find.byKey(ValueKey('studio-text-$positive'));
    return large.evaluate().isNotEmpty
        ? find.descendant(of: large, matching: find.byType(AnnotatedField))
        : find.descendant(
            of: find.byType(FoldInspector),
            matching: find.byType(AnnotatedField),
          );
  }

  for (final expanded in [false, true]) {
    testWidgets(
      'Ctrl-drag keeps both fragments inside the block editor (expanded=$expanded)',
      (tester) async {
        await mount(tester);
        await inspect(tester);
        if (expanded) {
          await tester.tap(find.byIcon(Icons.open_in_full));
          await tester.pumpAndSettle();
        }
        final field = tester.state<EditableTextState>(
          find.descendant(of: bodyField(), matching: find.byType(EditableText)),
        );
        Future<void> select(String word) async {
          await tester.pump(const Duration(milliseconds: 550));
          final render = field.renderEditable;
          final i = field.widget.controller.text.indexOf(word);
          Offset point(int offset) => render.localToGlobal(
            render.getLocalRectForCaret(TextPosition(offset: offset)).center,
          );
          final mouse = await tester.startGesture(
            point(i),
            kind: PointerDeviceKind.mouse,
          );
          await mouse.moveTo(
            Offset.lerp(point(i), point(i + word.length), .6)!,
          );
          await tester.pump();
          await mouse.moveTo(point(i + word.length));
          await tester.pump();
          await mouse.up();
          await tester.pumpAndSettle();
        }

        await select('artist:jyt');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await select('hat');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        final controller = field.widget.controller;
        final fragments = DesktopTextRanges.of(
          controller,
        ).selected.map((r) => r.textInside(controller.text)).toList();
        expect(fragments, [contains('artist:jyt'), contains('hat')]);
        expect(fragments.join(), isNot(contains('blue eyes')));
        await finish(tester);
      },
    );
  }

  testWidgets(
    'temporary block can acquire a negative side without adopting loose negatives',
    (tester) async {
      const link = PromptFoldLink(
        id: 'temp',
        temporaryCategory: 'artist-style',
        positiveName: '画风',
        positiveBody: '0.4::artist:jyt::, {blue eyes}, ~hat~',
        negativeName: '',
        negativeBody: '',
      );
      gen.setPrompts(
        positive: outputOf(raw),
        positiveRaw: raw,
        negative: 'watermark',
        negativeRaw: 'watermark',
        promptFoldLinks: [link],
      );
      await mount(tester);
      await inspect(tester);
      await tester.tap(find.byKey(const ValueKey('fold-inspector-负面')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnnotatedField>(bodyField()).controller.text,
        isEmpty,
      );
      expect(gen.state.promptFoldLinks.single, link);
      expect(gen.state.negativePrompt, 'watermark');
      await tester.enterText(
        find.descendant(of: bodyField(), matching: find.byType(TextField)),
        'extra limbs',
      );
      await tester.pumpAndSettle();
      final placed = gen.state.promptFoldLinks.single;
      expect(placed.id, link.id);
      expect(placed.temporaryCategory, 'artist-style');
      expect(placed.negativeBody, 'extra limbs');
      expect(gen.state.negativePrompt, 'watermark, extra limbs');
      expect(gen.state.promptRaw, raw);
      await tester.tap(find.byKey(const ValueKey('fold-inspector-正面')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnnotatedField>(bodyField()).controller.text,
        link.positiveBody,
      );
      await finish(tester);
    },
  );

  for (final library in [true, false]) {
    testWidgets(
      'one-sided block always offers both header tabs and lazily saves its own counterpart, library=$library',
      (t) async {
        final original = PromptFoldLink.forEntry(
          'local-style',
          positiveName: '画风',
          positiveBody: '0.4::artist:jyt::, {blue eyes}, ~hat~',
        );
        gen.setPrompts(
          positive: outputOf(raw),
          positiveRaw: raw,
          negative: 'loose negative',
          negativeRaw: 'loose negative',
          promptFoldLinks: [if (library) original],
        );
        await mount(t);
        await inspect(t);
        final inspector = find.byType(FoldInspector);
        final pos = find.byKey(const ValueKey('fold-inspector-正面'));
        final neg = find.byKey(const ValueKey('fold-inspector-负面'));
        final expand = find.descendant(
          of: inspector,
          matching: find.byIcon(Icons.open_in_full),
        );
        final unpack = find.descendant(
          of: inspector,
          matching: find.widgetWithText(TextButton, '解散为散词'),
        );
        final reset = find.descendant(
          of: inspector,
          matching: find.widgetWithText(TextButton, '重置权重'),
        );
        final disable = find.descendant(
          of: inspector,
          matching: find.widgetWithText(TextButton, '禁用整块'),
        );
        expect(
          t.getRect(reset).left - t.getRect(unpack).right,
          closeTo(t.getRect(unpack).left - t.getRect(disable).right, 1),
        );
        expect(t.getRect(pos).right, lessThan(t.getRect(neg).right));
        expect(t.getRect(neg).right, lessThan(t.getRect(expand).left));
        expect(t.getCenter(neg).dy, closeTo(t.getCenter(expand).dy, 2));
        expect(
          find.descendant(of: inspector, matching: find.text('完成')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('fold-whole-more')), findsNothing);
        await t.tap(neg);
        await t.pumpAndSettle();
        expect(t.widget<AnnotatedField>(bodyField()).controller.text, '');
        expect(gen.state.negativePromptRaw, 'loose negative');
        expect(gen.state.promptFoldLinks, [if (library) original]);
        await t.enterText(
          find.descendant(of: bodyField(), matching: find.byType(TextField)),
          '1.5::haze::',
        );
        await t.pumpAndSettle();
        final created = gen.state.promptFoldLinks.single;
        expect(created.paired, isTrue);
        expect(created.positiveName, '画风');
        expect(created.negativeBody, '1.5::haze::');
        expect(created.sourceEntryId, library ? original.sourceEntryId : null);
        expect(gen.state.promptRaw, raw);
        final scope = ProviderScope.containerOf(t.element(inspector));
        scope.read(editorProvider.notifier).undo();
        await t.pumpAndSettle();
        expect(t.widget<AnnotatedField>(bodyField()).controller.text, '');
        expect(gen.state.negativePrompt, 'loose negative');
        scope.read(editorProvider.notifier).redo();
        await t.pumpAndSettle();
        expect(
          t.widget<AnnotatedField>(bodyField()).controller.text,
          '1.5::haze::',
        );
        await t.tap(find.byKey(const ValueKey('fold-whole-clear-weight')));
        await t.pumpAndSettle();
        expect(gen.state.promptFoldLinks.single.negativeBody, 'haze');
        expect(gen.state.promptRaw, raw);
        await t.tap(pos);
        await t.pumpAndSettle();
        expect(
          t.widget<AnnotatedField>(bodyField()).controller.text,
          original.positiveBody,
        );
        await finish(t);
      },
    );
  }

  for (final temporary in [true, false]) {
    testWidgets(
      'disabled folded title is struck in the parent editor, temporary $temporary',
      (tester) async {
        final link = PromptFoldLink(
          id: 'placement',
          temporaryCategory: temporary ? 'artist-style' : null,
          sourceEntryId: temporary ? null : 'library',
          positiveName: '画风',
          positiveBody: '0.4::artist:jyt::, {blue eyes}, ~hat~',
          negativeName: '',
          negativeBody: '',
        );
        gen.setPrompts(
          positive: outputOf(raw),
          positiveRaw: raw,
          promptFoldLinks: [link],
        );
        await mount(tester);
        final parentField = find.byType(AnnotatedField);
        final editable = tester.state<EditableTextState>(
          find.descendant(of: parentField, matching: find.byType(EditableText)),
        );
        Iterable<TextSpan> titleSpans() =>
            (editable.renderEditable.text! as TextSpan).children!
                .whereType<TextSpan>()
                .where((span) => span.text?.contains('画风') == true);
        expect(
          titleSpans().single.style?.decoration,
          isNot(TextDecoration.lineThrough),
        );
        await inspect(tester);
        await tester.tap(
          find.descendant(
            of: find.byType(FoldInspector),
            matching: find.text('禁用整块'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          titleSpans().single.style?.decoration,
          TextDecoration.lineThrough,
        );
        expect(gen.state.prompt, 'sunrise');
        await captureDesktop(tester, capture, 'disabled-fold-$temporary');
        await tester.tap(
          find.descendant(
            of: find.byType(FoldInspector),
            matching: find.text('启用整块'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          titleSpans().single.style?.decoration,
          isNot(TextDecoration.lineThrough),
        );
        await tester.tap(
          find.descendant(
            of: find.byType(FoldInspector),
            matching: find.text('禁用整块'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .descendant(
                of: find.byType(FoldInspector),
                matching: find.byIcon(Icons.close),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('desktop-prompt-mode')));
        await tester.pumpAndSettle();
        final chip = find.descendant(
          of: find.byType(ChipFlowView),
          matching: find.text('画风'),
        );
        expect(
          tester.widget<Text>(chip).style?.decoration,
          TextDecoration.lineThrough,
        );
        await finish(tester);
      },
    );
  }

  testWidgets(
    'single click inspects and edits weighted text without unfolding; undo restores body',
    (tester) async {
      await mount(tester);
      final parent = tester
          .widget<AnnotatedField>(find.byType(AnnotatedField))
          .controller;
      final before = parent.text;
      await inspect(tester);
      await captureDesktop(tester, capture, 'fold-inspector-light');
      expect(parent.text, before);
      expect(gen.state.promptRaw, raw);
      final scoped = ProviderScope.containerOf(
        tester.element(find.byType(FoldInspector)),
      );
      expect(scoped.read(editorProvider).canUndo, isFalse);
      final body = find.descendant(
        of: bodyField(),
        matching: find.byType(TextField),
      );
      await tester.enterText(body, '0.7::artist:jyt::, {blue eyes}, ~hat~');
      await tester.pumpAndSettle();
      expect(parent.text, before);
      expect(
        gen.state.promptRaw,
        '<#画风: 0.7::artist:jyt::, {blue eyes}, ~hat~#>, sunrise',
      );
      scoped.read(editorProvider.notifier).undo();
      await tester.pumpAndSettle();
      expect(gen.state.promptRaw, raw);
      expect(
        tester.widget<AnnotatedField>(bodyField()).controller.text,
        '0.4::artist:jyt::, {blue eyes}, ~hat~',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'member click opens weight actions and applies changes inside the block',
    (tester) async {
      const body =
          '0.4::artist:jyt::, {blue eyes}, watercolor (medium), '
          'sunlight, year 2024, year 2025, soft colors, sky, clouds, '
          'best quality, very aesthetic, high detail';
      const positive = '<#画风: $body#>, sunrise';
      const negative = '<#画风·排除: lowres, blur#>';
      const link = PromptFoldLink(
        id: 'watercolor',
        positiveName: '画风',
        positiveBody: body,
        negativeName: '画风·排除',
        negativeBody: 'lowres, blur',
      );
      for (final (name, translation) in [
        ('artist:jyt', '画师 jyt'),
        ('blue eyes', '蓝眼睛'),
        ('watercolor (medium)', '水彩'),
        ('sunlight', '阳光'),
        ('clouds', '云'),
        ('soft colors', '柔和色彩'),
      ]) {
        cacheTagMeta(name, trans: translation);
      }
      gen.setPrompts(
        positive: outputOf(positive),
        positiveRaw: positive,
        negative: outputOf(negative),
        negativeRaw: negative,
        promptFoldLinks: [link],
      );
      await mount(tester);
      unawaited(
        container
            .read(editorSettingsProvider.notifier)
            .patch((s) => s.copyWith(showTranslation: true)),
      );
      await tester.pumpAndSettle();
      await inspect(tester);
      expect(find.text('正面 12'), findsOneWidget);
      final field = tester.widget<AnnotatedField>(bodyField());
      field.controller.selection = const TextSelection.collapsed(offset: 8);
      await tester.pumpAndSettle();
      final actions = find.byKey(const ValueKey('fold-member-actions'));
      expect(actions, findsOneWidget);
      expect(tester.widget<TagPanel>(actions).tok.tagMult, .4);
      await tester.tap(
        find.descendant(of: actions, matching: find.byIcon(Icons.add)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FoldInspector), findsOneWidget);
      expect(gen.state.promptRaw, contains('<#画风: 0.5::artist:jyt::'));
      expect(tester.widget<TagPanel>(actions).tok.tagMult, closeTo(.5, .00001));
      expect(find.byKey(const ValueKey('desktop-tag-popover')), findsOneWidget);
      final dock = tester.getRect(actions);
      expect(
        dock.top,
        greaterThanOrEqualTo(tester.getRect(bodyField()).bottom),
      );
      field.controller.selection = TextSelection.collapsed(
        offset: field.controller.text.indexOf('blue') + 1,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TagPanel>(actions).tok.name, 'blue eyes');
      expect(
        find.descendant(
          of: actions,
          matching: find.textContaining('蓝眼睛', findRichText: true),
        ),
        findsOneWidget,
      );
      expect(tester.getRect(actions), dock);
      await captureDesktop(tester, capture, 'fold-inspector-member');
      await finish(tester);
    },
  );

  testWidgets(
    'unpack in the block footer retains edited weights and supports undo',
    (tester) async {
      await mount(tester);
      await inspect(tester);
      final scoped = ProviderScope.containerOf(
        tester.element(find.byType(FoldInspector)),
      );
      await tester.tap(find.text('解散为散词'));
      await tester.pumpAndSettle();
      expect(find.byType(FoldInspector), findsNothing);
      expect(gen.state.prompt, outputOf(raw));
      expect(gen.state.promptRaw, isNot(contains('<#画风:')));
      scoped.read(editorProvider.notifier).undo();
      await tester.pumpAndSettle();
      expect(gen.state.promptRaw, raw);
      await finish(tester);
    },
  );

  for (final chip in [false, true]) {
    testWidgets(
      'only a consecutive double click unfolds in ${chip ? 'tag' : 'text'} view',
      (tester) async {
        await mount(tester);
        if (chip) {
          await tester.tap(find.byKey(const ValueKey('desktop-prompt-mode')));
          await tester.pumpAndSettle();
        }
        final point = chip
            ? tester
                  .state<ChipFlowViewState>(find.byType(ChipFlowView))
                  .chipAnchor(0)!
                  .center
            : tester.getCenter(foldHit().first);
        await tester.tapAt(point);
        await tester.pump();
        expect(find.byType(FoldInspector), findsOneWidget);
        expect(
          tester
              .getRect(find.byKey(const ValueKey('desktop-tag-popover')))
              .contains(point),
          isFalse,
          reason:
              'Immediate inspection must leave the title reachable for a second click',
        );
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(find.byType(FoldInspector), findsNothing);
        expect(gen.state.promptRaw, isNot(contains('<#画风:')));
        expect(gen.state.prompt, outputOf(raw));
        final page = chip
            ? find.byType(ChipFlowView)
            : find.byType(AnnotatedField);
        final scoped = ProviderScope.containerOf(tester.element(page));
        scoped.read(editorProvider.notifier).undo();
        await tester.pumpAndSettle();
        expect(gen.state.promptRaw, raw);
        await finish(tester);
      },
    );
  }

  for (final target in ['character', 'section']) {
    testWidgets(
      '$target inspector writes only its own block and survives mode switches',
      (tester) async {
        String? charId, sectionId;
        if (target == 'character') {
          gen.addCharacter();
          charId = gen.state.characters.single.id;
          gen.updateCharacter(
            charId,
            positive: outputOf(raw),
            positiveRaw: raw,
          );
        } else {
          sectionId = 'inspector-section';
          gen.replaceSections([
            PromptSection(
              id: sectionId,
              name: '场景',
              positive: outputOf(raw),
              positiveRaw: raw,
            ),
          ]);
        }
        await mount(tester, charId: charId, sectionId: sectionId);
        await inspect(tester);
        await tester.enterText(
          find.descendant(of: bodyField(), matching: find.byType(TextField)),
          '1.4::moonlight::',
        );
        await tester.pumpAndSettle();
        expect(gen.state.promptRaw, raw);
        final prefix = charId == null
            ? 'desktop-section-$sectionId'
            : 'desktop-character-$charId';
        await tester.tap(
          find
              .descendant(
                of: find.byType(FoldInspector),
                matching: find.byIcon(Icons.close),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('$prefix-mode')));
        await tester.pumpAndSettle();
        expect(find.byType(FoldInspector), findsNothing);
        final flow = tester.widget<ChipFlowView>(find.byType(ChipFlowView));
        expect(
          topLevelUnits(flow.controller.text, flow.foldBodies).first.isFold,
          isTrue,
        );
        final point = tester
            .state<ChipFlowViewState>(find.byType(ChipFlowView))
            .chipAnchor(0)!
            .center;
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(
          tester.widget<AnnotatedField>(bodyField()).controller.text,
          '1.4::moonlight::',
        );
        expect(
          charId == null
              ? gen.state.sections
                    .singleWhere((s) => s.id == sectionId)
                    .positiveRaw
              : gen.state.characters.single.positiveRaw,
          '<#画风: 1.4::moonlight::#>, sunrise',
        );
        await finish(tester);
      },
    );
  }

  testWidgets(
    'linked positive and negative contents are editable without changing the parent tab',
    (tester) async {
      const negative = '<#画风·排除: bad anatomy#>';
      gen.setPrompts(
        negative: 'bad anatomy',
        negativeRaw: negative,
        promptFoldLinks: [
          const PromptFoldLink(
            id: 'pair',
            positiveName: '画风',
            positiveBody: '0.4::artist:jyt::, {blue eyes}, ~hat~',
            negativeName: '画风·排除',
            negativeBody: 'bad anatomy',
          ),
        ],
      );
      await mount(tester);
      await inspect(tester);
      await tester.tap(find.byKey(const ValueKey('fold-inspector-负面')));
      await tester.pumpAndSettle();
      final parentScope = ProviderScope.containerOf(
        tester.element(find.byType(FoldInspector)),
      );
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: bodyField(positive: false),
          matching: find.byType(TextField),
        ),
        '0.6::bad anatomy::',
      );
      await tester.pumpAndSettle();
      expect(gen.state.promptRaw, raw);
      expect(gen.state.negativePromptRaw, '<#画风·排除: 0.6::bad anatomy::#>');
      expect(parentScope.read(editorProvider).activePositive, isTrue);
      expect(
        gen.state.promptFoldLinks.single.negativeBody,
        '0.6::bad anatomy::',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'long inspector stays inside a narrow dark viewport at large text scale',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final long =
          '<#画风: ${List.generate(25, (i) => '1.2::artist sample $i::').join(', ')}#>';
      gen.setPrompts(positive: outputOf(long), positiveRaw: long);
      await mount(tester, dark: true, scale: 1.5, width: 340);
      await inspect(tester);
      final bounds = tester.getRect(
        find.byKey(const ValueKey('desktop-tag-popover')).first,
      );
      expect(bounds.left, greaterThanOrEqualTo(8));
      expect(bounds.right, lessThanOrEqualTo(352));
      expect(bounds.top, greaterThanOrEqualTo(8));
      expect(bounds.bottom, lessThanOrEqualTo(752));
      final title = tester.getRect(find.text('#画风'));
      final footer = tester.getRect(
        find.byKey(const ValueKey('fold-whole-clear-weight')),
      );
      expect(footer.bottom, lessThanOrEqualTo(bounds.bottom));
      final input = tester.widget<AnnotatedField>(bodyField());
      expect(
        input.scrollController!.position.maxScrollExtent,
        greaterThan(100),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(bodyField()),
          scrollDelta: const Offset(0, 300),
        ),
      );
      await tester.pumpAndSettle();
      expect(input.scrollController!.offset, greaterThan(100));
      expect(tester.getRect(find.text('#画风')), title);
      expect(
        tester.getRect(find.byKey(const ValueKey('fold-whole-clear-weight'))),
        footer,
      );
      expect(tester.takeException(), isNull);
      await captureDesktop(tester, capture, 'fold-inspector-dark-narrow');
      await finish(tester);
    },
  );

  for (final character in [false, true]) {
    testWidgets(
      'fullscreen edits ${character ? 'character' : 'main'} block in the same undo session',
      (tester) async {
        String? id;
        if (character) {
          gen.addCharacter();
          id = gen.state.characters.single.id;
          gen.updateCharacter(id, positive: outputOf(raw), positiveRaw: raw);
        }
        await mount(tester, charId: id);
        final parent = tester
            .widget<AnnotatedField>(find.byType(AnnotatedField))
            .controller;
        final parentText = parent.text;
        await inspect(tester);
        final scoped = ProviderScope.containerOf(
          tester.element(find.byType(FoldInspector)),
        );
        expect(
          tester.getCenter(find.byIcon(Icons.open_in_full)).dx,
          lessThan(tester.getCenter(find.byIcon(Icons.content_copy).first).dx),
        );
        await tester.tap(find.byIcon(Icons.open_in_full));
        await tester.pumpAndSettle();
        final studio = find.byKey(const ValueKey('prompt-fullscreen-dialog'));
        expect(studio, findsOneWidget);
        expect(find.byType(FoldInspector), findsNothing);
        expect(tester.getRect(studio).topLeft, Offset.zero);
        expect(
          ProviderScope.containerOf(
            tester.element(bodyField()),
          ).read(editorSessionsProvider),
          same(scoped.read(editorSessionsProvider)),
        );
        await tester.enterText(
          find.descendant(of: bodyField(), matching: find.byType(TextField)),
          '1.3::moonlight::, blue eyes',
        );
        await tester.pumpAndSettle();
        expect(parent.text, parentText);
        expect(
          character
              ? gen.state.characters.single.positiveRaw
              : gen.state.promptRaw,
          '<#画风: 1.3::moonlight::, blue eyes#>, sunrise',
        );
        await captureDesktop(
          tester,
          capture,
          'fold-fullscreen-${character ? 'character' : 'main'}',
        );
        await tester.tap(find.byKey(const ValueKey('studio-back')));
        await tester.pumpAndSettle();
        expect(studio, findsNothing);
        expect(parent.text, parentText);
        scoped.read(editorProvider.notifier).undo();
        await tester.pumpAndSettle();
        expect(
          character
              ? gen.state.characters.single.positiveRaw
              : gen.state.promptRaw,
          raw,
        );
        await finish(tester);
      },
    );
  }

  testWidgets(
    'long block near the middle of a short window keeps both action bars accessible',
    (tester) async {
      tester.view.physicalSize = const Size(880, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final long =
          '<#画风: ${List.generate(60, (i) => 'sample tag $i').join(', ')}#>';
      gen.setPrompts(positive: outputOf(long), positiveRaw: long);
      await mount(tester, scale: 1.5, topPadding: 150);
      await inspect(tester);
      final panel = tester.getRect(
        find.byKey(const ValueKey('fold-inspector')),
      );
      expect(tester.getSize(bodyField()).height, greaterThan(24));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('fold-whole-clear-weight')))
            .bottom,
        lessThan(panel.bottom),
      );
      expect(panel.contains(tester.getCenter(foldHit().first)), isFalse);
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      final titleFinder = find.byKey(const ValueKey('studio-back'));
      final composer = find.byKey(const ValueKey('studio-focus-true'));
      final title = tester.getRect(titleFinder);
      final header = tester.getRect(composer);
      final scroll = tester
          .widget<AnnotatedField>(bodyField())
          .scrollController!;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(bodyField()),
          scrollDelta: const Offset(0, 350),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
      expect(tester.getRect(titleFinder), title);
      expect(tester.getRect(composer), header);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'fullscreen deletion still targets the block after its popover closes',
    (tester) async {
      await mount(tester);
      await inspect(tester);
      final scoped = ProviderScope.containerOf(
        tester.element(find.byType(FoldInspector)),
      );
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      if (find.text('移除此块').evaluate().isEmpty) {
        await tester.tap(find.byTooltip('词条与块检视器'));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text('移除此块'));
      await tester.tap(find.text('移除此块'));
      await tester.pumpAndSettle();
      final scaffold = tester.state<ScaffoldState>(
        find.descendant(
          of: find.byKey(const ValueKey('prompt-fullscreen-dialog')),
          matching: find.byType(Scaffold),
        ),
      );
      scaffold.closeEndDrawer();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('studio-back')));
      await tester.pumpAndSettle();
      expect(gen.state.prompt, 'sunrise');
      expect(gen.state.promptRaw, isEmpty);
      scoped.read(editorProvider.notifier).undo();
      await tester.pumpAndSettle();
      expect(gen.state.promptRaw, raw);
      await finish(tester);
    },
  );

  for (final character in [false, true]) {
    testWidgets(
      'mode switch preserves ${character ? 'character' : 'main'} folds and draft',
      (tester) async {
        String? id;
        if (character) {
          gen.addCharacter();
          id = gen.state.characters.single.id;
          gen.updateCharacter(id, positive: outputOf(raw), positiveRaw: raw);
        }
        await mount(tester, charId: id);
        final field = tester.widget<AnnotatedField>(
          find.byType(AnnotatedField),
        );
        final before = field.controller.text;
        expect(parseFoldRefs(before, field.controller.foldBodies).length, 1);
        final mode = find.byKey(
          ValueKey(
            id == null ? 'desktop-prompt-mode' : 'desktop-character-$id-mode',
          ),
        );
        await tester.tap(mode);
        await tester.pumpAndSettle();
        final flow = tester.widget<ChipFlowView>(find.byType(ChipFlowView));
        expect(flow.controller.text, before);
        expect(
          topLevelUnits(
            flow.controller.text,
            flow.foldBodies,
          ).where((u) => u.isFold).length,
          1,
        );
        await tester.tap(mode);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AnnotatedField>(find.byType(AnnotatedField))
              .controller
              .text,
          before,
        );
        expect(
          id == null
              ? gen.state.promptRaw
              : gen.state.characters.single.positiveRaw,
          raw,
        );
        await finish(tester);
      },
    );
  }
}
