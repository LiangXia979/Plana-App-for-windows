import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';

/// The import route owns the entire client area. Only the two body panes scroll.
class DesktopImportLayout extends StatelessWidget {
  const DesktopImportLayout({
    super.key,
    required this.bytes,
    required this.fileName,
    required this.title,
    required this.source,
    this.sourceLabel,
    required this.fileSize,
    required this.dimensions,
    required this.details,
    required this.referenceActions,
    required this.album,
    required this.summary,
    required this.onClose,
    required this.onEscape,
    this.quickPicks,
    this.onMetadata,
    this.confirm,
  });

  final Uint8List bytes;
  final String fileName, title, source, fileSize;
  final String? dimensions, sourceLabel;
  final Widget details, referenceActions, album;
  final List<String> summary;
  final Widget? quickPicks, confirm;
  final VoidCallback onClose, onEscape;
  final VoidCallback? onMetadata;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onEscape},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const ValueKey('desktop-import-window'),
          backgroundColor: scheme.surface,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, bounds) {
                final narrow =
                    bounds.maxWidth <
                    750 * MediaQuery.textScalerOf(context).scale(1);
                final header = Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(9),
                        child: Icon(
                          Icons.download_outlined,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          Row(
                            children: [
                              if (sourceLabel != null &&
                                  bounds.maxWidth > 420) ...[
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: scheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    child: Text(
                                      sourceLabel!,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onPrimaryContainer,
                                          ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                child: Tooltip(
                                  message: fileName,
                                  child: Text(
                                    [
                                      source,
                                      fileName,
                                      fileSize,
                                    ].where((s) => s.isNotEmpty).join('  ·  '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (!narrow && quickPicks != null) quickPicks!,
                    IconButton(
                      key: const ValueKey('desktop-import-close'),
                      tooltip: l10nNow.closeImport,
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                );
                final rail = _rail(context, narrow);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: narrow ? 12 : 24,
                        vertical: 10,
                      ),
                      child: header,
                    ),
                    if (narrow && quickPicks != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 12,
                          right: 12,
                          bottom: 6,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: quickPicks,
                          ),
                        ),
                      ),
                    const Divider(height: 1),
                    Expanded(
                      child: narrow
                          ? NestedScrollView(
                              headerSliverBuilder: (_, _) => [
                                SliverToBoxAdapter(child: rail),
                              ],
                              body: details,
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  width: (bounds.maxWidth * .30).clamp(
                                    248.0,
                                    460.0,
                                  ),
                                  child: ColoredBox(
                                    color: scheme.surfaceContainerLow,
                                    child: SingleChildScrollView(
                                      primary: false,
                                      child: rail,
                                    ),
                                  ),
                                ),
                                const VerticalDivider(width: 1),
                                Expanded(child: details),
                              ],
                            ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      key: const ValueKey('desktop-import-footer'),
                      padding: EdgeInsets.symmetric(
                        horizontal: narrow ? 12 : 24,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  if (summary.isNotEmpty) ...[
                                    const Text('将导入'),
                                    const SizedBox(width: 6),
                                    for (final label in summary)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 5,
                                        ),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: scheme.primaryContainer
                                                .withValues(alpha: .55),
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 9,
                                              vertical: 4,
                                            ),
                                            child: Text(
                                              label,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.labelMedium,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: onClose,
                            child: Text(l10nNow.cancel),
                          ),
                          if (confirm != null) ...[
                            const SizedBox(width: 6),
                            confirm!,
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _rail(BuildContext context, bool narrow) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.all(narrow ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, bounds) => Container(
              height: math.min(
                narrow ? 150.0 : MediaQuery.sizeOf(context).height * .40,
                bounds.maxWidth,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    bytes,
                    key: const ValueKey('desktop-import-preview'),
                    fit: BoxFit.contain,
                    cacheWidth: 900,
                    errorBuilder: (_, _, _) =>
                        const Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                  if (dimensions != null)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .70),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          child: Text(
                            dimensions!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (onMetadata != null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('desktop-import-metadata'),
              onPressed: onMetadata,
              icon: const Icon(Icons.data_object, size: 18),
              label: Text(l10nNow.fullMetadata),
            ),
          ],
          album,
          const SizedBox(height: 14),
          Text('直接用作图像参考', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          referenceActions,
        ],
      ),
    );
  }
}
