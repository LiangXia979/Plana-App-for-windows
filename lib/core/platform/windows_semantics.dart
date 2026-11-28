import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/semantics.dart' show SemanticsNode, SemanticsOwner;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

class PlanaWindowsBinding extends WidgetsFlutterBinding
    with WindowsSemanticsBinding {}

/// Flutter's Windows accessibility bridge assumes every submitted node belongs
/// to the root's traversal tree. Portals can emit detached nodes in the same
/// frame. Send only connected changes to that bridge (flutter/flutter#195144).
mixin WindowsSemanticsBinding on RendererBinding {
  final _trees = Expando<WindowsSemanticsTree>();

  @override
  SemanticsUpdateBuilder createSemanticsUpdateBuilder() {
    final delegate = super.createSemanticsUpdateBuilder();
    // The desktop app has one view. A new owner (e.g. after accessibility is
    // enabled again) needs a fresh copy of the tree that Windows has seen.
    final owner = renderViews.singleOrNull?.owner?.semanticsOwner;
    if (owner == null) return delegate;
    final tree = _trees[owner] ??= WindowsSemanticsTree();
    return _WindowsUpdate(delegate, tree, owner);
  }
}

typedef _Node = ({
  Int32List children,
  void Function(SemanticsUpdateBuilder, Int32List) write,
});

class WindowsSemanticsTree {
  final _nodes = <int, _Node>{};
  Map<int, int> _parents = {};
  Map<int, List<int>> _children = {};
  final _changed = <int>{};

  void update(
    int id,
    Int32List children,
    void Function(SemanticsUpdateBuilder, Int32List) write,
  ) {
    _nodes[id] = (children: children, write: write);
    _changed.add(id);
  }

  void commit(SemanticsUpdateBuilder delegate, bool Function(int) attached) {
    _nodes.removeWhere((id, _) => !attached(id));
    final parents = <int, int>{};
    final children = <int, List<int>>{};

    void visit(int id, int parent, bool reattached) {
      final node = _nodes[id]!;
      parents[id] = parent;
      final rebuild = reattached || _parents[id] != parent;
      final connected = <int>[];
      for (final child in node.children) {
        if (!parents.containsKey(child) && _nodes.containsKey(child)) {
          connected.add(child);
          visit(child, id, rebuild);
        }
      }
      children[id] = connected;
      if (rebuild ||
          _changed.contains(id) ||
          !listEquals(connected, _children[id])) {
        node.write(delegate, Int32List.fromList(connected));
      }
    }

    if (_nodes.containsKey(0)) visit(0, -1, false);
    _parents = parents;
    _children = children;
    _changed.clear();
  }
}

class _WindowsUpdate implements SemanticsUpdateBuilder {
  _WindowsUpdate(this.delegate, this.tree, this.owner);

  final SemanticsUpdateBuilder delegate;
  final WindowsSemanticsTree tree;
  final SemanticsOwner owner;

  @override
  SemanticsUpdate build() {
    // 3.44 exposes the physical tree through visitChildren. A portal can
    // remain attached here while temporarily absent from traversal order.
    final root = owner.rootSemanticsNode;
    if (root != null) {
      final attached = <int>{};
      bool collect(SemanticsNode node) {
        attached.add(node.id);
        node.visitChildren(collect);
        return true;
      }

      collect(root);
      tree.commit(delegate, attached.contains);
    }
    return delegate.build();
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => delegate.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );

  @override
  void updateNode({
    required int id,
    required SemanticsFlags flags,
    required int actions,
    required int maxValueLength,
    required int currentValueLength,
    required int textSelectionBase,
    required int textSelectionExtent,
    required int platformViewId,
    required int scrollChildren,
    required int scrollIndex,
    required int traversalParent,
    required double scrollPosition,
    required double scrollExtentMax,
    required double scrollExtentMin,
    required Rect rect,
    required String identifier,
    required String label,
    required List<StringAttribute> labelAttributes,
    required String value,
    required List<StringAttribute> valueAttributes,
    required String increasedValue,
    required List<StringAttribute> increasedValueAttributes,
    required String decreasedValue,
    required List<StringAttribute> decreasedValueAttributes,
    required String hint,
    required List<StringAttribute> hintAttributes,
    required String tooltip,
    required TextDirection? textDirection,
    required Float64List transform,
    required Float64List hitTestTransform,
    required Int32List childrenInTraversalOrder,
    required Int32List childrenInHitTestOrder,
    required Int32List additionalActions,
    int headingLevel = 0,
    String linkUrl = '',
    SemanticsRole role = SemanticsRole.none,
    required List<String>? controlsNodes,
    SemanticsValidationResult validationResult = SemanticsValidationResult.none,
    SemanticsHitTestBehavior hitTestBehavior = SemanticsHitTestBehavior.defer,
    required SemanticsInputType inputType,
    required Locale? locale,
    required String minValue,
    required String maxValue,
  }) {
    tree.update(
      id,
      childrenInTraversalOrder,
      (builder, connected) => builder.updateNode(
        id: id,
        flags: flags,
        actions: actions,
        maxValueLength: maxValueLength,
        currentValueLength: currentValueLength,
        textSelectionBase: textSelectionBase,
        textSelectionExtent: textSelectionExtent,
        platformViewId: platformViewId,
        scrollChildren: scrollChildren,
        scrollIndex: scrollIndex,
        traversalParent: traversalParent,
        scrollPosition: scrollPosition,
        scrollExtentMax: scrollExtentMax,
        scrollExtentMin: scrollExtentMin,
        rect: rect,
        identifier: identifier,
        label: label,
        labelAttributes: labelAttributes,
        value: value,
        valueAttributes: valueAttributes,
        increasedValue: increasedValue,
        increasedValueAttributes: increasedValueAttributes,
        decreasedValue: decreasedValue,
        decreasedValueAttributes: decreasedValueAttributes,
        hint: hint,
        hintAttributes: hintAttributes,
        tooltip: tooltip,
        textDirection: textDirection,
        transform: transform,
        hitTestTransform: hitTestTransform,
        childrenInTraversalOrder: connected,
        childrenInHitTestOrder: childrenInHitTestOrder,
        additionalActions: additionalActions,
        headingLevel: headingLevel,
        linkUrl: linkUrl,
        role: role,
        controlsNodes: controlsNodes,
        validationResult: validationResult,
        hitTestBehavior: hitTestBehavior,
        inputType: inputType,
        locale: locale,
        minValue: minValue,
        maxValue: maxValue,
      ),
    );
  }
}
