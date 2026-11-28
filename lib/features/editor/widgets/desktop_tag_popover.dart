import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum DesktopPopoverPlacement { below, token, side, block }

/// Anchors editor controls in the overlay without changing the sidebar layout.
class DesktopTagPopover extends StatefulWidget {
  const DesktopTagPopover({
    super.key,
    required this.visible,
    required this.anchor,
    required this.anchorRevision,
    required this.panel,
    required this.onDismiss,
    required this.child,
    this.tapGroupId,
    this.chipRows,
    this.panelWidth = 360,
    this.maxPanelHeight = 420,
    this.avoidAnchor = false,
    this.scrollPanel = true,
    this.followAnchor = false,
    this.placement = DesktopPopoverPlacement.below,
    this.yieldToControlDrag = false,
  });

  final bool visible;
  final Rect? Function() anchor;
  final Rect? Function()? chipRows;
  final int anchorRevision;
  final Widget panel;
  final VoidCallback onDismiss;
  final Widget child;
  final Object? tapGroupId;
  final double panelWidth, maxPanelHeight;
  final bool avoidAnchor;

  /// Panels with a fixed header/footer manage scrolling inside their body.
  final bool scrollPanel;
  final bool followAnchor;
  final DesktopPopoverPlacement placement;

  /// Keep the text and chips underneath the action panel accessible for Ctrl-drag.
  final bool yieldToControlDrag;

  @override
  State<DesktopTagPopover> createState() => _DesktopTagPopoverState();
}

class _DesktopTagPopoverState extends State<DesktopTagPopover> {
  // Keep the portal attached and render nothing when inactive. This avoids
  // mutating an OverlayPortalController during an editor/provider rebuild.
  final _portal = OverlayPortalController()..show();
  final _tapGroup = Object();
  final _storage = PageStorageBucket();
  final _scroll = ScrollController(keepScrollOffset: false);
  Rect? _openedAnchor;
  Size? _anchorChildSize;
  Size? _anchorOverlaySize;

  bool _watchingControl = false;
  bool _controlDown = false;

  void _watchControl() {
    final enabled = widget.visible && widget.yieldToControlDrag;
    if (enabled == _watchingControl) return;
    _watchingControl = enabled;
    _controlDown = enabled && HardwareKeyboard.instance.isControlPressed;
    if (enabled) {
      HardwareKeyboard.instance.addHandler(_controlKey);
    } else {
      HardwareKeyboard.instance.removeHandler(_controlKey);
    }
  }

  bool _controlKey(KeyEvent event) {
    final pressed = HardwareKeyboard.instance.isControlPressed;
    if (_controlDown != pressed) setState(() => _controlDown = pressed);
    return false;
  }

  @override
  void initState() {
    super.initState();
    _watchControl();
  }

  @override
  void dispose() {
    if (_watchingControl) HardwareKeyboard.instance.removeHandler(_controlKey);
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DesktopTagPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    _watchControl();
    if (!widget.visible ||
        widget.anchorRevision != oldWidget.anchorRevision ||
        widget.placement != oldWidget.placement) {
      _openedAnchor = null;
    }
  }

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: widget.tapGroupId ?? _tapGroup,
    onTapOutside: widget.visible && !_controlDown
        ? (_) => widget.onDismiss()
        : null,
    // Covered routes can retain their previous layout size during a resize.
    // Only request overlay geometry when the editor can actually display a panel.
    child: !widget.visible || ModalRoute.isCurrentOf(context) == false
        ? OverlayPortal(
            controller: _portal,
            overlayChildBuilder: (_) => const SizedBox.shrink(),
            child: widget.child,
          )
        : OverlayPortal.overlayChildLayoutBuilder(
            controller: _portal,
            overlayChildBuilder: (context, info) {
              if (!widget.visible || _controlDown) {
                return const SizedBox.shrink();
              }
              final overlay =
                  Overlay.of(context).context.findRenderObject() as RenderBox;
              Rect relative(Rect global) => Rect.fromPoints(
                overlay.globalToLocal(global.topLeft),
                overlay.globalToLocal(global.bottomRight),
              );
              // Keep the screen snapshot while scrolling, but resample after reflow:
              // resizing a sidebar/window can wrap the toolbar or selected tags.
              // The layout builder runs after the portal child has its new size.
              if (widget.followAnchor ||
                  _openedAnchor == null ||
                  _anchorChildSize != info.childSize ||
                  _anchorOverlaySize != info.overlaySize) {
                final globalAnchor = widget.anchor();
                if (globalAnchor == null) return const SizedBox.shrink();
                _openedAnchor = relative(globalAnchor);
                _anchorChildSize = info.childSize;
                _anchorOverlaySize = info.overlaySize;
              }
              final anchor = _openedAnchor!;
              final viewport = Offset.zero & info.overlaySize;
              final host = MatrixUtils.transformRect(
                info.childPaintTransform,
                Offset.zero & info.childSize,
              );
              var visible = viewport;
              var current = this.context;
              // The active card can extend underneath fixed sidebar headers/footers.
              while (true) {
                final scrollable = Scrollable.maybeOf(
                  current,
                  axis: Axis.vertical,
                );
                if (scrollable == null) break;
                final box = scrollable.context.findRenderObject();
                if (box is RenderBox &&
                    box.hasSize &&
                    scrollable.position.hasContentDimensions &&
                    scrollable.position.maxScrollExtent >
                        scrollable.position.minScrollExtent) {
                  visible = visible.intersect(
                    relative(box.localToGlobal(Offset.zero) & box.size),
                  );
                }
                current = scrollable.context;
              }
              final placement = widget.placement;
              if (widget.followAnchor &&
                  !visible.overlaps(
                    (placement == DesktopPopoverPlacement.side ? host : anchor)
                        .inflate(1),
                  )) {
                return const SizedBox.shrink();
              }
              final chipRows = widget.chipRows?.call();
              final scheme = Theme.of(context).colorScheme;
              final panel = CustomSingleChildLayout(
                delegate: _TagPopoverLayout(
                  anchor,
                  viewport,
                  widget.panelWidth,
                  widget.maxPanelHeight,
                  widget.avoidAnchor,
                  placement,
                  host,
                  visible,
                  chipRows == null ? null : relative(chipRows),
                ),
                child: TapRegion(
                  groupId: widget.tapGroupId ?? _tapGroup,
                  child: TextFieldTapRegion(
                    child: Material(
                      key: const ValueKey('desktop-tag-popover'),
                      elevation: 8,
                      color: scheme.surfaceContainerLow,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          placement == DesktopPopoverPlacement.token
                              ? 28
                              : placement == DesktopPopoverPlacement.block
                              ? 18
                              : 12,
                        ),
                        side: BorderSide(color: scheme.outlineVariant),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: PageStorage(
                        bucket: _storage,
                        child: PrimaryScrollController.none(
                          child: widget.scrollPanel
                              ? SingleChildScrollView(
                                  controller: _scroll,
                                  primary: false,
                                  child: widget.panel,
                                )
                              : widget.panel,
                        ),
                      ),
                    ),
                  ),
                ),
              );
              return panel;
            },
            child: widget.child,
          ),
  );
}

class _TagPopoverLayout extends SingleChildLayoutDelegate {
  _TagPopoverLayout(
    this.anchor,
    this.viewport,
    this.width,
    this.maxHeight,
    this.avoidAnchor,
    this.placement,
    this.host,
    this.visible,
    this.chipRows,
  );
  final Rect anchor, host, visible;
  final Rect? chipRows;
  final DesktopPopoverPlacement placement;
  final Rect viewport;
  final double width, maxHeight;
  final bool avoidAnchor;
  static const margin = 8.0;
  // Includes the inset between the editor and its sidebar card border.
  static const sideGap = 16.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    var availableWidth = math.min(
      width,
      math.max(0.0, constraints.maxWidth - margin * 2),
    );
    var availableHeight = viewport.height - margin * 2;
    if (placement == DesktopPopoverPlacement.token) {
      availableWidth = math.min(
        availableWidth,
        math.max(0.0, host.width - margin),
      );
    } else if (placement == DesktopPopoverPlacement.side) {
      // Prefer the outer side. With a narrow window, use the free space on
      // either side if it can hold a readable list, or fit inside the window.
      final room =
          math.max(viewport.right - host.right, host.left - viewport.left) -
          sideGap -
          margin;
      if (room >= 240) availableWidth = math.min(availableWidth, room);
      availableHeight = visible.height - margin * 2;
    } else if (avoidAnchor) {
      availableHeight =
          math.max(anchor.top - viewport.top, viewport.bottom - anchor.bottom) -
          margin * 2;
    }
    return BoxConstraints(
      minWidth: availableWidth,
      maxWidth: availableWidth,
      maxHeight: math.min(maxHeight, math.max(0.0, availableHeight)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double fit(double value, double min, double max) =>
        value.clamp(min, math.max(min, max)).toDouble();
    if (placement == DesktopPopoverPlacement.side) {
      final right = host.right + sideGap;
      final left = host.left - sideGap - childSize.width;
      // Reserve room for a full list, so results of different lengths share
      // the same origin even when editing the lowest visible card.
      final slotHeight = math.min(maxHeight, visible.height - 2 * margin);
      final x = right + childSize.width <= size.width - margin || left < margin
          ? right
          : left;
      return Offset(
        fit(x, margin, size.width - childSize.width - margin),
        fit(
          host.top,
          visible.top + margin,
          visible.bottom - slotHeight - margin,
        ),
      );
    }
    if (placement == DesktopPopoverPlacement.token) {
      final x = fit(
        anchor.center.dx - childSize.width / 2,
        math.max(margin, host.left + 4),
        math.min(size.width - margin, host.right - 4) - childSize.width,
      );
      final above = anchor.top - childSize.height - 6;
      final below = anchor.bottom + 6;
      final freeBelowChips =
          chipRows != null &&
          above + childSize.height > chipRows!.top &&
          below >= chipRows!.bottom &&
          below + childSize.height <= visible.bottom;
      final y = above >= visible.top + 4 && !freeBelowChips ? above : below;
      return Offset(
        x,
        fit(y, visible.top + 4, visible.bottom - childSize.height - 4),
      );
    }
    final x = anchor.left.clamp(
      margin,
      math.max(margin, size.width - childSize.width - margin),
    );
    final below = anchor.bottom + margin;
    final y = below + childSize.height <= viewport.bottom - margin
        ? below
        : anchor.top - childSize.height - margin;
    return Offset(
      x.toDouble(),
      y.clamp(
        viewport.top + margin,
        math.max(
          viewport.top + margin,
          viewport.bottom - childSize.height - margin,
        ),
      ),
    );
  }

  @override
  bool shouldRelayout(_TagPopoverLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.viewport != viewport ||
      oldDelegate.width != width ||
      oldDelegate.maxHeight != maxHeight ||
      oldDelegate.avoidAnchor != avoidAnchor ||
      oldDelegate.placement != placement ||
      oldDelegate.host != host ||
      oldDelegate.visible != visible ||
      oldDelegate.chipRows != chipRows;
}
