import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/app_theme.dart';

/// Two panes separated by a hairline divider with a wider invisible grip.
///
/// Both panes stay mounted while collapsed, so editors, trees and scroll
/// positions survive hiding and showing a pane.
class SplitView extends StatefulWidget {
  const SplitView({
    super.key,
    required this.first,
    required this.second,
    this.axis = Axis.horizontal,
    this.initialFraction = 0.25,
    this.minFirst = 120,
    this.minSecond = 120,
    this.collapsedFirst = false,
    this.collapsedSecond = false,
    this.collapseDuration = Duration.zero,
  });

  final Widget first;
  final Widget second;
  final Axis axis;
  final double initialFraction;
  final double minFirst;
  final double minSecond;

  /// When true only [second] is shown (e.g. sidebar hidden).
  final bool collapsedFirst;

  /// When true only [first] is shown (e.g. results panel hidden).
  final bool collapsedSecond;

  /// How long [first] takes to slide in or out when [collapsedFirst] changes.
  /// Zero (the default) cuts instantly; callers pass zero for keyboard toggles.
  final Duration collapseDuration;

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> with SingleTickerProviderStateMixin {
  late double _fraction = widget.initialFraction;
  bool _hover = false;
  bool _dragging = false;

  /// 1 = [SplitView.first] fully shown, 0 = fully collapsed.
  late final AnimationController _reveal = AnimationController(vsync: this, value: widget.collapsedFirst ? 0 : 1)
    ..addListener(() => setState(() {}));

  @override
  void didUpdateWidget(SplitView old) {
    super.didUpdateWidget(old);
    if (old.collapsedSecond != widget.collapsedSecond) _hover = _dragging = false;
    if (old.collapsedFirst == widget.collapsedFirst) return;
    // The grip disappears under a stationary pointer, which never sends onExit.
    _hover = _dragging = false;
    final target = widget.collapsedFirst ? 0.0 : 1.0;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.collapseDuration == Duration.zero || reduced) {
      _reveal.value = target;
    } else {
      // Retargets from the current value, so a second toggle mid-slide reverses smoothly.
      _reveal.animateTo(target, duration: widget.collapseDuration, curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final horizontal = widget.axis == Axis.horizontal;
    return LayoutBuilder(
      builder: (context, box) {
        final total = horizontal ? box.maxWidth : box.maxHeight;
        const line = 1.0;
        const grip = 8.0;
        var firstSize = (total - line) * _fraction;
        final maxFirst = total - line - widget.minSecond;
        if (maxFirst > widget.minFirst) firstSize = firstSize.clamp(widget.minFirst, maxFirst);

        // The tree keeps the same shape in every state; only extents change.
        final t = _reveal.value;
        final firstShown = t > 0;
        final secondShown = !widget.collapsedSecond;
        final firstExtent = secondShown ? firstSize * t : total;
        final lineExtent = firstShown && secondShown ? line : 0.0;
        final secondExtent = secondShown ? (total - firstExtent - lineExtent).clamp(0.0, total) : 0.0;
        final resizable = t == 1 && secondShown;

        final active = _hover || _dragging;
        final divider = Container(
          width: horizontal ? lineExtent : null,
          height: horizontal ? null : lineExtent,
          color: active ? c.accent.withValues(alpha: 0.6) : c.separator,
        );
        // [first] keeps its full size while sliding, pinned to the divider, so it
        // moves as one piece instead of reflowing; [second] reflows to fill.
        // Hidden panes lay out at their natural size, never at zero.
        final children = [
          _slot(widget.first, firstShown, firstExtent, secondShown ? firstSize : total, horizontal, pinEnd: true),
          divider,
          _slot(
            widget.second,
            secondShown,
            secondExtent,
            secondShown ? secondExtent : total - line - firstSize,
            horizontal,
          ),
        ];
        final handle = MouseRegion(
          cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => setState(() => _dragging = true),
            onPanEnd: (_) => setState(() => _dragging = false),
            onPanCancel: () => setState(() => _dragging = false),
            onDoubleTap: () => setState(() => _fraction = widget.initialFraction),
            onPanUpdate: (d) => setState(() {
              final delta = horizontal ? d.delta.dx : d.delta.dy;
              _fraction = ((firstSize + delta) / (total - line)).clamp(0.05, 0.95);
            }),
          ),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: horizontal ? Row(children: children) : Column(children: children),
            ),
            if (resizable && horizontal)
              Positioned(left: firstSize - grip / 2, top: 0, bottom: 0, width: grip + line, child: handle)
            else if (resizable)
              Positioned(top: firstSize - grip / 2, left: 0, right: 0, height: grip + line, child: handle),
          ],
        );
      },
    );
  }

  /// A pane occupying [extent] but laid out at [full]; when hidden it keeps
  /// its state but takes no input, focus, paint or tickers.
  Widget _slot(Widget child, bool shown, double extent, double full, bool horizontal, {bool pinEnd = false}) {
    full = full.clamp(0.0, double.infinity);
    return SizedBox(
      width: horizontal ? extent : null,
      height: horizontal ? null : extent,
      child: ClipRect(
        child: OverflowBox(
          alignment: pinEnd
              ? (horizontal ? Alignment.centerRight : Alignment.bottomCenter)
              : (horizontal ? Alignment.centerLeft : Alignment.topCenter),
          minWidth: horizontal ? full : null,
          maxWidth: horizontal ? full : null,
          minHeight: horizontal ? null : full,
          maxHeight: horizontal ? null : full,
          child: Visibility(
            visible: shown,
            maintainState: true,
            child: ExcludeFocus(excluding: !shown, child: child),
          ),
        ),
      ),
    );
  }
}

/// Keeps laying out [child] at the constraints it last had while [hold] was
/// false. Wrap the hidden children of an [IndexedStack] in it: the stack lays
/// out every child, so without it each sidebar slide frame would reflow every
/// open tab instead of only the visible one.
class HoldLayout extends SingleChildRenderObjectWidget {
  const HoldLayout({super.key, required this.hold, super.child});

  final bool hold;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHoldLayout(hold);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) => (renderObject as _RenderHoldLayout).hold = hold;
}

class _RenderHoldLayout extends RenderProxyBox {
  _RenderHoldLayout(this._hold);

  bool _hold;
  set hold(bool value) {
    if (value == _hold) return;
    _hold = value;
    markNeedsLayout();
  }

  BoxConstraints? _held;

  @override
  void performLayout() {
    if (!_hold || _held == null) _held = constraints;
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_held!, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }
}
