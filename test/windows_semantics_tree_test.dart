import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/windows_semantics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Windows only receives reachable nodes and restores a reattached subtree',
    () {
      final tree = WindowsSemanticsTree();
      final alive = <int>{0, 1, 2, 3, 4};
      final writes = <int, List<int>>{};
      void node(int id, List<int> children) => tree.update(
        id,
        Int32List.fromList(children),
        (_, connected) => writes[id] = connected.toList(),
      );
      void frame() {
        writes.clear();
        final builder = SemanticsUpdateBuilder();
        tree.commit(builder, alive.contains);
        builder.build().dispose();
      }

      node(3, [4]);
      node(4, []);
      node(1, []);
      node(2, [0, 2, 90]);
      node(0, [1, 2]);
      frame();
      expect(writes, {
        0: [1, 2],
        1: [],
        2: [],
      });
      node(1, [3]);
      frame();
      expect(writes, {
        1: [3],
        3: [4],
        4: [],
      });
      node(1, []);
      node(2, [3]);
      frame();
      expect(writes, {
        1: [],
        2: [3],
        3: [4],
        4: [],
      });
      alive.remove(3);
      frame();
      expect(writes, {2: []});
      frame();
      expect(writes, isEmpty);
    },
  );
}
