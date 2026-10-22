import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// AppKit control sizes. Each control maps them to its own metrics.
enum ControlScale {
  mini(ControlSize.mini, TypeSize.mini, 12),
  small(ControlSize.small, TypeSize.caption, 13),
  regular(ControlSize.regular, TypeSize.body, 14),
  toolbar(ControlSize.toolbar, TypeSize.body, 18);

  const ControlScale(this.height, this.fontSize, this.iconSize);

  final double height;
  final double fontSize;

  /// Glyph size next to a label (icon-only buttons use [ToolButton] sizes).
  final double iconSize;
}

/// Devices that drag items on a pannable canvas (ERD tables, query builder
/// boxes). Trackpad two-finger scrolls arrive as pan-zoom gestures: leaving
/// them out lets them reach the enclosing InteractiveViewer, so scrolling
/// over an item pans the canvas instead of moving the item. A trackpad
/// click-and-drag still arrives as a mouse.
const kCanvasDragDevices = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

/// Keyboard focus halo drawn outside [child] (AppKit focus ring): 3.5pt at
/// `focusRing`, faded in over [Motion.fast]. Shown only while [visible].
///
/// With [inset] the ring is drawn inside the bounds instead (grid cells,
/// rows that sit edge to edge).
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.visible,
    required this.child,
    this.radius = Radii.control,
    this.inset = false,
    this.color,
    this.animated = true,
  });

  final bool visible;
  final Widget child;
  final double radius;
  final bool inset;

  /// Fades the ring in and out. Grids turn it off so the cursor follows
  /// clicks and arrow keys without lag.
  final bool animated;

  /// Overrides the ring color (fields with an error use `danger`).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ring = color ?? DbColors.of(context).focusRing;
    if (!animated) {
      return CustomPaint(foregroundPainter: visible ? _RingPainter(ring, radius, inset) : null, child: child);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(end: visible ? 1 : 0),
      duration: Motion.of(context, Motion.fast),
      child: child,
      builder: (context, t, child) => CustomPaint(
        foregroundPainter: t == 0 ? null : _RingPainter(ring.withValues(alpha: ring.a * t), radius, inset),
        child: child,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.color, this.radius, this.inset);

  final Color color;
  final double radius;
  final bool inset;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    canvas.drawRRect(
      inset ? rrect.deflate(0.75) : rrect.inflate(1.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = inset ? 1.5 : 3.5
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color || old.radius != radius || old.inset != inset;
}

/// Shared interaction for every clickable control: hover, press, keyboard
/// focus (Space and Invio activate), disabled state, tooltip and semantics.
///
/// [builder] receives the current states: [WidgetState.hovered],
/// [WidgetState.pressed], [WidgetState.focused] (keyboard focus only, the
/// state that shows a [FocusRing]) and [WidgetState.disabled].
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.onPressed,
    required this.builder,
    this.focusNode,
    this.autofocus = false,
    this.focusable = true,
    this.tooltip,
    this.semanticLabel,
    this.toggled,
    this.cursor = SystemMouseCursors.basic,
    this.onSecondaryTapDown,
    this.shortcuts,
    this.actions,
    this.onPressDown,
  });

  final VoidCallback? onPressed;
  final Widget Function(BuildContext context, Set<WidgetState> states) builder;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Whether Tab reaches the control. Tool buttons stay out of the tab loop,
  /// as in AppKit without Full Keyboard Access.
  final bool focusable;
  final String? tooltip;
  final String? semanticLabel;

  /// Checked state for toggles (checkbox, switch, scope buttons).
  final bool? toggled;
  final MouseCursor cursor;
  final GestureTapDownCallback? onSecondaryTapDown;

  /// Extra key bindings while focused (e.g. arrow keys on a pop-up).
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Handlers for the intents in [shortcuts].
  final Map<Type, Action<Intent>>? actions;

  /// Called on mouse down, before [onPressed] (steppers that repeat).
  final GestureTapDownCallback? onPressDown;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hover = false;
  bool _down = false;
  bool _focus = false;

  bool get _enabled => widget.onPressed != null;

  late final _activateActions = <Type, Action<Intent>>{
    ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate()),
    ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(onInvoke: (_) => _activate()),
  };

  Object? _activate() {
    widget.onPressed?.call();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final states = <WidgetState>{
      if (!_enabled) WidgetState.disabled,
      if (_enabled && _hover) WidgetState.hovered,
      if (_enabled && _down) WidgetState.pressed,
      if (_enabled && _focus) WidgetState.focused,
      if (widget.toggled == true) WidgetState.selected,
    };
    Widget child = FocusableActionDetector(
      enabled: _enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      descendantsAreFocusable: false,
      mouseCursor: _enabled ? widget.cursor : SystemMouseCursors.basic,
      shortcuts: widget.shortcuts,
      actions: widget.actions == null ? _activateActions : {..._activateActions, ...widget.actions!},
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      onShowHoverHighlight: (v) => setState(() {
        _hover = v;
        if (!v) _down = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled
            ? (d) {
                setState(() => _down = true);
                widget.onPressDown?.call(d);
              }
            : null,
        onTapUp: _enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onPressed,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: Semantics(
          button: widget.toggled == null,
          toggled: widget.toggled,
          enabled: _enabled,
          label: widget.semanticLabel ?? widget.tooltip,
          child: widget.builder(context, states),
        ),
      ),
    );
    if (!widget.focusable) {
      child = ExcludeFocus(excluding: true, child: child);
    }
    final tip = widget.tooltip;
    return tip == null || tip.isEmpty ? child : Tooltip(message: tip, child: child);
  }
}

/// Darkens (light) or lightens (dark) a fill for the pressed state.
Color pressedFill(BuildContext context, Color fill) =>
    Color.alphaBlend(DbColors.of(context).pressed, fill);
