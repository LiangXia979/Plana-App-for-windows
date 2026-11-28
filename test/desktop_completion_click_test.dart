import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/editor/data/tag_completion.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/editor/data/completion_source.dart';
import 'package:plana_app/features/editor/widgets/desktop_completion_menu.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/widgets/desktop_prompt_card.dart';

import 'support/desktop_capture.dart';

class _Styles extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState(
    entries: [
      TagEntry(
        id: 'style',
        name: '粉彩',
        category: TagCategory.artist,
        aliases: ['D33'],
        positive: 'artist:one, pastel colors',
      ),
    ],
  );
}

class _Completion extends Fake implements TagCompletion {
  @override
  Future<SuggestResult> query(String raw) async => raw == 'bl'
      ? const SuggestResult(
          works: [
            Suggestion(
              text: 'blue archive',
              kind: SuggestionKind.work,
              count: 10,
            ),
          ],
          tags: [
            Suggestion(
              text: 'blue sky',
              trans: '蓝天',
              kind: SuggestionKind.tag,
              count: 30,
            ),
            Suggestion(text: 'blue bird', kind: SuggestionKind.tag, count: 20),
          ],
        )
      : const SuggestResult();

  Completer<String?>? translation;
  @override
  Future<String?> translateNatural(String text) async =>
      translation == null ? 'seaside sunset' : await translation!.future;
  @override
  Future<String?> randomCharacterOf(String name) async => 'hina';
  @override
  Future<WikiPreview?> fetchWiki(String name) async =>
      WikiPreview(summaryZh: '蓝色天空');
  @override
  Future<String?> fetchWikiZh(String name) async => null;
  @override
  Future<List<String>> relatedOf(String name) async => const ['cloud'];
}

void main() {
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  late AppStores stores;
  late ProviderContainer container;
  late _Completion service;

  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  Future<void> mount(
    WidgetTester tester,
    bool chips, {
    double topInset = 0,
  }) async {
    stores = AppStores.ephemeral();
    service = _Completion();
    await tester.runAsync(
      () => stores.prefs.write(
        key: 'editor_settings',
        value: jsonEncode(
          EditorSettings(chipMode: chips, showTranslation: false).toJson(),
        ),
      ),
    );
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        tagLibraryProvider.overrideWith(_Styles.new),
        desktopModeProvider.overrideWithValue(true),
        effectiveCompletionSourceProvider.overrideWithValue(
          CompletionSource.enhanced,
        ),
        tagCompletionProvider.overrideWithValue(service),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
    final theme = AppTheme.light();
    container
        .read(generateProvider.notifier)
        .setPrompts(positive: 'solo', negative: 'lowres');
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
            home: Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.only(top: topInset),
                child: const SizedBox(width: 340, child: DesktopPromptCard()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> mouseClick(WidgetTester tester, Finder finder) async {
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.down(tester.getCenter(finder));
    // A real mouse press and release can straddle a layout frame.
    await tester.pump(const Duration(milliseconds: 50));
    await pointer.up();
    await tester.pumpAndSettle();
    await pointer.removePointer();
  }

  for (final negative in [false, true]) {
    for (final chips in [false, true]) {
      testWidgets(
        'mouse completion inserts in ${negative ? 'negative' : 'positive'} sidebar ${chips ? 'chips' : 'text'}',
        (tester) async {
          await mount(tester, chips);
          if (negative) {
            await tester.tap(
              find.byKey(const ValueKey('desktop-prompt-negative-tab')),
            );
            await tester.pumpAndSettle();
          }
          final host = find.byType(DesktopPromptCard);
          final field = find
              .descendant(of: host, matching: find.byType(TextField))
              .first;
          await tester.enterText(
            field,
            chips ? 'bl' : '${negative ? 'lowres' : 'solo'}, bl',
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byType(DesktopCompletionMenu)).width,
            greaterThan(340),
          );
          final suggestion = find.byKey(
            const ValueKey('completion-row-tag-blue sky'),
          );
          await mouseClick(tester, suggestion);
          expect(
            negative
                ? container.read(generateProvider).negativePrompt
                : container.read(generateProvider).prompt,
            contains('blue sky'),
          );
          expect(
            negative
                ? container.read(generateProvider).prompt
                : container.read(generateProvider).negativePrompt,
            negative ? 'solo' : 'lowres',
          );
          expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
          if (chips) {
            expect(
              chipInputBody(tester.widget<TextField>(field).controller!.text),
              isEmpty,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 5));
        },
      );

      testWidgets(
        'keyboard switches categories and repeatedly inserts in ${negative ? 'negative' : 'positive'} sidebar ${chips ? 'chips' : 'text'}',
        (tester) async {
          await mount(tester, chips);
          if (negative) {
            await tester.tap(
              find.byKey(const ValueKey('desktop-prompt-negative-tab')),
            );
            await tester.pumpAndSettle();
          }
          final host = find.byType(DesktopPromptCard);
          final field = find
              .descendant(of: host, matching: find.byType(TextField))
              .first;
          await tester.enterText(
            field,
            chips ? 'bl' : '${negative ? 'lowres' : 'solo'}, bl',
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(
            find.byKey(const ValueKey('completion-row-tag-blue sky')),
            findsNothing,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(
            find.byKey(const ValueKey('completion-row-tag-blue sky')),
            findsOneWidget,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pumpAndSettle();
          expect(find.byType(DesktopCompletionMenu), findsOneWidget);
          expect(
            negative
                ? container.read(generateProvider).negativePrompt
                : container.read(generateProvider).prompt,
            contains('blue bird'),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(
            negative
                ? container.read(generateProvider).negativePrompt
                : container.read(generateProvider).prompt,
            contains('blue sky'),
          );
          expect(find.byType(DesktopCompletionMenu), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 5));
        },
      );
    }
  }

  Finder field() => find
      .descendant(
        of: find.byType(DesktopPromptCard),
        matching: find.byType(TextField),
      )
      .first;
  Future<void> typeQuery(WidgetTester tester, String text) async {
    await tester.enterText(field(), text);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  for (final chips in [false, true]) {
    testWidgets(
      'side completion stays beside the field across typing and supports keyboard insertion (chips=$chips)',
      (tester) async {
        tester.view.physicalSize = const Size(1250, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        // The last character card can sit close to the bottom of the screen.
        await mount(tester, chips, topInset: chips ? 490 : 0);
        await typeQuery(tester, chips ? 'bl' : 'solo, bl');
        final menu = find.byType(DesktopCompletionMenu);
        final follow = tester.getRect(menu);
        final host = tester.getRect(find.byType(DesktopPromptCard));
        container
            .read(themeSettingsProvider.notifier)
            .patch((s) => s.copyWith(completionFixedToSide: true));
        await tester.pumpAndSettle();
        final fixed = tester.getRect(menu);
        expect(fixed.left, greaterThanOrEqualTo(host.right));
        expect(fixed.left, greaterThan(follow.left));
        if (!chips) {
          await captureDesktop(tester, capture, 'sidebar-completion-fixed');
        }
        await typeQuery(tester, chips ? 'blue' : 'solo, ocean view, blue');
        expect(tester.getTopLeft(menu), fixed.topLeft);
        await typeQuery(tester, chips ? 'bl' : 'solo, bl');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(container.read(generateProvider).prompt, contains('blue sky'));
        expect(menu, findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  testWidgets(
    'the local style alias previews the actual tags and inserts its fold',
    (tester) async {
      await mount(tester, true);
      await typeQuery(tester, 'd33');
      expect(find.text('artist:one, pastel colors'), findsOneWidget);
      expect(find.text('画风 1'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final draft = container.read(generateProvider);
      expect(draft.promptRaw, contains('粉彩'));
      expect(draft.prompt, 'solo, artist:one, pastel colors');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'an unmatched English word can be inserted as typed or translated without leaving the sidebar',
    (tester) async {
      await mount(tester, true);
      await typeQuery(tester, 'green');
      expect(find.text('AI 翻译「green」为英文提示词标签并插入'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(container.read(generateProvider).prompt, contains('green'));
      await typeQuery(tester, '海边夕阳');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        container.read(generateProvider).prompt,
        contains('seaside sunset'),
      );
      expect(find.byType(DesktopCompletionMenu), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('an in-flight translation cannot overwrite a newer query', (
    tester,
  ) async {
    await mount(tester, true);
    final original = service.translation = Completer<String?>();
    await typeQuery(tester, '海边夕阳');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await typeQuery(tester, '绿树');
    expect(find.text('直接将「绿树」作为原文词条插入'), findsOneWidget);
    service.translation = Completer<String?>();
    await tester.tap(find.byKey(const ValueKey('completion-fallback-0')));
    await tester.pump();
    original.complete('seaside sunset');
    await tester.pump();
    expect(container.read(generateProvider).prompt, 'solo');
    expect(find.text('翻译中…'), findsOneWidget);
    service.translation!.complete('green tree');
    await tester.pumpAndSettle();
    expect(container.read(generateProvider).prompt, 'solo, green tree');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'IME composing keeps Enter for the candidate and Escape then closes completion',
    (tester) async {
      await mount(tester, false);
      await typeQuery(tester, '海边');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '海边',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        container.read(generateProvider).prompt,
        isNot(contains('seaside sunset')),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '海边',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopCompletionMenu), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'wiki, related tags and work character picks use the selected row',
    (tester) async {
      await mount(tester, true);
      await typeQuery(tester, 'bl');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('蓝色天空'), findsOneWidget);
      await mouseClick(tester, find.text('cloud'));
      expect(container.read(generateProvider).prompt, contains('cloud'));
      await mouseClick(tester, find.byTooltip('从作品随机抽取角色'));
      expect(container.read(generateProvider).prompt, contains('hina'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );
}
