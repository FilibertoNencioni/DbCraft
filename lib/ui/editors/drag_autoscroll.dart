import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

/// Edge autoscroll while selecting text with the mouse, as in native editors:
/// with the pointer dragged past an edge of the editor the text scrolls every
/// frame, faster the farther the pointer is.
///
/// re_editor alone scrolls one line every 100 ms (10 lines/s at any
/// distance), so reaching the top of a long script takes ages. Here the
/// offset moves every frame and, after each step, a synthetic move of the
/// same pointer lets re_editor extend the selection to the new line under the
/// pointer (its own position -> line mapping, folding included).
///
/// It acts only after the selection has changed during the drag, so
/// dragging the scrollbar thumb outside the editor does not scroll.
class DragSelectAutoScroll extends StatefulWidget {
  const DragSelectAutoScroll({super.key, required this.controller, required this.scroll, required this.child});

  final CodeLineEditingController controller;
  final CodeScrollController scroll;
  final Widget child;

  /// Scroll speed (px/s) at [distance] px past the edge: a few lines per
  /// second at the edge, hundreds far away.
  static double speed(double distance) => min(60000, 12 * (distance + 8) + 0.12 * distance * distance);

  @override
  State<DragSelectAutoScroll> createState() => _DragSelectAutoScrollState();
}

class _DragSelectAutoScrollState extends State<DragSelectAutoScroll> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);

  int? _pointer;
  int _device = 0;
  int _buttons = 0;
  Offset? _position;
  CodeLineSelection? _downSelection;
  bool _selecting = false;

  /// Time stamp of the last real pointer event and ticker time at that event,
  /// for monotonic time stamps on the synthetic moves.
  Duration _eventStamp = Duration.zero;
  Duration _eventElapsed = Duration.zero;
  Duration _lastElapsed = Duration.zero;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse || e.buttons != kPrimaryButton) return;
    _pointer = e.pointer;
    _device = e.device;
    _buttons = e.buttons;
    _position = e.position;
    _eventStamp = e.timeStamp;
    // The editor (deeper in the tree) already handled the down.
    _downSelection = widget.controller.selection;
    _selecting = false;
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer || e.synthesized) return;
    _position = e.position;
    _eventStamp = e.timeStamp;
    _eventElapsed = _lastElapsed;
    if (!_ticker.isActive) {
      _lastElapsed = _eventElapsed = Duration.zero;
      _ticker.start();
    }
  }

  void _end(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _position = null;
    _selecting = false;
    _ticker.stop();
  }

  void _tick(Duration elapsed) {
    final dt = min((elapsed - _lastElapsed).inMicroseconds / 1e6, 0.05);
    _lastElapsed = elapsed;
    // The drag recognizer extends the selection after this widget sees the
    // move, so the check is done here.
    if (!_selecting && widget.controller.selection != _downSelection) _selecting = true;
    final pos = _position, box = context.findRenderObject() as RenderBox?;
    if (!_selecting || pos == null || box == null || !box.attached || dt <= 0) return;
    final local = box.globalToLocal(pos);
    final dy = _overflow(local.dy, box.size.height), dx = _overflow(local.dx, box.size.width);
    final moved = _scrollBy(widget.scroll.verticalScroller, dy, dt) | _scrollBy(widget.scroll.horizontalScroller, dx, dt);
    if (!moved) return;
    GestureBinding.instance.handlePointerEvent(
      PointerMoveEvent(
        timeStamp: _eventStamp + (elapsed - _eventElapsed),
        pointer: _pointer!,
        device: _device,
        kind: PointerDeviceKind.mouse,
        buttons: _buttons,
        position: pos,
        synthesized: true,
      ),
    );
  }

  /// Distance past the edges of [0, extent]: negative before, positive after.
  static double _overflow(double v, double extent) => v < 0 ? v : (v > extent ? v - extent : 0);

  static bool _scrollBy(ScrollController c, double overflow, double dt) {
    if (overflow == 0 || !c.hasClients) return false;
    final p = c.position;
    final target = (p.pixels + overflow.sign * DragSelectAutoScroll.speed(overflow.abs()) * dt)
        .clamp(p.minScrollExtent, p.maxScrollExtent);
    if (target == p.pixels) return false;
    c.jumpTo(target);
    return true;
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _end,
        onPointerCancel: _end,
        child: widget.child,
      );
}
