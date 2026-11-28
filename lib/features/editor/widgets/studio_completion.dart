part of '../prompt_studio.dart';

/// Both presentations use the active pane's caret, result list and keyboard selection.
mixin _StudioCompletion on ConsumerState<PromptStudio> {
  final _menu = GlobalKey<DesktopCompletionMenuState>();
  final _completionTapGroup = Object();
  Timer? _debounce;
  _StudioPaneState? _source;
  String _query = '';
  int _generation = 0;
  bool _loading = false, _translating = false, _continuous = false;
  SuggestResult _result = const SuggestResult();

  void _closeCompletion() {
    _debounce?.cancel();
    _generation++;
    if (_source == null) return;
    setState(() {
      _source = null;
      _query = '';
      _continuous = false;
      _loading = _translating = false;
      _result = const SuggestResult();
    });
  }

  void _search(_StudioPaneState source, String word) {
    final q = word.trim();
    final settings =
        ref.read(editorSettingsProvider).value ?? const EditorSettings();
    if (q.isEmpty || !settings.enableCompletion) {
      _closeCompletion();
      return;
    }
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _source = source;
      _query = q;
      _continuous = _translating = false;
      _loading = true;
      _result = const SuggestResult();
    });
    _debounce = Timer(const Duration(milliseconds: 100), () async {
      var result = const SuggestResult();
      try {
        result = await desktopPromptSuggestions(
          ref,
          q,
          includeStyles: settings.entitySuggest,
        );
      } catch (_) {
        // The raw text and translation actions are still available offline.
      }
      if (!mounted || !source.mounted || generation != _generation) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    });
  }

  KeyEventResult _completionKey(_StudioPaneState pane, KeyEvent event) {
    final composing = pane._inputValue.composing;
    final keyboard = HardwareKeyboard.instance;
    if (_source != pane ||
        !composing.isCollapsed && composing.isValid ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    return _menu.currentState?.handleKey(event) ?? KeyEventResult.ignored;
  }

  void _pickCompletion(
    String text, {
    Suggestion? suggestion,
    bool keepOpen = false,
  }) {
    final pane = _source;
    if (pane == null || !pane.mounted) return;
    pane._accept(text, suggestion, continuous: _continuous);
    if (keepOpen) {
      _continuous = true;
    } else {
      _closeCompletion();
    }
  }

  Future<void> _translateCompletion() async {
    if (_source == null || _translating) return;
    final generation = _generation;
    setState(() => _translating = true);
    String? english;
    try {
      english = await ref.read(tagCompletionProvider).translateNatural(_query);
    } catch (_) {}
    if (!mounted || generation != _generation) return;
    if (english == null || english.trim().isEmpty) {
      setState(() => _translating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.studioTranslateFailed)),
      );
    } else {
      _pickCompletion(english);
    }
  }

  Widget _completionMenu() => TapRegion(
    groupId: _completionTapGroup,
    child: TextFieldTapRegion(
      child: ExcludeFocus(
        child: DesktopCompletionMenu(
          key: _menu,
          query: _query,
          result: _result,
          loading: _loading,
          translating: _translating,
          showRelated: false,
          onPick: (s, {required keepOpen}) => _pickCompletion(
            s.insertText ?? s.text,
            suggestion: s,
            keepOpen: keepOpen,
          ),
          onTranslate: _translateCompletion,
          onRaw: () => _pickCompletion(_query),
          onClose: _closeCompletion,
        ),
      ),
    ),
  );

  Widget _completionDock() {
    final scheme = Theme.of(context).colorScheme;
    final menu = _completionMenu();
    return Material(
      key: const ValueKey('studio-completion-dock'),
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Material(
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: scheme.primary),
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(
            builder: (context, box) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (box.maxHeight >= 130)
                  TapRegion(
                    groupId: _completionTapGroup,
                    child: TextFieldTapRegion(
                      child: ExcludeFocus(
                        child: ColoredBox(
                          color: scheme.secondaryContainer.withValues(
                            alpha: .45,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${context.l10n.studioCompleting}  $_query',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                TextButton(
                                  key: const ValueKey(
                                    'studio-return-inspector',
                                  ),
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(0, 26),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                    ),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: _closeCompletion,
                                  child: Text(
                                    'Esc  ${context.l10n.studioReturnInspector}',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Expanded(child: menu),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
