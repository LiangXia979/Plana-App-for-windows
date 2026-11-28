part of '../prompt_studio.dart';

class _StudioPosition extends ConsumerStatefulWidget {
  const _StudioPosition({super.key, required this.char, required this.gen});
  final CharacterPrompt char;
  final GenerateState gen;
  @override
  ConsumerState<_StudioPosition> createState() => _StudioPositionState();
}

class _StudioPositionState extends ConsumerState<_StudioPosition> {
  bool _expanded = true;
  String? _lastManual;

  void _manual(bool value) {
    final char = widget.char;
    final gen = widget.gen;
    final editor = ref.read(generateProvider.notifier);
    if (value) {
      if (resolveCharacterCenter(char.position) == null) {
        editor.updateCharacter(
          char.id,
          position:
              _lastManual ??
              nextSpawnPosition(
                gen.characters
                    .where((c) => c.id != char.id)
                    .map((c) => c.position),
                freeform: isNai5Model(gen.params.model),
              ),
        );
      }
      editor.setUseCoords(true);
    } else if (gen.params.useCoords && char.position != null) {
      _lastManual = char.position;
      editor.updateCharacter(char.id, position: null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gen = widget.gen;
    final char = widget.char;
    final theme = Theme.of(context), l = context.l10n;
    final scheme = theme.colorScheme;
    final position = gen.params.useCoords
        ? gridCellForPosition(char.position)
        : null;
    final manual = position != null;
    final center = resolveCharacterCenter(
      isNai5Model(gen.params.model) ? char.position : position,
    );
    final others = {
      if (gen.params.useCoords)
        for (final c in gen.characters)
          if (c.id != char.id && c.enabled) gridCellForPosition(c.position),
    };
    final code = position ?? 'AUTO';
    void toggle() => setState(() => _expanded = !_expanded);
    final controls = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EditorSegments<bool>(
          expanded: true,
          options: {true: l.studioManual, false: 'AUTO'},
          optionKey: (v) => ValueKey('studio-position-manual-$v'),
          value: manual,
          onPick: _manual,
        ),
        const SizedBox(height: 5),
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  code,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (manual && center != null)
                  Text(
                    'X ${(center.x * 100).round()}% · Y ${(center.y * 100).round()}%',
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        OutlinedButton(
          key: const ValueKey('studio-position-dialog'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          onPressed: () => showPositionGridDialog(context, char.id),
          child: Text(l.position, textAlign: TextAlign.center),
        ),
      ],
    );
    Widget axis(String value) => Center(
      child: Text(
        value,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    final matrix = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const SizedBox(width: 13),
            for (final c in 'ABCDE'.split('')) Expanded(child: axis(c)),
          ],
        ),
        for (var row = 0; row < 5; row++)
          Row(
            children: [
              SizedBox(width: 13, child: axis('${row + 1}')),
              for (var col = 0; col < 5; col++)
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final cell = '${'ABCDE'[col]}${row + 1}';
                      final current = cell == position;
                      return Padding(
                        padding: const EdgeInsets.all(1),
                        child: Semantics(
                          button: true,
                          selected: current,
                          child: Tooltip(
                            message: cell,
                            child: Material(
                              color: current
                                  ? scheme.primary
                                  : scheme.surfaceContainerLowest,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(3),
                                side: BorderSide(color: scheme.outlineVariant),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                key: ValueKey('studio-position-cell-$cell'),
                                onTap: () {
                                  final editor = ref.read(
                                    generateProvider.notifier,
                                  );
                                  editor.updateCharacter(
                                    char.id,
                                    position: cell,
                                  );
                                  editor.setUseCoords(true);
                                },
                                child: SizedBox(
                                  height: 16,
                                  child: !current && others.contains(cell)
                                      ? Center(
                                          child: Container(
                                            width: 10,
                                            height: 6,
                                            decoration: BoxDecoration(
                                              color: scheme.tertiary,
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                            ),
                                          ),
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: toggle,
                hoverColor: Colors.transparent,
                highlightColor: Colors.transparent,
                splashFactory: NoSplash.splashFactory,
                borderRadius: BorderRadius.circular(6),
                child: Row(
                  children: [
                    Icon(Icons.grid_on, size: 15, color: scheme.primary),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        l.studioPosition,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        child: Text(code, style: theme.textTheme.labelSmall),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Tooltip(
              message: manual ? l.setCharPosition('AUTO') : l.studioManual,
              child: Semantics(
                toggled: !manual,
                child: OutlinedButton(
                  key: const ValueKey('studio-position-auto'),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: manual ? null : scheme.secondaryContainer,
                    side: BorderSide(color: scheme.outlineVariant),
                    minimumSize: const Size(0, 26),
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _manual(!manual),
                  child: const Text('AUTO'),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('studio-position-toggle'),
              tooltip: _expanded ? l.collapse : l.expand,
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: toggle,
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            ),
          ],
        ),
        if (_expanded) ...[
          const Divider(height: 14),
          LayoutBuilder(
            builder: (context, box) {
              final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
              if (box.maxWidth < 202 * scale) {
                return Column(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: matrix,
                    ),
                    const SizedBox(height: 6),
                    controls,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: matrix),
                  const SizedBox(width: 8),
                  Expanded(child: controls),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}
