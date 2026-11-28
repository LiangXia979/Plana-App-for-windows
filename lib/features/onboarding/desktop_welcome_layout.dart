import '../../l10n/l10n.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../profile/manual/user_manual_entry.dart';
import 'package:flutter/foundation.dart';

/// 桌面引导的外框。内容保活，步骤导航只允许返回或按顺序继续。
class DesktopWelcomeLayout extends StatelessWidget {
  const DesktopWelcomeLayout({
    super.key,
    required this.index,
    required this.pages,
    required this.onStepSelected,
    required this.onNext,
    required this.nextLabel,
    this.onBack,
    this.onSkip,
    this.onClose,
    this.hint,
  });

  final int index;
  final List<Widget> pages;
  final ValueChanged<int> onStepSelected;
  final VoidCallback? onNext;
  final String nextLabel;
  final VoidCallback? onBack;
  final VoidCallback? onSkip;
  final VoidCallback? onClose;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final l = context.l10n;
    final steps = [
      (l.guideWelcome, l.guideWelcomeSub),
      (l.guideAppearance, l.guideAppearanceSub),
      (l.guideGeneration, l.guideAccessSub),
      (l.guideBotStep, l.guideBotSub),
      (l.guideStorage, l.guideStorageSub),
      (l.guideFinish, l.guideFinishSub),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // 引导也会打开在「我的」右侧面板内，以实际可用宽度判断布局。
        final wide =
            constraints.maxWidth >=
            760 * MediaQuery.textScalerOf(context).scale(1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10nNow.desktopGettingStarted,
                          style: context.texts.titleMedium!.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l.guideProgress(
                            index + 1,
                            pages.length,
                            steps[index].$1,
                          ),
                          key: const ValueKey('desktop-welcome-progress'),
                          style: context.texts.bodySmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onClose != null)
                    TextButton.icon(
                      key: const ValueKey('desktop-welcome-close'),
                      onPressed: onClose,
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: Text(l10nNow.desktopBack),
                    ),
                ],
              ),
            ),
            if (!wide)
              LinearProgressIndicator(
                value: (index + 1) / pages.length,
                minHeight: 3,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide)
                    SizedBox(
                      key: const ValueKey('desktop-welcome-navigation'),
                      width: 196,
                      child: Material(
                        color: scheme.surfaceContainerLow,
                        shape: Border(
                          right: BorderSide(
                            color: scheme.outlineVariant.withValues(alpha: .5),
                          ),
                        ),
                        child: ListView(
                          padding: const EdgeInsets.all(12),
                          children: [
                            for (var i = 0; i < steps.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: ListTile(
                                  key: ValueKey('desktop-welcome-step-$i'),
                                  selected: i == index,
                                  enabled:
                                      i <= index ||
                                      (i == index + 1 && onNext != null),
                                  onTap: () => onStepSelected(i),
                                  dense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  minLeadingWidth: 24,
                                  horizontalTitleGap: 10,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  selectedTileColor: scheme.primaryContainer,
                                  leading: i < index
                                      ? Icon(
                                          Icons.check_circle_outline,
                                          size: 24,
                                          color: scheme.primary,
                                        )
                                      : CircleAvatar(
                                          radius: 12,
                                          backgroundColor: i == index
                                              ? scheme.primary
                                              : scheme.surfaceContainerHighest,
                                          foregroundColor: i == index
                                              ? scheme.onPrimary
                                              : scheme.onSurfaceVariant,
                                          child: Text(
                                            '${i + 1}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                  title: Text(steps[i].$1),
                                  subtitle: Text(steps[i].$2),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    key: const ValueKey('desktop-welcome-content'),
                    child: IndexedStack(
                      index: index,
                      sizing: StackFit.expand,
                      children: [
                        for (var i = 0; i < pages.length; i++)
                          TickerMode(
                            enabled: i == index,
                            child: ExcludeFocus(
                              excluding: i != index,
                              child: pages[i],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              key: const ValueKey('desktop-welcome-footer'),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              padding: const EdgeInsets.all(16),
              child:
                  constraints.maxWidth >=
                      880 * MediaQuery.textScalerOf(context).scale(1)
                  ? Row(
                      children: [
                        Expanded(child: _hint(context, hint ?? l.guideLater)),
                        const SizedBox(width: 16),
                        _actions(),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hint != null) ...[
                          _hint(context, hint!),
                          const SizedBox(height: 8),
                        ],
                        _actions(),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _hint(BuildContext context, String text) => Text(
    text,
    style: context.texts.bodySmall!.copyWith(
      color: context.scheme.onSurfaceVariant,
    ),
  );

  Widget _actions() => Wrap(
    alignment: WrapAlignment.end,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 8,
    children: [
      if (index == pages.length - 1 &&
          defaultTargetPlatform == TargetPlatform.windows)
        const UserManualEntry(asButton: true),
      TextButton.icon(
        key: const ValueKey('desktop-welcome-back'),
        onPressed: onBack,
        icon: const Icon(Icons.chevron_left, size: 18),
        label: Text(l10nNow.previous),
      ),
      if (onSkip != null)
        TextButton(
          key: const ValueKey('desktop-welcome-skip'),
          onPressed: onSkip,
          child: Text(l10nNow.skipForNow),
        ),
      FilledButton.icon(
        key: const ValueKey('desktop-welcome-next'),
        onPressed: onNext,
        icon: Icon(
          index == pages.length - 1 ? Icons.check : Icons.chevron_right,
          size: 18,
        ),
        iconAlignment: IconAlignment.end,
        label: Text(nextLabel),
      ),
    ],
  );
}
