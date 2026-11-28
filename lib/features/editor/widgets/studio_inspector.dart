part of '../prompt_studio.dart';

class _StudioInspector extends ConsumerWidget {
  const _StudioInspector({
    required this.studio,
    required this.state,
    required this.gen,
    required this.showCompletion,
  });
  final _PromptStudioState studio;
  final EditorState state;
  final GenerateState gen;
  final bool showCompletion;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(editorSettingsProvider).value ?? const EditorSettings();
    final scheme = Theme.of(context).colorScheme;
    final l = context.l10n;
    final side = studio._positive;
    final text = studio._text(state, side);
    final bodies = studio._bodies(state);
    final units = topLevelUnits(text, bodies);
    final indices =
        studio._selection.where((i) => i >= 0 && i < units.length).toList()
          ..sort();
    final unit = indices.length == 1 ? units[indices.first] : null;
    final fold = unit?.fold;
    final tok = unit?.tok;
    final entries = ref.watch(tagLibraryProvider);
    final char = gen.characters
        .where((c) => c.id == studio._target.charId)
        .firstOrNull;
    void apply(String next) => studio._write(side, next, structural: true);
    void setWeight(double value) => apply(
      tok == null
          ? batchSetMultUnits(text, bodies, indices, value)
          : setTokMult(text, tok, value).$1,
    );
    void resetWeight() => apply(
      tok == null
          ? batchClearWeightUnits(text, bodies, indices)
          : clearWeight(text, tok).$1,
    );
    final tokens = <Tok>[for (final i in indices) ?units[i].tok];
    final disabled = tokens.isNotEmpty && tokens.every((t) => t.disabled);
    void copySelection() => Clipboard.setData(
      ClipboardData(
        text:
            tok?.name ??
            [
              for (final i in indices)
                expandFolds(
                  text.substring(units[i].start, units[i].end),
                  bodies,
                ),
            ].join(', '),
      ),
    );
    void packSelection() {
      final slot = selectedFoldSlot(text, bodies, indices.toSet());
      if (slot == null) return;
      final name = studio._editor.registerFold(
        tokens.first.name,
        slot.body(bodies),
      );
      apply(slot.replace(foldRefLiteral(name)));
      studio._select(side, {indices.first});
    }

    final activeBlock =
        fold?.name ?? (indices.isEmpty ? studio._sideName(state, side) : null);
    final members = activeBlock == null
        ? ''
        : state.foldBodies[activeBlock] ?? '';
    final memberTokens = parseToks(members);
    final blockDisabled =
        memberTokens.isNotEmpty && memberTokens.every((t) => t.disabled);
    final anchor = activeBlock == null
        ? null
        : state.placementOf(activeBlock)?.link;
    final original =
        (side ? anchor?.positiveWeightOrigin : anchor?.negativeWeightOrigin) ??
        '';
    void writeWhole(String value, {String? origin}) {
      if (activeBlock != null) {
        studio._editor.editFoldBody(
          activeBlock,
          value,
          structural: true,
          weightOrigin: origin,
        );
      }
    }

    void switchBlock() => studio._open(
      studio._target,
      block: fold == null ? null : activeBlock,
      positive: side,
    );
    void removeBlock(bool unpack) {
      if (activeBlock == null) return;
      final parent = side ? state.positiveText : state.negativeText;
      final ref = parseFoldRefs(
        parent,
        state.foldBodies,
      ).where((f) => f.name == activeBlock).firstOrNull;
      if (ref == null) return;
      studio._open(studio._target, positive: side);
      studio._write(
        side,
        unpack
            ? unfoldRef(parent, ref, state.foldBodies)
            : deleteFoldRef(parent, ref).$1,
        structural: true,
        detach: unpack,
      );
    }

    Widget section(List<Widget> contents) => Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: contents,
        ),
      ),
    );
    Widget label(String value) =>
        Text(value, style: Theme.of(context).textTheme.titleMedium);
    final query = studio._libraryQuery.trim().toLowerCase();
    final latinQuery = query.replaceAll(RegExp(r'\s+'), '');
    final quickList = (entries.value?.entries ?? const <TagEntry>[]).where((
      entry,
    ) {
      if (isStockInspirationExample(entry)) return false;
      final character = entry.category == TagCategory.character;
      if ((side ? entry.positive : entry.negative).trim().isEmpty &&
          !(character && (entry.positive + entry.negative).trim().isNotEmpty)) {
        return false;
      }
      if (query.isEmpty) return true;
      final fields = [
        entry.name,
        ...entry.aliases,
        ...entry.tags,
        entry.positive,
        entry.negative,
        tagCategoryDef(entry.category).label,
      ];
      if (fields.any((s) => s.toLowerCase().contains(query))) return true;
      return studio._romanizations(entry).contains(latinQuery);
    }).toList();
    final cards = ListView(
      primary: false,
      shrinkWrap: showCompletion,
      padding: const EdgeInsets.all(8),
      children: [
        if (activeBlock != null)
          section([
            Row(
              children: [
                Expanded(
                  child: Text.rich(
                    foldLabelSpan(
                      activeBlock,
                      foldIconsOf(state.foldLinks)[activeBlock],
                      hash: true,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      fold == null ? l.studioBlock : l.wholeBlock,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              '${l.itemsCount(memberTokens.length)} · ${original.isEmpty ? l.studioIndependentWeights : l.studioBlockWeight}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 9),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                stripFolds(members),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ),
            Row(
              children: [
                Text(
                  original.isEmpty
                      ? l.studioOriginalWeights
                      : l.studioBlockWeight,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: DesktopWeightControl(
                      key: const ValueKey('studio-block-weight'),
                      expanded: true,
                      multiplier: memberTokens.firstOrNull?.numWeight ?? 1,
                      mixed: original.isEmpty,
                      enabled: memberTokens.isNotEmpty && !blockDisabled,
                      onStep: (up) {
                        final base = original.isEmpty
                            ? 1.0
                            : memberTokens.first.numWeight;
                        writeWhole(
                          batchSetMult(
                            members,
                            0,
                            memberTokens.length - 1,
                            base +
                                (up
                                    ? settings.weightStep
                                    : -settings.weightStep),
                          ),
                          origin: original.isEmpty ? members : original,
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ..._inspectorRows([
              (
                _inspectorAction(
                  context,
                  l.studioResetWeight,
                  Icons.restart_alt,
                  original.isEmpty
                      ? null
                      : () => writeWhole(original, origin: ''),
                  key: 'studio-block-reset',
                ),
                _inspectorAction(
                  context,
                  l.studioCopyBlock,
                  Icons.content_copy,
                  () => Clipboard.setData(ClipboardData(text: members)),
                ),
              ),
              (
                _inspectorAction(
                  context,
                  blockDisabled ? l.enableBlock : l.disableBlock,
                  blockDisabled
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  memberTokens.isEmpty
                      ? null
                      : () => writeWhole(
                          batchSetDisabled(
                            members,
                            0,
                            memberTokens.length - 1,
                            !blockDisabled,
                          ),
                          origin: original.isEmpty
                              ? null
                              : batchSetDisabled(
                                  original,
                                  0,
                                  parseToks(original).length - 1,
                                  !blockDisabled,
                                ),
                        ),
                ),
                _inspectorAction(
                  context,
                  fold == null ? l.studioParent : l.studioExpand,
                  fold == null ? Icons.arrow_back : Icons.open_in_full,
                  switchBlock,
                  key: 'studio-edit-block',
                ),
              ),
              (
                _inspectorAction(
                  context,
                  l.unpackBlock,
                  Icons.unfold_more,
                  () => removeBlock(true),
                ),
                _inspectorAction(
                  context,
                  l.studioRemoveBlock,
                  Icons.delete_outline,
                  () => removeBlock(false),
                  danger: true,
                ),
              ),
            ]),
          ])
        else if (indices.isNotEmpty)
          section([
            _StudioTagTools(
              title: tok?.name ?? l.selectedItems(indices.length),
              translation: tok?.trans,
              positive: side,
              tokens: tokens,
              disabled: disabled,
              onWrap: (up) => apply(
                tok == null
                    ? batchWrapUnits(text, bodies, indices, up: up)
                    : wrapBracket(text, tok, up: up),
              ),
              onStep: (up) => setWeight(
                tokens.first.numWeight +
                    (up ? settings.weightStep : -settings.weightStep),
              ),
              onReset: resetWeight,
              onCopy: copySelection,
              onDisable: () =>
                  apply(setUnitsDisabled(text, bodies, indices, !disabled)),
              onWiki: tok == null ? null : () => openTagWiki(context, tok.name),
              onPack: studio._block == null && tokens.length == indices.length
                  ? packSelection
                  : null,
              onDelete: () {
                apply(deleteUnits(text, bodies, indices).$1);
                studio._select(side, {});
              },
            ),
          ])
        else
          section([
            label(context.l10n.studioInspector),
            Text(
              studio._name(gen),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.studioInspectHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Text(
              '${l.positiveShort} ${l.itemsCount(topLevelUnits(studio._text(state, true), bodies).length)}  ·  ${l.negativeShort} ${l.itemsCount(topLevelUnits(studio._text(state, false), bodies).length)}',
            ),
          ]),
      ],
    );
    return ColoredBox(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (char != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: box.maxHeight * .53,
                      ),
                      child: SingleChildScrollView(
                        primary: false,
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                        child: section([
                          _StudioPosition(
                            key: ValueKey(char.id),
                            char: char,
                            gen: gen,
                          ),
                        ]),
                      ),
                    ),
                  Expanded(
                    child: showCompletion ? studio._completionDock() : cards,
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              children: [
                Icon(Icons.lightbulb_outline, size: 17, color: scheme.primary),
                const SizedBox(width: 6),
                label(context.l10n.studioLibrary),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 0, 9, 6),
            child: TextField(
              key: const ValueKey('studio-library-search'),
              controller: studio._librarySearch,
              onChanged: studio._setLibraryQuery,
              style: Theme.of(context).textTheme.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                hintText: l.studioSearchLibrary,
                prefixIcon: const Icon(Icons.search, size: 17),
                prefixIconConstraints: const BoxConstraints(minWidth: 30),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 28,
                  minHeight: 28,
                ),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l.desktopClearSearch,
                        iconSize: 15,
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          studio._librarySearch.clear();
                          studio._setLibraryQuery('');
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
          SizedBox(
            height: (MediaQuery.sizeOf(context).height * .24).clamp(
              68.0,
              180.0,
            ),
            child: quickList.isEmpty
                ? Center(
                    child: Text(
                      entries.isLoading
                          ? context.l10n.studioLoading
                          : query.isEmpty
                          ? l.studioNoLocal
                          : l.studioNoMatches,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : ListView.builder(
                    primary: false,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: quickList.length,
                    itemBuilder: (_, i) {
                      final entry = quickList[i];
                      return Card(
                        elevation: 0,
                        color: scheme.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: scheme.outlineVariant),
                        ),
                        margin: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          key: ValueKey('studio-insert-${entry.id}'),
                          dense: true,
                          title: Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            tagCategoryDef(entry.category).label,
                            maxLines: 1,
                          ),
                          trailing: const Icon(Icons.add, size: 17),
                          onTap: () => studio._insertEntry(entry),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _StudioTagTools extends StatelessWidget {
  const _StudioTagTools({
    required this.title,
    required this.translation,
    required this.positive,
    required this.tokens,
    required this.disabled,
    required this.onWrap,
    required this.onStep,
    required this.onReset,
    required this.onCopy,
    required this.onDisable,
    required this.onWiki,
    required this.onPack,
    required this.onDelete,
  });

  final String title;
  final String? translation;
  final bool positive, disabled;
  final List<Tok> tokens;
  final ValueChanged<bool> onWrap, onStep;
  final VoidCallback onReset, onCopy, onDisable, onDelete;
  final VoidCallback? onWiki, onPack;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = context.editor;
    final mult = tokens.firstOrNull?.tagMult ?? 1;
    final weighted = tokens.any(
      (t) =>
          t.braceLevel != 0 ||
          t.innerStart != t.nameStart ||
          t.numGroup != null,
    );
    final sideColor = positive ? scheme.primary : scheme.error;
    Widget bracket(bool up) {
      final color = up ? palette.weightUp : palette.weightDown;
      return OutlinedButton(
        onPressed: tokens.isEmpty ? null : () => onWrap(up),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          minimumSize: const Size(32, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: color,
          backgroundColor: color.withValues(alpha: .10),
          side: BorderSide(color: color.withValues(alpha: .4)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        child: Text(up ? '{ }' : '[ ]'),
      );
    }

    final pairs = [
      (
        _inspectorAction(
          context,
          l.studioResetWeight,
          Icons.restart_alt,
          weighted ? onReset : null,
          key: 'studio-reset',
        ),
        _inspectorAction(
          context,
          l.studioCopyTag,
          Icons.content_copy,
          onCopy,
          key: 'studio-copy-token',
        ),
      ),
      (
        _inspectorAction(
          context,
          disabled ? l.enable : l.studioDisableTag,
          disabled ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          tokens.isEmpty ? null : onDisable,
          key: 'studio-disable-token',
        ),
        _inspectorAction(context, l.danbooruWiki, Icons.language, onWiki),
      ),
      (
        _inspectorAction(
          context,
          l.studioPack,
          Icons.inventory_2_outlined,
          onPack,
        ),
        _inspectorAction(
          context,
          l.studioDeleteTag,
          Icons.delete_outline,
          onDelete,
          danger: true,
        ),
      ),
    ];
    final stepper = SizedBox(
      height: 32,
      child: DesktopWeightControl(
        expanded: true,
        multiplier: mult,
        mixed: tokens.any((t) => t.tagMult != mult),
        enabled: tokens.isNotEmpty,
        onStep: onStep,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (translation != null)
                    Text(
                      translation!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            DecoratedBox(
              decoration: BoxDecoration(
                color: sideColor.withValues(alpha: .11),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  positive ? l.positiveShort : l.negativeShort,
                  style: theme.textTheme.labelSmall?.copyWith(color: sideColor),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            final brackets = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                bracket(false),
                const SizedBox(width: 4),
                bracket(true),
              ],
            );
            if (box.maxWidth <
                162 * MediaQuery.textScalerOf(context).scale(14) / 14) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [brackets, const SizedBox(height: 4), stepper],
              );
            }
            return Row(
              children: [
                brackets,
                const SizedBox(width: 8),
                Expanded(child: stepper),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        ..._inspectorRows(pairs),
      ],
    );
  }
}

Widget _inspectorAction(
  BuildContext context,
  String label,
  IconData icon,
  VoidCallback? callback, {
  String? key,
  bool danger = false,
}) {
  final scheme = Theme.of(context).colorScheme;
  return OutlinedButton(
    key: key == null ? null : ValueKey(key),
    onPressed: callback,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      minimumSize: const Size(0, 34),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: danger ? scheme.error : scheme.onSurface,
      backgroundColor: danger
          ? scheme.errorContainer.withValues(alpha: .35)
          : scheme.surfaceContainerLow,
      side: BorderSide(
        color: (danger ? scheme.error : scheme.outlineVariant).withValues(
          alpha: .55,
        ),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 15),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

List<Widget> _inspectorRows(List<(Widget, Widget)> pairs) => [
  for (final (left, right) in pairs)
    Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: left),
          const SizedBox(width: 6),
          Expanded(child: right),
        ],
      ),
    ),
];
