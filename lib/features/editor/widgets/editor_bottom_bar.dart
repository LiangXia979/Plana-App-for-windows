import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart' show measureText;
import '../../generate/generate_state.dart';
import '../editor_state.dart';
import '../../../l10n/l10n.dart';

/// 底栏控件的统一高度:正/负滑块、展开钮、右侧操作胶囊共用一个数。
/// 高度钉死,系统字号放大时各控件不会各长各的。
const double _kBarH = 36;

/// 编辑器底栏的正负提示词、编辑模式与撤销操作。
class EditorBottomBar extends ConsumerWidget {
  const EditorBottomBar({
    super.key,
    required this.onToggleMode,
    required this.chipMode,
  });

  /// 正文形态切换:注音富文本 ⇄ 芯片流。选择记在编辑器设置里。
  final VoidCallback onToggleMode;
  final bool chipMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final st = ref.watch(editorProvider);
    final medium = ref.watch(
      generateProvider.select((s) => s.params.isNaiMedium),
    );
    final notifier = ref.read(editorProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: scheme.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: medium
                      ? Text(l10nNow.positivePrompt)
                      : _PosNegToggle(
                          positive: st.activePositive,
                          onChanged: notifier.setActivePositive,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Material(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(_kBarH / 2),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      height: _kBarH,
                      child: Row(
                        children: [
                          // 文案/图标报的是**切过去**的那一头(和 web 那颗
                          // Grid/AlignLeft 同款语义),所以不做选中高亮 ——
                          // 高亮加文案会互相打架。
                          Expanded(
                            child: _GroupAction(
                              icon: chipMode
                                  ? Icons.notes_rounded
                                  : Icons.grid_view_rounded,
                              label: chipMode ? '文本' : '芯片',
                              enabled: true,
                              onTap: onToggleMode,
                            ),
                          ),
                          SizedBox(
                            width: 1,
                            height: 16,
                            child: ColoredBox(color: scheme.outlineVariant),
                          ),
                          Expanded(
                            child: _GroupAction(
                              icon: Icons.undo,
                              label: l10nNow.undo,
                              enabled: st.canUndo,
                              onTap: notifier.undo,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 右侧胶囊里的一颗操作钮:图标 + 文案,禁用置灰(形态切换 / 撤销共用)。
/// 图标与字号同左侧滑块的分段;放不下时整体缩小。
class _GroupAction extends StatelessWidget {
  const _GroupAction({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final fg = enabled ? scheme.onSurface : scheme.outlineVariant;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: SizedBox(
        height: _kBarH,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 5),
                Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 正面 / 负面 切换 —— 滑块分段:激活段填充语义色(正面金 / 负面红)并滑动过渡。
/// 宽度由底栏分配,两段各占一半。
class _PosNegToggle extends StatelessWidget {
  const _PosNegToggle({required this.positive, required this.onChanged});

  final bool positive;
  final ValueChanged<bool> onChanged;

  static const double _h = _kBarH;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final thumbColor = positive ? scheme.primary : scheme.error;
    final onThumb = positive ? scheme.onPrimary : scheme.onError;

    final l = context.l10n;
    return LayoutBuilder(
      builder: (context, c) {
        // 两段都放得下「图标 + 粗体文案」才带图标
        final room = (c.maxWidth - 6) / 2 - 8 - 19;
        const bold = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700);
        final icons = [
          l.positiveShort,
          l.negativeShort,
        ].every((t) => measureText(context, t, bold) <= room);
        return _box(context, thumbColor, onThumb, icons);
      },
    );
  }

  Widget _box(
    BuildContext context,
    Color thumbColor,
    Color onThumb,
    bool icons,
  ) {
    final scheme = context.scheme;
    return Container(
      height: _h,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(_h / 2),
      ),
      child: Stack(
        children: [
          // 滑块:填充当前语义色,左右滑动
          AnimatedAlign(
            duration: Motion.medium,
            curve: Motion.emphasized,
            alignment: positive ? Alignment.centerLeft : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: .5,
              child: AnimatedContainer(
                duration: Motion.medium,
                curve: Motion.standard,
                height: _h - 6,
                decoration: BoxDecoration(
                  color: thumbColor,
                  borderRadius: BorderRadius.circular((_h - 6) / 2),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _seg(
                  context.l10n.positiveShort,
                  icons ? Icons.check : null,
                  active: positive,
                  onThumb: onThumb,
                  onTap: () => onChanged(true),
                ),
              ),
              Expanded(
                child: _seg(
                  context.l10n.negativeShort,
                  icons ? Icons.block : null,
                  active: !positive,
                  onThumb: onThumb,
                  onTap: () => onChanged(false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seg(
    String label,
    IconData? icon, {
    required bool active,
    required Color onThumb,
    required VoidCallback onTap,
  }) {
    return _SegLabel(
      label: label,
      icon: icon,
      active: active,
      onThumb: onThumb,
      height: _h - 6,
      onTap: onTap,
    );
  }
}

class _SegLabel extends StatelessWidget {
  const _SegLabel({
    required this.label,
    required this.icon,
    required this.active,
    required this.onThumb,
    required this.height,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool active;
  final Color onThumb;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final fg = active ? onThumb : scheme.onSurfaceVariant;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
