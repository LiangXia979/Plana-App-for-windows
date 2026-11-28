import 'package:flutter/material.dart';

/// The visible count follows the active editor. Hover reveals both local counts.
class PromptTokenCounts extends StatelessWidget {
  const PromptTokenCounts({
    super.key,
    this.used,
    required this.limit,
    required this.positive,
    required this.negative,
  });

  final int? used;
  final int limit;
  final int positive;
  // Medium keeps the High negative draft but does not send it.
  final int? negative;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label =
        '正向 $positive · ${negative == null ? 'Medium 使用固定负面' : '负面 $negative'}';
    final count = used ?? positive;
    return Tooltip(
      message: label,
      child: Text(
        '$count / $limit',
        textAlign: TextAlign.end,
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
          color: count > limit ? scheme.error : scheme.outline,
        ),
      ),
    );
  }
}
