import '../../../l10n/l10n.dart';
import 'package:flutter/material.dart';

import '../../generate/preset_manage_page.dart';

/// Opens the shared preset manager without leaving the prompt editor.
class PromptPresetMenuButton extends StatelessWidget {
  const PromptPresetMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: const ValueKey('desktop-prompt-preset'),
      tooltip: context.l10n.desktopSwitchPreset,
      icon: const Icon(Icons.bookmarks_outlined, size: 18),
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        fixedSize: const Size.square(30),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: scheme.surfaceContainerHigh,
        foregroundColor: scheme.onSurfaceVariant,
      ),
      onPressed: () => showPromptPresetManager(context),
    );
  }
}
