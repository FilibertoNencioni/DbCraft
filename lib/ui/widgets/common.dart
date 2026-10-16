import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../odbc/odbc_types.dart';
import '../theme/app_theme.dart';

export '../theme/app_theme.dart';

const kMono = kMonoFamily;

TextStyle monoStyle(BuildContext context, {double size = 13, Color? color}) => TextStyle(
  fontFamily: kMonoFamily,
  fontFamilyFallback: kMonoFallback,
  fontSize: size,
  color: color ?? DbColors.of(context).text,
  height: 1.35,
  fontFeatures: kTabular,
);

/// Hover-tinted, ripple-free button used in toolbars (macOS style).
class ToolButton extends StatefulWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
    this.active = false,
    this.size = 17,
    this.extent = 28,
    this.label,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final bool active;
  final double size;

  /// Height and minimum width of the hit area: 28 for controls, 32 for the
  /// unified window toolbar.
  final double extent;

  /// Optional text shown next to the icon.
  final String? label;

  @override
  State<ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<ToolButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final enabled = widget.onPressed != null;
    final fg = !enabled ? c.textTertiary : (widget.active ? c.accent : (widget.color ?? c.textSecondary));
    Color bg = Colors.transparent;
    if (enabled && _down) {
      bg = c.pressed;
    } else if (widget.active) {
      bg = c.accent.withValues(alpha: 0.12);
    } else if (enabled && _hover) {
      bg = c.hover;
    }
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(widget.icon, size: widget.size, color: fg),
        if (widget.label != null) ...[
          const SizedBox(width: 5),
          Text(
            widget.label!,
            style: TextStyle(fontSize: TypeSize.small + 0.5, fontWeight: FontWeight.w500, color: fg),
          ),
        ],
      ],
    );
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.basic : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _down = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onPressed,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: widget.tooltip,
            child: Container(
              height: widget.extent,
              constraints: BoxConstraints(minWidth: widget.extent),
              padding: EdgeInsets.symmetric(horizontal: widget.label == null ? 4 : 8),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.control)),
              // Shrink-wrap the content: an aligned Container would fill bounded parents.
              child: Center(widthFactor: 1, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class ToolSeparator extends StatelessWidget {
  const ToolSeparator({super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 16,
    margin: const EdgeInsets.symmetric(horizontal: 6),
    color: DbColors.of(context).separator,
  );
}

/// Primary action with press feedback (scale 0.97, 120ms ease-out).
class PrimaryButton extends StatefulWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.tooltip, this.color});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final enabled = widget.onPressed != null;
    final color = widget.color ?? c.accent;
    final btn = AnimatedScale(
      scale: _down ? 0.97 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onPressed,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: enabled ? color : c.pressed,
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 15, color: enabled ? Colors.white : c.textTertiary),
                const SizedBox(width: 5),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: TypeSize.body,
                  fontWeight: FontWeight.w600,
                  color: enabled ? Colors.white : c.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return widget.tooltip == null ? btn : Tooltip(message: widget.tooltip!, child: btn);
  }
}

/// Small uppercase-free section label (macOS sidebar group title).
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.padding});
  final String text;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.sm, Gap.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: TypeSize.caption, fontWeight: FontWeight.w600, color: c.textSecondary),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Kept for compatibility: a light header row with optional actions.
class PanelHeader extends StatelessWidget {
  const PanelHeader({super.key, required this.title, this.icon, this.actions = const []});
  final String title;
  final IconData? icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => SectionLabel(
    title,
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 2),
    trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
  );
}

/// Height of a source-list row (macOS medium sidebar size).
const double kSidebarRowHeight = 28;

/// Source-list row: icon, single-line title, optional trailing detail.
///
/// The hover and selection tint is the row itself, so it always covers exactly
/// what the row shows. Row actions live in [onMenu] (right click, or the "…"
/// button that appears on hover), never in permanent per-row buttons.
class SidebarRow extends StatefulWidget {
  const SidebarRow({
    super.key,
    required this.icon,
    required this.title,
    this.iconColor,
    this.detail,
    this.selected = false,
    this.onTap,
    this.onMenu,
    this.tooltip,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;

  /// Short secondary text right-aligned in the row (date, count).
  final String? detail;
  final bool selected;
  final VoidCallback? onTap;

  /// Opens the row's context menu at a global position.
  final void Function(Offset globalPosition)? onMenu;
  final String? tooltip;

  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  bool _hover = false;
  final _menuKey = GlobalKey();

  void _openMenuFromButton() {
    final box = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    widget.onMenu!(box.localToGlobal(Offset(0, box.size.height + 2)));
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final showMenuButton = widget.onMenu != null && _hover;
    final row = Container(
      height: kSidebarRowHeight,
      padding: const EdgeInsets.only(left: Gap.sm, right: Gap.xs),
      decoration: BoxDecoration(
        color: widget.selected ? c.selectionMuted : (_hover ? c.hover : Colors.transparent),
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Row(
        children: [
          Icon(widget.icon, size: 17, color: widget.iconColor ?? c.textSecondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: TypeSize.body, color: c.text),
            ),
          ),
          if (showMenuButton)
            SizedBox(
              key: _menuKey,
              child: ToolButton(
                icon: AppIcons.more,
                tooltip: 'Azioni',
                extent: 22,
                size: 16,
                onPressed: _openMenuFromButton,
              ),
            )
          else if (widget.detail != null)
            Padding(
              padding: const EdgeInsets.only(left: Gap.sm, right: Gap.xs),
              child: Text(
                widget.detail!,
                style: TextStyle(fontSize: TypeSize.small, color: c.textTertiary, fontFeatures: kTabular),
              ),
            ),
        ],
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapDown: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
        child: widget.tooltip == null
            ? row
            : Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 1000), child: row),
      ),
    );
  }
}

/// Navigator selector at the top of the sidebar (Xcode style): plain icons,
/// the selected one tinted with the accent. No pill, no background.
class SidebarTabs<T> extends StatelessWidget {
  const SidebarTabs({super.key, required this.value, required this.items, required this.onChanged});

  final T value;
  final List<(T, String, IconData)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.separator))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final (v, label, icon) in items)
            ToolButton(
              icon: icon,
              tooltip: label,
              size: 18,
              extent: 30,
              color: v == value ? c.accent : c.textSecondary,
              onPressed: () => onChanged(v),
            ),
        ],
      ),
    );
  }
}

/// Rounded, filled search field (NSSearchField look).
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.width,
    this.focusNode,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final double? width;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final radius = BorderRadius.circular(Radii.control);
    return SizedBox(
      width: width,
      height: 28,
      child: ValueListenableBuilder(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          style: const TextStyle(fontSize: TypeSize.body),
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: c.hover,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            prefixIcon: Icon(AppIcons.search, size: 15, color: c.textTertiary),
            prefixIconConstraints: const BoxConstraints(minWidth: 28),
            suffixIcon: value.text.isEmpty
                ? null
                : GestureDetector(
                    onTap: () {
                      controller.clear();
                      onChanged?.call('');
                    },
                    child: Icon(AppIcons.clearFill, size: 14, color: c.textTertiary),
                  ),
            suffixIconConstraints: const BoxConstraints(minWidth: 26),
            border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
              borderRadius: radius,
              borderSide: BorderSide(color: c.accent.withValues(alpha: 0.6), width: 2),
            ),
          ),
        ),
      ),
    );
  }
}

/// macOS style segmented control.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.expand = false,
    this.dot,
    this.iconOnly = false,
  });

  final T value;
  final List<(T, String, IconData?)> items;
  final ValueChanged<T> onChanged;
  final bool expand;

  /// Show only the icons; labels become tooltips (narrow places).
  final bool iconOnly;

  /// Optional colored dot before a segment's label (null = no dot).
  final Color? Function(T value)? dot;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget seg((T, String, IconData?) it) {
      final selected = it.$1 == value;
      final child = GestureDetector(
        onTap: () => onChanged(it.$1),
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? (dark ? const Color(0xFF5A5A5F) : Colors.white) : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            boxShadow: selected && !dark
                ? const [BoxShadow(color: Color(0x26000000), blurRadius: 2, offset: Offset(0, 1))]
                : null,
          ),
          child: iconOnly && it.$3 != null
              ? Icon(it.$3, size: 15, color: selected ? c.text : c.textSecondary)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (it.$3 != null) ...[
                      Icon(it.$3, size: 14, color: selected ? c.text : c.textSecondary),
                      const SizedBox(width: 5),
                    ],
                    if (dot?.call(it.$1) case final Color d) ...[StatusDot(d, size: 7), const SizedBox(width: 6)],
                    Text(
                      it.$2,
                      style: TextStyle(
                        fontSize: TypeSize.small + 0.5,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        color: selected ? c.text : c.textSecondary,
                      ),
                    ),
                  ],
                ),
        ),
      );
      final w = iconOnly
          ? Tooltip(message: it.$2, waitDuration: const Duration(milliseconds: 500), child: child)
          : child;
      return expand ? Expanded(child: w) : w;
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: c.pressed, borderRadius: BorderRadius.circular(Radii.control + 1)),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [for (final it in items) seg(it)],
      ),
    );
  }
}

/// Colored dot (connection environment / status).
class StatusDot extends StatelessWidget {
  const StatusDot(this.color, {super.key, this.size = 8, this.ring = false});
  final Color color;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: ring ? Colors.transparent : color,
      shape: BoxShape.circle,
      border: ring ? Border.all(color: color, width: 1.5) : null,
    ),
  );
}

/// Small rounded count / tag badge.
class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.color, this.filled = false});
  final String text;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final col = color ?? c.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: filled ? col : col.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: TypeSize.caption,
          fontWeight: FontWeight.w600,
          color: filled ? Colors.white : col,
          fontFeatures: kTabular,
        ),
      ),
    );
  }
}

/// Teaching empty state.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: c.textTertiary),
              const SizedBox(height: Gap.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: TypeSize.title - 1, fontWeight: FontWeight.w600, color: c.text),
              ),
              if (message != null) ...[
                const SizedBox(height: Gap.xs),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary, height: 1.4),
                ),
              ],
              if (action != null) ...[const SizedBox(height: Gap.lg), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline notice above or between form groups: a problem the user can act on
/// without leaving the sheet. Tinted with [color] (warning or danger).
class InlineNotice extends StatelessWidget {
  const InlineNotice({
    super.key,
    required this.color,
    required this.title,
    this.icon = AppIcons.warning,
    this.message,
    this.child,
    this.action,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String? message;

  /// Extra content under the message (e.g. a command to copy).
  final Widget? child;

  /// Trailing button, aligned with the title.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.lg),
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm + 2, Gap.sm, Gap.sm + 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.panel + 2),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.text),
                ),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary, height: 1.35),
                  ),
                ],
                if (child != null) ...[const SizedBox(height: Gap.sm), child!],
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: Gap.sm), action!],
        ],
      ),
    );
  }
}

/// Grouped settings box (macOS System Settings form section).
class FormGroup extends StatelessWidget {
  const FormGroup({super.key, this.title, required this.children, this.footer});
  final String? title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 6),
              child: Text(
                title!,
                style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.text),
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: c.chrome,
              borderRadius: BorderRadius.circular(Radii.panel + 2),
              border: Border.all(color: c.separator),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, indent: Gap.md, color: c.separator),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                    child: children[i],
                  ),
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 6),
              child: Text(
                footer!,
                style: TextStyle(fontSize: TypeSize.caption + 0.5, color: c.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

/// Label on the left, control on the right (inside a [FormGroup]).
class FormRow extends StatelessWidget {
  const FormRow({super.key, required this.label, required this.child, this.help, this.labelWidth = 150});
  final String label;
  final Widget child;
  final String? help;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: labelWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: TypeSize.body, color: c.text),
              ),
              if (help != null)
                Text(
                  help!,
                  style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary),
                ),
            ],
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(child: child),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String message, {
  String ok = 'OK',
  String cancel = 'Annulla',
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = DbColors.of(ctx);
      return AlertDialog(
        icon: Icon(
          destructive ? AppIcons.warning : AppIcons.help,
          size: 32,
          color: destructive ? c.danger : c.accent,
        ),
        title: Text(title, textAlign: TextAlign.center),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 360),
          child: SingleChildScrollView(child: SelectableText(message, textAlign: TextAlign.center)),
        ),
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: Text(cancel)),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: Colors.white)
                : null,
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ok),
          ),
        ],
      );
    },
  );
  return r ?? false;
}

Future<String?> promptText(
  BuildContext context,
  String title, {
  String label = '',
  String initial = '',
  bool obscure = false,
  int maxLines = 1,
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: obscure,
          maxLines: obscure ? 1 : maxLines,
          decoration: InputDecoration(hintText: label.isEmpty ? null : label),
          onSubmitted: maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
      ],
    ),
  );
}

void showErrorDialog(BuildContext context, Object error, {String title = 'Errore'}) {
  final msg = error is OdbcException ? error.message : error.toString();
  showDialog<void>(
    context: context,
    builder: (ctx) {
      final c = DbColors.of(ctx);
      return AlertDialog(
        icon: Icon(AppIcons.error, size: 32, color: c.danger),
        title: Text(title, textAlign: TextAlign.center),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 380),
          child: Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: c.chrome,
              borderRadius: BorderRadius.circular(Radii.panel),
              border: Border.all(color: c.separator),
            ),
            child: SingleChildScrollView(child: SelectableText(msg, style: monoStyle(ctx, size: 12))),
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: msg)),
            child: const Text('Copia'),
          ),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: const Text('Chiudi')),
        ],
      );
    },
  );
}

void showToast(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  final c = DbColors.of(context);
  m.showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(
            error ? AppIcons.error : AppIcons.checkCircle,
            size: 16,
            color: error ? c.danger : c.success,
          ),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(message)),
        ],
      ),
      duration: Duration(seconds: error ? 6 : 3),
    ),
  );
}

/// Runs [action] showing errors in a dialog. Returns true on success.
Future<bool> guarded(BuildContext context, Future<void> Function() action, {String title = 'Errore'}) async {
  try {
    await action();
    return true;
  } catch (e) {
    if (context.mounted) showErrorDialog(context, e, title: title);
    return false;
  }
}

/// Key/value list used in property pages.
class PropertyTable extends StatelessWidget {
  const PropertyTable({super.key, required this.entries, this.labelWidth = 180});
  final List<(String, String)> entries;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.chrome,
        borderRadius: BorderRadius.circular(Radii.panel + 2),
        border: Border.all(color: c.separator),
      ),
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: Gap.md, color: c.separator),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Text(
                      entries[i].$1,
                      style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      entries[i].$2.isEmpty ? '—' : entries[i].$2,
                      style: TextStyle(
                        fontSize: TypeSize.body,
                        color: entries[i].$2.isEmpty ? c.textTertiary : c.text,
                        fontFeatures: kTabular,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Read-only zebra table for metadata lists (columns, indexes, …).
class SimpleGrid extends StatelessWidget {
  const SimpleGrid({super.key, required this.headers, required this.rows, this.onRowDoubleTap});
  final List<String> headers;
  final List<List<String>> rows;
  final void Function(int row)? onRowDoubleTap;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    if (rows.isEmpty) {
      return const EmptyState(icon: AppIcons.empty, title: 'Nessun elemento');
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Align(
        alignment: Alignment.topLeft,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.panel + 2),
            border: Border.all(color: c.separator),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 30,
              dataRowMinHeight: 26,
              dataRowMaxHeight: 30,
              columnSpacing: 32,
              horizontalMargin: Gap.md,
              showCheckboxColumn: false,
              dividerThickness: 0,
              columns: [for (final h in headers) DataColumn(label: Text(h))],
              rows: [
                for (var i = 0; i < rows.length; i++)
                  DataRow(
                    color: WidgetStatePropertyAll(i.isOdd ? c.zebra : c.content),
                    onSelectChanged: onRowDoubleTap == null ? null : (_) => onRowDoubleTap!(i),
                    cells: [
                      for (final (j, v) in rows[i].indexed)
                        DataCell(
                          SelectableText(
                            v,
                            style: TextStyle(
                              fontSize: TypeSize.body,
                              fontWeight: j == 1 ? FontWeight.w500 : null,
                              color: c.text,
                              fontFeatures: kTabular,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// macOS pop-up button: looks like a field, opens a menu of fixed choices.
class SelectField<T> extends StatelessWidget {
  const SelectField({super.key, required this.value, required this.items, required this.onChanged});

  final T value;

  /// Value, label and optional leading icon (with its color).
  final List<(T, String, (IconData, Color)?)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    Widget entry((T, String, (IconData, Color)?) it) => Row(
      children: [
        if (it.$3 case (final icon, final color)) ...[
          Icon(icon, size: 15, color: color),
          const SizedBox(width: Gap.sm),
        ],
        Flexible(
          child: Text(
            it.$2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: TypeSize.body, color: c.text),
          ),
        ),
      ],
    );
    final current = items.firstWhere((it) => it.$1 == value, orElse: () => items.first);
    return PopupMenuButton<T>(
      tooltip: '',
      position: PopupMenuPosition.under,
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [for (final it in items) PopupMenuItem<T>(value: it.$1, height: 28, child: entry(it))],
      child: Container(
        height: 28,
        padding: const EdgeInsets.only(left: 10, right: 6),
        decoration: BoxDecoration(
          color: c.content,
          borderRadius: BorderRadius.circular(Radii.control),
          border: Border.all(color: c.separator),
        ),
        child: Row(
          children: [
            Expanded(child: entry(current)),
            Icon(AppIcons.upDown, size: 15, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Compact macOS-sized switch.
class DbSwitch extends StatelessWidget {
  const DbSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 38,
    height: 22,
    child: FittedBox(
      fit: BoxFit.contain,
      child: CupertinoSwitch(value: value, onChanged: onChanged, activeTrackColor: DbColors.of(context).accent),
    ),
  );
}

/// Environment marker: shown only for test / production connections, where
/// knowing the environment prevents mistakes.
class EnvDot extends StatelessWidget {
  const EnvDot(this.color, {super.key, required this.show, this.size = 7, this.tooltip});
  final Color color;
  final bool show;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (!show) return const SizedBox.shrink();
    final dot = StatusDot(color, size: size);
    return tooltip == null ? dot : Tooltip(message: tooltip!, child: dot);
  }
}
