import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/editor_theme.dart';
import '../../core/theme/theme_settings.dart';
import '../desktop/desktop_pane_divider.dart';
import 'widgets/desktop_tag_popover.dart';
import '../../core/ui/desktop_text_selection.dart';
import '../../core/util/nai_tokenizer.dart';
import '../../l10n/l10n.dart';
import '../generate/canvas_state.dart';
import '../generate/char_position.dart';
import '../inspiration/widgets/tag_card.dart' show TagCardPreview;
import '../generate/display_names.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart';
import '../generate/prompt_presets.dart';
import '../generate/prompt_sections.dart';
import '../generate/widgets/position_grid_dialog.dart';
import '../generate/widgets/prompt_inline_name.dart';
import '../generate/widgets/prompt_reorder_scroll.dart'
    show desktopPromptDragProxy;
import '../generate/widgets/common.dart' show hintSnack;
import '../inspiration/public_tags.dart'
    show tagCoverPreviewsProvider, tagPreviewOf;
import '../inspiration/tag_library.dart';
import '../inspiration/inspiration_examples.dart'
    show isStockInspirationExample;
import '../inspiration/tag_models.dart';
import 'data/suggestions.dart';
import 'data/tag_completion.dart';
import 'data/tag_translation_service.dart';
import 'editor_models.dart';
import 'editor_settings.dart';
import 'editor_state.dart';
import 'widgets/annotated_field.dart';
import 'widgets/chip_flow_view.dart';
import 'widgets/desktop_completion_menu.dart';
import 'widgets/editor_settings_sheet.dart';
import 'widgets/editor_segments.dart';
import 'widgets/fold_icon.dart';
import 'widgets/rich_tag_controller.dart';
import 'widgets/tag_panel.dart';

part 'widgets/studio_prompt_pane.dart';
part 'widgets/studio_outline.dart';
part 'widgets/studio_inspector.dart';
part 'widgets/studio_position.dart';
part 'widgets/studio_completion.dart';

enum _StudioLayout { split, positive, negative }

typedef _Target = ({String? charId, String? sectionId});
const _main = (charId: null, sectionId: null);

class PromptStudio extends ConsumerStatefulWidget {
  const PromptStudio({
    super.key,
    this.charId,
    this.sectionId,
    this.foldName,
    this.positive = true,
  });
  final String? charId, sectionId, foldName;
  final bool positive;
  @override
  ConsumerState<PromptStudio> createState() => _PromptStudioState();
}

class _PromptStudioState extends ConsumerState<PromptStudio>
    with _StudioCompletion {
  final _scaffold = GlobalKey<ScaffoldState>();
  late _Target _target;
  String? _block;
  late bool _positive;
  bool _ready = false;
  String? _canvasId;
  Set<int> _selection = {};
  final _librarySearch = TextEditingController();
  String _libraryQuery = '';
  final _libraryRomanizations = Expando<String>();
  var _layout = _StudioLayout.split;
  double _splitFraction = .5;
  var _paneKeys = {
    for (final side in [true, false]) side: GlobalKey<_StudioPaneState>(),
  };
  late final EditorSessions _sessions;
  EditorNotifier get _editor => ref.read(editorProvider.notifier);
  EditorState get _state => ref.read(editorProvider);

  @override
  void initState() {
    super.initState();
    _sessions = ref.read(editorSessionsProvider)
      ..prepareInputs.add(_commitInput);
    _target = (charId: widget.charId, sectionId: widget.sectionId);
    _positive = widget.positive;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open(_target, block: widget.foldName, positive: _positive);
    });
  }

  @override
  void dispose() {
    _librarySearch.dispose();
    _sessions.prepareInputs.remove(_commitInput);
    super.dispose();
  }

  void _commitInput() {
    _paneKeys[_positive]?.currentState?._commitChips();
    _closeCompletion();
  }

  void _open(
    _Target target, {
    String? block,
    bool? positive,
    int? foldIndex,
    bool reload = false,
  }) {
    if (reload) {
      _closeCompletion();
    } else {
      _commitInput();
      if (_ready) _editor.flushPendingWriteBack();
    }
    final gen = ref.read(generateProvider);
    FocusManager.instance.primaryFocus?.unfocus();
    final side = positive ?? _positive;
    if (!_ready || target != _target || reload) {
      _canvasId = ref.read(canvasWorkspaceProvider).activeId;
      final (pos, neg) = editorDrafts(
        gen,
        charId: target.charId,
        sectionId: target.sectionId,
      );
      _editor.load(
        positive: pos,
        negative: neg,
        startPositive: side || gen.params.isNaiMedium,
        charId: target.charId,
        sectionId: target.sectionId,
      );
    }
    if (foldIndex != null) {
      final refs = parseFoldRefs(
        side ? _state.positiveText : _state.negativeText,
        _state.foldBodies,
      );
      block = foldIndex < refs.length ? refs[foldIndex].name : null;
    }
    final placed = block == null ? null : _state.placementOf(block);
    var active = side;
    if (gen.params.isNaiMedium && placed == null) active = true;
    _editor.setActivePositive(active);
    setState(() {
      _target = target;
      _ready = true;
      _block = placed == null ? null : block;
      _positive = active;
      if (_layout != _StudioLayout.split) {
        _layout = active ? _StudioLayout.positive : _StudioLayout.negative;
      }
      _selection = {};
      _paneKeys = {
        for (final side in [true, false]) side: GlobalKey<_StudioPaneState>(),
      };
    });
    _scaffold.currentState?.closeDrawer();
  }

  String? _sideName(EditorState st, bool positive) {
    if (_block == null) return null;
    final placed = st.placementOf(_block!);
    return (positive ? placed?.positive : placed?.negative)?.name;
  }

  String _text(EditorState st, bool positive) => _block == null
      ? (positive ? st.positiveText : st.negativeText)
      : st.foldBodies[_sideName(st, positive)] ?? '';
  bool _available(bool side) =>
      side || _block != null || !ref.read(generateProvider).params.isNaiMedium;
  Map<String, String> _bodies(EditorState st) =>
      _block == null ? st.foldBodies : const {};
  void _activate(bool side) {
    if (!_available(side) || side == _positive) return;
    _commitInput();
    _editor.setActivePositive(side);
    setState(() {
      _positive = side;
      _selection = {};
    });
  }

  void _select(bool side, Set<int> indices) {
    if (!_available(side)) return;
    _activate(side);
    if (!setEquals(_selection, indices)) setState(() => _selection = indices);
  }

  void _write(
    bool side,
    String text, {
    bool structural = false,
    bool detach = false,
  }) {
    if (!_available(side) || text == _text(_state, side)) return;
    _activate(side);
    final block = _block;
    if (block == null) {
      _editor.editActive(
        text,
        structural: structural,
        detachRemovedFolds: detach,
      );
    } else if (_sideName(_state, side) case final name?) {
      _editor.editFoldBody(name, text, structural: structural);
    } else {
      _editor.addFoldSide(block, positive: side, body: text);
    }
  }

  void _history(bool redo) {
    _commitInput();
    final editedBlock = _block;
    redo ? _editor.redo() : _editor.undo();
    setState(() {
      _selection = {};
      if (editedBlock != null && _state.placementOf(editedBlock) == null) {
        _block = null;
      }
    });
  }

  String _insertion(
    String value,
    Suggestion? suggestion, {
    required bool plainSlot,
  }) {
    final text = value.trim();
    if (plainSlot &&
        _block == null &&
        suggestion?.insertText?.isNotEmpty == true &&
        (suggestion!.kind == SuggestionKind.artist ||
            suggestion.kind == SuggestionKind.oc) &&
        parseToks(text).length > 1) {
      return foldRefLiteral(
        _editor.registerFold(suggestion.text, stripFolds(text)),
      );
    }
    return text;
  }

  void _deleteTarget(_Target target) {
    _sessions.flushPending();
    final notifier = ref.read(generateProvider.notifier);
    if (target.charId case final id?) {
      notifier.removeCharacter(id);
    } else if (target.sectionId case final id?) {
      notifier.removeSection(id);
    }
  }

  String _romanizations(TagEntry entry) {
    final cached = _libraryRomanizations[entry];
    if (cached != null) return cached;
    final keys = <String>[];
    for (final name in [entry.name, ...entry.aliases]) {
      final syllables = PinyinHelper.getPinyinE(
        name,
      ).toLowerCase().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      keys.add(syllables.join());
      keys.add(syllables.map((s) => s[0]).join());
    }
    return _libraryRomanizations[entry] = keys.join(' ');
  }

  void _setLibraryQuery(String value) => setState(() => _libraryQuery = value);

  void _insertEntry(TagEntry entry) {
    if (!_available(_positive)) return;
    _commitInput();
    if (entry.category == TagCategory.character &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _editor.flushPendingWriteBack();
      final gen = ref.read(generateProvider);
      final notifier = ref.read(generateProvider.notifier);
      final current = gen.characters
          .where((c) => c.id == _target.charId)
          .firstOrNull;
      final reuse =
          current != null &&
          [
            current.positive,
            current.negative,
            current.positiveRaw,
            current.negativeRaw,
          ].every((text) => text.trim().isEmpty);
      if (!reuse &&
          gen.characters.length >= maxCharactersOf(gen.params.model)) {
        hintSnack(
          context,
          context.l10n.charsFullN(maxCharactersOf(gen.params.model)),
        );
        return;
      }
      if (!reuse) notifier.addCharacter();
      final id = reuse
          ? current.id
          : ref.read(generateProvider).characters.last.id;
      final draft = foldTagEntry(entry);
      final positive = outputOf(draft.positiveDraft);
      final negative = outputOf(draft.negativeDraft);
      notifier.fillCharacterFrom(
        id,
        name: entry.name,
        positive: positive,
        negative: negative,
        avatar: tagPreviewOf(
          entry,
          ref.read(tagCoverPreviewsProvider(TagCategory.character)),
        ),
        source: entry.id,
      );
      notifier.updateCharacter(
        id,
        positiveRaw: draftOf(draft.positiveDraft, positive),
        negativeRaw: draftOf(draft.negativeDraft, negative),
        foldLinks: draft.links,
      );
      _open(
        (charId: id, sectionId: null),
        positive: positive.isNotEmpty || gen.params.isNaiMedium,
        reload: true,
      );
      _scaffold.currentState?.closeEndDrawer();
      return;
    }
    if (_block != null) {
      final body = _positive ? entry.positive : entry.negative;
      _write(
        _positive,
        appendUnit(_text(_state, _positive), stripFolds(body)),
        structural: true,
      );
      setState(() => _selection = {});
    } else {
      _editor.applySavedInspiration(
        entryId: entry.id,
        title: entry.name,
        positiveBody: _positive ? entry.positive : null,
        negativeBody: _positive ? null : entry.negative,
      );
      setState(() => _selection = {});
    }
    _scaffold.currentState?.closeEndDrawer();
  }

  String _name(GenerateState gen) {
    if (_block != null) return _block!;
    final l = context.l10n;
    if (_target.charId != null) {
      final char = gen.characters
          .where((c) => c.id == _target.charId)
          .firstOrNull;
      return characterDisplayName(l, char?.name ?? l.refCharacter);
    }
    final section = gen.sections
        .where((s) => s.id == _target.sectionId)
        .firstOrNull;
    return section == null
        ? context.l10n.studioMain
        : sectionDisplayName(l, section.name);
  }

  int _count(String text) =>
      totalPromptTokens(ref.watch(naiTokenizerProvider).value, main: text);
  int _sideCount(EditorState st, bool side) =>
      _count(outputOf(expandFolds(_text(st, side), _bodies(st))));

  @override
  Widget build(BuildContext context) {
    ref.listen(generateProvider, (previous, next) {
      if (!_ready || previous == null || _editor.isWritingBack) return;
      final changedCanvas =
          _canvasId != ref.read(canvasWorkspaceProvider).activeId;
      final char = _target.charId, section = _target.sectionId;
      final missing =
          (char != null && !next.characters.any((c) => c.id == char)) ||
          (section != null && !next.sections.any((s) => s.id == section));
      if (changedCanvas ||
          missing ||
          (next.params.isNaiMedium && _block == null && !_positive) ||
          editorDrafts(previous, charId: char, sectionId: section) !=
              editorDrafts(next, charId: char, sectionId: section) ||
          !listEquals(
            editorFoldLinks(previous, charId: char, sectionId: section),
            editorFoldLinks(next, charId: char, sectionId: section),
          )) {
        _open(
          changedCanvas || missing ? _main : _target,
          block: changedCanvas || missing ? null : _block,
          reload: true,
        );
      }
    });
    ref.listen(editorSettingsProvider, (old, next) {
      if (old?.value?.chipMode != next.value?.chipMode ||
          next.value?.enableCompletion == false && _source != null) {
        _commitInput();
      }
    });
    final fixed = ref.watch(
      themeSettingsProvider.select((s) => s.studioCompletionFixedToSide),
    );
    final gen = ref.watch(generateProvider);
    final st = ref.watch(editorProvider);
    final settings =
        ref.watch(editorSettingsProvider).value ?? const EditorSettings();
    final theme = editorTheme(context);
    final positiveCount = _sideCount(st, true);
    final positiveOnly = gen.params.isNaiMedium && _block == null;
    final negativeCount = positiveOnly ? 0 : _sideCount(st, false);
    return Theme(
      data: theme,
      child: LayoutBuilder(
        builder: (context, size) {
          final width = size.maxWidth;
          final rails = width >= 970;
          final showInspector = rails || fixed && _source != null;
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final narrow = width < 665 * scale;
          final left = (width * .18).clamp(180.0, 248.0);
          final right = math.min(
            (width * .235).clamp(235.0, 320.0),
            width * .47,
          );
          final title = _name(gen);
          final outline = _StudioOutline(studio: this, gen: gen, state: st);
          final inspector = _StudioInspector(
            studio: this,
            state: st,
            gen: gen,
            showCompletion: showInspector && fixed && _source != null,
          );
          final actions = <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
                _history(false),
            const SingleActivator(LogicalKeyboardKey.keyY, control: true): () =>
                _history(true),
            const SingleActivator(
              LogicalKeyboardKey.keyZ,
              control: true,
              shift: true,
            ): () =>
                _history(true),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.maybePop(context),
          };
          return CallbackShortcuts(
            bindings: actions,
            child: PopScope<void>(
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) _commitInput();
              },
              child: Scaffold(
                key: _scaffold,
                drawer: rails ? null : Drawer(child: SafeArea(child: outline)),
                endDrawer: showInspector
                    ? null
                    : Drawer(child: SafeArea(child: inspector)),
                body: SafeArea(
                  child: !_ready
                      ? const SizedBox.expand()
                      : Column(
                          children: [
                            _header(
                              context,
                              gen,
                              st,
                              settings,
                              title,
                              rails,
                              showInspector,
                              narrow,
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (rails) ...[
                                    SizedBox(width: left, child: outline),
                                    const VerticalDivider(width: 1),
                                  ],
                                  Expanded(
                                    child: Column(
                                      children: [
                                        _stageHeader(
                                          context,
                                          gen,
                                          st,
                                          title,
                                          narrow,
                                          positiveCount,
                                          negativeCount,
                                        ),
                                        const Divider(height: 1),
                                        Expanded(
                                          child: _promptPanes(
                                            st,
                                            settings,
                                            positiveOnly: positiveOnly,
                                            fixed: fixed,
                                            positiveCount: positiveCount,
                                            negativeCount: negativeCount,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (showInspector) ...[
                                    const VerticalDivider(width: 1),
                                    SizedBox(width: right, child: inspector),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _promptPanes(
    EditorState state,
    EditorSettings settings, {
    required bool positiveOnly,
    required bool fixed,
    required int positiveCount,
    required int negativeCount,
  }) => LayoutBuilder(
    builder: (context, space) {
      final split = !positiveOnly && _layout == _StudioLayout.split;
      Widget pane(bool side) => _StudioPane(
        key: _paneKeys[side],
        studio: this,
        state: state,
        positive: side,
        settings: settings,
        split: split,
        follow: !fixed,
        count: side ? positiveCount : negativeCount,
      );
      if (!split) {
        return pane(positiveOnly || _layout == _StudioLayout.positive);
      }
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final vertical = space.maxWidth < 480;
      final available = math.max(
        0.0,
        (vertical ? space.maxHeight : space.maxWidth) -
            DesktopPaneDivider.extent,
      );
      final minimum = math.min(
        available / 2,
        (vertical ? 100.0 : 180.0) * scale,
      );
      final positiveSize = (available * _splitFraction).clamp(
        minimum,
        available - minimum,
      );
      return Flex(
        direction: vertical ? Axis.vertical : Axis.horizontal,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: vertical ? null : positiveSize,
            height: vertical ? positiveSize : null,
            child: pane(true),
          ),
          DesktopPaneDivider(
            key: const ValueKey('studio-split-divider'),
            axis: vertical ? Axis.vertical : Axis.horizontal,
            label: context.l10n.desktopPositivePrompt,
            paneWidth: positiveSize,
            onResize: (size) {
              if (available <= 0) return;
              setState(
                () => _splitFraction =
                    size.clamp(minimum, available - minimum) / available,
              );
            },
            onReset: () => setState(() => _splitFraction = .5),
          ),
          Expanded(child: pane(false)),
        ],
      );
    },
  );

  Widget _header(
    BuildContext context,
    GenerateState gen,
    EditorState st,
    EditorSettings settings,
    String title,
    bool rails,
    bool showInspector,
    bool narrow,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final preset = ref.watch(activePromptPresetProvider);
    final tokenizer = ref.watch(naiTokenizerProvider).value;
    final chars = ref.watch(countedCharactersProvider);
    final total = totalPromptTokens(
      tokenizer,
      main: _positive
          ? (mainEnabled(gen.sections) ? gen.prompt : '')
          : gen.negativePrompt,
      parts: [
        ...sectionTexts(gen.sections, positive: _positive),
        for (final c in chars) _positive ? c.positive : c.negative,
      ],
      preset: (_positive ? preset?.positive : preset?.negative) ?? '',
    );
    final limit = tokenLimitOf(gen.params.model);
    final canvas = canvasDisplayName(
      context.l10n,
      ref.watch(canvasWorkspaceProvider.select((w) => w.active.name)),
    );
    Widget tool(IconData icon, String label, VoidCallback? fn, [String? key]) =>
        IconButton(
          key: key == null ? null : ValueKey(key),
          tooltip: label,
          onPressed: fn,
          icon: Icon(icon, size: 19),
          visualDensity: VisualDensity.compact,
        );
    final tools = [
      if (_block != null || !gen.params.isNaiMedium)
        EditorSegments<_StudioLayout>(
          options: {
            _StudioLayout.split: context.l10n.studioBoth,
            _StudioLayout.positive: context.l10n.studioPosOnly,
            _StudioLayout.negative: context.l10n.studioNegOnly,
          },
          value: _layout,
          onPick: (v) {
            setState(() => _layout = v);
            if (v != _StudioLayout.split) {
              _activate(v == _StudioLayout.positive);
            }
          },
        ),
      EditorSegments<bool>(
        options: {false: context.l10n.modeText, true: context.l10n.modeChips},
        value: settings.chipMode,
        onPick: (v) => ref
            .read(editorSettingsProvider.notifier)
            .patch((s) => s.copyWith(chipMode: v)),
      ),
      tool(
        Icons.undo,
        context.l10n.undo,
        st.canUndo ? () => _history(false) : null,
        'studio-undo',
      ),
      tool(
        Icons.redo,
        context.l10n.studioRedo,
        st.canRedo ? () => _history(true) : null,
        'studio-redo',
      ),
      tool(
        Icons.settings_outlined,
        context.l10n.editorSettings,
        () => showDesktopEditorSettings(context),
      ),
    ];
    final meter = SizedBox(
      width:
          (narrow ? 118.0 : 156.0) *
          (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 1.5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  gen.params.isNaiMedium
                      ? nai5FullMediumLabel
                      : gen.params.model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$total / $limit',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: (total / limit).clamp(0, 1),
            minHeight: 4,
            color: total > limit ? scheme.error : null,
            borderRadius: BorderRadius.circular(8),
          ),
        ],
      ),
    );
    final roomy =
        MediaQuery.sizeOf(context).width >=
        1180 * (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 1.5);
    final navigation = Row(
      children: [
        if (roomy)
          TextButton.icon(
            key: const ValueKey('studio-back'),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back, size: 17),
            label: Text(context.l10n.desktopBackToCreate),
          )
        else
          tool(
            Icons.arrow_back,
            context.l10n.desktopBackToCreate,
            () => Navigator.of(context).pop(),
            'studio-back',
          ),
        if (!rails)
          tool(
            Icons.account_tree_outlined,
            context.l10n.studioOutline,
            () => _scaffold.currentState?.openDrawer(),
          ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$canvas  /  $title',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      ],
    );
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: navigation),
                meter,
                if (roomy)
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: tools,
                    ),
                  )
                else if (!narrow) ...[
                  const SizedBox(width: 12),
                  ...tools,
                ],
                if (!showInspector)
                  tool(
                    Icons.tune,
                    context.l10n.studioInspector,
                    () => _scaffold.currentState?.openEndDrawer(),
                  ),
              ],
            ),
            if (narrow)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: tools),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stageHeader(
    BuildContext context,
    GenerateState gen,
    EditorState st,
    String title,
    bool narrow,
    int positiveCount,
    int negativeCount,
  ) {
    final l = context.l10n;
    final parent = _target.charId != null
        ? context.l10n.refCharacter
        : _target.sectionId != null
        ? context.l10n.studioSection
        : context.l10n.studioGlobal;
    void copyPrompt() {
      final parts = [
        for (final side in [
          true,
          if (_block != null || !gen.params.isNaiMedium) false,
        ])
          outputOf(expandFolds(_text(st, side), _bodies(st))),
      ];
      Clipboard.setData(
        ClipboardData(text: parts.where((s) => s.isNotEmpty).join('\n\n')),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.copied), duration: const Duration(seconds: 1)),
      );
    }

    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: LayoutBuilder(
        builder: (_, bounds) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final wide = bounds.maxWidth >= 620 * scale;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                if (_block != null)
                  IconButton(
                    tooltip: l.studioUp,
                    icon: const Icon(Icons.subdirectory_arrow_left),
                    onPressed: () => _open(_target),
                  )
                else
                  Icon(
                    _target.charId != null
                        ? Icons.person_outline
                        : Icons.edit_outlined,
                    size: 19,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (!narrow)
                  Container(
                    margin: const EdgeInsets.only(right: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _block == null ? parent : l.studioBlock,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                if (wide) ...[
                  Text(
                    gen.params.isNaiMedium && _block == null
                        ? '${l.positiveShort} $positiveCount tok'
                        : '${l.positiveShort} $positiveCount · ${l.negativeShort} $negativeCount tok',
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    key: const ValueKey('studio-copy-prompt'),
                    onPressed: copyPrompt,
                    icon: const Icon(Icons.copy_all_outlined, size: 16),
                    label: Text(l.studioCopyComplete),
                  ),
                ] else
                  IconButton(
                    key: const ValueKey('studio-copy-prompt'),
                    tooltip: l.studioCopyComplete,
                    icon: const Icon(Icons.copy_all_outlined, size: 19),
                    onPressed: copyPrompt,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
