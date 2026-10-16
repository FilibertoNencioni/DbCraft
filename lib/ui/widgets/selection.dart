import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'control_base.dart';
import 'menus.dart';

// ---------------------------------------------------------------------------
// Checkbox and radio
// ---------------------------------------------------------------------------

/// The bezel of an unchecked checkbox or radio: control fill, hairline and
/// the control shadow.
BoxDecoration _offBezel(BuildContext context, {required BoxShape shape, bool down = false}) {
  final c = DbColors.of(context);
  final fill = down ? pressedFill(context, c.controlBackground) : c.controlBackground;
  return BoxDecoration(
    color: fill,
    shape: shape,
    borderRadius: shape == BoxShape.rectangle ? BorderRadius.circular(3.5) : null,
    border: Border.all(color: c.controlBorder, width: 0.5),
    boxShadow: Elevation.control(Theme.of(context).brightness),
  );
}

/// AppKit checkbox: 14pt square, radius 3.5. Checked and mixed use the
/// accent with a white ✓ or –, gray when the window is in the background.
///
/// A `null` [value] shows the mixed state; clicking it checks the box.
class MacCheckbox extends StatelessWidget {
  const MacCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
  });

  final bool? value;
  final ValueChanged<bool>? onChanged;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Pressable(
      onPressed: onChanged == null ? null : () => onChanged!(value != true),
      toggled: value ?? false,
      focusNode: focusNode,
      autofocus: autofocus,
      semanticLabel: semanticLabel,
      builder: (context, s) {
        final disabled = s.contains(WidgetState.disabled);
        final down = s.contains(WidgetState.pressed);
        final on = value != false;
        Color fill = c.defaultButton;
        if (down) fill = Color.lerp(fill, const Color(0xFF000000), 0.15)!;
        final box = Container(
          width: 14,
          height: 14,
          decoration: on
              ? BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(3.5),
                  border: c.windowActive ? null : Border.all(color: c.controlBorder, width: 0.5),
                )
              : _offBezel(context, shape: BoxShape.rectangle, down: down),
          child: on ? CustomPaint(painter: _CheckPainter(c.onDefaultButton, mixed: value == null)) : null,
        );
        return FocusRing(
          visible: s.contains(WidgetState.focused),
          radius: 3.5,
          child: Opacity(opacity: disabled ? 0.5 : 1, child: box),
        );
      },
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.color, {required this.mixed});
  final Color color;
  final bool mixed;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    if (mixed) {
      canvas.drawLine(Offset(w * 0.28, w / 2), Offset(w * 0.72, w / 2), p);
    } else {
      canvas.drawPath(
        Path()
          ..moveTo(w * 0.26, w * 0.52)
          ..lineTo(w * 0.43, w * 0.69)
          ..lineTo(w * 0.75, w * 0.3),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.color != color || old.mixed != mixed;
}

/// Checkbox with its label (the label toggles too) and optional help line.
/// The way to show an on/off option inside bars and dense forms.
class CheckboxRow extends StatelessWidget {
  const CheckboxRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.help,
    this.small = false,
    this.focusNode,
  });

  final bool? value;
  final ValueChanged<bool>? onChanged;
  final String label;
  final String? help;

  /// 11pt label for bars.
  final bool small;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final enabled = onChanged != null;
    return Pressable(
      onPressed: enabled ? () => onChanged!(value != true) : null,
      toggled: value ?? false,
      focusNode: focusNode,
      semanticLabel: label,
      builder: (context, s) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: help == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: help == null ? 0 : 2),
            child: ExcludeFocus(
              child: IgnorePointer(
                child: FocusRing(
                  visible: s.contains(WidgetState.focused),
                  radius: 3.5,
                  child: MacCheckbox(value: value, onChanged: enabled ? (_) {} : null),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: uiText(small ? TypeSize.caption : TypeSize.body, color: enabled ? c.text : c.textTertiary),
                ),
                if (help != null)
                  Text(help!, style: uiText(TypeSize.caption, color: c.textSecondary, height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// AppKit radio button: 14pt circle, accent with a white dot when on.
class MacRadio<T> extends StatelessWidget {
  const MacRadio({super.key, required this.value, required this.groupValue, required this.onChanged});

  final T value;
  final T? groupValue;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final on = value == groupValue;
    return Pressable(
      onPressed: onChanged == null ? null : () => onChanged!(value),
      toggled: on,
      builder: (context, s) {
        final down = s.contains(WidgetState.pressed);
        Color fill = c.defaultButton;
        if (down) fill = Color.lerp(fill, const Color(0xFF000000), 0.15)!;
        return FocusRing(
          visible: s.contains(WidgetState.focused),
          radius: 7,
          child: Opacity(
            opacity: s.contains(WidgetState.disabled) ? 0.5 : 1,
            child: Container(
              width: 14,
              height: 14,
              alignment: Alignment.center,
              decoration: on
                  ? BoxDecoration(color: fill, shape: BoxShape.circle)
                  : _offBezel(context, shape: BoxShape.circle, down: down),
              child: on
                  ? Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: c.onDefaultButton, shape: BoxShape.circle),
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }
}

/// A column (or row) of labelled radio buttons for one choice.
class MacRadioGroup<T> extends StatelessWidget {
  const MacRadioGroup({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.axis = Axis.vertical,
  });

  final T value;

  /// Value, label and optional help line.
  final List<(T, String, String?)> items;
  final ValueChanged<T>? onChanged;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final enabled = onChanged != null;
    final children = [
      for (final (v, label, help) in items)
        Pressable(
          onPressed: enabled ? () => onChanged!(v) : null,
          toggled: v == value,
          semanticLabel: label,
          builder: (context, s) => Padding(
            padding: axis == Axis.vertical ? const EdgeInsets.symmetric(vertical: 3) : EdgeInsets.zero,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: help == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: help == null ? 0 : 2),
                  child: ExcludeFocus(
                    child: IgnorePointer(
                      child: FocusRing(
                        visible: s.contains(WidgetState.focused),
                        radius: 7,
                        child: MacRadio<T>(value: v, groupValue: value, onChanged: enabled ? (_) {} : null),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: uiText(TypeSize.body, color: enabled ? c.text : c.textTertiary)),
                      if (help != null) Text(help, style: uiText(TypeSize.caption, color: c.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
    return axis == Axis.vertical
        ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children)
        : Wrap(spacing: Gap.lg, runSpacing: Gap.xs, children: children);
  }
}

// ---------------------------------------------------------------------------
// Switch
// ---------------------------------------------------------------------------

/// NSSwitch: 38×22 (small 32×18), accent track when on.
///
/// HIG: a switch belongs in a settings [FormRow]. In toolbars and bars use a
/// small [CheckboxRow] instead.
class DbSwitch extends StatelessWidget {
  const DbSwitch({super.key, required this.value, required this.onChanged, this.small = false, this.focusNode});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool small;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final w = small ? 32.0 : 38.0;
    final h = small ? 18.0 : 22.0;
    const inset = 1.5;
    final knob = h - 2 * inset;
    final d = Motion.of(context, Motion.regular);
    return Pressable(
      onPressed: onChanged == null ? null : () => onChanged!(!value),
      toggled: value,
      focusNode: focusNode,
      builder: (context, s) {
        final on = value;
        final track = on ? (c.windowActive ? c.accent : c.textTertiary) : c.pressed;
        return FocusRing(
          visible: s.contains(WidgetState.focused),
          radius: h / 2,
          child: Opacity(
            opacity: s.contains(WidgetState.disabled) ? 0.5 : 1,
            child: AnimatedContainer(
              duration: d,
              curve: Curves.easeOut,
              width: w,
              height: h,
              padding: const EdgeInsets.all(inset),
              decoration: BoxDecoration(
                color: track,
                borderRadius: BorderRadius.circular(h / 2),
                border: on ? null : Border.all(color: c.controlBorder, width: 0.5),
              ),
              child: AnimatedAlign(
                duration: d,
                curve: Curves.easeOut,
                alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    color: s.contains(WidgetState.pressed) ? const Color(0xFFF0F0F0) : const Color(0xFFFFFFFF),
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(color: Color(0x40000000), blurRadius: 1.5, offset: Offset(0, 0.5)),
                      BoxShadow(color: Color(0x14000000), blurRadius: 0, spreadRadius: 0.5),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Segmented control
// ---------------------------------------------------------------------------

/// NSSegmentedControl (select one): a recessed track with the selected
/// segment as a raised pill. Text, icon or icon-only segments, optional
/// colored dot. ←/→ change the selection when focused.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.expand = false,
    this.dot,
    this.iconOnly = false,
    this.small = false,
  });

  final T value;
  final List<(T, String, IconData?)> items;
  final ValueChanged<T>? onChanged;
  final bool expand;

  /// Show only the icons; labels become tooltips (narrow places).
  final bool iconOnly;

  /// Optional colored dot before a segment's label (null = no dot).
  final Color? Function(T value)? dot;

  /// 19pt high with 11pt labels.
  final bool small;

  void _step(int delta) {
    final i = items.indexWhere((it) => it.$1 == value);
    final j = (i + delta).clamp(0, items.length - 1);
    if (j != i) onChanged?.call(items[j].$1);
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scale = small ? ControlScale.small : ControlScale.regular;
    final selectedIndex = items.indexWhere((it) => it.$1 == value);
    final enabled = onChanged != null;

    Widget seg(int i) {
      final it = items[i];
      final selected = i == selectedIndex;
      final fg = !enabled ? c.textTertiary : (selected ? c.text : c.textSecondary);
      Widget content = iconOnly && it.$3 != null
          ? Icon(it.$3, size: small ? 13 : 15, color: fg)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (it.$3 != null) ...[Icon(it.$3, size: scale.iconSize - 1, color: fg), const SizedBox(width: 5)],
                if (dot?.call(it.$1) case final Color d) ...[
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: d, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    it.$2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(scale.fontSize, color: fg, weight: selected ? FontWeight.w500 : null),
                  ),
                ),
              ],
            );
      content = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(it.$1) : null,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: iconOnly ? 8 : 10),
          alignment: Alignment.center,
          decoration: selected
              ? BoxDecoration(
                  color: c.segmentSelected,
                  borderRadius: BorderRadius.circular(Radii.control - 1),
                  border: dark ? Border.all(color: c.controlBorder, width: 0.5) : null,
                  boxShadow: Elevation.control(Theme.of(context).brightness),
                )
              : null,
          child: content,
        ),
      );
      if (iconOnly) content = Tooltip(message: it.$2, child: content);
      return expand ? Expanded(child: content) : content;
    }

    Widget divider(int i) {
      // Hairline between two unselected neighbours, as in AppKit.
      final show = i != selectedIndex && i + 1 != selectedIndex;
      return Container(width: 1, height: scale.height - 10, color: show ? c.separator : const Color(0x00000000));
    }

    return Pressable(
      onPressed: enabled ? () {} : null,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
      },
      actions: {_StepIntent: CallbackAction<_StepIntent>(onInvoke: (i) => _step(i.delta))},
      builder: (context, s) => FocusRing(
        visible: s.contains(WidgetState.focused),
        child: Container(
          height: scale.height,
          padding: const EdgeInsets.all(1),
          decoration: BoxDecoration(color: c.pressed, borderRadius: BorderRadius.circular(Radii.control)),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              for (var i = 0; i < items.length; i++) ...[if (i > 0) divider(i - 1), seg(i)],
            ],
          ),
        ),
      ),
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.delta);
  final int delta;
}

// ---------------------------------------------------------------------------
// Pop-up button
// ---------------------------------------------------------------------------

/// Where a [PopUpButton] sits, which decides its bezel.
enum PopUpStyle {
  /// Push-button bezel with the accent ⌃⌄ capsule on the right (forms).
  form,

  /// No bezel until hovered; text plus a small ⌃⌄ (inside tables and grids).
  inline,

  /// 28pt, bezel on hover only (window and pane toolbars).
  toolbar,
}

/// NSPopUpButton: shows the current choice and opens a menu of fixed choices
/// with the current one aligned over the control.
class PopUpButton<T> extends StatelessWidget {
  const PopUpButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.style = PopUpStyle.form,
    this.small = false,
    this.expand = false,
    this.width,
    this.placeholder,
    this.tooltip,
    this.focusNode,
    this.entries,
  });

  final T value;

  /// Value, label and optional leading icon (with its color).
  final List<(T, String, (IconData, Color)?)> items;

  /// Custom menu rows (`MenuEntry.connection`) in place of the ones built
  /// from [items]; their values must be the [items] values.
  final List<MenuEntry<T>> Function()? entries;
  final ValueChanged<T>? onChanged;
  final PopUpStyle style;
  final bool small;

  /// Fill the available width (form rows).
  final bool expand;
  final double? width;

  /// Shown when [value] matches no item.
  final String? placeholder;
  final String? tooltip;
  final FocusNode? focusNode;

  Future<void> _open(BuildContext context) async {
    final hasIcons = items.any((it) => it.$3 != null);
    final picked = await showMacMenu<T>(
      context,
      anchor: anchorRect(context),
      initial: value,
      alignInitial: style != PopUpStyle.toolbar,
      minWidth: style == PopUpStyle.toolbar ? anchorRect(context).width : 0,
      entries:
          entries?.call() ??
          [
            for (final it in items)
              MenuEntry<T>(
                it.$2,
                value: it.$1,
                checked: it.$1 == value,
                leading: hasIcons && it.$3 != null ? Icon(it.$3!.$1, size: 13, color: it.$3!.$2) : null,
              ),
          ],
    );
    if (picked != null && picked != value) onChanged?.call(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final scale = style == PopUpStyle.toolbar ? ControlScale.toolbar : (small ? ControlScale.small : ControlScale.regular);
    final current = items.where((it) => it.$1 == value).firstOrNull;
    final enabled = onChanged != null && items.isNotEmpty;
    return _TypeSelect(
      labels: [for (final it in items) it.$2],
      current: items.indexWhere((it) => it.$1 == value),
      onPick: enabled ? (i) => onChanged!(items[i].$1) : null,
      child: Builder(
        builder: (anchor) => Pressable(
          onPressed: enabled ? () => _open(anchor) : null,
          focusNode: focusNode,
          focusable: style != PopUpStyle.toolbar,
          tooltip: tooltip,
          semanticLabel: current?.$2 ?? placeholder,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowDown): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp): ActivateIntent(),
          },
          builder: (context, s) {
            final disabled = s.contains(WidgetState.disabled);
            final down = s.contains(WidgetState.pressed);
            final fg = disabled ? c.textTertiary : (current == null ? c.textTertiary : c.text);
            final label = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (current?.$3 case (final icon, final color)) ...[
                  Icon(icon, size: scale.iconSize, color: disabled ? c.textTertiary : color),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    current?.$2 ?? placeholder ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(style == PopUpStyle.form ? scale.fontSize : TypeSize.small, color: fg),
                  ),
                ),
              ],
            );
            final Widget body;
            switch (style) {
              case PopUpStyle.form:
                final fill = down ? pressedFill(context, c.controlBackground) : c.controlBackground;
                body = Container(
                  height: scale.height,
                  padding: const EdgeInsets.only(left: 8, right: 2),
                  decoration: BoxDecoration(
                    color: disabled ? c.controlBackground.withValues(alpha: 0.6) : fill,
                    borderRadius: BorderRadius.circular(Radii.control),
                    border: Border.all(color: c.controlBorder, width: 0.5),
                    boxShadow: disabled ? null : Elevation.control(Theme.of(context).brightness),
                  ),
                  child: Row(
                    mainAxisSize: expand || width != null ? MainAxisSize.max : MainAxisSize.min,
                    children: [
                      expand || width != null ? Expanded(child: label) : Flexible(child: label),
                      const SizedBox(width: 6),
                      _UpDownCapsule(height: scale.height - 4, enabled: !disabled),
                    ],
                  ),
                );
              case PopUpStyle.inline:
              case PopUpStyle.toolbar:
                body = Container(
                  height: scale.height,
                  padding: const EdgeInsets.only(left: 6, right: 3),
                  decoration: BoxDecoration(
                    color: down ? c.pressed : (s.contains(WidgetState.hovered) ? c.hover : null),
                    borderRadius: BorderRadius.circular(Radii.control),
                  ),
                  child: Row(
                    mainAxisSize: expand || width != null ? MainAxisSize.max : MainAxisSize.min,
                    children: [
                      expand || width != null ? Expanded(child: label) : Flexible(child: label),
                      const SizedBox(width: 4),
                      Icon(AppIcons.upDown, size: 11, color: disabled ? c.textTertiary : c.textSecondary),
                    ],
                  ),
                );
            }
            return FocusRing(
              visible: s.contains(WidgetState.focused),
              child: SizedBox(width: width, child: body),
            );
          },
        ),
      ),
    );
  }
}

/// Type-to-select on a closed pop-up, as NSPopUpButton: letters typed in
/// quick succession pick the next item whose label starts with them; the same
/// letter repeated cycles through the items starting with it.
class _TypeSelect extends StatefulWidget {
  const _TypeSelect({required this.labels, required this.current, required this.onPick, required this.child});
  final List<String> labels;
  final int current;
  final ValueChanged<int>? onPick;
  final Widget child;

  @override
  State<_TypeSelect> createState() => _TypeSelectState();
}

class _TypeSelectState extends State<_TypeSelect> {
  String _typed = '';

  /// Forgets the typed prefix after a pause.
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (widget.onPick == null || e is KeyUpEvent) return KeyEventResult.ignored;
    final ch = e.character;
    final keys = HardwareKeyboard.instance;
    if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 0x20 || keys.isMetaPressed || keys.isControlPressed) {
      return KeyEventResult.ignored;
    }
    // Space opens the menu unless it continues a typed prefix.
    if (ch == ' ' && _typed.isEmpty) return KeyEventResult.ignored;
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 1), () => _typed = '');
    _typed += ch.toLowerCase();
    final repeated = _typed.split('').every((x) => x == _typed[0]);
    final prefix = repeated ? _typed[0] : _typed;
    final n = widget.labels.length;
    // A new or repeated letter searches after the current item; a longer
    // prefix may still match the current one.
    final start = widget.current < 0 ? 0 : (repeated ? widget.current + 1 : widget.current);
    for (var i = 0; i < n; i++) {
      final idx = (start + i) % n;
      if (widget.labels[idx].toLowerCase().startsWith(prefix)) {
        if (idx != widget.current) widget.onPick!(idx);
        break;
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: widget.child);
}

/// The accent capsule with ⌃⌄ at the right end of a form pop-up.
class _UpDownCapsule extends StatelessWidget {
  const _UpDownCapsule({required this.height, required this.enabled});
  final double height;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final active = enabled && c.windowActive;
    return Container(
      width: 16,
      height: height,
      decoration: BoxDecoration(
        color: active ? c.accent : null,
        borderRadius: BorderRadius.circular(Radii.small),
      ),
      child: Icon(AppIcons.upDown, size: 11, color: active ? c.onAccent : c.textSecondary),
    );
  }
}

/// The pop-up used in forms: fills its row. Same as [PopUpButton] with
/// `expand: true`.
class SelectField<T> extends PopUpButton<T> {
  const SelectField({super.key, required super.value, required super.items, required super.onChanged, super.small})
    : super(expand: true);
}

// ---------------------------------------------------------------------------
// Scope bar
// ---------------------------------------------------------------------------

/// A recessed toggle (Finder scope bar button): transparent when off, the
/// pressed fill when on. Optional dot and count.
class ToggleButton extends StatelessWidget {
  const ToggleButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onChanged,
    this.dot,
    this.count,
    this.icon,
    this.small = false,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onChanged;
  final Color? dot;
  final int? count;
  final IconData? icon;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Pressable(
      onPressed: onChanged == null ? null : () => onChanged!(!selected),
      toggled: selected,
      semanticLabel: label,
      builder: (context, s) {
        final disabled = s.contains(WidgetState.disabled);
        final fg = disabled ? c.textTertiary : (selected ? c.text : c.textSecondary);
        Color? bg;
        if (selected || s.contains(WidgetState.pressed)) {
          bg = c.pressed;
        } else if (s.contains(WidgetState.hovered)) {
          bg = c.hover;
        }
        return FocusRing(
          visible: s.contains(WidgetState.focused),
          child: Container(
            height: small ? ControlSize.small : ControlSize.regular,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.control)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 5)],
                if (dot != null) ...[
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                ],
                Text(label, style: uiText(TypeSize.small, color: fg, weight: selected ? FontWeight.w500 : null)),
                if (count != null) ...[
                  const SizedBox(width: 5),
                  Text('$count', style: uiText(TypeSize.small, color: c.textTertiary, features: kTabular)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class ScopeItem<T> {
  const ScopeItem(this.value, this.label, {this.dot, this.count, this.icon});
  final T value;
  final String label;
  final Color? dot;
  final int? count;
  final IconData? icon;
}

/// A row of [ToggleButton]s that filter a list (Finder scope bar). Multi
/// select by default; with [multi] false exactly one stays on.
class ScopeBar<T> extends StatelessWidget {
  const ScopeBar({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.multi = true,
    this.small = false,
  });

  final List<ScopeItem<T>> items;
  final Set<T> selected;
  final ValueChanged<Set<T>> onChanged;
  final bool multi;
  final bool small;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 2,
    runSpacing: 2,
    children: [
      for (final it in items)
        ToggleButton(
          label: it.label,
          dot: it.dot,
          count: it.count,
          icon: it.icon,
          small: small,
          selected: selected.contains(it.value),
          onChanged: (on) {
            if (!multi) {
              onChanged({it.value});
            } else {
              onChanged(on ? {...selected, it.value} : ({...selected}..remove(it.value)));
            }
          },
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Slider
// ---------------------------------------------------------------------------

/// NSSlider: 4pt track, white 18pt knob, optional ticks, value on the right.
class MacSlider extends StatelessWidget {
  const MacSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.valueLabel,
    this.width,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;

  /// Current value as text, shown tabular to the right of the track.
  final String? valueLabel;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: c.windowActive ? c.accent : c.textTertiary,
        trackHeight: 4,
        thumbColor: const Color(0xFFFFFFFF),
        overlayShape: SliderComponentShape.noOverlay,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 1.5, pressedElevation: 2),
      ),
      child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
    );
    return SizedBox(
      width: width,
      height: ControlSize.regular,
      child: Row(
        mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
        children: [
          width == null ? SizedBox(width: 160, child: slider) : Expanded(child: slider),
          if (valueLabel != null) ...[
            const SizedBox(width: Gap.sm),
            Text(valueLabel!, style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular)),
          ],
        ],
      ),
    );
  }
}
