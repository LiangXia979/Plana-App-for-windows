import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor_state.dart';
import '../prompt_studio.dart';

/// Open a window-filling route above the creation page and its navigation.
Future<void> openPromptStudio(
  BuildContext context, {
  String? charId,
  String? sectionId,
  String? foldName,
  bool positive = true,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(editorSessionsProvider).flushPending();
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => UncontrolledProviderScope(
        container: container,
        child: ProviderScope(
          overrides: [
            editorProvider.overrideWith(
              () => EditorNotifier(immediateWriteBack: true),
            ),
          ],
          child: PromptStudio(
            key: const ValueKey('prompt-fullscreen-dialog'),
            charId: charId,
            sectionId: sectionId,
            foldName: foldName,
            positive: positive,
          ),
        ),
      ),
    ),
  );
}
