import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'badges.dart';
import 'buttons.dart';
import 'control_base.dart';
import 'menus.dart';

const double _kLineHeight = 1.3;

TextStyle _fieldText(DbColors c, {required bool small, required bool mono, bool tabular = false, Color? color}) {
  final size = mono ? (small ? TypeSize.monoSmall : TypeSize.mono) : (small ? TypeSize.caption : TypeSize.body);
  if (mono) {
    return TextStyle(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
      fontSize: size,
      height: _kLineHeight,
      color: color ?? c.text,
      fontFeatures: kTabular,
    );
  }
  return uiText(size, color: color ?? c.text, height: _kLineHeight, features: tabular ? kTabular : null);
}

/// AppKit text field (NSTextField, bezeled): 22pt (small 19), radius 5,
/// content fill, 0.5pt hairline and the focus ring while editing.
///
/// Variants: [mono] for SQL and values, multiline ([maxLines] > 1 or null),
/// a [unit] after the text ("secondi"), a [token] before it ("WHERE" in mono
/// accent), [leading]/[trailing] accessories. A non-null [error] turns the
/// hairline red; a non-empty one also shows it under the field. With
/// [expands] the field fills its parent's height (text from the top), as a
/// text view inside a sheet.
class MacTextField extends StatelessWidget {
  const MacTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.small = false,
    this.mono = false,
    this.tabular = false,
    this.maxLines = 1,
    this.minLines,
    this.obscure = false,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.keyboardType,
    this.inputFormatters,
    this.textInputAction,
    this.textAlign = TextAlign.start,
    this.unit,
    this.token,
    this.leading,
    this.trailing,
    this.error,
    this.width,
    this.autocorrect = false,
    this.expands = false,
    this.color,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final bool small;
  final bool mono;

  /// Fill the parent's (bounded) height; ignores [maxLines] and [minLines].
  final bool expands;

  /// Text color in place of the primary text (a new column in success).
  final Color? color;

  /// Tabular figures (numbers that line up).
  final bool tabular;
  final int? maxLines;
  final int? minLines;
  final bool obscure;
  final bool enabled;
  final bool readOnly;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final TextAlign textAlign;

  /// Unit after the value, in secondary text ("secondi", "righe").
  final String? unit;

  /// Clause keyword inside the field before the text ("WHERE").
  final String? token;
  final Widget? leading;
  final Widget? trailing;
  final String? error;
  final double? width;
  final bool autocorrect;

  bool get _multiline => !obscure && (expands || maxLines == null || maxLines! > 1);

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final style = _fieldText(c, small: small, mono: mono, tabular: tabular, color: enabled ? color : c.textTertiary);
    final h = small ? ControlSize.small : ControlSize.regular;
    final vPad = _multiline ? 4.0 : ((h - style.fontSize! * _kLineHeight) / 2).clamp(1.0, 8.0);
    final hasError = error != null;
    final line = hasError ? c.danger : c.controlBorder;
    final ring = hasError ? c.danger.withValues(alpha: 0.5) : c.focusRing;
    final radius = BorderRadius.circular(Radii.control);

    Widget? prefix = leading;
    if (token != null) {
      prefix = Padding(
        padding: const EdgeInsets.only(left: 6, right: 2),
        child: Text(
          token!,
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontFamilyFallback: kMonoFallback,
            fontSize: TypeSize.monoSmall,
            fontWeight: FontWeight.w600,
            color: c.accent,
          ),
        ),
      );
    }
    Widget? suffix = trailing;
    if (unit != null) {
      suffix = Padding(
        padding: const EdgeInsets.only(right: 6, left: 2),
        child: Text(unit!, style: uiText(small ? TypeSize.caption : TypeSize.small, color: c.textSecondary)),
      );
    }

    Widget field = TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      enabled: enabled,
      readOnly: readOnly,
      obscureText: obscure,
      maxLines: obscure ? 1 : (expands ? null : maxLines),
      minLines: expands ? null : minLines,
      expands: expands && !obscure,
      textAlignVertical: expands ? TextAlignVertical.top : null,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      onTap: onTap,
      keyboardType: keyboardType ?? (_multiline ? TextInputType.multiline : null),
      inputFormatters: inputFormatters,
      textInputAction: textInputAction,
      textAlign: textAlign,
      autocorrect: autocorrect,
      enableSuggestions: autocorrect,
      style: style,
      cursorWidth: 1.5,
      cursorHeight: style.fontSize! * 1.2,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: style.copyWith(color: c.textTertiary),
        isDense: true,
        filled: true,
        fillColor: enabled ? c.content : c.content.withValues(alpha: 0.5),
        hoverColor: const Color(0x00000000),
        contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: vPad),
        prefixIcon: prefix,
        prefixIconConstraints: const BoxConstraints(),
        suffixIcon: suffix,
        suffixIconConstraints: const BoxConstraints(),
        border: MacFieldBorder(color: line, borderRadius: radius),
        enabledBorder: MacFieldBorder(color: line, borderRadius: radius),
        disabledBorder: MacFieldBorder(color: c.controlBorder.withValues(alpha: 0.5), borderRadius: radius),
        focusedBorder: MacFieldBorder(color: line, ring: ring, borderRadius: radius),
      ),
    );
    if (width != null) field = SizedBox(width: width, child: field);
    if (error == null || error!.isEmpty) return field;
    return Column(
      mainAxisSize: expands ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [expands ? Expanded(child: field) : field, FieldMessage(error!, error: true)],
    );
  }
}

/// Help or error text under a field: 11pt, secondary or danger.
class FieldMessage extends StatelessWidget {
  const FieldMessage(this.text, {super.key, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 1),
      child: Text(text, style: uiText(TypeSize.caption, color: error ? c.danger : c.textSecondary, height: 1.3)),
    );
  }
}

/// Password field with an inline eye button that reveals the text.
///
/// Multi-line secrets (a connection string, a JSON key) set [maxLines]: the
/// field stays on one masked line while hidden and grows up to [maxLines]
/// once revealed. With [onChoose] a "Scegli…" push button follows the field
/// (the caller loads the secret from a file).
class SecureField extends StatefulWidget {
  const SecureField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    this.error,
    this.width,
    this.revealable = true,
    this.maxLines = 1,
    this.mono,
    this.onChoose,
    this.chooseLabel = 'Scegli…',
    this.chooseTooltip,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool enabled;
  final String? error;
  final double? width;

  /// Show the eye button.
  final bool revealable;

  /// Lines shown once revealed (the field grows from one line).
  final int maxLines;

  /// Monospaced text; defaults to on for multi-line secrets.
  final bool? mono;

  /// Shows a "Scegli…" button after the field.
  final VoidCallback? onChoose;
  final String chooseLabel;
  final String? chooseTooltip;

  @override
  State<SecureField> createState() => _SecureFieldState();
}

class _SecureFieldState extends State<SecureField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final multiline = widget.maxLines > 1;
    final field = MacTextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      hint: widget.hint,
      obscure: _obscure,
      maxLines: widget.maxLines,
      minLines: multiline ? 1 : null,
      mono: widget.mono ?? multiline,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      error: widget.error,
      width: widget.onChoose == null ? widget.width : null,
      trailing: !widget.revealable
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: 2),
              child: ToolButton(
                icon: _obscure ? AppIcons.eye : AppIcons.eyeOff,
                tooltip: _obscure ? 'Mostra password' : 'Nascondi password',
                extent: 18,
                size: 13,
                onPressed: widget.enabled ? () => setState(() => _obscure = !_obscure) : null,
              ),
            ),
    );
    if (widget.onChoose == null) return field;
    return SizedBox(
      width: widget.width,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: field),
          const SizedBox(width: 6),
          PushButton(
            label: widget.chooseLabel,
            tooltip: widget.chooseTooltip,
            onPressed: widget.enabled ? widget.onChoose : null,
          ),
        ],
      ),
    );
  }
}

/// NSSearchField: rounded, filled, magnifier on the left and a clear ⓧ while
/// it has text. 22pt, or 28pt in the window toolbar.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    this.width,
    this.focusNode,
    this.autofocus = false,
    this.toolbar = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final double? width;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool toolbar;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final h = toolbar ? ControlSize.toolbar : ControlSize.regular;
    final style = uiText(TypeSize.body, color: c.text, height: _kLineHeight);
    final radius = BorderRadius.circular(Radii.menu);
    final none = MacFieldBorder(color: const Color(0x00000000), borderRadius: radius);
    return SizedBox(
      width: width,
      height: h,
      child: ValueListenableBuilder(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          style: style,
          cursorWidth: 1.5,
          cursorHeight: TypeSize.body * 1.2,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: style.copyWith(color: c.textTertiary),
            isDense: true,
            filled: true,
            fillColor: c.hover,
            hoverColor: const Color(0x00000000),
            contentPadding: EdgeInsets.symmetric(vertical: (h - TypeSize.body * _kLineHeight) / 2),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 7, right: 4),
              child: Icon(AppIcons.search, size: 13, color: c.textSecondary),
            ),
            prefixIconConstraints: const BoxConstraints(),
            suffixIcon: value.text.isEmpty
                ? null
                : MouseRegion(
                    cursor: SystemMouseCursors.basic,
                    child: GestureDetector(
                      onTap: () {
                        controller.clear();
                        onChanged?.call('');
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: Icon(AppIcons.clearFill, size: 13, color: c.textTertiary),
                      ),
                    ),
                  ),
            suffixIconConstraints: const BoxConstraints(),
            border: none,
            enabledBorder: none,
            disabledBorder: none,
            focusedBorder: MacFieldBorder(color: const Color(0x00000000), ring: c.focusRing, borderRadius: radius),
          ),
        ),
      ),
    );
  }
}

/// NSComboBox: a text field with an attached ⌄ that lists suggestions. The
/// user can type anything; picking a suggestion replaces the text. ↓ opens
/// the list from the keyboard, narrowed to the suggestions that contain the
/// typed text. With [autocomplete], typing at the end completes inline the
/// first suggestion that starts with the text, the added part selected.
///
/// Menu rows can carry a secondary [optionDetail] on the right ("più
/// veloce") and an [optionIcon]; [actions] are commands listed after a
/// divider ("Installa driver…"). [onChanged] runs for typing and picking,
/// [onSelected] only for a suggestion chosen from the menu.
class ComboField extends StatefulWidget {
  const ComboField({
    super.key,
    required this.controller,
    required this.options,
    this.hint,
    this.onChanged,
    this.onSelected,
    this.mono = false,
    this.small = false,
    this.enabled = true,
    this.width,
    this.focusNode,
    this.error,
    this.autocomplete = true,
    this.leading,
    this.optionDetail,
    this.optionIcon,
    this.actions = const [],
  });

  final TextEditingController controller;

  /// Suggestions, or a function evaluated when the list opens.
  final List<String> Function() options;
  final bool autocomplete;
  final String? hint;
  final ValueChanged<String>? onChanged;

  /// A suggestion was chosen from the menu (after [onChanged]).
  final ValueChanged<String>? onSelected;
  final bool mono;
  final bool small;
  final bool enabled;
  final double? width;
  final FocusNode? focusNode;
  final String? error;

  /// Inside the field before the text, typically a 16pt icon (the driver's).
  final Widget? leading;

  /// Secondary text on the right of a suggestion's menu row.
  final String? Function(String option)? optionDetail;

  /// Icon (and its color) of a suggestion's menu row; the ✓ of the current
  /// suggestion takes its place.
  final (IconData, Color?)? Function(String option)? optionIcon;

  /// Commands after the suggestions, separated by a divider. They act through
  /// [MenuEntry.onSelected]; an action with a value fills the field like a
  /// suggestion.
  final List<MenuEntry<String>> actions;

  @override
  State<ComboField> createState() => _ComboFieldState();
}

class _ComboFieldState extends State<ComboField> {
  final _key = GlobalKey();

  /// What the user typed, without the inline completion.
  String _last = '';

  @override
  void initState() {
    super.initState();
    _last = widget.controller.text;
  }

  /// Completes [text] inline when it grew by typing at its end. Deleting
  /// (including the selected completion) never completes.
  void _changed(String text) {
    final sel = widget.controller.selection;
    final typedAtEnd = text.length > _last.length && sel.isCollapsed && sel.baseOffset == text.length;
    _last = text;
    if (widget.autocomplete && typedAtEnd) {
      final lower = text.toLowerCase();
      final match = widget
          .options()
          .where((o) => o.length > text.length && o.toLowerCase().startsWith(lower))
          .firstOrNull;
      if (match != null) {
        final full = text + match.substring(text.length);
        widget.controller.value = TextEditingValue(
          text: full,
          selection: TextSelection(baseOffset: text.length, extentOffset: full.length),
        );
        text = full;
      }
    }
    widget.onChanged?.call(text);
  }

  MenuEntry<String> _entry(String o) {
    final icon = widget.optionIcon?.call(o);
    final detail = widget.optionDetail?.call(o);
    return MenuEntry<String>(
      o,
      value: o,
      checked: o == widget.controller.text,
      leading: icon == null ? null : Icon(icon.$1, size: 13, color: icon.$2),
      trailing: detail == null ? null : _MenuDetail(detail),
    );
  }

  Future<void> _open() async {
    final ctx = _key.currentContext;
    final all = widget.options();
    final typed = widget.controller.text.trim().toLowerCase();
    final narrowed = typed.isEmpty || all.contains(widget.controller.text)
        ? all
        : all.where((o) => o.toLowerCase().contains(typed)).toList();
    final options = narrowed.isEmpty ? all : narrowed;
    final actions = widget.actions;
    if (ctx == null || (options.isEmpty && actions.isEmpty)) return;
    final rect = anchorRect(ctx);
    final v = await showMacMenu<String>(
      context,
      anchor: rect,
      minWidth: rect.width,
      entries: [
        for (final o in options) _entry(o),
        if (options.isNotEmpty && actions.isNotEmpty) const MenuEntry.divider(),
        ...actions,
      ],
    );
    if (v == null || !mounted) return;
    widget.controller.value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
    _last = v;
    widget.onChanged?.call(v);
    widget.onSelected?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final h = (widget.small ? ControlSize.small : ControlSize.regular) - 4;
    return KeyedSubtree(
      key: _key,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.arrowDown): _open},
        child: MacTextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          hint: widget.hint,
          onChanged: _changed,
          mono: widget.mono,
          small: widget.small,
          enabled: widget.enabled,
          width: widget.width,
          error: widget.error,
          leading: widget.leading == null
              ? null
              : Padding(padding: const EdgeInsets.only(left: 5), child: widget.leading),
          trailing: Pressable(
            onPressed: widget.enabled ? _open : null,
            focusable: false,
            semanticLabel: 'Suggerimenti',
            builder: (context, s) => Container(
              width: 17,
              height: h,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                color: s.contains(WidgetState.pressed)
                    ? c.pressed
                    : (s.contains(WidgetState.hovered) ? c.hover : null),
                borderRadius: BorderRadius.circular(Radii.small),
                border: Border(left: BorderSide(color: c.separator, width: 0.5)),
              ),
              child: Icon(AppIcons.chevronDown, size: 9, color: widget.enabled ? c.textSecondary : c.textTertiary),
            ),
          ),
        ),
      ),
    );
  }
}

/// Secondary text on the right of a menu row; white on the highlighted row.
class _MenuDetail extends StatelessWidget {
  const _MenuDetail(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Text(
      text,
      maxLines: 1,
      style: uiText(TypeSize.body, color: RowTint.emphasizedOf(context) ? c.onAccent : c.textSecondary),
    );
  }
}

/// A path plus a "Scegli…" push button. Editable when given a [controller],
/// otherwise a read-only [path] in a field-like box.
class PathField extends StatelessWidget {
  const PathField({
    super.key,
    this.controller,
    this.path,
    required this.onChoose,
    this.chooseLabel = 'Scegli…',
    this.hint,
    this.mono = false,
    this.onChanged,
    this.enabled = true,
    this.error,
  });

  final TextEditingController? controller;
  final String? path;
  final VoidCallback? onChoose;
  final String chooseLabel;
  final String? hint;
  final bool mono;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final Widget field;
    if (controller != null) {
      field = MacTextField(
        controller: controller,
        hint: hint,
        mono: mono,
        onChanged: onChanged,
        enabled: enabled,
        error: error,
      );
    } else {
      final empty = path == null || path!.isEmpty;
      field = Container(
        height: ControlSize.regular,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        decoration: ShapeDecoration(
          color: c.content.withValues(alpha: 0.5),
          shape: MacFieldBorder(color: c.controlBorder),
        ),
        child: Tooltip(
          message: empty ? '' : path!,
          child: Text(
            empty ? (hint ?? 'Nessun file') : path!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _fieldText(c, small: false, mono: mono, color: empty ? c.textTertiary : c.textSecondary),
          ),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: field),
        const SizedBox(width: 6),
        PushButton(label: chooseLabel, onPressed: enabled ? onChoose : null),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

/// NSStepper: 13×22 up/down arrows. Holding an arrow repeats.
class MacStepper extends StatelessWidget {
  const MacStepper({super.key, required this.onUp, required this.onDown, this.small = false});

  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final h = small ? ControlSize.small : ControlSize.regular;
    return Container(
      width: 13,
      height: h,
      decoration: BoxDecoration(
        color: c.controlBackground,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: c.controlBorder, width: 0.5),
        boxShadow: Elevation.control(Theme.of(context).brightness),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.control),
        child: Column(
          children: [
            Expanded(child: _StepperHalf(up: true, onStep: onUp)),
            Expanded(child: _StepperHalf(up: false, onStep: onDown)),
          ],
        ),
      ),
    );
  }
}

class _StepperHalf extends StatefulWidget {
  const _StepperHalf({required this.up, required this.onStep});
  final bool up;
  final VoidCallback? onStep;

  @override
  State<_StepperHalf> createState() => _StepperHalfState();
}

class _StepperHalfState extends State<_StepperHalf> {
  bool _down = false;
  Timer? _repeat;

  void _start() {
    widget.onStep?.call();
    setState(() => _down = true);
    _repeat = Timer(const Duration(milliseconds: 400), () {
      _repeat = Timer.periodic(const Duration(milliseconds: 70), (_) => widget.onStep?.call());
    });
  }

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
    if (mounted) setState(() => _down = false);
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final enabled = widget.onStep != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _start() : null,
      onTapUp: enabled ? (_) => _stop() : null,
      onTapCancel: _stop,
      child: Container(
        color: _down ? c.pressed : null,
        alignment: widget.up ? const Alignment(0, 0.4) : const Alignment(0, -0.4),
        child: CustomPaint(
          size: const Size(7, 4),
          painter: _TrianglePainter(enabled ? c.text : c.textTertiary, up: widget.up),
        ),
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter(this.color, {required this.up});
  final Color color;
  final bool up;

  @override
  void paint(Canvas canvas, Size s) {
    final path = up
        ? (Path()
            ..moveTo(0, s.height)
            ..lineTo(s.width / 2, 0)
            ..lineTo(s.width, s.height))
        : (Path()
            ..moveTo(0, 0)
            ..lineTo(s.width / 2, s.height)
            ..lineTo(s.width, 0));
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.color != color || old.up != up;
}

/// Numeric field: right-aligned tabular text and a [MacStepper]. ↑/↓ and the
/// scroll wheel (while focused) step by [step] within [min]…[max]; a typed
/// value outside the range is brought back into it when the field loses focus.
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.controller,
    this.min,
    this.max,
    this.step = 1,
    this.decimals = 0,
    this.unit,
    this.hint,
    this.onChanged,
    this.width = 90,
    this.focusNode,
    this.enabled = true,
    this.stepper = true,
    this.small = false,
    this.error,
  });

  final TextEditingController controller;
  final num? min;
  final num? max;
  final num step;
  final int decimals;
  final String? unit;
  final String? hint;
  final ValueChanged<String>? onChanged;

  /// Width of the field without the stepper.
  final double? width;
  final FocusNode? focusNode;
  final bool enabled;
  final bool stepper;
  final bool small;
  final String? error;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(NumberField old) {
    super.didUpdateWidget(old);
    final was = old.focusNode ?? _own;
    if (was != _focus) {
      was?.removeListener(_focusChanged);
      _focus.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _own?.dispose();
    super.dispose();
  }

  num? get _current => num.tryParse(widget.controller.text.trim().replaceAll(',', '.'));

  num _clamp(num v) {
    if (widget.min != null && v < widget.min!) return widget.min!;
    if (widget.max != null && v > widget.max!) return widget.max!;
    return v;
  }

  void _write(num v) {
    final text = widget.decimals == 0 ? v.round().toString() : v.toStringAsFixed(widget.decimals);
    widget.controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    widget.onChanged?.call(text);
  }

  void _focusChanged() {
    if (_focus.hasFocus) return;
    final cur = _current;
    if (cur != null && _clamp(cur) != cur) _write(_clamp(cur));
  }

  void _step(int dir) {
    if (!widget.enabled) return;
    final cur = _current;
    _write(_clamp(cur == null ? (widget.min ?? 0) : cur + dir * widget.step));
  }

  @override
  Widget build(BuildContext context) {
    final negative = widget.min == null || widget.min! < 0;
    final allowed = '0-9${widget.decimals > 0 ? '.,' : ''}${negative ? '\\-' : ''}';
    final field = Listener(
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent || !_focus.hasFocus || e.scrollDelta.dy == 0) return;
        GestureBinding.instance.pointerSignalResolver.register(e, (e) {
          _step((e as PointerScrollEvent).scrollDelta.dy < 0 ? 1 : -1);
        });
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _step(-1),
        },
        child: MacTextField(
          controller: widget.controller,
          focusNode: _focus,
          hint: widget.hint,
          small: widget.small,
          tabular: true,
          textAlign: TextAlign.right,
          enabled: widget.enabled,
          unit: widget.unit,
          error: widget.error,
          onChanged: widget.onChanged,
          keyboardType: TextInputType.numberWithOptions(decimal: widget.decimals > 0, signed: negative),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[$allowed]'))],
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.width == null ? Flexible(child: field) : SizedBox(width: widget.width, child: field),
        if (widget.stepper) ...[
          const SizedBox(width: 3),
          MacStepper(
            small: widget.small,
            onUp: widget.enabled ? () => _step(1) : null,
            onDown: widget.enabled ? () => _step(-1) : null,
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Date
// ---------------------------------------------------------------------------

const _kMonths = [
  'gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno',
  'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre',
];

int _daysIn(int year, int month) => DateTime(year, month + 1, 0).day;

/// NSDatePicker (text field with stepper style): day, month and year are
/// separate segments, plus hours and minutes with [time]. Click or ←/→
/// select a segment, digits type it, ↑/↓ change it. The calendar button opens
/// a mini calendar in a popover (it keeps the time). With [clearable], ⌫ or
/// Canc with nothing typed empties the date (`null`).
class DateField extends StatefulWidget {
  const DateField({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.focusNode,
    this.clearable = true,
    this.time = false,
  });

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool enabled;
  final FocusNode? focusNode;
  final bool clearable;

  /// Date and time (hh:mm, seconds kept from [value]) for timestamps.
  final bool time;

  @override
  State<DateField> createState() => _DateFieldState();
}

class _DateFieldState extends State<DateField> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'DateField'));
  int _seg = 0;
  String _typed = '';

  int get _lastSeg => widget.time ? 4 : 2;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _own?.dispose();
    super.dispose();
  }

  void _focusChanged() => setState(() => _typed = '');

  DateTime get _base {
    final now = DateTime.now();
    return widget.value ?? DateTime(now.year, now.month, now.day);
  }

  void _set({int? day, int? month, int? year, int? hour, int? minute}) {
    final b = _base;
    final y = year ?? b.year;
    final m = month ?? b.month;
    final d = (day ?? b.day).clamp(1, _daysIn(y, m));
    widget.onChanged(
      widget.time ? DateTime(y, m, d, hour ?? b.hour, minute ?? b.minute, b.second) : DateTime(y, m, d),
    );
  }

  void _adjust(int delta) {
    final b = _base;
    switch (_seg) {
      case 0:
        final n = _daysIn(b.year, b.month);
        _set(day: (b.day - 1 + delta) % n + 1);
      case 1:
        _set(month: (b.month - 1 + delta) % 12 + 1);
      case 2:
        _set(year: (b.year + delta).clamp(1, 9999));
      case 3:
        _set(hour: (b.hour + delta) % 24);
      default:
        _set(minute: (b.minute + delta) % 60);
    }
  }

  void _type(String digit) {
    _typed += digit;
    final v = int.parse(_typed);
    switch (_seg) {
      case 0:
        if (v > 0) _set(day: v.clamp(1, 31));
        if (_typed.length == 2 || v > 3) _advance();
      case 1:
        if (v > 0) _set(month: v.clamp(1, 12));
        if (_typed.length == 2 || v > 1) _advance();
      case 2:
        if (_typed.length == 4) {
          _set(year: v.clamp(1, 9999));
          _advance();
        }
      case 3:
        _set(hour: v.clamp(0, 23));
        if (_typed.length == 2 || v > 2) _advance();
      default:
        _set(minute: v.clamp(0, 59));
        if (_typed.length == 2 || v > 5) _typed = '';
    }
    setState(() {});
  }

  void _advance() {
    _typed = '';
    if (_seg < _lastSeg) _seg++;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp) {
      _typed = '';
      _adjust(1);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _typed = '';
      _adjust(-1);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      setState(() {
        _typed = '';
        _seg = (_seg - 1).clamp(0, _lastSeg);
      });
    } else if (k == LogicalKeyboardKey.arrowRight) {
      setState(() {
        _typed = '';
        _seg = (_seg + 1).clamp(0, _lastSeg);
      });
    } else if ((k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete) && _typed.isEmpty) {
      if (!widget.clearable || widget.value == null) return KeyEventResult.ignored;
      setState(() => _seg = 0);
      widget.onChanged(null);
    } else if (k == LogicalKeyboardKey.backspace) {
      setState(() => _typed = _typed.substring(0, _typed.length - 1));
    } else if (e.character case final ch? when RegExp(r'^\d$').hasMatch(ch)) {
      _type(ch);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _openCalendar(BuildContext anchor) async {
    final picked = await showPopover<DateTime>(
      context,
      anchor: anchorRect(anchor),
      padding: const EdgeInsets.all(Gap.sm),
      builder: (ctx) => MiniCalendar(selected: widget.value, onPick: (d) => Navigator.of(ctx).pop(d)),
    );
    if (picked == null) return;
    final b = _base;
    widget.onChanged(
      widget.time ? DateTime(picked.year, picked.month, picked.day, b.hour, b.minute, b.second) : picked,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final focused = _focus.hasFocus;
    final v = widget.value;
    final style = uiText(TypeSize.body, color: widget.enabled ? c.text : c.textTertiary, features: kTabular, height: 1);
    String two(int n) => n.toString().padLeft(2, '0');
    Widget seg(int i, String text, String placeholder) {
      final on = focused && _seg == i;
      final shown = on && _typed.isNotEmpty ? _typed : (v == null ? placeholder : text);
      return GestureDetector(
        onTapDown: widget.enabled
            ? (_) {
                _focus.requestFocus();
                setState(() {
                  _seg = i;
                  _typed = '';
                });
              }
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 1.5, vertical: 1),
          decoration: BoxDecoration(
            color: on ? c.selectionEmphasized : null,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            shown,
            style: style.copyWith(
              color: on ? c.onSelectionEmphasized : (v == null ? c.textTertiary : null),
            ),
          ),
        ),
      );
    }

    Text sep(String s) => Text(s, style: style.copyWith(color: c.textTertiary));
    return Focus(
      focusNode: _focus,
      canRequestFocus: widget.enabled,
      onKeyEvent: _onKey,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: ControlSize.regular,
            padding: const EdgeInsets.symmetric(horizontal: 4.5),
            decoration: ShapeDecoration(
              color: widget.enabled ? c.content : c.content.withValues(alpha: 0.5),
              shape: MacFieldBorder(color: c.controlBorder, ring: focused ? c.focusRing : null),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                seg(0, v == null ? '' : two(v.day), 'gg'),
                sep('/'),
                seg(1, v == null ? '' : two(v.month), 'mm'),
                sep('/'),
                seg(2, v == null ? '' : v.year.toString().padLeft(4, '0'), 'aaaa'),
                if (widget.time) ...[
                  const SizedBox(width: 5),
                  seg(3, v == null ? '' : two(v.hour), 'hh'),
                  sep(':'),
                  seg(4, v == null ? '' : two(v.minute), 'mm'),
                ],
              ],
            ),
          ),
          const SizedBox(width: 3),
          Builder(
            builder: (anchor) => ToolButton(
              icon: AppIcons.calendar,
              tooltip: 'Calendario',
              extent: ControlSize.regular,
              size: 14,
              onPressed: widget.enabled ? () => _openCalendar(anchor) : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Month grid used by [DateField]: Monday first, today in accent, the
/// selected day in an accent circle.
class MiniCalendar extends StatefulWidget {
  const MiniCalendar({super.key, required this.selected, required this.onPick});

  final DateTime? selected;
  final ValueChanged<DateTime> onPick;

  @override
  State<MiniCalendar> createState() => _MiniCalendarState();
}

class _MiniCalendarState extends State<MiniCalendar> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final d = widget.selected ?? DateTime.now();
    _month = DateTime(d.year, d.month);
  }

  void _shift(int months) => setState(() => _month = DateTime(_month.year, _month.month + months));

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final now = DateTime.now();
    final first = DateTime(_month.year, _month.month);
    final start = first.subtract(Duration(days: first.weekday - 1));
    const cell = 24.0;
    bool same(DateTime a, DateTime? b) => b != null && a.year == b.year && a.month == b.month && a.day == b.day;
    return SizedBox(
      width: cell * 7,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    '${_kMonths[_month.month - 1]} ${_month.year}',
                    style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text),
                  ),
                ),
              ),
              ToolButton(icon: AppIcons.chevronLeft, tooltip: 'Mese precedente', extent: 20, size: 12, onPressed: () => _shift(-1)),
              ToolButton(icon: AppIcons.chevronRight, tooltip: 'Mese successivo', extent: 20, size: 12, onPressed: () => _shift(1)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final d in const ['L', 'M', 'M', 'G', 'V', 'S', 'D'])
                SizedBox(
                  width: cell,
                  child: Text(d, textAlign: TextAlign.center, style: uiText(TypeSize.mini, weight: FontWeight.w600, color: c.textSecondary)),
                ),
            ],
          ),
          for (var w = 0; w < 6; w++)
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Builder(
                    builder: (context) {
                      final d = DateTime(start.year, start.month, start.day + w * 7 + i);
                      final inMonth = d.month == _month.month;
                      final sel = same(d, widget.selected);
                      final today = same(d, now);
                      return GestureDetector(
                        onTap: () => widget.onPick(d),
                        child: SizedBox(
                          width: cell,
                          height: 22,
                          child: Center(
                            child: Container(
                              width: 20,
                              height: 20,
                              alignment: Alignment.center,
                              decoration: sel ? BoxDecoration(color: c.selectionEmphasized, shape: BoxShape.circle) : null,
                              child: Text(
                                '${d.day}',
                                style: uiText(
                                  TypeSize.small,
                                  features: kTabular,
                                  weight: today ? FontWeight.w600 : null,
                                  color: sel
                                      ? c.onSelectionEmphasized
                                      : today
                                      ? c.accent
                                      : (inMonth ? c.text : c.textTertiary),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

/// A filter or value token (NSTokenField): 19pt capsule tinted with the
/// accent, ⓧ on the right to remove it.
class FilterToken extends StatelessWidget {
  const FilterToken({super.key, required this.label, this.onRemove, this.onTap, this.mono = false, this.tooltip});

  final String label;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;
  final bool mono;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final text = mono
        ? TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: TypeSize.monoSmall, color: c.text)
        : uiText(TypeSize.small, color: c.text);
    return Pressable(
      onPressed: onTap,
      focusable: onTap != null,
      tooltip: tooltip,
      semanticLabel: label,
      builder: (context, s) => FocusRing(
        visible: s.contains(WidgetState.focused),
        radius: ControlSize.small / 2,
        child: Container(
          height: ControlSize.small,
          padding: EdgeInsets.only(left: 8, right: onRemove == null ? 8 : 3),
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: s.contains(WidgetState.pressed) ? Tint.strong : Tint.regular),
            borderRadius: BorderRadius.circular(ControlSize.small / 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text)),
              if (onRemove != null) ...[
                const SizedBox(width: 3),
                Pressable(
                  onPressed: onRemove,
                  focusable: false,
                  tooltip: 'Rimuovi',
                  builder: (context, rs) => Icon(
                    AppIcons.clearFill,
                    size: 13,
                    color: c.accent.withValues(alpha: rs.contains(WidgetState.hovered) ? 0.9 : 0.55),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Tokens in a wrapping row, optionally joined by a word ("e") and followed
/// by an accessory (the "+" that adds one).
class TokenField extends StatelessWidget {
  const TokenField({super.key, required this.tokens, this.joiner, this.trailing});

  final List<Widget> tokens;
  final String? joiner;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < tokens.length; i++) ...[
          if (i > 0 && joiner != null) Text(joiner!, style: uiText(TypeSize.caption, color: c.textTertiary)),
          tokens[i],
        ],
        ?trailing,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Grid cell editor
// ---------------------------------------------------------------------------

/// Border of an editor inside a grid cell: no outline, an inner 1.5pt focus
/// ring while editing (the cell sits edge to edge with its neighbours).
class CellFieldBorder extends InputBorder {
  const CellFieldBorder({this.ring}) : super(borderSide: BorderSide.none);

  final Color? ring;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  bool get isOutline => false;

  @override
  CellFieldBorder copyWith({BorderSide? borderSide}) => CellFieldBorder(ring: ring);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => Path()..addRect(rect);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Path()..addRect(rect);

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (ring == null) return;
    canvas.drawRect(
      rect.deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = ring!,
    );
  }

  @override
  CellFieldBorder scale(double t) => this;

  @override
  bool operator ==(Object other) => other is CellFieldBorder && other.ring == ring;

  @override
  int get hashCode => ring.hashCode;
}

/// Decoration for a grid cell editor: content fill, inner focus ring.
InputDecoration cellEditorDecoration(BuildContext context, {EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 4)}) {
  final c = DbColors.of(context);
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: c.content,
    hoverColor: const Color(0x00000000),
    contentPadding: padding,
    border: const CellFieldBorder(),
    enabledBorder: const CellFieldBorder(),
    focusedBorder: CellFieldBorder(ring: c.focusRing),
  );
}
