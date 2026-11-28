part of '../prompt_studio.dart';

class _StudioOutline extends StatelessWidget {
  const _StudioOutline({
    required this.studio,
    required this.gen,
    required this.state,
  });
  final _PromptStudioState studio;
  final GenerateState gen;
  final EditorState state;

  @override
  Widget build(BuildContext context) {
    final ref = studio.ref;
    final library = ref.read(generateProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final l = context.l10n;
    Widget heading(String title, String count) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 6, 7),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.labelLarge),
          ),
          Text(count, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
    Iterable<Widget> branch(
      _Target target,
      String title,
      IconData icon, {
      VoidCallback? toggle,
      bool enabled = true,
      String? avatar,
      String? position,
      required List<PromptFoldLink> links,
      int? dragIndex,
    }) sync* {
      final current = studio._target == target;
      final (pos, neg) = editorDrafts(
        gen,
        charId: target.charId,
        sectionId: target.sectionId,
      );
      final selected = current && studio._block == null;
      final id = target.charId ?? target.sectionId ?? 'main';
      final symbol = Icon(icon, size: 18);
      final nameStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
        fontWeight: FontWeight.w600,
        color: enabled ? scheme.onSurface : scheme.outline,
      );
      final leading = avatar == null
          ? symbol
          : ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: SizedBox.square(
                dimension: 27,
                child: TagCardPreview(
                  url: avatar,
                  name: title,
                  decodeWidth: 32,
                  alignment: Alignment.topCenter,
                  placeholder: symbol,
                ),
              ),
            );

      Widget header(VoidCallback? rename, Widget? editor) {
        Widget label = ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 38),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 4),
            child: Row(
              children: [
                SizedBox(width: avatar == null ? 22 : 27, child: leading),
                const SizedBox(width: 7),
                Expanded(
                  child:
                      editor ??
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: nameStyle,
                      ),
                ),
                if (position != null && editor == null) ...[
                  const SizedBox(width: 3),
                  Text(position, style: Theme.of(context).textTheme.labelSmall),
                ],
              ],
            ),
          ),
        );
        if (editor == null && dragIndex != null) {
          label = MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: ReorderableDragStartListener(index: dragIndex, child: label),
          );
        }
        final radius = BorderRadius.circular(8);
        return Material(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            key: editor == null ? ValueKey('studio-target-$id') : null,
            borderRadius: radius,
            onTap: editor == null ? () => studio._open(target) : null,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 5),
              child: Row(
                children: [
                  Expanded(child: label),
                  if (editor == null && toggle != null) ...[
                    if (rename != null) ...[
                      DesktopTagAction(
                        key: ValueKey('studio-rename-$id'),
                        icon: Icons.edit_outlined,
                        label: l.rename,
                        onPressed: rename,
                      ),
                      DesktopTagAction(
                        key: ValueKey('studio-delete-$id'),
                        icon: Icons.delete_outline,
                        label: l.delete,
                        onPressed: () => studio._deleteTarget(target),
                      ),
                    ],
                    DesktopTagAction(
                      icon: enabled
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: enabled ? scheme.primary : scheme.outline,
                      label: enabled ? l.disableTag : l.enable,
                      onPressed: toggle,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      }

      if (target == _main) {
        yield header(null, null);
      } else {
        final canvas = ref.read(canvasWorkspaceProvider).activeId;
        yield PromptInlineName(
          identifier: 'studio-name-$id',
          identity: (canvas, target),
          name: title,
          fallbackName: title,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          style: nameStyle,
          rowBuilder: header,
          onRename: (name) {
            if (name == title ||
                ref.read(canvasWorkspaceProvider).activeId != canvas) {
              return;
            }
            if (target.charId != null) {
              library.updateCharacter(id, name: name);
            } else {
              library.updateSection(id, name: name);
            }
          },
        );
      }
      final paired = {
        for (final link
            in (current
                ? state.foldLinks
                : validPromptFoldLinks(pos, neg, links)))
          if (link.positiveName.isNotEmpty) link.negativeName,
      };
      for (final side in [true, if (!gen.params.isNaiMedium) false]) {
        final raw = side ? pos : neg;
        final entries = current
            ? [
                for (final f in parseFoldRefs(
                  side ? state.positiveText : state.negativeText,
                  state.foldBodies,
                ))
                  (f.name, state.foldBodies[f.name] ?? ''),
              ]
            : [
                for (final f in parseFolds(raw))
                  (f.name, raw.substring(f.bodyStart, f.bodyEnd)),
              ];
        for (final (index, item) in entries.indexed) {
          if (!side && paired.contains(item.$1)) continue;
          final placement = current && studio._block != null
              ? state.placementOf(studio._block!)
              : null;
          final chosen =
              placement != null &&
              [
                placement.positive?.name,
                placement.negative?.name,
              ].contains(item.$1);
          yield Padding(
            padding: const EdgeInsets.only(left: 15),
            child: Material(
              color: chosen ? scheme.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                key: ValueKey('studio-outline-fold-$id-$side-$index'),
                borderRadius: BorderRadius.circular(6),
                onTap: () =>
                    studio._open(target, positive: side, foldIndex: index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.subdirectory_arrow_right,
                        size: 14,
                        color: scheme.outline,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text.rich(
                          foldLabelSpan(
                            item.$1,
                            foldIconsOf(
                              current ? state.foldLinks : links,
                            )[item.$1],
                            hash: true,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        '${parseToks(item.$2).length}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
      }
    }

    final sections = withMainRow(gen.sections, gen.prompt);
    final extraMain = !sections.any((s) => s.isMain);
    final maxChars = maxCharactersOf(gen.params.model);
    return ColoredBox(
      color: scheme.surface,
      child: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              primary: false,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(8, 3, 8, 0),
                  sliver: SliverToBoxAdapter(
                    child: heading(
                      l.studioSections,
                      '${sections.length + (extraMain ? 1 : 0)}',
                    ),
                  ),
                ),
                if (extraMain)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        children: branch(
                          _main,
                          l.studioMain,
                          Icons.edit_outlined,
                          links: gen.promptFoldLinks,
                        ).toList(),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  sliver: SliverReorderableList(
                    itemCount: sections.length,
                    proxyDecorator: desktopPromptDragProxy,
                    onReorderStart: (_) {
                      Tooltip.dismissAllToolTips();
                      studio._sessions.flushPending();
                    },
                    onReorderItem: library.reorderSections,
                    itemBuilder: (_, i) {
                      final s = sections[i];
                      return Column(
                        key: ValueKey('studio-section-${s.id}'),
                        children: branch(
                          s.isMain ? _main : (charId: null, sectionId: s.id),
                          s.isMain
                              ? l.studioMain
                              : sectionDisplayName(l, s.name),
                          s.isMain
                              ? Icons.edit_outlined
                              : Icons.layers_outlined,
                          dragIndex: sections.length > 1 ? i : null,
                          links: s.isMain ? gen.promptFoldLinks : s.foldLinks,
                          enabled: s.enabled,
                          toggle: () =>
                              library.updateSection(s.id, enabled: !s.enabled),
                        ).toList(),
                      );
                    },
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  sliver: SliverToBoxAdapter(
                    child: heading(
                      l.characterPrompts,
                      '${gen.characters.length} / $maxChars',
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  sliver: SliverReorderableList(
                    itemCount: gen.characters.length,
                    proxyDecorator: desktopPromptDragProxy,
                    onReorderStart: (_) {
                      Tooltip.dismissAllToolTips();
                      studio._sessions.flushPending();
                    },
                    onReorderItem: library.reorderCharacters,
                    itemBuilder: (_, i) {
                      final c = gen.characters[i];
                      return Column(
                        key: ValueKey('studio-character-${c.id}'),
                        children: branch(
                          (charId: c.id, sectionId: null),
                          characterDisplayName(l, c.name),
                          Icons.person_outline,
                          avatar: c.avatar,
                          position: positionChipLabel(
                            gen.params.useCoords ? c.position : null,
                          ),
                          links: c.foldLinks,
                          enabled: c.enabled,
                          dragIndex: gen.characters.length > 1 ? i : null,
                          toggle: () => library.updateCharacter(
                            c.id,
                            enabled: !c.enabled,
                          ),
                        ).toList(),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(6),
            child: Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(context.l10n.importNewSection),
                  onPressed: () {
                    library.addSection();
                    final section = ref.read(generateProvider).sections.last;
                    studio._open((charId: null, sectionId: section.id));
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.person_add_alt, size: 16),
                  label: Text(context.l10n.addCharacter),
                  onPressed: gen.characters.length >= maxChars
                      ? null
                      : () {
                          library.addCharacter();
                          studio._open((
                            charId: ref
                                .read(generateProvider)
                                .characters
                                .last
                                .id,
                            sectionId: null,
                          ));
                        },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
