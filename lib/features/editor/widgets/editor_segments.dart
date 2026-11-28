import 'package:flutter/material.dart';

class EditorSegments<T> extends StatelessWidget {
  const EditorSegments({
    super.key,
    required this.options,
    required this.value,
    required this.onPick,
    this.optionKey,
    this.expanded = false,
  });
  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onPick;
  final Key Function(T)? optionKey;
  final bool expanded;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget segment(T key, String label) => Semantics(
      key: optionKey?.call(key),
      selected: key == value,
      child: TextButton(
        onPressed: () => onPick(key),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          backgroundColor: key == value ? scheme.surface : null,
          foregroundColor: key == value
              ? scheme.primary
              : scheme.onSurfaceVariant,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in options.entries)
                if (expanded)
                  Expanded(child: segment(entry.key, entry.value))
                else
                  segment(entry.key, entry.value),
            ],
          ),
        ),
      ),
    );
  }
}
