import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/core/ui/desktop_text_selection.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/data/tag_completion.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/widgets/prompt_fullscreen_dialog.dart';
import 'package:plana_app/features/editor/widgets/annotated_field.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/nai_request.dart'
    show naiNegativePrompt;
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'support/character_avatar_fixture.dart' show waitForAvatarImage;
import 'support/desktop_capture.dart';

class _Library extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState(
    entries: [
      TagEntry(
        id: 'scene',
        category: TagCategory.scene,
        name: '黄昏海风',
        positive: 'ocean, sunset',
        negative: 'indoors, noon',
      ),
      TagEntry(
        id: 'char1',
        category: TagCategory.character,
        name: '凉夏',
        positive: 'green eyes, cat ears',
        negative: 'hat',
        aliases: ['夏日'],
      ),
      TagEntry(
        id: 'char2',
        category: TagCategory.character,
        name: '蓝铃',
        positive: 'blue eyes',
        negative: 'gloves',
      ),
      TagEntry(
        id: 'style',
        category: TagCategory.artist,
        name: '清透水彩',
        positive: 'watercolor, soft colors',
      ),
    ],
  );
}

class _Completion extends Fake implements TagCompletion {
  Completer<SuggestResult>? delayed;
  int relatedQueries = 0;
  @override
  Future<SuggestResult> query(String q) async =>
      q == 'awaited' && delayed != null
      ? delayed!.future
      : const SuggestResult(
          tags: [
            Suggestion(text: 'blue sky', kind: SuggestionKind.tag, trans: '蓝天'),
          ],
        );
  @override
  Future<List<String>> relatedOf(String name) async {
    relatedQueries++;
    return ['inferred tag'];
  }

  @override
  Future<WikiPreview?> fetchWiki(String tag) async => null;
}

void main() {
  final capture = GlobalKey();
  late AppStores stores;
  late ProviderContainer container;
  late GenerateNotifier gen;
  late String role, section;
  late String clipboard;
  late _Completion completion;
  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: jsonEncode(
        const EditorSettings(
          enableCompletion: true,
          showTranslation: false,
        ).toJson(),
      ),
    );
    completion = _Completion();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        tagLibraryProvider.overrideWith(_Library.new),
        tagCompletionProvider.overrideWithValue(completion),
      ],
    );
    gen = container.read(generateProvider.notifier);
    gen.setModel('NAI 5.0 Full', naiEffort: NaiEffort.high);
    const pos =
        '<#水彩: 0.8::watercolor::, soft light#>, 1.2::blue sky::, sunlight';
    const neg = '<#水彩·排除: grain, blur#>, noise';
    gen.setPrompts(
      positive: outputOf(pos),
      positiveRaw: pos,
      negative: outputOf(neg),
      negativeRaw: neg,
      promptFoldLinks: [
        PromptFoldLink.forEntry('paired').copyWith(
          positiveName: '水彩',
          positiveBody: '0.8::watercolor::, soft light',
          negativeName: '水彩·排除',
          negativeBody: 'grain, blur',
        ),
      ],
    );
    gen.addSection();
    section = gen.state.sections.last.id;
    gen.updateSection(section, name: '光影与空气感');
    gen.addCharacter();
    role = gen.state.characters.single.id;
    gen.updateCharacter(
      role,
      name: '旅人',
      positive: 'blue eyes',
      negative: 'hat',
    );
    clipboard = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = call.arguments['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    container.dispose();
    stores.flushNow();
  });
  Finder key(String name) => find.byKey(ValueKey(name));
  Finder field(bool side) => find.descendant(
    of: key('studio-text-$side'),
    matching: find.byType(TextField),
  );
  Future<void> tap(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.tap(f);
    await t.pumpAndSettle();
  }

  Future<void> mount(WidgetTester t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(const Color(0xFF00897B)).copyWith(
              textTheme: AppTheme.light(
                const Color(0xFF00897B),
              ).textTheme.apply(fontFamily: 'Microsoft YaHei'),
            ),
            builder: (ctx, child) => DesktopTextSelection(child: child!),
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  key: const ValueKey('open'),
                  onPressed: () => openPromptStudio(ctx),
                  child: const Text('编辑'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tap(t, key('open'));
    expect(
      t.getRect(key('prompt-fullscreen-dialog')),
      const Rect.fromLTWH(0, 0, 1440, 900),
    );
  }

  Future<void> finish(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    expect(t.takeException(), isNull);
  }

  testWidgets(
    'search by pinyin, initials and prompt, then import into one named role per character',
    (t) async {
      await mount(t);
      await tap(t, key('studio-target-$role'));
      final search = key('studio-library-search');
      for (final q in ['liangxia', 'lx', 'green eyes']) {
        await t.enterText(search, q);
        await t.pumpAndSettle();
        expect(key('studio-insert-char1'), findsOneWidget);
        expect(key('studio-insert-char2'), findsNothing);
      }
      await tap(t, key('studio-insert-char1'));
      expect(gen.state.characters.map((c) => c.name), ['旅人', '凉夏']);
      expect(gen.state.characters.last.positive, 'green eyes, cat ears');
      expect(gen.state.characters.last.negative, 'hat');
      expect(gen.state.characters.last.source, 'char1');
      gen.addCharacter();
      await t.pumpAndSettle();
      final empty = gen.state.characters.last.id;
      await tap(t, key('studio-target-$empty'));
      await t.enterText(search, 'lanling');
      await t.pumpAndSettle();
      await tap(t, key('studio-insert-char2'));
      expect(gen.state.characters.map((c) => c.name), ['旅人', '凉夏', '蓝铃']);
      expect(gen.state.characters.last.id, empty);
      await finish(t);
    },
  );

  testWidgets(
    'outline actions are fixed, reorder only parent rows and delete an active role',
    (t) async {
      gen.addCharacter();
      final other = gen.state.characters.last.id;
      gen.fillCharacterFrom(
        other,
        name: '角色 2',
        positive: 'wind',
        negative: '',
        avatar: 'assets/app_icon.png',
      );
      await mount(t);
      final row = key('studio-target-$other');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      for (final target in ['main', section, role]) {
        final header = key('studio-target-$target');
        final actions = find.descendant(
          of: header,
          matching: find.byType(IconButton),
        );
        final toggle = actions.last;
        final bounds = t.getRect(header);
        await mouse.moveTo(t.getCenter(toggle));
        await t.pumpAndSettle();
        expect(t.widget<InkWell>(header).onTap, isNotNull);
        expect(bounds.contains(t.getTopRight(toggle)), isTrue);
        if (target == role) {
          await captureDesktop(t, capture, 'studio-outline-row-hover');
        }
      }
      await mouse.removePointer();
      await tap(t, row);
      await waitForAvatarImage(t, row);
      final avatar = find.descendant(of: row, matching: find.byType(Image));
      expect(t.widget<Image>(avatar).alignment, Alignment.topCenter);
      expect(t.widget<Image>(avatar).fit, BoxFit.cover);
      final rowCenter = t.getCenter(row).dy;
      await tap(t, key('studio-rename-$other'));
      final edit = key('studio-name-$other-editor');
      final controller = t.widget<TextField>(edit).controller!;
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.selection.textInside(controller.text), '角色 2');
      expect(t.getCenter(edit).dy, closeTo(rowCenter, 1));
      expect(key('studio-delete-$other'), findsNothing);
      await waitForAvatarImage(t, key('studio-character-$other'));
      await captureDesktop(t, capture, 'studio-outline-inline-rename');
      await t.enterText(edit, '海风');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(gen.state.characters.last.name, '海风');
      await tap(t, key('studio-rename-$section'));
      final sectionEdit = key('studio-name-$section-editor');
      await t.enterText(sectionEdit, '取消这个名字');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(sectionEdit, findsNothing);
      expect(gen.state.sections.last.name, '光影与空气感');
      await tap(t, key('studio-rename-$section'));
      await t.enterText(sectionEdit, '黄昏');
      await t.tap(key('studio-target-$other'), kind: PointerDeviceKind.mouse);
      await t.pumpAndSettle();
      expect(gen.state.sections.last.name, '黄昏');
      expect(t.widget<TextField>(field(true)).controller!.text, 'wind');
      Future<void> drag(Finder from, Finder to) async {
        final start = t.getCenter(from),
            end = t.getBottomLeft(to) + const Offset(45, 2);
        final g = await t.startGesture(start, kind: PointerDeviceKind.mouse);
        await t.pump(const Duration(milliseconds: 1));
        for (var n = 1; n <= 12; n++) {
          await g.moveTo(
            Offset(start.dx, start.dy + (end.dy - start.dy) * n / 12),
          );
          await t.pump(const Duration(milliseconds: 24));
        }
        await t.pumpAndSettle();
        await g.up();
        await t.pumpAndSettle();
      }

      await drag(
        key('studio-outline-fold-main-true-0'),
        key('studio-target-$section'),
      );
      expect(gen.state.sections.first.isMain, isTrue);
      await drag(key('studio-target-main'), key('studio-target-$section'));
      expect(gen.state.sections.last.isMain, isTrue);
      await drag(key('studio-target-$role'), key('studio-target-$other'));
      expect(gen.state.characters.map((c) => c.id), [other, role]);
      await tap(t, key('studio-target-$other'));
      await tap(t, key('studio-delete-$other'));
      expect(find.byType(AlertDialog), findsNothing);
      expect(key('studio-target-$other'), findsNothing);
      expect(gen.state.characters.single.id, role);
      await tap(t, key('studio-delete-$section'));
      expect(find.byType(AlertDialog), findsNothing);
      expect(key('studio-target-$section'), findsNothing);
      expect(gen.state.sections.where((s) => !s.isMain), isEmpty);
      expect(
        t.widget<TextField>(field(true)).controller!.text,
        contains('blue sky'),
      );
      await finish(t);
    },
  );

  testWidgets(
    'block weight override and reset preserve original member weights across scope changes',
    (t) async {
      await mount(t);
      await tap(t, key('studio-outline-fold-main-true-0'));
      final initial = gen.state.promptRaw;
      expect(
        t.widget<OutlinedButton>(key('studio-block-reset')).onPressed,
        isNull,
      );
      await tap(
        t,
        find.descendant(
          of: key('studio-block-weight'),
          matching: find.byIcon(Icons.add),
        ),
      );
      expect(gen.state.promptRaw, contains('1.1::watercolor, soft light::'));
      expect(
        gen.state.promptFoldLinks.single.positiveWeightOrigin,
        '0.8::watercolor::, soft light',
      );
      expect(
        PromptFoldLink.decode([gen.state.promptFoldLinks.single.toJson()]),
        gen.state.promptFoldLinks,
      );
      await tap(t, key('studio-edit-block'));
      await tap(t, key('studio-outline-fold-main-true-0'));
      await tap(t, key('studio-block-reset'));
      expect(gen.state.promptRaw, initial);
      await captureDesktop(t, capture, 'studio-independent-block-weights');
      await finish(t);
    },
  );

  testWidgets(
    'studio outline switches scope, edits both blocks, and keeps separate undo and redo histories',
    (t) async {
      await mount(t);
      expect(key('studio-target-main'), findsOneWidget);
      expect(key('studio-target-$role'), findsOneWidget);
      expect(key('studio-target-$section'), findsOneWidget);
      expect(find.byTooltip('收藏标签'), findsNothing);
      expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
      await captureDesktop(t, capture, 'prompt-studio-overview');
      await tap(t, key('studio-outline-fold-main-true-0'));
      expect(t.widget<TextField>(field(false)).controller!.text, 'grain, blur');
      await t.enterText(field(false), 'grain, fog');
      await t.pumpAndSettle();
      expect(gen.state.negativePromptRaw, contains('<#水彩·排除: grain, fog#>'));
      await tap(t, key('studio-undo'));
      expect(gen.state.negativePromptRaw, contains('grain, blur'));
      await tap(t, key('studio-redo'));
      expect(gen.state.negativePromptRaw, contains('grain, fog'));
      await tap(t, key('studio-target-$role'));
      await t.enterText(field(true), 'red hair');
      await t.pumpAndSettle();
      await tap(t, key('studio-undo'));
      expect(gen.state.characters.single.positive, 'blue eyes');
      await tap(t, key('studio-target-$section'));
      expect(t.widget<IconButton>(key('studio-redo')).onPressed, isNull);
      await tap(t, key('studio-target-$role'));
      await tap(t, key('studio-redo'));
      expect(gen.state.characters.single.positive, 'red hair');
      expect(gen.state.prompt, contains('blue sky'));
      expect(gen.state.characters.single.negative, 'hat');
      await tap(t, key('studio-target-main'));
      await tap(t, find.text('仅负面'));
      expect(field(true), findsNothing);
      await tap(t, find.text('同屏'));
      expect(field(true), findsOneWidget);
      await finish(t);
    },
  );

  testWidgets(
    'keyboard deletion treats a collapsed block as one unit and undo restores it',
    (t) async {
      await mount(t);
      final text = t.widget<TextField>(field(true)).controller!;
      await t.tap(field(true));
      final fold = foldRefLiteral('水彩');
      final start = text.text.indexOf(fold);
      expect(start, isNonNegative);
      text.selection = TextSelection.collapsed(offset: start + 1);
      expect(text.selection.extentOffset, start);
      text.selection = TextSelection.collapsed(offset: start + fold.length);
      await t.sendKeyEvent(LogicalKeyboardKey.backspace);
      await t.pumpAndSettle();
      expect(gen.state.prompt, '1.2::blue sky::, sunlight');
      expect(gen.state.negativePrompt, 'noise');
      await tap(t, key('studio-undo'));
      expect(gen.state.negativePromptRaw, contains('grain, blur'));
      expect(
        gen.state.promptRaw,
        contains('<#水彩: 0.8::watercolor::, soft light#>'),
      );
      await finish(t);
    },
  );

  testWidgets(
    'first mouse click after switching roles inspects the clicked token',
    (t) async {
      gen.addCharacter();
      final second = gen.state.characters.last.id;
      gen.updateCharacter(
        second,
        positive: 'red hair, green eyes',
        negative: 'rain',
      );
      await mount(t);
      await tap(t, find.text('仅正面'));
      for (final (id, word, side) in [
        (role, 'blue eyes', true),
        (second, 'green eyes', true),
        (role, 'hat', false),
      ]) {
        await tap(t, key('studio-target-$id'));
        if (!side) await tap(t, find.text('仅负面'));
        final editable = t.state<EditableTextState>(
          find.descendant(of: field(side), matching: find.byType(EditableText)),
        );
        final offset = editable.widget.controller.text.indexOf(word) + 2;
        final render = editable.renderEditable;
        final point = render.localToGlobal(
          render.getLocalRectForCaret(TextPosition(offset: offset)).center,
        );
        await t.tapAt(point, kind: PointerDeviceKind.mouse);
        await t.pumpAndSettle();
        expect(key('studio-copy-token'), findsOneWidget);
        await tap(t, key('studio-copy-token'));
        expect(clipboard, word);
      }
      await finish(t);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'inspector resets and copies directly, quick insert and completion write to the focused side',
    (t) async {
      await mount(t);
      final text = t.widget<TextField>(field(true)).controller!;
      await t.tap(field(true));
      text.selection = TextSelection.collapsed(
        offset: text.text.indexOf('blue sky') + 2,
      );
      await t.pumpAndSettle();
      await tap(t, key('studio-copy-token'));
      expect(clipboard, 'blue sky');
      await tap(t, key('studio-reset'));
      expect(gen.state.prompt, isNot(contains('1.2::blue sky')));
      final initial = gen.state.promptRaw;
      await tap(t, key('studio-focus-false'));
      await tap(t, key('studio-insert-scene'));
      expect(gen.state.negativePromptRaw, contains('indoors, noon'));
      expect(gen.state.promptRaw, initial);
      expect(find.text('清透水彩'), findsNothing);
      final neg = t.widget<TextField>(field(false)).controller!.text;
      await t.enterText(field(false), '$neg, blu');
      await t.pump(const Duration(milliseconds: 150));
      await t.pumpAndSettle();
      expect(key('studio-completion-dock'), findsOneWidget);
      expect(
        find.descendant(
          of: key('studio-completion-dock'),
          matching: key('completion-row-tag-blue sky'),
        ),
        findsOneWidget,
      );
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(gen.state.negativePrompt, contains('blue sky'));
      expect(gen.state.promptRaw, initial);
      await tap(t, key('studio-target-$role'));
      await tap(t, find.text('芯片'));
      expect(key('studio-chips-true'), findsOneWidget);
      expect(key('studio-chips-false'), findsOneWidget);
      await tap(t, find.text('文本'));
      await t.enterText(field(true), 'green eyes');
      await t.pumpAndSettle();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      expect(gen.state.characters.single.positive, 'blue eyes');
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyY);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      expect(gen.state.characters.single.positive, 'green eyes');
      await finish(t);
    },
  );
  testWidgets(
    'split starts equal, clamps both panes, and focus labels track the right edge only in split',
    (t) async {
      await mount(t);
      Finder header(bool side) => key('studio-focus-$side');
      final divider = key('studio-split-divider');
      double width(bool side) => t.getSize(header(side)).width;
      void checkLabels() {
        for (final side in [true, false]) {
          expect(
            t.getRect(header(side)).right -
                t.getRect(key('studio-focus-label-$side')).right,
            closeTo(12, 1),
          );
        }
      }

      expect(width(true), closeTo(width(false), .01));
      checkLabels();
      await t.drag(divider, const Offset(130, 0));
      await t.pumpAndSettle();
      expect(width(true), greaterThan(width(false) + 150));
      checkLabels();
      await t.drag(divider, const Offset(1800, 0));
      await t.pumpAndSettle();
      expect(width(false), closeTo(180, 1));
      await t.drag(divider, const Offset(-1800, 0));
      await t.pumpAndSettle();
      expect(width(true), closeTo(180, 1));
      await t.tap(divider);
      await t.pump(const Duration(milliseconds: 60));
      await t.tap(divider);
      await t.pumpAndSettle();
      expect(width(true), closeTo(width(false), .01));
      for (final mode in ['仅正面', '仅负面']) {
        await tap(t, find.text(mode));
        expect(divider, findsNothing);
        expect(header(true), findsNothing);
        expect(header(false), findsNothing);
        expect(find.text('当前输入焦点'), findsNothing);
        expect(field(mode == '仅正面'), findsOneWidget);
      }
      await tap(t, find.text('同屏'));
      t.view.physicalSize = const Size(440, 790);
      await t.pumpAndSettle();
      final before = t.getRect(divider);
      expect(before.width, greaterThan(before.height));
      await t.drag(divider, const Offset(0, 90));
      await t.pumpAndSettle();
      expect(t.getRect(divider).center.dy, greaterThan(before.center.dy + 50));
      expect(t.takeException(), isNull);
      await finish(t);
    },
  );

  testWidgets(
    'docked completion uses the typed token and preserves weights, position and neighboring text',
    (t) async {
      gen.setPrompts(
        positive: 'sun, grass',
        positiveRaw: '',
        negative: 'noise',
        negativeRaw: '',
        promptFoldLinks: [],
      );
      await mount(t);
      expect(key('studio-composer-input'), findsNothing);
      final negative = gen.state.negativePromptRaw;
      await t.showKeyboard(field(true));
      const text = 'sun, 1.2::blu::, grass';
      t.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: 13),
        ),
      );
      await t.pump(const Duration(milliseconds: 150));
      await t.pumpAndSettle();
      final dock = key('studio-completion-dock');
      expect(dock, findsOneWidget);
      expect(
        t.getRect(dock).left,
        greaterThanOrEqualTo(t.getRect(field(false)).right),
      );
      expect(key('studio-copy-token'), findsNothing);
      expect(find.textContaining('Esc'), findsWidgets);
      expect(
        t.getRect(dock).bottom,
        lessThanOrEqualTo(t.getRect(find.text('灵感库快插')).top),
      );
      expect(completion.relatedQueries, 0);
      await captureDesktop(t, capture, 'studio-completion-dock');
      await tap(t, key('completion-row-tag-blue sky'));
      expect(gen.state.prompt, 'sun, 1.2::blue sky::, grass');
      expect(gen.state.negativePromptRaw, negative);
      expect(dock, findsNothing);
      expect(find.text('inferred tag'), findsNothing);
      await finish(t);
    },
  );

  testWidgets(
    'character position matrix, automatic mode and the full position dialog use the active character',
    (t) async {
      gen.updateCharacter(role, position: '0.35,0.80');
      gen.addCharacter();
      final other = gen.state.characters.last.id;
      gen.updateCharacter(other, name: '同伴', position: 'A1');
      gen.setUseCoords(true);
      await mount(t);
      await tap(t, key('studio-target-$role'));
      expect(find.text('X 35% · Y 80%'), findsOneWidget);
      await tap(t, key('studio-position-toggle'));
      expect(key('studio-position-cell-D2'), findsNothing);
      await tap(t, key('studio-position-auto'));
      expect(gen.state.characters.first.position, isNull);
      await tap(t, key('studio-position-auto'));
      expect(gen.state.characters.first.position, '0.35,0.80');
      expect(gen.state.characters.last.position, 'A1');
      await tap(t, key('studio-position-toggle'));
      await tap(t, key('studio-position-cell-D2'));
      expect(gen.state.characters.first.position, 'D2');
      expect(find.text('X 70% · Y 30%'), findsOneWidget);
      await tap(t, key('studio-position-manual-false'));
      expect(gen.state.characters.first.position, isNull);
      expect(gen.state.characters.last.position, 'A1');
      await tap(t, key('studio-position-manual-true'));
      expect(gen.state.characters.first.position, 'D2');
      await tap(t, key('studio-position-dialog'));
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.text('设置角色位置')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.text('确认保存')),
        findsOneWidget,
      );
      await tap(t, find.text('取消'));
      expect(gen.state.characters.first.position, 'D2');
      expect(gen.state.characters.last.position, 'A1');
      await finish(t);
    },
  );

  testWidgets(
    'character dock replaces weight controls between the placement card and library and restores on Escape',
    (t) async {
      cacheTagMeta('pink inner ear', trans: '粉色耳内侧');
      gen.updateCharacter(
        role,
        position: 'C3',
        positive: '1.2::pink inner ear::',
      );
      gen.setUseCoords(true);
      await mount(t);
      await tap(t, key('studio-target-$role'));
      await t.showKeyboard(field(true));
      final text = t.widget<TextField>(field(true)).controller!;
      text.selection = TextSelection.collapsed(
        offset: text.text.indexOf('pink') + 2,
      );
      await t.pumpAndSettle();
      final reset = key('studio-reset'),
          copy = key('studio-copy-token'),
          disable = key('studio-disable-token');
      expect(t.getCenter(reset).dy, closeTo(t.getCenter(copy).dy, 1));
      expect(t.getTopLeft(reset).dx, closeTo(t.getTopLeft(disable).dx, 1));
      expect(find.text('0.8'), findsNothing);
      expect(find.text('粉色耳内侧'), findsOneWidget);
      final pos = t.getRect(key('studio-position-dialog'));
      final library = t.getRect(find.text('灵感库快插'));
      await captureDesktop(t, capture, 'studio-character-weight');
      Future<void> type(String query) async {
        await t.enterText(field(true), query);
        await t.pump(const Duration(milliseconds: 150));
        await t.pumpAndSettle();
      }

      await type('blu');
      final dock = key('studio-completion-dock');
      expect(dock, findsOneWidget);
      expect(reset, findsNothing);
      expect(t.getRect(key('studio-position-dialog')), pos);
      expect(t.getRect(find.text('灵感库快插')), library);
      expect(t.getRect(dock).top, greaterThan(pos.bottom));
      expect(t.getRect(dock).bottom, lessThan(library.top));
      await captureDesktop(t, capture, 'studio-character-completion');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(dock, findsNothing);
      expect(copy, findsOneWidget);
      await tap(t, key('studio-position-toggle'));
      await type('blue');
      expect(key('studio-position-dialog'), findsNothing);
      await tap(t, key('studio-return-inspector'));
      expect(dock, findsNothing);
      expect(copy, findsOneWidget);
      expect(key('studio-position-dialog'), findsNothing);
      await type('blu');
      await tap(t, key('completion-row-tag-blue sky'));
      expect(gen.state.characters.single.positive, contains('blue sky'));
      expect(dock, findsNothing);
      await finish(t);
    },
  );
  testWidgets(
    'following completion moves with the caret, keeps IME composition, and inserts repeatedly in the active role',
    (t) async {
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(studioCompletionFixedToSide: false));
      await mount(t);
      await tap(t, key('studio-target-$role'));
      await t.showKeyboard(field(false));
      const typed = 'soft light,\n\n\nblu';
      final caret = TextSelection.collapsed(offset: typed.length);
      t.testTextInput.updateEditingValue(
        TextEditingValue(
          text: typed,
          selection: caret,
          composing: TextRange(start: typed.length - 3, end: typed.length),
        ),
      );
      await t.pump(const Duration(milliseconds: 150));
      await t.pumpAndSettle();
      final following = key('studio-completion-follow');
      expect(following, findsOneWidget);
      expect(key('studio-completion-dock'), findsNothing);
      final editor = t.state<AnnotatedFieldState>(
        find.descendant(
          of: key('studio-text-false'),
          matching: find.byType(AnnotatedField),
        ),
      );
      final anchor = editor.selectionAnchor()!;
      final popup = t.getRect(following);
      expect(popup.top, closeTo(anchor.bottom, 16));
      expect(popup.left, lessThanOrEqualTo(anchor.right));
      expect(popup.right, greaterThan(anchor.left));
      expect(
        t
            .widget<TextField>(field(false))
            .controller!
            .value
            .composing
            .isCollapsed,
        isFalse,
      );
      await captureDesktop(t, capture, 'studio-completion-follow');
      t.testTextInput.updateEditingValue(
        TextEditingValue(text: typed, selection: caret),
      );
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pumpAndSettle();
      expect(following, findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(following, findsNothing);
      expect(
        'blue sky'.allMatches(gen.state.characters.single.negative).length,
        2,
      );
      expect(gen.state.characters.single.negative, isNot(contains('blu,')));
      expect(gen.state.characters.single.positive, 'blue eyes');
      await finish(t);
    },
  );

  testWidgets(
    'changing scope rejects stale searches and both chip inputs can complete directly',
    (t) async {
      completion.delayed = Completer<SuggestResult>();
      await mount(t);
      await t.enterText(field(true), 'awaited');
      await t.pump(const Duration(milliseconds: 130));
      await tap(t, key('studio-target-$section'));
      completion.delayed!.complete(
        const SuggestResult(
          tags: [Suggestion(text: 'outdated', kind: SuggestionKind.tag)],
        ),
      );
      await t.pumpAndSettle();
      expect(key('studio-completion-dock'), findsNothing);
      await tap(t, find.text('芯片'));
      Finder chips(bool side) => find.descendant(
        of: key('studio-chips-$side'),
        matching: find.byType(TextField),
      );
      await t.enterText(chips(true), 'blu');
      await t.pump(const Duration(milliseconds: 150));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(key('prompt-fullscreen-dialog'), findsOneWidget);
      expect(key('studio-completion-dock'), findsNothing);
      await t.enterText(chips(false), 'bl');
      await t.pump(const Duration(milliseconds: 150));
      await t.pumpAndSettle();
      await tap(t, key('completion-row-tag-blue sky'));
      final edited = gen.state.sections.singleWhere((s) => s.id == section);
      expect(edited.negative, contains('blue sky'));
      expect(edited.positive, endsWith('blu'));
      expect(gen.state.prompt, 'awaited');
      await finish(t);
    },
  );
  testWidgets(
    'a narrow window docks on the right and can follow the chip input when switched',
    (t) async {
      await mount(t);
      t.view.physicalSize = const Size(600, 740);
      await t.pumpAndSettle();
      await tap(t, find.text('芯片'));
      final positive = key('studio-chips-true');
      final input = find.descendant(
        of: positive,
        matching: find.byType(TextField),
      );
      await t.enterText(input, 'bl');
      await t.pump(const Duration(milliseconds: 160));
      await t.pumpAndSettle();
      expect(
        t.getRect(key('studio-completion-dock')).left,
        greaterThanOrEqualTo(t.getRect(positive).right),
      );
      expect(t.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(studioCompletionFixedToSide: false));
      await t.pumpAndSettle();
      expect(key('studio-completion-dock'), findsNothing);
      expect(key('studio-completion-follow'), findsOneWidget);
      await tap(t, key('completion-row-tag-blue sky'));
      expect(gen.state.prompt, endsWith('blue sky'));
      expect(t.takeException(), isNull);
      await finish(t);
    },
  );

  testWidgets(
    'a negative-only block gains its own positive side and retains it when reopened',
    (t) async {
      const neg = '<#反光·排除: lens flare#>, noise';
      gen.setPrompts(
        positive: 'sun',
        positiveRaw: '',
        negative: outputOf(neg),
        negativeRaw: neg,
        promptFoldLinks: [],
      );
      await mount(t);
      await tap(t, key('studio-outline-fold-main-false-0'));
      expect(t.widget<TextField>(field(true)).controller!.text, '');
      await t.enterText(field(true), 'soft light');
      await t.pumpAndSettle();
      expect(gen.state.promptFoldLinks.single.negativeName, '反光·排除');
      expect(gen.state.promptFoldLinks.single.positiveName, '反光');
      expect(gen.state.negativePromptRaw, neg);
      expect(gen.state.prompt, 'sun, soft light');
      await tap(t, key('studio-back'));
      await tap(t, key('open'));
      await tap(t, key('studio-outline-fold-main-true-0'));
      expect(t.widget<TextField>(field(true)).controller!.text, 'soft light');
      expect(t.widget<TextField>(field(false)).controller!.text, 'lens flare');
      await finish(t);
    },
  );

  testWidgets(
    'Medium keeps the main editor single-sided and can store a block negative draft',
    (t) async {
      gen.setModel('NAI 5.0 Full', naiEffort: NaiEffort.medium);
      final sent = naiNegativePrompt(gen.state);
      await mount(t);
      expect(key('studio-focus-label-true'), findsNothing);
      expect(field(false), findsNothing);
      await tap(t, key('studio-outline-fold-main-true-0'));
      await t.enterText(field(false), 'blur, grain');
      await t.pumpAndSettle();
      expect(gen.state.promptFoldLinks.single.negativeBody, 'blur, grain');
      expect(naiNegativePrompt(gen.state), sent);
      await finish(t);
    },
  );
}
