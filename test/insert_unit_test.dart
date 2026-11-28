import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/editor_models.dart';

void main() {
  group('insertUnitAt:在光标处插一枚', () {
    test('空正文直接落词', () {
      expect(insertUnitAt('', 0, 'smile'), ('smile', 5));
      expect(insertUnitAt('  ', 2, 'smile'), ('smile', 5));
    });

    test('接在词后补 `, `,右边还有词再补一个', () {
      expect(insertUnitAt('a', 1, 'x'), ('a, x', 4));
      expect(insertUnitAt('a, b', 1, 'x'), ('a, x, b', 4));
    });

    test('逗号后只补空格,不叠出 `,,`', () {
      expect(insertUnitAt('a, ', 3, 'x'), ('a, x', 4));
      expect(insertUnitAt('a, b', 2, 'x'), ('a, x, b', 4));
    });

    test('文首、换行后直接接', () {
      expect(insertUnitAt('a', 0, 'x'), ('x, a', 1));
      expect(insertUnitAt('a,\nb', 3, 'x'), ('a,\nx, b', 4));
    });
  });
}
