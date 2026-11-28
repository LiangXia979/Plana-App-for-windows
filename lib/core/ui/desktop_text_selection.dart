import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Flutter handles the active drag (including scrolling, IME and word
/// boundaries). Only the earlier, disjoint selections need extra state.
class DesktopTextRanges extends ChangeNotifier {
  DesktopTextRanges._(this.controller);

  static final _documents = Expando<DesktopTextRanges>();
  static DesktopTextRanges of(TextEditingController controller) =>
      _documents[controller] ??= DesktopTextRanges._(controller);

  final TextEditingController controller;
  List<TextRange> _pinned = const [];
  String? _text;
  List<TextRange> get pinned => _pinned;
  List<TextRange> get selected => merge([...pinned, controller.selection]);

  static List<TextRange> merge(Iterable<TextRange> ranges) {
    final sorted = ranges.where((r) => r.isValid && !r.isCollapsed).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final result = <TextRange>[];
    for (final r in sorted) {
      if (result.isEmpty || r.start > result.last.end) {
        result.add(TextRange(start: r.start, end: r.end));
      } else if (r.end > result.last.end) {
        result.last = TextRange(start: result.last.start, end: r.end);
      }
    }
    return result;
  }

  void replace(Iterable<TextRange> ranges) {
    final next = merge(ranges.where((r) => r.end <= controller.text.length));
    if (listEquals(_pinned, next)) return;
    if (_pinned.isEmpty) controller.addListener(_textChanged);
    _pinned = next;
    _text = controller.text;
    if (next.isEmpty) controller.removeListener(_textChanged);
    notifyListeners();
  }

  void _textChanged() {
    if (controller.text != _text) replace(const []);
  }

  TextEditingValue replaced(List<TextRange> ranges, String insertion) {
    var text = controller.text;
    for (final range in ranges.reversed) {
      text = text.replaceRange(
        range.start,
        range.end,
        range == ranges.first ? insertion : '',
      );
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: ranges.first.start + insertion.length,
      ),
    );
  }
}

/// Applies the OS/IME's edit to a disjoint prompt selection, inserting the
/// replacement once and leaving everything between the ranges intact.
class DesktopSelectionFormatter extends TextInputFormatter {
  DesktopSelectionFormatter(this.controller);
  final TextEditingController controller;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final doc = DesktopTextRanges.of(controller);
    final active = oldValue.selection;
    if (doc.pinned.isEmpty ||
        !active.isValid ||
        active.isCollapsed ||
        oldValue.text == newValue.text ||
        oldValue.text != controller.text) {
      return newValue;
    }
    final before = oldValue.text.substring(0, active.start);
    final after = oldValue.text.substring(active.end);
    if (newValue.text.length < before.length + after.length ||
        !newValue.text.startsWith(before) ||
        !newValue.text.endsWith(after)) {
      return newValue;
    }
    final inserted = newValue.text.substring(
      before.length,
      newValue.text.length - after.length,
    );
    final ranges = doc.selected;
    final replacement = doc.replaced(ranges, inserted);
    final composing = newValue.composing;
    if (!composing.isValid ||
        composing.start < active.start ||
        composing.end > active.start + inserted.length) {
      return replacement;
    }
    final delta = ranges.first.start - active.start;
    return replacement.copyWith(
      composing: TextRange(
        start: composing.start + delta,
        end: composing.end + delta,
      ),
    );
  }
}

class _RangePainter extends RenderEditablePainter {
  _RangePainter(this.document, this.color, this.previous) {
    document.addListener(notifyListeners);
    previous?.addListener(notifyListeners);
  }
  final DesktopTextRanges document;
  final Color color;
  final RenderEditablePainter? previous;

  @override
  void paint(Canvas canvas, Size size, RenderEditable renderEditable) {
    previous?.paint(canvas, size, renderEditable);
    final paint = Paint()
      ..color = color.withValues(alpha: color.a.clamp(.25, .46));
    // The proposal diff has opaque span backgrounds over Flutter's native
    // selection paint. Include its active range in the foreground as well.
    final active = renderEditable.selection;
    final ranges =
        renderEditable.readOnly && renderEditable.hasFocus && active != null
        ? DesktopTextRanges.merge([...document.pinned, active])
        : document.pinned;
    for (final r in ranges) {
      final selection = TextSelection(baseOffset: r.start, extentOffset: r.end);
      for (final box in renderEditable.getBoxesForSelection(selection)) {
        canvas.drawRect(box.toRect(), paint);
      }
    }
  }

  @override
  bool shouldRepaint(RenderEditablePainter? oldDelegate) => oldDelegate != this;

  @override
  void dispose() {
    previous?.removeListener(notifyListeners);
    document.removeListener(notifyListeners);
    super.dispose();
  }
}

typedef _Fragment = ({
  EditableTextState field,
  TextEditingController controller,
  String text,
  TextSelection selection,
});

class DesktopTextSelection extends StatefulWidget {
  const DesktopTextSelection({super.key, required this.child});
  final Widget child;

  static Widget contextMenu(BuildContext context, EditableTextState field) {
    final host =
        context.findAncestorStateOfType<_DesktopTextSelectionState>() ??
        field.context.findAncestorStateOfType<_DesktopTextSelectionState>();
    if (host == null || !host._hasSelection(field)) {
      return AdaptiveTextSelectionToolbar.editableText(
        editableTextState: field,
      );
    }
    final items = field.contextMenuButtonItems.map((item) {
      final action = switch (item.type) {
        ContextMenuButtonType.copy => () => host._copy(field),
        ContextMenuButtonType.cut => () => host._cut(field),
        ContextMenuButtonType.paste => () => host._paste(field),
        _ => null,
      };
      return action == null
          ? item
          : item.copyWith(
              onPressed: () {
                field.hideToolbar();
                action();
              },
            );
    }).toList();
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: field.contextMenuAnchors,
      buttonItems: items,
    );
  }

  @override
  State<DesktopTextSelection> createState() => _DesktopTextSelectionState();
}

class _DesktopTextSelectionState extends State<DesktopTextSelection> {
  final _painters = <EditableTextState, _RangePainter>{};
  _Fragment? _last, _previous;
  EditableTextState? _target;
  Offset? _origin;
  int? _pointer;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_key);
  }

  // TextField can ignore direct hits on its RenderEditable. Its enclosing
  // tap region still identifies the actual field under the pointer, including
  // SelectableText in dialogs. Never look through a foreground route or card.
  ({EditableTextState? field, bool textControl}) _targetAt(
    PointerDownEvent event,
  ) {
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, event.position, event.viewId);
    RenderEditable? found;
    var textControl = false;
    void visit(RenderObject object) {
      if (found != null) return;
      if (object is RenderBox &&
          (!object.hasSize ||
              !object.size.contains(object.globalToLocal(event.position)))) {
        return;
      }
      if (object is RenderEditable) {
        found = object;
      } else {
        object.visitChildren(visit);
      }
    }

    for (final entry in hit.path) {
      final target = entry.target;
      if (target is RenderEditable) found = target;
      if (target is RenderTapRegion && target.groupId == EditableText) {
        textControl = true;
        visit(target);
      }
      if (found != null) break;
    }
    final delegate = found?.textSelectionDelegate;
    if (delegate is! EditableTextState) {
      return (field: null, textControl: textControl);
    }
    if (delegate.widget.obscureText || !delegate.widget.selectionEnabled) {
      return (field: null, textControl: false);
    }
    return (field: delegate, textControl: true);
  }

  EditableTextState? get _focusedField => FocusManager
      .instance
      .primaryFocus
      ?.context
      ?.findAncestorStateOfType<EditableTextState>();

  _Fragment? _snapshot(EditableTextState? field) {
    if (field == null ||
        !field.mounted ||
        field.widget.obscureText ||
        !field.widget.selectionEnabled) {
      return null;
    }
    final value = field.widget.controller.value;
    if (!value.selection.isValid || value.selection.isCollapsed) return null;
    return (
      field: field,
      controller: field.widget.controller,
      text: value.text,
      selection: value.selection,
    );
  }

  void _down(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryButton) {
      return;
    }
    final hit = _targetAt(event);
    final field = hit.field;
    for (final other in _painters.keys.toList()) {
      if (!other.mounted ||
          _painters[other]!.document.controller != other.widget.controller ||
          ModalRoute.of(other.context)?.isCurrent == false) {
        _forget(other);
      }
    }
    _pointer = null;
    _previous = null;
    if (field == null) {
      // A prompt action or editing toolbar operates on the selection.
      // A click elsewhere (including another app tab) dismisses it.
      if (!hit.textControl) {
        _clear();
        _target = null;
        _last = null;
      }
      return;
    }
    _target = field;
    _pointer = event.pointer;
    _origin = event.position;
    if (!HardwareKeyboard.instance.isControlPressed) {
      _clear();
      _last = null;
      return;
    }
    final prior = _last ?? _snapshot(_focusedField) ?? _snapshot(field);
    if (prior != null &&
        prior.field.mounted &&
        prior.field.widget.controller == prior.controller &&
        prior.controller.text == prior.text &&
        ModalRoute.of(prior.field.context) == ModalRoute.of(field.context)) {
      _previous = prior;
    }
  }

  void _move(PointerMoveEvent event) {
    final prior = _previous;
    if (_pointer != event.pointer ||
        prior == null ||
        (event.position - _origin!).distance < kPrecisePointerPanSlop) {
      return;
    }
    _previous = null;
    if (!prior.field.mounted ||
        prior.field.widget.controller != prior.controller ||
        prior.controller.text != prior.text) {
      return;
    }
    final doc = DesktopTextRanges.of(prior.field.widget.controller);
    _attach(prior.field);
    if (_target case final active?
        when active.mounted && active.widget.readOnly) {
      _attach(active);
    }
    doc.replace([...doc.pinned, prior.selection]);
  }

  void _attach(EditableTextState field) {
    _painters.putIfAbsent(field, () {
      final render = field.renderEditable;
      final painter = _RangePainter(
        DesktopTextRanges.of(field.widget.controller),
        render.selectionColor ??
            Theme.of(field.context).colorScheme.primary.withValues(alpha: .35),
        render.foregroundPainter,
      );
      render.foregroundPainter = painter;
      return painter;
    });
  }

  void _up(PointerEvent event) {
    if (_pointer != event.pointer) return;
    _pointer = null;
    _previous = null;
    _last = _snapshot(_target);
  }

  void _forget(EditableTextState field) {
    final painter = _painters.remove(field)!;
    if (field.mounted &&
        field.renderEditable.attached &&
        identical(field.renderEditable.foregroundPainter, painter)) {
      field.renderEditable.foregroundPainter = painter.previous;
    }
    painter.document.replace(const []);
    painter.dispose();
  }

  void _clear() {
    for (final field in _painters.keys.toList()) {
      _forget(field);
    }
  }

  bool _hasSelection(EditableTextState field) =>
      field.mounted &&
      _painters.entries.any(
        (e) =>
            e.key.mounted &&
            e.value.document.pinned.isNotEmpty &&
            ModalRoute.of(e.key.context) == ModalRoute.of(field.context),
      );

  Map<EditableTextState, List<TextRange>> _selection(EditableTextState active) {
    final route = ModalRoute.of(active.context);
    final fields = {..._painters.keys, active}
        .where(
          (f) =>
              f.mounted &&
              f.renderEditable.attached &&
              ModalRoute.of(f.context) == route,
        )
        .toList();
    fields.sort((a, b) {
      final p = a.renderEditable.localToGlobal(Offset.zero);
      final q = b.renderEditable.localToGlobal(Offset.zero);
      return p.dy == q.dy ? p.dx.compareTo(q.dx) : p.dy.compareTo(q.dy);
    });
    return {
      for (final field in fields)
        field: DesktopTextRanges.merge([
          ...DesktopTextRanges.of(field.widget.controller).pinned,
          if (field == active) field.widget.controller.selection,
        ]),
    }..removeWhere((_, ranges) => ranges.isEmpty);
  }

  Future<void> _copy(EditableTextState field) {
    final parts = [
      for (final f in _selection(field).entries)
        for (final r in f.value) r.textInside(f.key.widget.controller.text),
    ];
    return Clipboard.setData(ClipboardData(text: parts.join('\n')));
  }

  void _replace(EditableTextState field, String insertion) {
    final selections = _selection(field);
    if (selections.isEmpty || selections.keys.any((f) => f.widget.readOnly)) {
      return;
    }
    // Update the focused field last so its caret remains the editing target.
    final updates = {
      for (final f in [...selections.keys.where((f) => f != field), field])
        if (selections[f] case final ranges?)
          f: DesktopTextRanges.of(
            f.widget.controller,
          ).replaced(ranges, f == field ? insertion : ''),
    };
    _clear();
    _last = null;
    for (final entry in updates.entries) {
      if (entry.key.mounted) {
        entry.key.userUpdateTextEditingValue(
          entry.value,
          SelectionChangedCause.keyboard,
        );
      }
    }
  }

  /// A clipboard round trip can outlive a view, a document edit or a new drag.
  /// In any of those cases the pending cut/paste no longer owns the selection.
  bool Function() _stillSelected(EditableTextState field) {
    final original = _selection(field);
    final texts = {for (final f in original.keys) f: f.widget.controller.text};
    return () {
      if (!mounted ||
          !field.mounted ||
          !field.widget.focusNode.hasFocus ||
          !_hasSelection(field)) {
        return false;
      }
      final current = _selection(field);
      return current.length == original.length &&
          original.entries.every(
            (e) =>
                e.key.mounted &&
                e.key.widget.controller.text == texts[e.key] &&
                listEquals(current[e.key], e.value),
          );
    };
  }

  Future<void> _cut(EditableTextState field) async {
    final valid = _stillSelected(field);
    await _copy(field);
    if (valid()) _replace(field, '');
  }

  Future<void> _paste(EditableTextState field) async {
    final valid = _stillSelected(field);
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (clipboard?.text != null && valid()) _replace(field, clipboard!.text!);
  }

  KeyEventResult _key(KeyEvent event) {
    final field = _target ?? _focusedField;
    if (event is KeyUpEvent) {
      if (field != null && field.mounted && field.widget.focusNode.hasFocus) {
        _last = _snapshot(field);
      }
      return KeyEventResult.ignored;
    }
    if (_painters.isEmpty) return KeyEventResult.ignored;
    if (field == null ||
        !field.mounted ||
        !field.widget.focusNode.hasFocus ||
        ModalRoute.of(field.context)?.isCurrent == false ||
        !_hasSelection(field)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      if (key == LogicalKeyboardKey.keyC) {
        _copy(field);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyX && !field.widget.readOnly) {
        _cut(field);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV && !field.widget.readOnly) {
        unawaited(_paste(field));
        return KeyEventResult.handled;
      }
    }
    if (!field.widget.readOnly &&
        (key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace)) {
      _replace(field, '');
      return KeyEventResult.handled;
    }
    if ({
          LogicalKeyboardKey.escape,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.home,
          LogicalKeyboardKey.end,
          LogicalKeyboardKey.tab,
          LogicalKeyboardKey.pageUp,
          LogicalKeyboardKey.pageDown,
        }.contains(key) ||
        (keyboard.isControlPressed && key == LogicalKeyboardKey.keyA)) {
      _clear();
      _last = null;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _up,
    onPointerCancel: _up,
    child: widget.child,
  );

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_key);
    _clear();
    super.dispose();
  }
}
