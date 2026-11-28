import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A narrow hit area; the workspace fits both panes as this divider is dragged.
class DesktopPaneDivider extends StatefulWidget {
  const DesktopPaneDivider({
    super.key,
    required this.label,
    required this.paneWidth,
    this.onResizeStart,
    required this.onResize,
    this.onResizeEnd,
    required this.onReset,
    this.trailingPane = false,
    this.axis = Axis.horizontal,
  });

  static const extent = 8.0;
  final String label;
  final double paneWidth;
  final bool trailingPane;
  final Axis axis;
  final VoidCallback? onResizeStart;
  final ValueChanged<double> onResize;
  final VoidCallback? onResizeEnd;
  final VoidCallback onReset;

  @override
  State<DesktopPaneDivider> createState() => _DesktopPaneDividerState();
}

class _DesktopPaneDividerState extends State<DesktopPaneDivider> {
  bool _hovered = false;
  bool _dragging = false;
  double _startPosition = 0;
  double _startWidth = 0;

  void _endDrag() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onResizeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _hovered || _dragging;
    final horizontal = widget.axis == Axis.horizontal;
    final dimension = horizontal ? '宽度' : '高度';
    double along(Offset offset) => horizontal ? offset.dx : offset.dy;
    void start(DragStartDetails details) {
      _startPosition = along(details.globalPosition);
      _startWidth = widget.paneWidth;
      widget.onResizeStart?.call();
      setState(() => _dragging = true);
    }

    void update(DragUpdateDetails details) {
      final delta = along(details.globalPosition) - _startPosition;
      widget.onResize(_startWidth + (widget.trailingPane ? -delta : delta));
    }

    return Semantics(
      label: '${widget.label}$dimension',
      value: '${widget.paneWidth.round()} 像素',
      child: MouseRegion(
        cursor: horizontal
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Tooltip(
          message: '拖动调整${widget.label}$dimension，双击恢复默认',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: horizontal ? start : null,
            onHorizontalDragUpdate: horizontal ? update : null,
            onHorizontalDragEnd: horizontal ? (_) => _endDrag() : null,
            onHorizontalDragCancel: horizontal ? _endDrag : null,
            onVerticalDragStart: horizontal ? null : start,
            onVerticalDragUpdate: horizontal ? null : update,
            onVerticalDragEnd: horizontal ? null : (_) => _endDrag(),
            onVerticalDragCancel: horizontal ? null : _endDrag,
            onDoubleTap: widget.onReset,
            child: SizedBox(
              width: horizontal ? DesktopPaneDivider.extent : null,
              height: horizontal ? null : DesktopPaneDivider.extent,
              child: ColoredBox(
                color: active
                    ? scheme.primary.withValues(alpha: .10)
                    : scheme.surfaceContainerLow,
                child: Center(
                  child: Container(
                    width: horizontal ? 1 : null,
                    height: horizontal ? null : 1,
                    color: active ? scheme.primary : scheme.outlineVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
