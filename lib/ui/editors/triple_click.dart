import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

/// Triple click selects the whole line, as in native editors.
///
/// re_editor handles only single click (cursor) and double click (word):
/// a third click either selects the word again or, with the double click
/// selection under the pointer, collapses it on release. This widget counts
/// the consecutive primary clicks itself and, from the third on, selects the
/// clicked line including its line break (to the end of the text on the
/// last line), after re_editor (deeper in the tree) handled the event.
class TripleClickLineSelect extends StatefulWidget {
  const TripleClickLineSelect({super.key, required this.controller, required this.child});

  final CodeLineEditingController controller;
  final Widget child;

  /// Same distance used by re_editor to recognize a double click.
  static const double slop = 10;

  @override
  State<TripleClickLineSelect> createState() => _TripleClickLineSelectState();
}

class _TripleClickLineSelectState extends State<TripleClickLineSelect> {
  int _count = 0;
  Duration? _lastStamp;
  Offset? _lastPosition;
  int? _pointer;
  CodeLineSelection? _lineSelection;

  void _down(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse || e.buttons != kPrimaryButton) {
      _count = 0;
      return;
    }
    final last = _lastStamp, pos = _lastPosition;
    final chained = last != null &&
        pos != null &&
        e.timeStamp - last < kDoubleTapTimeout &&
        (e.position - pos).distance < TripleClickLineSelect.slop;
    _count = chained ? _count + 1 : 1;
    _lastStamp = e.timeStamp;
    _lastPosition = e.position;
    _pointer = null;
    _lineSelection = null;
    if (_count < 3) return;
    // re_editor has already placed the cursor / selected the word on the
    // clicked line: its extent is on that line (in the controller's indexes,
    // folding included).
    final sel = _selectLine(widget.controller.selection.extentIndex);
    if (sel == null) return;
    _pointer = e.pointer;
    _lineSelection = sel;
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final sel = _lineSelection;
    _lineSelection = null;
    // re_editor collapses a selection clicked inside on release; a drag
    // started by the third click leaves its own (non collapsed) selection.
    if (sel != null && widget.controller.selection.isCollapsed) widget.controller.selection = sel;
  }

  CodeLineSelection? _selectLine(int index) {
    final lines = widget.controller.codeLines;
    if (index < 0 || index >= lines.length) return null;
    final last = index == lines.length - 1;
    final sel = CodeLineSelection(
      baseIndex: index,
      baseOffset: 0,
      extentIndex: last ? index : index + 1,
      extentOffset: last ? lines[index].length : 0,
    );
    widget.controller.selection = sel;
    return sel;
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: (_) => _pointer = _lineSelection = null,
        child: widget.child,
      );
}
