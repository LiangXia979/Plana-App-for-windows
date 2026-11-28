part of '../prompt_studio.dart';

class _StudioPane extends ConsumerStatefulWidget {
  const _StudioPane({
    super.key,
    required this.studio,
    required this.state,
    required this.positive,
    required this.settings,
    required this.count,
    required this.split,
    required this.follow,
  });
  final _PromptStudioState studio;
  final EditorState state;
  final bool positive, split, follow;
  final EditorSettings settings;
  final int count;
  @override
  ConsumerState<_StudioPane> createState() => _StudioPaneState();
}

class _StudioPaneState extends ConsumerState<_StudioPane> {
  final _controller = RichTagController();
  final _focus = FocusNode();
  final _scroll = ScrollController(keepScrollOffset: false);
  final _chipInput = TextEditingController(text: kChipInputPad);
  final _chipFocus = FocusNode();
  final _field = GlobalKey<AnnotatedFieldState>();
  TextSelection? _completionSelection;
  Rect? _followCaret;
  bool _anchorScheduled = false;
  TextEditingValue get _inputValue =>
      widget.settings.chipMode ? _chipInput.value : _controller.value;
  late String _previous;
  bool _syncing = false;
  _PromptStudioState get studio => widget.studio;
  bool get side => widget.positive;

  @override
  void initState() {
    super.initState();
    _previous = studio._text(widget.state, side);
    _controller.text = _previous;
    _controller.addListener(_edited);
    DesktopTextRanges.of(_controller).addListener(_selectionChanged);
    _focus.addListener(_focusChanged);
    _chipFocus.addListener(_focusChanged);
    _translate(_previous);
  }

  void _focusChanged() {
    if (_focus.hasFocus || _chipFocus.hasFocus) {
      studio._activate(side);
      // A Windows click can move the caret before the field receives focus.
      if (_focus.hasFocus) _selectionChanged();
    } else if (studio._source == this) {
      studio._closeCompletion();
    }
  }

  Rect? _caret() {
    if (!widget.settings.chipMode) {
      return _field.currentState?.selectionAnchor();
    }
    final render = _chipFocus.context
        ?.findAncestorStateOfType<EditableTextState>()
        ?.renderEditable;
    if (render == null || !render.hasSize || !_chipInput.selection.isValid) {
      return null;
    }
    final rect = render.getLocalRectForCaret(_chipInput.selection.extent);
    return Rect.fromPoints(
      render.localToGlobal(rect.topLeft),
      render.localToGlobal(rect.bottomRight),
    );
  }

  // RenderEditable lays out the new text after the controller notifies listeners.
  // Read its caret after layout, including when the text scrolls inside the pane.
  void _refreshFollowCaret() {
    if (_anchorScheduled || !widget.follow || studio._source != this) return;
    _anchorScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorScheduled = false;
      if (!mounted || !widget.follow || studio._source != this) return;
      var caret = _caret();
      final box = context.findRenderObject() as RenderBox?;
      if (caret != null &&
          box != null &&
          box.hasSize &&
          !(box.localToGlobal(Offset.zero) & box.size).overlaps(
            caret.inflate(1),
          )) {
        caret = null;
      }
      if (caret != _followCaret) setState(() => _followCaret = caret);
    });
  }

  void _commitChips([String? submitted]) {
    final draft = chipInputBody(_chipInput.text);
    if (draft.isEmpty) return;
    _clearChips();
    final raw = (submitted ?? draft).trim();
    if (raw.isEmpty) return;
    studio._write(
      side,
      appendUnit(studio._text(studio._state, side), raw),
      structural: true,
    );
  }

  void _clearChips() {
    _chipInput.value = const TextEditingValue(
      text: kChipInputPad,
      selection: TextSelection.collapsed(offset: 1),
    );
  }

  void _chipChanged(String raw) {
    studio._activate(side);
    final word = chipInputBody(raw);
    final delimiter = RegExp(r'[,，\n]\s*$').firstMatch(word);
    if (delimiter != null && _chipInput.value.composing.isCollapsed) {
      _commitChips(word.substring(0, delimiter.start));
      studio._closeCompletion();
    } else {
      studio._search(this, word);
    }
  }

  void _accept(
    String text,
    Suggestion? suggestion, {
    required bool continuous,
  }) {
    if (widget.settings.chipMode) {
      _clearChips();
      final insertion = studio._insertion(text, suggestion, plainSlot: true);
      studio._write(
        side,
        appendUnit(studio._text(studio._state, side), insertion),
        structural: true,
      );
      _chipFocus.requestFocus();
      return;
    }
    final before = _controller.text;
    final caret = _controller.selection.extentOffset.clamp(0, before.length);
    final (String next, int at) = continuous
        ? () {
            final prefix = before.substring(0, caret);
            final separator =
                prefix.trim().isEmpty || RegExp(r'[,，\n]\s*$').hasMatch(prefix)
                ? ''
                : ', ';
            final insertion =
                separator +
                studio._insertion(text, suggestion, plainSlot: true);
            return withPromptTrailingComma(
              before.replaceRange(caret, caret, insertion),
              caret + insertion.length,
              autoComma: widget.settings.autoComma,
            );
          }()
        : completePromptAt(
            before,
            caret,
            (plain) => studio._insertion(text, suggestion, plainSlot: plain),
            autoComma: widget.settings.autoComma,
          );
    _syncing = true;
    _previous = next;
    _completionSelection = TextSelection.collapsed(offset: at);
    _controller.value = TextEditingValue(
      text: next,
      selection: _completionSelection!,
    );
    _syncing = false;
    studio._write(side, next, structural: true);
    _translate(next);
    _focus.requestFocus();
    _selectionChanged();
  }

  void _translate(String text) {
    if (widget.settings.showTranslation) {
      ref
          .read(tagTranslationServiceProvider)
          .request(parseToks(text).map((t) => t.name));
    }
  }

  @override
  void didUpdateWidget(_StudioPane old) {
    super.didUpdateWidget(old);
    final value = studio._text(widget.state, side);
    if (_controller.text != value) {
      _syncing = true;
      final at = _controller.selection.extentOffset.clamp(0, value.length);
      _previous = value;
      DesktopTextRanges.of(_controller).replace(const []);
      _controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: at),
      );
      _syncing = false;
      _translate(value);
    } else if (!old.settings.showTranslation &&
        widget.settings.showTranslation) {
      _translate(value);
    }
  }

  void _selectionChanged() {
    if (_syncing || !_focus.hasFocus || widget.settings.chipMode) return;
    final units = topLevelUnits(_controller.text, studio._bodies(widget.state));
    final ranges = DesktopTextRanges.of(_controller).selected;
    final caret = _controller.selection.extentOffset;
    studio._select(side, {
      for (final (i, unit) in units.indexed)
        if (ranges.isEmpty
            ? caret >= unit.start && caret <= unit.end
            : ranges.any((r) => r.start < unit.end && r.end > unit.start))
          i,
    });
  }

  void _edited() {
    if (_syncing) return;
    var next = _controller.text;
    final selection = _controller.selection;
    final bodies = studio._bodies(widget.state);
    if (next != _previous) {
      final deletion = deleteFoldOnSingleEdit(
        _previous,
        next,
        selection.baseOffset,
        bodies,
      );
      if (deletion != null) {
        next = deletion.$1;
        _syncing = true;
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: deletion.$2),
        );
        _syncing = false;
      }
      _previous = next;
      studio._write(side, next, structural: deletion != null);
      _translate(next);
      _completionSelection = _controller.selection;
      final at = _controller.selection.extentOffset;
      final inBlock = parseFoldRefs(
        next,
        bodies,
      ).any((f) => at > f.start && at <= f.end);
      final query =
          deletion == null &&
              !inBlock &&
              _controller.selection.isValid &&
              _controller.selection.isCollapsed
          ? completionWordAt(next, at)
          : '';
      studio._search(this, query);
    } else if (selection.isValid && selection.isCollapsed) {
      final offset = snapFoldCaret(next, bodies, selection.baseOffset);
      if (offset != selection.baseOffset) {
        _syncing = true;
        _controller.selection = TextSelection.collapsed(offset: offset);
        _syncing = false;
      }
    }
    if (studio._source == this &&
        _controller.selection != _completionSelection) {
      studio._closeCompletion();
    }
    _selectionChanged();
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _chipFocus.removeListener(_focusChanged);
    _chipFocus.dispose();
    DesktopTextRanges.of(_controller).removeListener(_selectionChanged);
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    _chipInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.follow && studio._source == this) {
      _refreshFollowCaret();
    } else {
      _followCaret = null;
    }
    final st = widget.state;
    final bodies = studio._bodies(st);
    final settings = widget.settings;
    final active = studio._positive == side;
    _controller
      ..foldBodies = bodies
      ..foldIcons = foldIconsOf(st.foldLinks)
      ..showTrans = settings.showTranslation;
    final units = topLevelUnits(_controller.text, bodies);
    final selection = active ? studio._selection : const <int>{};
    final scheme = Theme.of(context).colorScheme;
    final trans = ref.watch(tagTranslationServiceProvider);
    final title = side
        ? context.l10n.desktopPositivePrompt
        : context.l10n.studioNegative;
    void inspect(String name) {
      final index = units.indexWhere((u) => u.fold?.name == name);
      if (index >= 0) studio._select(side, {index});
    }

    final editor = ListenableBuilder(
      listenable: trans,
      builder: (_, _) => settings.chipMode
          ? ChipFlowView(
              key: ValueKey('studio-chips-$side'),
              controller: _controller,
              foldBodies: bodies,
              selection: selection,
              onSelectionChanged: (items) => studio._select(side, items),
              onLongPressChip: (i) => studio._select(side, {i}),
              onMove: (to) {
                final before = _controller.text;
                final next = moveUnits(before, bodies, studio._selection, to);
                if (before == next) return;
                studio._write(side, next, structural: true);
                studio._select(side, {});
              },
              onFoldDoubleTap: (i) => studio._open(
                studio._target,
                block: units[i].fold!.name,
                positive: side,
              ),
              desktopDrag: true,
              input: _chipInput,
              inputFocus: _chipFocus,
              onInputChanged: _chipChanged,
              onInputSubmitted: (_) {
                _commitChips();
                studio._closeCompletion();
              },
              onChipTap: (_) => studio._activate(side),
              translating: trans.isPending,
              showTrans: settings.showTranslation,
              fontSize: settings.chipFontSize,
              primaryFontScale: .8,
              padding: const EdgeInsets.all(12),
            )
          : KeyedSubtree(
              key: ValueKey('studio-text-$side'),
              child: AnnotatedField(
                key: _field,
                controller: _controller,
                focusNode: _focus,
                scrollController: _scroll,
                hint: title,
                showTrans: settings.showTranslation,
                showWeightWash: settings.showWeightWash,
                fontSize: settings.fontSize,
                padding: const EdgeInsets.all(14),
                onFoldTap: (name, _) => inspect(name),
                onFoldDoubleTap: (name) =>
                    studio._open(studio._target, block: name, positive: side),
              ),
            ),
    );
    final label = active
        ? context.l10n.studioFocused
        : context.l10n.studioFocusHere;
    final heading = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: LayoutBuilder(
        builder: (_, bounds) {
          final wide =
              bounds.maxWidth >=
              285 * MediaQuery.textScalerOf(context).scale(14) / 14;
          return Row(
            children: [
              Icon(
                Icons.circle,
                size: 9,
                color: side ? scheme.primary : scheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${context.l10n.itemsCount(units.length)} · ${widget.count} tok',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.split) ...[
                const SizedBox(width: 6),
                if (wide)
                  Container(
                    key: ValueKey('studio-focus-label-$side'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: active ? scheme.secondaryContainer : null,
                      border: Border.all(
                        color: active ? scheme.primary : scheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  )
                else
                  Tooltip(
                    key: ValueKey('studio-focus-label-$side'),
                    message: label,
                    child: Icon(
                      active ? Icons.edit : Icons.edit_outlined,
                      size: 14,
                      color: scheme.primary,
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
    return ColoredBox(
      color: side ? scheme.surfaceContainerLowest : scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: scheme.surfaceContainerLow,
            child: widget.split
                ? InkWell(
                    key: ValueKey('studio-focus-$side'),
                    onTap: () {
                      studio._activate(side);
                      (settings.chipMode ? _chipFocus : _focus).requestFocus();
                    },
                    child: heading,
                  )
                : heading,
          ),
          Expanded(
            child: Focus(
              onKeyEvent: (_, event) => studio._completionKey(this, event),
              child: TapRegion(
                groupId: studio._completionTapGroup,
                onTapOutside: studio._source == this && !widget.follow
                    ? (_) => studio._closeCompletion()
                    : null,
                child: DesktopTagPopover(
                  visible: widget.follow && studio._source == this,
                  anchor: () => _followCaret,
                  anchorRevision: studio._generation,
                  followAnchor: true,
                  avoidAnchor: true,
                  scrollPanel: false,
                  panelWidth: 552,
                  maxPanelHeight: 362,
                  tapGroupId: studio._completionTapGroup,
                  onDismiss: studio._closeCompletion,
                  panel: widget.follow && studio._source == this
                      ? KeyedSubtree(
                          key: const ValueKey('studio-completion-follow'),
                          child: studio._completionMenu(),
                        )
                      : const SizedBox.shrink(),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (_) {
                      _refreshFollowCaret();
                      return false;
                    },
                    child: editor,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
