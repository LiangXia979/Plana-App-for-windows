part of 'welcome_page.dart';

class _GuideGrid extends StatelessWidget {
  const _GuideGrid({
    required this.children,
    this.maxColumns = 2,
    this.minCardWidth = 230,
  });
  final List<Widget> children;
  final int maxColumns;
  final double minCardWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      const gap = 12.0;
      final minimum = minCardWidth * MediaQuery.textScalerOf(context).scale(1);
      final columns = ((bounds.maxWidth + gap) / (minimum + gap)).floor().clamp(
        1,
        maxColumns,
      );
      final width = (bounds.maxWidth - (columns - 1) * gap) / columns;
      if (columns > 1 && children.every((item) => item is _GuideCard)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < children.length; index += columns) ...[
              if (index > 0) const SizedBox(height: gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (
                      var i = index;
                      i < index + columns && i < children.length;
                      i++
                    ) ...[
                      if (i > index) const SizedBox(width: gap),
                      SizedBox(width: width, child: children[i]),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      }
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

class _GuideCard extends StatelessWidget {
  const _GuideCard(
    this.icon,
    this.title,
    this.description, {
    this.selected,
    this.onTap,
  });
  final IconData icon;
  final String title, description;
  final bool? selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final active = selected == true;
    final content = Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: context.texts.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (active)
                Icon(Icons.check_circle, size: 18, color: scheme.primary),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: context.texts.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    return Semantics(
      selected: selected,
      button: onTap == null ? null : true,
      child: Material(
        color: active ? scheme.secondaryContainer : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: active ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? content : InkWell(onTap: onTap, child: content),
      ),
    );
  }
}

class _GuideThemePreview extends StatelessWidget {
  const _GuideThemePreview();
  @override
  Widget build(BuildContext context) {
    final l = context.l10n, scheme = context.scheme;
    return Semantics(
      label: l.guideThemePreview,
      image: true,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.guideThemePreview, style: context.texts.labelMedium),
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Text(
                    l.defaultCanvas,
                    style: TextStyle(color: scheme.onPrimaryContainer),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                height: 60,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.landscape_outlined,
                  size: 32,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: scheme.primary,
                    shape: const StadiumBorder(),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 5,
                    ),
                    child: Text(
                      l.generate,
                      style: TextStyle(color: scheme.onPrimary),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuideStorageStep extends ConsumerStatefulWidget {
  const _GuideStorageStep();
  @override
  ConsumerState<_GuideStorageStep> createState() => _GuideStorageStepState();
}

class _GuideStorageStepState extends ConsumerState<_GuideStorageStep> {
  bool _picking = false, _switching = false;
  Future<void> _directory({bool clear = false}) async {
    setState(() => _picking = true);
    try {
      final selected = clear
          ? null
          : await FilePicker.platform.getDirectoryPath(
              dialogTitle: context.l10n.guidePickFolder,
              initialDirectory: ref.read(desktopSaveDirectoryProvider),
            );
      if (!mounted || (!clear && selected == null)) return;
      await ref.read(desktopSaveDirectoryProvider.notifier).select(selected);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _choose(String canvas, bool temporary) async {
    if (ref.read(temporaryOptionsProvider).canvases.contains(canvas) ==
        temporary) {
      return;
    }
    setState(() => _switching = true);
    try {
      await setDesktopCanvasGalleryMode(
        context,
        ref,
        canvas,
        temporary: temporary,
      );
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, text = context.texts;
    final canvas = ref.watch(canvasWorkspaceProvider.select((w) => w.active));
    final options = ref.watch(temporaryOptionsProvider);
    final temp = options.canvases.contains(canvas.id);
    final folder = ref.watch(desktopSaveDirectoryProvider);
    final save = ref.watch(saveSettingsProvider);
    return _Step(
      active: true,
      icon: Icons.folder_outlined,
      title: l.guideStorage,
      desc: l.guideStorageLead,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.guideDirectory, style: text.titleMedium),
          const SizedBox(height: 4),
          Text(l.guideDirectoryHint),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SelectableText(folder ?? l.guideUnset),
              OutlinedButton.icon(
                onPressed: _picking ? null : _directory,
                icon: const Icon(Icons.folder_open, size: 18),
                label: Text(l.guidePickFolder),
              ),
              if (folder != null)
                TextButton(
                  onPressed: _picking ? null : () => _directory(clear: true),
                  child: Text(l.guideClearFolder),
                ),
            ],
          ),
          const Divider(height: 28),
          Text(
            '${l.guideCurrentGallery} · ${canvas.name}',
            style: text.titleMedium,
          ),
          const SizedBox(height: 8),
          _GuideGrid(
            children: [
              _GuideCard(
                Icons.photo_library_outlined,
                l.guideStandard,
                l.guideStandardHint,
                selected: !temp,
                onTap: _switching ? null : () => _choose(canvas.id, false),
              ),
              _GuideCard(
                Icons.hourglass_empty,
                l.temporaryName,
                l.guideTempHint,
                selected: temp,
                onTap: _switching ? null : () => _choose(canvas.id, true),
              ),
            ],
          ),
          if (temp) ...[
            const SizedBox(height: 10),
            DecoratedBox(
              key: const ValueKey('desktop-guide-temp-detail'),
              decoration: BoxDecoration(
                color: context.scheme.surfaceContainerLow,
                border: Border.all(color: context.scheme.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  l.guideTempDetail,
                  style: text.bodySmall?.copyWith(
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
          if (temp || options.temporaryForNewCanvases)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l.guideNewTemp),
              value: options.temporaryForNewCanvases,
              onChanged: (v) => ref
                  .read(temporaryOptionsProvider.notifier)
                  .update(temporaryForNewCanvases: v),
            ),
          const Divider(height: 28),
          Text(l.guideFormat, style: text.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<SaveFormat>(
            showSelectedIcon: false,
            segments: [
              for (final f in SaveFormat.values)
                ButtonSegment(
                  value: f,
                  label: Text(
                    f == SaveFormat.webp ? 'WebP' : f.name.toUpperCase(),
                  ),
                ),
            ],
            selected: {save.value?.format ?? SaveFormat.png},
            onSelectionChanged: save.hasValue
                ? (v) => ref
                      .read(saveSettingsProvider.notifier)
                      .patch((s) => s.copyWith(format: v.first))
                : null,
          ),
          if (save.value?.format == SaveFormat.jpg) ...[
            const SizedBox(height: 6),
            Text(l.guideJpgHint, style: text.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _GuideSummary extends ConsumerWidget {
  const _GuideSummary({required this.active});
  final bool active;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n, scheme = context.scheme;
    final theme = ref.watch(themeSettingsProvider);
    final appearance = switch (theme.mode) {
      ThemeMode.system => l.followSystem,
      ThemeMode.light => l.themeLight,
      ThemeMode.dark => l.themeDark,
    };
    final bot = ref.watch(authModeProvider).value == AuthMode.bot;
    final authorized = ref.watch(botSessionProvider).value != null;
    final primary = ref.watch(primaryNaiKeyProvider).value;
    final ready = bot ? authorized : primary != null;
    final connection = !ready
        ? l.guideNoAccess
        : bot
        ? l.guideBotReady
        : primary!.isThirdParty
        ? '${l.thirdParty} · ${naiEndpointIsChat(primary.endpoint) ? NaiApiFormat.openai.label : NaiApiFormat.nai.label} · ${l.statusSaved}'
        : l.guideSavedOfficial;
    final canvas = ref.watch(canvasWorkspaceProvider.select((w) => w.active));
    final options = ref.watch(temporaryOptionsProvider);
    final album = options.canvases.contains(canvas.id)
        ? l.temporaryName
        : '${l.guideStandard} · ${desktopLibraryLabel(ref.watch(desktopLibraryProvider), ref.watch(albumsProvider))}';
    final modeSummary = options.temporaryForNewCanvases
        ? '${canvas.name} · $album · ${l.guideNewTempShort}'
        : '${canvas.name} · $album';
    final folder = ref.watch(desktopSaveDirectoryProvider) ?? l.guideUnset;
    final format =
        ref.watch(saveSettingsProvider).value?.format ?? SaveFormat.png;
    return _Step(
      active: active,
      icon: Icons.check_rounded,
      title: l.desktopSetupComplete,
      desc: ready ? l.guideReady : l.guideNotReady,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final row in [
                    (l.guideAppearance, '$appearance · ${theme.seed.label}'),
                    (l.guideGeneration, connection),
                    (
                      l.desktopExtensions,
                      authorized ? l.desktopAuthorized : l.guideNoBot,
                    ),
                    (
                      l.guideSaveFormat,
                      "$folder · ${format == SaveFormat.webp ? 'WebP' : format.name.toUpperCase()}",
                    ),
                    (l.guideMode, modeSummary),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 102,
                            child: Text(
                              row.$1,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(row.$2)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(l.guideTips, style: context.texts.titleMedium),
          const SizedBox(height: 8),
          _GuideGrid(
            children: [
              _GuideCard(
                Icons.image_search,
                l.guideImportTip,
                l.guideImportTipBody,
              ),
              _GuideCard(
                Icons.edit_note,
                l.guideStudioTip,
                l.guideStudioTipBody,
              ),
              _GuideCard(
                Icons.archive_outlined,
                l.guideTempTip,
                l.guideTempTipBody,
              ),
              _GuideCard(
                Icons.compare_outlined,
                l.guideToolsTip,
                l.guideToolsTipBody,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
