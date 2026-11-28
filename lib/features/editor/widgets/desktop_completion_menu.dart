import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../inspiration/widgets/tag_card.dart';
import '../data/completion_source.dart';
import '../data/suggestions.dart';
import '../data/tag_completion.dart';
import 'completion_bar.dart' show suggestionGlyph;

const _categories = <SuggestionKind?, String>{
  null: '全部',
  SuggestionKind.artist: '画风',
  SuggestionKind.oc: 'OC',
  SuggestionKind.character: '角色',
  SuggestionKind.work: '作品',
  SuggestionKind.tag: '标签',
};

class DesktopCompletionMenu extends ConsumerStatefulWidget {
  const DesktopCompletionMenu({
    super.key,
    required this.query,
    required this.result,
    required this.loading,
    required this.translating,
    required this.onPick,
    required this.onTranslate,
    required this.onRaw,
    required this.onClose,
    this.showRelated = true,
  });
  final String query;
  final SuggestResult result;
  final bool loading, translating, showRelated;
  final void Function(Suggestion, {required bool keepOpen}) onPick;
  final VoidCallback onTranslate, onRaw, onClose;
  @override
  ConsumerState<DesktopCompletionMenu> createState() =>
      DesktopCompletionMenuState();
}

class DesktopCompletionMenuState extends ConsumerState<DesktopCompletionMenu> {
  SuggestionKind? _category;
  bool _byHeat = true;
  int _index = 0;
  String? _rolling;
  final _rowKeys = <int, GlobalKey>{};
  List<Suggestion> get _all =>
      widget.result.flat.where((s) => !s.natural).toList();
  List<SuggestionKind?> get _tabs => [
    null,
    for (final kind in _categories.keys.whereType<SuggestionKind>())
      if (_all.any((s) => s.kind == kind)) kind,
  ];
  List<Suggestion> get _visible {
    final items = _all
        .where((s) => _category == null || s.kind == _category)
        .toList();
    items.sort((a, b) {
      if (a.local != b.local) return a.local ? -1 : 1;
      final heat = _byHeat ? b.count.compareTo(a.count) : 0;
      return heat != 0
          ? heat
          : a.text.toLowerCase().compareTo(b.text.toLowerCase());
    });
    return items;
  }

  @override
  void didUpdateWidget(DesktopCompletionMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query || oldWidget.result != widget.result) {
      _index = 0;
      if (oldWidget.query != widget.query || !_tabs.contains(_category)) {
        _category = null;
      }
    }
  }

  void _select(int i, {bool scroll = false, bool backwards = false}) {
    if (i != _index) setState(() => _index = i);
    if (scroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = _rowKeys[i]?.currentContext;
        final render = context?.findRenderObject();
        if (context == null || render == null) return;
        Scrollable.of(context).position.ensureVisible(
          render,
          alignmentPolicy: backwards
              ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
              : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      });
    }
  }

  KeyEventResult handleKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (widget.loading || widget.translating) return KeyEventResult.ignored;
    final items = _visible;
    final length = items.isEmpty ? 2 : items.length;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final up = k == LogicalKeyboardKey.arrowUp;
      _select(
        (_index + (up ? -1 : 1)) % length,
        scroll: items.isNotEmpty,
        backwards: up,
      );
    } else if (k == LogicalKeyboardKey.tab && items.isNotEmpty) {
      final tabs = _tabs;
      final index =
          (tabs.indexOf(_category) +
              (HardwareKeyboard.instance.isShiftPressed ? -1 : 1)) %
          tabs.length;
      setState(() {
        _category = tabs[index];
        _index = 0;
      });
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      if (e is KeyRepeatEvent) return KeyEventResult.handled;
      if (items.isEmpty) {
        (_index == 0 ? widget.onTranslate : widget.onRaw)();
      } else {
        widget.onPick(
          items[_index],
          keepOpen: HardwareKeyboard.instance.isShiftPressed,
        );
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _matchedText(String value, TextStyle? style, ColorScheme scheme) {
    final query = widget.query.trim();
    final at = value.toLowerCase().indexOf(query.toLowerCase());
    if (query.isEmpty || at < 0 || at + query.length > value.length) {
      return Text(value, style: style);
    }
    final end = at + query.length;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: value.substring(0, at)),
          TextSpan(
            text: value.substring(at, end),
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(text: value.substring(end)),
        ],
      ),
      style: style,
    );
  }

  Future<void> _roll(Suggestion work) async {
    if (_rolling != null) return;
    final query = widget.query;
    setState(() => _rolling = work.text);
    try {
      final name = await ref
          .read(tagCompletionProvider)
          .randomCharacterOf(work.text);
      if (!mounted || widget.query != query) return;
      if (name != null && name.isNotEmpty) {
        widget.onPick(
          Suggestion(text: name, kind: SuggestionKind.character),
          keepOpen: true,
        );
      } else {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('暂时没有可抽取的角色')));
      }
    } finally {
      if (mounted) setState(() => _rolling = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (widget.loading || widget.translating) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(widget.translating ? '翻译中…' : '查询中…'),
      );
    }
    final all = _all, items = _visible;
    if (items.isEmpty) {
      final choices = [
        'AI 翻译「${widget.query}」为英文提示词标签并插入',
        '直接将「${widget.query}」作为原文词条插入',
      ];
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 2; i++)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: OutlinedButton.icon(
                  key: ValueKey('completion-fallback-$i'),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    backgroundColor: _index == i
                        ? scheme.primaryContainer
                        : scheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: i == 0 ? widget.onTranslate : widget.onRaw,
                  icon: Icon(i == 0 ? Icons.translate : Icons.add, size: 16),
                  label: Text(choices[i]),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '↑↓ 选择    Enter 插入    Esc 关闭',
                style: text.labelSmall,
              ),
            ),
          ],
        ),
      );
    }
    final active = items[_index.clamp(0, items.length - 1)];
    final online =
        ref.watch(effectiveCompletionSourceProvider) ==
        CompletionSource.enhanced;
    Widget row(int i) {
      final s = items[i];
      final (glyph, color) = suggestionGlyph(context, s.kind);
      final subtitle = [
        transOf(s),
        s.source,
      ].whereType<String>().where((v) => v.isNotEmpty).join(' · ');
      return MouseRegion(
        key: _rowKeys.putIfAbsent(i, GlobalKey.new),
        onEnter: (_) => _select(i),
        child: Material(
          color: i == _index
              ? scheme.primaryContainer.withValues(alpha: .6)
              : scheme.surface,
          child: InkWell(
            key: ValueKey('completion-row-${s.kind.name}-${s.text}'),
            onTap: () => widget.onPick(s, keepOpen: false),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 5, 3, 5),
              child: Row(
                children: [
                  Icon(glyph, color: color, size: 17),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _matchedText(s.text, text.labelLarge, scheme),
                        if (subtitle.isNotEmpty)
                          _matchedText(
                            subtitle,
                            text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                            scheme,
                          ),
                      ],
                    ),
                  ),
                  if (formatCount(s.count) case final heat?)
                    Text(heat, style: text.labelSmall),
                  if (s.kind == SuggestionKind.work && online)
                    IconButton(
                      tooltip: '从作品随机抽取角色',
                      onPressed: _rolling == null ? () => _roll(s) : null,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.casino_outlined, size: 16),
                    ),
                  IconButton(
                    tooltip: '连续插入',
                    onPressed: () => widget.onPick(s, keepOpen: true),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add, size: 16),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 420, short = box.maxHeight < 145;
        final preview = _SuggestionPreview(
          key: ValueKey((active.kind, active.text)),
          item: active,
          showRelated: widget.showRelated,
          onRelated: (tag) => widget.onPick(
            Suggestion(text: tag, kind: SuggestionKind.tag),
            keepOpen: true,
          ),
        );
        return SizedBox(
          height: math.min(
            box.maxHeight,
            math.max(168.0, math.min(items.length, 6) * 50.0 + 76),
          ),
          child: Column(
            children: [
              if (!short)
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final kind in _tabs)
                              TextButton(
                                style: TextButton.styleFrom(
                                  minimumSize: Size.zero,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 8,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  backgroundColor: _category == kind
                                      ? scheme.primaryContainer
                                      : null,
                                  foregroundColor: _category == kind
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                                onPressed: () => setState(() {
                                  _category = kind;
                                  _index = 0;
                                }),
                                child: Text(
                                  '${_categories[kind]} ${kind == null ? all.length : all.where((v) => v.kind == kind).length}',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _byHeat = !_byHeat;
                        _index = 0;
                      }),
                      icon: const Icon(Icons.sort, size: 16),
                      label: Text(_byHeat ? '按热度' : '按字母'),
                    ),
                  ],
                ),
              if (!short) const Divider(height: 1),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: SingleChildScrollView(
                        primary: false,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < items.length; i++) row(i),
                            if (!wide) preview,
                          ],
                        ),
                      ),
                    ),
                    if (wide) ...[
                      const VerticalDivider(width: 1),
                      Expanded(
                        flex: 2,
                        child: SingleChildScrollView(
                          primary: false,
                          child: preview,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!short)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '↑↓ 选择    Enter 替换    Shift+Enter 连插    Tab 切分类    Esc 关闭',
                      style: text.labelSmall,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

final _previewDetails = FutureProvider.autoDispose
    .family<({String? wiki, List<String> related}), (String, bool)>((
      ref,
      key,
    ) async {
      final (tag, showRelated) = key;
      final tc = ref.watch(tagCompletionProvider);
      final online =
          ref.watch(effectiveCompletionSourceProvider) ==
          CompletionSource.enhanced;
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!ref.mounted) return (wiki: null, related: <String>[]);
      final (wiki, related) = await (
        online ? tc.fetchWiki(tag) : Future<WikiPreview?>.value(),
        showRelated ? tc.relatedOf(tag) : Future.value(const <String>[]),
      ).wait;
      String? body = wiki?.summaryZh;
      if ((body == null || body.isEmpty) &&
          wiki?.hasText == true &&
          ref.mounted) {
        body = await tc.fetchWikiZh(tag) ?? wiki?.summary;
      }
      return (wiki: body, related: related);
    });

class _SuggestionPreview extends ConsumerWidget {
  const _SuggestionPreview({
    super.key,
    required this.item,
    required this.showRelated,
    required this.onRelated,
  });
  final Suggestion item;
  final bool showRelated;
  final ValueChanged<String> onRelated;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final s = item;
    final isTag =
        s.kind == SuggestionKind.tag || s.kind == SuggestionKind.character;
    final details = isTag
        ? ref.watch(_previewDetails((s.text, showRelated))).value
        : null;
    final body = s.insertText ?? details?.wiki ?? s.note ?? transOf(s);
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s.previewUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: SizedBox.square(
                dimension: 44,
                child: TagCardPreview(
                  name: s.text,
                  url: s.previewUrl,
                  mosaic: s.mosaic,
                  decodeWidth: 56,
                ),
              ),
            ),
          Text(s.text, style: theme.textTheme.titleSmall),
          Text(
            [_categories[s.kind]!, if (s.source != null) s.source!].join(' · '),
            style: theme.textTheme.labelSmall,
          ),
          if (body != null && body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(body, style: theme.textTheme.bodySmall),
            ),
          if (details != null && details.related.isNotEmpty)
            Wrap(
              spacing: 4,
              children: [
                for (final tag in details.related.take(8))
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(tag),
                    onPressed: () => onRelated(tag),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
