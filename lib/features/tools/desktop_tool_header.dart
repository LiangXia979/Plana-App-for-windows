import 'package:flutter/material.dart';

/// Lets the tool controls share the tab row or wrap together in a narrow pane.
class DesktopToolHeader extends StatelessWidget {
  const DesktopToolHeader({super.key, this.tabs, required this.actions});

  final Widget? tabs;
  final Widget actions;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: tabs == null ? WrapAlignment.end : WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 12,
    runSpacing: 8,
    children: [?tabs, actions],
  );
}
