import 'fold_icon.dart';
import '../../../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../inspiration/tag_library.dart';
import '../../inspiration/tag_models.dart';
import '../data/suggestions.dart';
import '../data/tag_completion.dart';
import '../editor_models.dart';
import '../editor_settings.dart';
import '../editor_state.dart';
import 'annotated_field.dart';
import 'desktop_tag_popover.dart';
import 'editor_segments.dart';
import 'prompt_fullscreen_dialog.dart';
import 'rich_tag_controller.dart';
import 'tag_panel.dart';

/// Edits a block's body without replacing its reference in the parent prompt.
/// The sidebar keeps member tools in the inspector; other editors can float them.
class FoldInspector extends ConsumerStatefulWidget {
  const FoldInspector({
    super.key,
    required this.name,
    required this.tapGroupId,
    required this.onClose,
    required this.onDelete,
    this.onEditInspiration,
    this.initialPositive,
    this.fullscreen = false,
    this.sidebar = false,
    this.onUnpack,
    this.charId,
    this.sectionId,
  });
  final String name;
  final String? charId, sectionId;
  final Object tapGroupId;
  final VoidCallback onClose, onDelete;
  final ValueChanged<String>? onEditInspiration;
  final bool fullscreen, sidebar;
  final VoidCallback? onUnpack;
  final bool? initialPositive;

  @override
  ConsumerState<FoldInspector> createState() => _FoldInspectorState();
}

class _FoldInspectorState extends ConsumerState<FoldInspector> {
  final _controller = RichTagController();
  final _focus = FocusNode();
  final _scroll = ScrollController(keepScrollOffset: false);
  final _fieldKey = GlobalKey<AnnotatedFieldState>();
  late String _name;
  bool? _missingPositive;
  late bool _positive;
  bool _attachingSide = false;
  String _previous = '';
  bool _muting = false;
  bool _cursorDragging = false;
  Tok? _selected;
  int _anchorRevision = 0;
  List<String> _related = const [];
  String? _relatedName;
  bool _openingFullscreen = false;

  EditorNotifier get _editor => ref.read(editorProvider.notifier);

  @override
  void initState() {
    super.initState();
    _initializeSide();
    _controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(FoldInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) {
      _initializeSide();
    }
  }

  void _initializeSide() {
    final state = ref.read(editorProvider);
    final placed = state.placementOf(widget.name);
    _selectSide(
      placed,
      widget.initialPositive ??
          (placed == null
              ? state.activePositive
              : placed.positive?.name == widget.name),
    );
  }

  void _loadBody() {
    final body = _missingPositive == null
        ? ref.read(editorProvider).foldBodies[_name] ?? ''
        : '';
    if (body == _previous && _controller.text == body) return;
    _muting = true;
    _controller.value = TextEditingValue(
      text: body,
      selection: const TextSelection.collapsed(offset: -1),
    );
    _previous = body;
    _selected = widget.sidebar ? parseToks(body).firstOrNull : null;
    _muting = false;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onController() {
    if (_muting) return;
    if (_previous != _controller.text) {
      _previous = _controller.text;
      if (_missingPositive case final positive?) {
        if (_previous.trim().isEmpty) return;
        _attachingSide = true;
        try {
          final name = _editor.addFoldSide(
            widget.name,
            positive: positive,
            body: _previous,
          );
          if (name != null) {
            _name = name;
            _missingPositive = null;
          }
        } finally {
          _attachingSide = false;
        }
      } else {
        _editor.editFoldBody(_name, _controller.text);
      }
      setState(() => _selected = null);
    } else {
      _route();
    }
  }

  void _route() {
    final text = _controller.text;
    final selection = _controller.selection;
    final tokens = parseToks(text);
    final at = selection.isValid ? selection.extentOffset : -1;
    final index = tokIndexAt(text, at, tokens);
    final tok = index < 0 || at >= text.length ? null : tokens[index];
    if (_selected?.segStart != tok?.segStart) _anchorRevision++;
    setState(() => _selected = tok);
    if (_relatedName != tok?.name) {
      _relatedName = tok?.name;
      _related = const [];
      if (tok != null) {
        ref.read(tagCompletionProvider).relatedOf(tok.name).then((related) {
          if (mounted && _relatedName == tok.name) {
            setState(() => _related = related);
          }
        });
      }
    }
  }

  void _change(String text, int caret, {bool keepPanel = true}) {
    _muting = true;
    _previous = text;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret.clamp(0, text.length)),
    );
    _muting = false;
    _editor.editFoldBody(_name, text, structural: true);
    if (keepPanel) {
      _route();
    } else {
      setState(() => _selected = null);
    }
  }

  void _selectSide(PlacedPromptFold? placed, bool positive) {
    _positive = positive;
    final name = (positive ? placed?.positive : placed?.negative)?.name;
    _missingPositive = name == null ? positive : null;
    _name = name ?? widget.name;
    _selected = null;
    _loadBody();
  }

  void _openFullscreen() {
    if (_openingFullscreen) return;
    _openingFullscreen = true;
    openPromptStudio(
      context,
      charId: widget.charId,
      sectionId: widget.sectionId,
      foldName: widget.name,
      positive: _positive,
    );
    widget.onClose();
  }

  Widget _memberPanel(Tok tok, EditorSettings settings) => TagPanel(
    key: const ValueKey('fold-member-actions'),
    strip: widget.sidebar ? DesktopTagStrip.member : null,
    tapGroupId: widget.tapGroupId,
    tok: tok,
    count: countOf(tok.name),
    related: _related,
    weightStep: settings.weightStep,
    onWrap: (up) =>
        _change(wrapBracket(_controller.text, tok, up: up), tok.nameStart),
    onSetMult: (mult) {
      final next = setTokMult(_controller.text, tok, mult);
      _change(next.$1, next.$2);
    },
    onClear: () {
      final next = clearWeight(_controller.text, tok);
      _change(next.$1, next.$2);
    },
    onToggleDisabled: () =>
        _change(toggleTokDisabled(_controller.text, tok), tok.nameStart),
    onDelete: () {
      final next = deleteTok(_controller.text, tok);
      _change(next.$1, next.$2, keepPanel: false);
    },
    onRename: (name) =>
        _change(renameTok(_controller.text, tok, name), tok.nameStart),
    onAddRelated: (name) {
      final next = insertUnitAt(_controller.text, tok.segEnd, name);
      _change(next.$1, next.$2, keepPanel: false);
    },
    onClose: () => setState(() => _selected = null),
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(editorProvider, (_, next) {
      if (_attachingSide) return;
      final placed = next.placementOf(widget.name);
      final name = (_positive ? placed?.positive : placed?.negative)?.name;
      if (name != (_missingPositive == null ? _name : null)) {
        setState(() => _selectSide(placed, _positive));
      } else if (name != null && next.foldBodies[name] != _controller.text) {
        setState(_loadBody);
      }
    });
    final state = ref.watch(editorProvider);
    final settings =
        ref.watch(editorSettingsProvider).value ?? const EditorSettings();
    _controller.showTrans = settings.showTranslation;
    final placed = state.placementOf(widget.name);
    final link = placed?.link;
    final tokens = parseToks(_controller.text);
    final mixed = tokens.any(
      (t) => (t.effMult - tokens.first.effMult).abs() > .0001,
    );
    final mult = tokens.isEmpty || mixed ? 1.0 : tokens.first.effMult;
    final disabled = allFoldMembersDisabled(tokens);
    final blockTok = Tok(
      segStart: 0,
      segEnd: _name.length,
      coreStart: 0,
      coreEnd: _name.length,
      innerStart: 0,
      innerEnd: _name.length,
      nameStart: 0,
      nameEnd: _name.length,
      braceLevel: 0,
      numMult: mult,
      disabled: disabled,
      name: '#$_name',
    );
    void whole(String Function(String, int, int) edit) {
      if (tokens.isEmpty) return;
      _change(
        edit(_controller.text, 0, tokens.length - 1),
        0,
        keepPanel: false,
      );
    }

    final sides = EditorSegments<bool>(
      options: {
        for (final (positive, name) in [
          (true, placed?.positive?.name),
          (false, placed?.negative?.name),
        ])
          positive:
              '${positive ? context.l10n.positiveShort : context.l10n.negativeShort} ${parseToks(state.foldBodies[name] ?? '').length}',
      },
      optionKey: (positive) =>
          ValueKey(positive ? 'fold-inspector-正面' : 'fold-inspector-负面'),
      value: _positive,
      onPick: (positive) => setState(() => _selectSide(placed, positive)),
    );
    final field = AnnotatedField(
      key: _fieldKey,
      controller: _controller,
      focusNode: _focus,
      onCursorDrag: (dragging) => setState(() => _cursorDragging = dragging),
      hint: switch (_missingPositive) {
        true => context.l10n.emptyTemporaryPrompt(context.l10n.positiveShort),
        false => context.l10n.emptyTemporaryPrompt(context.l10n.negativeShort),
        null => '输入块内提示词…',
      },
      showTrans: settings.showTranslation,
      showWeightWash: settings.showWeightWash,
      fontSize: settings.fontSize,
      scrollable: true,
      scrollController: _scroll,
      minLines: 3,
      padding: const EdgeInsets.symmetric(vertical: 4),
    );
    final content = widget.sidebar
        ? field
        : DesktopTagPopover(
            yieldToControlDrag: true,
            tapGroupId: widget.tapGroupId,
            visible: _selected != null && !_cursorDragging,
            anchor: () => _fieldKey.currentState?.selectionAnchor(),
            anchorRevision: _anchorRevision,
            onDismiss: () => setState(() => _selected = null),
            panel: _selected == null
                ? const SizedBox.shrink()
                : _memberPanel(_selected!, settings),
            child: field,
          );
    final footer = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          l10nNow.desktopClickTextToEditItTheControlsBelow,
          style: context.texts.labelSmall!.copyWith(
            color: context.scheme.outline,
          ),
        ),
        const Divider(),
      ],
    );
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          if (_selected != null) {
            setState(() => _selected = null);
          } else {
            widget.onClose();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: widget.sidebar
          ? _sidebarPanel(
              context,
              state,
              link,
              tokens,
              settings,
              field,
              sides,
              mult: mult,
              mixed: mixed,
              disabled: disabled,
              whole: whole,
            )
          : TagPanel(
              key: const ValueKey('fold-inspector'),
              tok: blockTok,
              titleSpan: foldLabelSpan(
                _name,
                foldIconsOf(state.foldLinks)[_name],
                hash: true,
              ),
              count: null,
              related: const [],
              showWiki: false,
              copyText: _controller.text,
              content: content,
              contentHeader: Align(
                alignment: Alignment.centerRight,
                child: sides,
              ),
              contentFooter: footer,
              constrainContent: true,
              expandContent: widget.fullscreen,
              temporaryInspiration: link?.temporaryCategory != null,
              onFullscreen: widget.fullscreen ? null : _openFullscreen,
              onEditInspiration: widget.onEditInspiration == null
                  ? null
                  : () {
                      final name = _name;
                      if (widget.fullscreen) widget.onClose();
                      widget.onEditInspiration!(name);
                    },
              mixedWeight: mixed,
              weightStep: settings.weightStep,
              onWrap: (up) => whole(
                (text, first, last) => batchWrap(text, first, last, up: up),
              ),
              onSetMult: (mult) => whole(
                (text, first, last) => batchSetMult(text, first, last, mult),
              ),
              onClear: () => whole(batchClearWeight),
              onToggleDisabled: () => whole(
                (text, first, last) =>
                    batchSetDisabled(text, first, last, !disabled),
              ),
              onDelete: widget.onDelete,
              onClose: widget.onClose,
              onAddRelated: (_) {},
            ),
    );
  }

  Widget _sidebarPanel(
    BuildContext context,
    EditorState state,
    PromptFoldLink? link,
    List<Tok> tokens,
    EditorSettings settings,
    Widget field,
    Widget sides, {
    required double mult,
    required bool mixed,
    required bool disabled,
    required void Function(String Function(String, int, int)) whole,
  }) {
    final l10n = context.l10n;
    final scheme = context.scheme;
    final temporaryIcon = foldIconsOf(state.foldLinks)[_name];
    final sourceId = link?.sourceEntryId;
    final category = sourceId == null
        ? null
        : ref.watch(
            tagLibraryProvider.select(
              (library) => library.value?.entries
                  .where((entry) => entry.id == sourceId)
                  .firstOrNull
                  ?.category,
            ),
          );
    final definition = category == null ? null : tagCategoryDef(category);
    final source = sourceId?.startsWith('pub_') == true
        ? l10n.publicLibrary
        : definition == null
        ? null
        : l10n.myInCat(definition.label);
    final sideLabel = _positive ? l10n.positiveShort : l10n.negativeShort;
    final header = LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          Icon(
            temporaryIcon ?? definition?.icon ?? Icons.view_module_outlined,
            size: 18,
            color: scheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '#${temporaryIcon == null ? _name : _name.substring(1).trimLeft()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  [
                    ?source,
                    '$sideLabel ${l10n.itemsCount(tokens.length)}',
                    if (link?.paired == true) l10n.pairedPromptBlock,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * .71),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  sides,
                  if (widget.onEditInspiration case final edit?)
                    DesktopTagAction(
                      icon: link?.temporaryCategory != null
                          ? Icons.library_add_outlined
                          : Icons.edit_outlined,
                      label: link?.temporaryCategory != null
                          ? l10n.saveSelectionAsInspiration
                          : l10n.editInspirationBlock,
                      onPressed: () => edit(_name),
                    ),
                  DesktopTagAction(
                    icon: Icons.open_in_full,
                    label: l10n.desktopOpenFullScreenPromptEditor,
                    onPressed: _openFullscreen,
                  ),
                  DesktopTagAction(
                    icon: Icons.content_copy,
                    label: l10n.copy,
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: _controller.text),
                    ),
                  ),
                  DesktopTagAction(
                    icon: Icons.close,
                    label: l10n.close,
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    final action = _selected;
    return Material(
      key: const ValueKey('fold-inspector'),
      color: scheme.surface,
      child: LayoutBuilder(
        builder: (context, bounds) {
          final wholeButtons = <Widget>[
            DesktopWeightControl(
              prefix: l10n.wholeBlock,
              multiplier: mult,
              mixed: mixed,
              enabled: tokens.isNotEmpty && !disabled,
              onStep: (up) => whole(
                (s, a, b) => batchSetMult(
                  s,
                  a,
                  b,
                  mult + (up ? settings.weightStep : -settings.weightStep),
                ),
              ),
            ),
            DesktopTagAction(
              icon: disabled
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              label: disabled ? l10n.enableBlock : l10n.disableBlock,
              showLabel:
                  bounds.maxWidth >=
                  410 * MediaQuery.textScalerOf(context).scale(14) / 14,
              onPressed: tokens.isEmpty
                  ? null
                  : () => whole(
                      (s, a, b) => batchSetDisabled(s, a, b, !disabled),
                    ),
            ),
            DesktopTagAction(
              icon: Icons.unfold_more,
              label: l10n.unpackBlock,
              showLabel:
                  bounds.maxWidth >=
                  410 * MediaQuery.textScalerOf(context).scale(14) / 14,
              onPressed: widget.onUnpack,
            ),
            DesktopTagAction(
              key: const ValueKey('fold-whole-clear-weight'),
              icon: Icons.restart_alt,
              label: l10n.studioResetWeight,
              showLabel: true,
              onPressed: tokens.isEmpty ? null : () => whole(batchClearWeight),
            ),
          ];
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: header,
              ),
              const Divider(height: 1),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: field,
                ),
              ),
              const Divider(height: 1),
              SizedBox(
                height: 38 * MediaQuery.textScalerOf(context).scale(14) / 14,
                child: action == null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l10n.selectBlockTag,
                            style: context.texts.bodySmall,
                          ),
                        ),
                      )
                    : _memberPanel(action, settings),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: wholeButtons,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
