import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/ui/desktop_text_selection.dart';
import 'package:plana_app/features/assistant/prompt_diff.dart';
import 'package:plana_app/features/assistant/widgets/proposal_sheet.dart';

void main() {
  String? clipboard;
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    clipboard = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = call.arguments['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        return null;
      },
    );
  });
  tearDown(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );

  Future<void> mount(WidgetTester tester, List<Widget> children) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => DesktopTextSelection(child: child!),
        home: Scaffold(body: Column(children: children)),
      ),
    );
  }

  Future<void> drag(WidgetTester tester, int field, int from, int to) async {
    await tester.pump(const Duration(milliseconds: 550));
    final render = tester
        .state<EditableTextState>(find.byType(EditableText).at(field))
        .renderEditable;
    Offset point(int offset) => render.localToGlobal(
      render.getLocalRectForCaret(TextPosition(offset: offset)).center,
    );
    final start = point(from), end = point(to);
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(Offset.lerp(start, end, .55)!);
    await tester.pump();
    await mouse.moveTo(end);
    await tester.pump();
    await mouse.up();
    await tester.pump();
  }

  testWidgets(
    'Ctrl-drag copies, merges overlaps and deletes only selected text',
    (tester) async {
      final controller = TextEditingController(
        text: 'alpha GAP beta GAP gamma',
      );
      await mount(tester, [
        TextField(
          controller: controller,
          inputFormatters: [DesktopSelectionFormatter(controller)],
        ),
      ]);
      await drag(tester, 0, 0, 5);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await drag(tester, 0, 24, 19);
      final doc = DesktopTextRanges.of(controller);
      expect(doc.pinned, [const TextRange(start: 0, end: 5)]);
      expect(
        tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable
            .foregroundPainter,
        isA<RenderEditablePainter>(),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(clipboard, 'alpha\ngamma');
      await drag(tester, 0, 3, 7);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(clipboard, 'alpha G\ngamma');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      expect(controller.text, 'AP beta GAP ');
      expect(doc.pinned, isEmpty);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'the expanded AI proposal shares Ctrl-drag between full prompt and character text',
    (tester) async {
      final diff = diffPrompt('first paragraph', 'first paragraph');
      await mount(tester, [
        ProposalDetails(
          positive: 'first paragraph',
          characters: const [
            (name: 'Iris', positive: 'second paragraph', position: null),
          ],
          emptyNote: '',
          diff: diff,
          words: markChangedWords(diff),
        ),
      ]);
      await drag(tester, 1, 0, 6);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await drag(tester, 0, 0, 5);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(clipboard, 'first\nsecond');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await drag(tester, 0, 6, 15);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(clipboard, 'paragraph');
    },
  );

  testWidgets('cut and paste use the same disjoint selection as copy', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'one two three');
    await mount(tester, [
      TextField(
        controller: controller,
        contextMenuBuilder: DesktopTextSelection.contextMenu,
      ),
    ]);
    await drag(tester, 0, 8, 13);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await drag(tester, 0, 0, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(clipboard, 'one\nthree');
    expect(controller.text, ' two ');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    controller.text = 'one two three';
    await drag(tester, 0, 0, 3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await drag(tester, 0, 8, 13);
    clipboard = '新';
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(controller.text, '新 two ');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'typing over two ranges preserves the gap and the IME composition',
    (tester) async {
      final controller = TextEditingController(text: 'one two three');
      await mount(tester, [
        TextField(
          controller: controller,
          inputFormatters: [DesktopSelectionFormatter(controller)],
        ),
      ]);
      await drag(tester, 0, 0, 3);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await drag(tester, 0, 8, 13);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'one two 新',
          selection: TextSelection.collapsed(offset: 9),
          composing: TextRange(start: 8, end: 9),
        ),
      );
      await tester.pump();
      expect(controller.text, '新 two ');
      expect(controller.value.composing, const TextRange(start: 0, end: 1));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
