import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../l10n/l10n.dart';
import 'temporary_gallery_state.dart';

typedef TemporaryCanvasCounts = ({
  String name,
  int removing,
  int collected,
  int kept,
});
typedef TemporaryExitDecision = ({TemporaryExitAction action, bool remember});

class TemporaryGalleryExitDialog extends StatefulWidget {
  const TemporaryGalleryExitDialog({
    super.key,
    required this.canvases,
    this.deletingCanvas = false,
  });

  final List<TemporaryCanvasCounts> canvases;
  final bool deletingCanvas;

  @override
  State<TemporaryGalleryExitDialog> createState() =>
      _TemporaryGalleryExitDialogState();
}

class _TemporaryGalleryExitDialogState
    extends State<TemporaryGalleryExitDialog> {
  bool remember = false;

  void _choose(TemporaryExitAction action) =>
      Navigator.of(context).pop((action: action, remember: remember));

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final colors = context.scheme;
    final counts = widget.canvases;
    final multi = counts.length > 1;
    final removing = counts.fold(0, (n, c) => n + c.removing);
    final collected = counts.fold(0, (n, c) => n + c.collected);
    final kept = counts.fold(0, (n, c) => n + c.kept);
    final quantity = l.temporaryCount(removing);
    final lead = multi
        ? l.temporaryMultiLead(counts.length, quantity)
        : l.temporarySingleLead(quantity);
    final offset = lead.indexOf(quantity);
    final pendingColor = ColorScheme.fromSeed(
      seedColor: FixedSemantic.warn,
      brightness: colors.brightness,
    ).primary;
    final emphasis = context.texts.titleMedium!.copyWith(
      color: pendingColor,
      fontWeight: FontWeight.bold,
    );
    String breakdown(TemporaryCanvasCounts c) => l.temporaryCanvasCountDetail(
      c.name,
      c.removing > 0
          ? l.temporaryCleanStat(c.removing)
          : c.kept > 0
          ? l.temporaryKeptStat(c.kept)
          : l.temporaryCollectedStat(c.collected),
    );
    Widget pill(String text, Color color) => DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        border: Border.all(color: color.withValues(alpha: .25)),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        child: Text(
          text,
          style: context.texts.labelMedium!.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
    final zipLabel = widget.deletingCanvas
        ? l.temporaryZipDelete
        : multi
        ? l.temporaryZipExit
        : l.temporarySingleZipExit;
    final back = TextButton(
      onPressed: () => Navigator.pop(context),
      child: Text(l.desktopBackToCreate),
    );
    final commands = Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 6,
      children: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 40),
            visualDensity: VisualDensity.standard,
            backgroundColor: colors.primary.withValues(alpha: .06),
            side: BorderSide(color: colors.primary.withValues(alpha: .28)),
          ),
          onPressed: () => _choose(TemporaryExitAction.zipThenClean),
          child: Text(zipLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 40),
            visualDensity: VisualDensity.standard,
          ),
          onPressed: () => _choose(TemporaryExitAction.clean),
          child: Text(
            widget.deletingCanvas
                ? l.temporaryCleanDelete
                : l.temporaryCleanExit,
          ),
        ),
      ],
    );
    return Dialog(
      backgroundColor: colors.surfaceContainerLow,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 510),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: colors.primary.withValues(alpha: .25),
                      ),
                    ),
                    child: Icon(
                      Icons.hourglass_empty,
                      size: 21,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.deletingCanvas
                          ? l.temporaryDeleteQuestion
                          : l.temporaryExitQuestion,
                      style: context.texts.titleLarge!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: lead.substring(0, offset)),
                    TextSpan(text: quantity, style: emphasis),
                    TextSpan(text: lead.substring(offset + quantity.length)),
                  ],
                ),
                style: context.texts.titleMedium,
              ),
              if (collected > 0 || kept > 0) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    pill(l.temporaryCleanStat(removing), pendingColor),
                    if (collected > 0)
                      pill(l.temporaryCollectedStat(collected), colors.primary),
                    if (kept > 0)
                      pill(l.temporaryKeptStat(kept), colors.onSurfaceVariant),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Text(
                multi
                    ? l.temporaryMultiDetail(counts.map(breakdown).join(' · '))
                    : l.temporarySingleDetail(counts.single.name),
                style: context.texts.bodyMedium!.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              if (!widget.deletingCanvas) ...[
                const SizedBox(height: 18),
                Material(
                  color: Color.alphaBlend(
                    colors.primary.withValues(alpha: .035),
                    colors.surfaceContainerLow,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: .55),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: CheckboxListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      l.temporarySkipPrompt,
                      style: context.texts.bodyMedium,
                    ),
                    subtitle: remember
                        ? Text(
                            l.temporaryRememberHint,
                            style: context.texts.bodySmall,
                          )
                        : null,
                    value: remember,
                    onChanged: (v) => setState(() => remember = v == true),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                overflowSpacing: 6,
                children: [back, commands],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
