import 'package:flutter/material.dart';

import '../../model/connection_config.dart';
import '../theme/app_theme.dart';
import 'control_base.dart';
import 'menus.dart';
import 'progress.dart';

// ---------------------------------------------------------------------------
// Row context
// ---------------------------------------------------------------------------

/// What the row behind an accessory looks like. Rows with an emphasized
/// selection (solid accent) or a highlighted menu row set it, so counts,
/// tags and dots switch to white and ring dots match the row fill.
class RowTint extends InheritedWidget {
  const RowTint({super.key, this.background, this.emphasized = false, required super.child});

  /// The row fill, or null when the row shows the list background.
  final Color? background;

  /// The row is drawn on the solid accent: accessories turn white.
  final bool emphasized;

  static RowTint? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<RowTint>();

  static bool emphasizedOf(BuildContext context) => maybeOf(context)?.emphasized ?? false;

  @override
  bool updateShouldNotify(RowTint old) => old.background != background || old.emphasized != emphasized;
}

// ---------------------------------------------------------------------------
// Counts and tags
// ---------------------------------------------------------------------------

/// A count (Mail sidebar badge): 16pt capsule, neutral `pressed` fill, 11
/// semibold tabular secondary. [prominent] uses the accent with white text,
/// only to call attention (unread, conflicts).
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.prominent = false, this.tooltip});

  /// A number, or a short text such as "99+".
  final Object count;
  final bool prominent;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final on = RowTint.emphasizedOf(context);
    final Color fill;
    final Color fg;
    if (on) {
      fill = c.onSelectionEmphasized.withValues(alpha: Tint.strong);
      fg = c.onSelectionEmphasized;
    } else if (prominent) {
      fill = c.windowActive ? c.accent : c.textTertiary;
      fg = c.onAccent;
    } else {
      fill = c.pressed;
      fg = c.textSecondary;
    }
    final badge = Container(
      height: 16,
      constraints: const BoxConstraints(minWidth: 16),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(8)),
      child: Center(
        widthFactor: 1,
        child: Text(
          '$count',
          maxLines: 1,
          style: uiText(TypeSize.caption, weight: FontWeight.w600, color: fg, height: 1.1, features: kTabular),
        ),
      ),
    );
    return tooltip == null ? badge : Tooltip(message: tooltip!, child: badge);
  }
}

/// A status or label tag: "vista", "nuova", "sola lettura", the environment.
/// Radius 4 (not a capsule), 16pt, 11 medium in [color] on its
/// `Tint.regular` fill.
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color, this.tooltip, this.mono = false});

  final String label;

  /// Semantic color (success, warning, danger, environment); secondary when
  /// null.
  final Color? color;
  final String? tooltip;

  /// Monospaced label (a language, a type).
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final col = RowTint.emphasizedOf(context) ? c.onSelectionEmphasized : (color ?? c.textSecondary);
    final style = mono
        ? TextStyle(
            fontFamily: kMonoFamily,
            fontFamilyFallback: kMonoFallback,
            fontSize: TypeSize.mini,
            color: col,
            height: 1.1,
          )
        : uiText(TypeSize.caption, weight: FontWeight.w500, color: col, height: 1.1);
    final tag = Container(
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: col.withValues(alpha: Tint.regular),
        borderRadius: BorderRadius.circular(Radii.small),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      ),
    );
    return tooltip == null ? tag : Tooltip(message: tooltip!, child: tag);
  }
}

/// Base of every capsule (radius h/2): the activity view, join and drag
/// chips, tokens. `raised` fill by default, or [color]; optional
/// [Elevation.control] shadow.
class Capsule extends StatelessWidget {
  const Capsule({
    super.key,
    required this.child,
    this.height = ControlSize.small,
    this.color,
    this.elevated = false,
    this.bordered = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
  });

  final Widget child;
  final double height;
  final Color? color;
  final bool elevated;

  /// 0.5px `controlBorder` outline (capsules on a canvas).
  final bool bordered;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? c.raised,
        borderRadius: BorderRadius.circular(height / 2),
        border: bordered ? Border.all(color: c.controlBorder, width: 0.5) : null,
        boxShadow: elevated ? Elevation.control(Theme.of(context).brightness) : null,
      ),
      child: Center(widthFactor: 1, child: child),
    );
  }
}

// ---------------------------------------------------------------------------
// Dots and marks
// ---------------------------------------------------------------------------

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
      color: ring ? const Color(0x00000000) : color,
      shape: BoxShape.circle,
      border: ring ? Border.all(color: color, width: 1.5) : null,
    ),
  );
}

/// Environment colors: green for development, orange for test, red for
/// production, from the semantic palette so they follow light and dark.
extension ConnectionTypeColor on ConnectionType {
  Color colorOf(DbColors c) => switch (this) {
    ConnectionType.development => c.success,
    ConnectionType.test => c.warning,
    ConnectionType.production => c.danger,
  };
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

/// A status dot over the bottom-right corner of an icon (connected,
/// error), ringed with the row fill so it reads on any selection.
class IconBadge extends StatelessWidget {
  const IconBadge({super.key, required this.child, required this.color, this.tooltip});

  /// The icon, usually 16pt.
  final Widget child;

  /// Dot color, or null for no dot.
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (color == null) return child;
    final c = DbColors.of(context);
    final ring = RowTint.maybeOf(context)?.background ?? c.sidebar;
    Widget dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 1.5, strokeAlign: BorderSide.strokeAlignOutside),
      ),
    );
    if (tooltip != null) dot = Tooltip(message: tooltip!, child: dot);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(right: -1.5, bottom: -1.5, child: dot),
      ],
    );
  }
}

/// A file's state in a source-control list (Xcode): the letter (M, A, D,
/// U, R, ?) 10 bold in a 14pt square, radius 3, on the color's
/// `Tint.regular`.
class StatusLetter extends StatelessWidget {
  const StatusLetter(this.letter, {super.key, required this.color, this.tooltip});

  final String letter;
  final Color color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final col = RowTint.emphasizedOf(context) ? c.onSelectionEmphasized : color;
    final mark = Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: col.withValues(alpha: Tint.regular),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        letter,
        style: uiText(TypeSize.mini, weight: FontWeight.w700, color: col, height: 1),
      ),
    );
    return tooltip == null ? mark : Tooltip(message: tooltip!, child: mark);
  }
}

/// Unsaved-changes dot (document tabs, script rows): 7pt, secondary.
class DirtyDot extends StatelessWidget {
  const DirtyDot({super.key, this.tooltip = 'Modifiche non salvate'});

  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final color = RowTint.emphasizedOf(context) ? c.onSelectionEmphasized : c.textSecondary;
    final dot = StatusDot(color, size: 7);
    return tooltip == null ? dot : Tooltip(message: tooltip!, child: dot);
  }
}

/// A column type next to its name (grid header, record view, ER boxes):
/// 11 regular tertiary, lowercase. [mono] when it is an exact SQL type
/// (`numeric(10,2)`), not a family (`numero`).
class TypeLabel extends StatelessWidget {
  const TypeLabel(this.type, {super.key, this.mono = false, this.size = TypeSize.caption});

  final String type;
  final bool mono;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final color = RowTint.emphasizedOf(context) ? c.onSelectionEmphasized.withValues(alpha: 0.75) : c.textTertiary;
    return Text(
      type,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.fade,
      style: mono
          ? TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: size - 1, color: color)
          : uiText(size, color: color),
    );
  }
}

// ---------------------------------------------------------------------------
// Shortcuts
// ---------------------------------------------------------------------------

/// A key combination as text ("⌘⇧N", "⌘Invio"; "Ctrl+Shift+N" off macOS),
/// formatted by [shortcutLabel], the one formatter used by menus, tooltips,
/// the welcome page and sheets.
class ShortcutText extends StatelessWidget {
  const ShortcutText(this.activator, {super.key, this.size = TypeSize.body, this.color});

  final SingleActivator activator;
  final double size;

  /// Secondary when null.
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    shortcutLabel(activator),
    maxLines: 1,
    style: uiText(size, color: color ?? DbColors.of(context).textSecondary, features: kTabular),
  );
}

/// A key cap (shortcut lists, help text): radius 4, `chrome` fill, 0.5
/// hairline, 11. [KeyCap.shortcut] formats an activator with
/// [shortcutLabel].
class KeyCap extends StatelessWidget {
  const KeyCap(this.label, {super.key});

  KeyCap.shortcut(SingleActivator activator, {Key? key}) : this(shortcutLabel(activator), key: key);

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      height: 18,
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: c.chrome,
        borderRadius: BorderRadius.circular(Radii.small),
        border: Border.all(color: c.controlBorder, width: 0.5),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          maxLines: 1,
          style: uiText(TypeSize.caption, color: c.textSecondary, height: 1.1, features: kTabular),
        ),
      ),
    );
  }
}

/// Shortcut keys shared by help texts: alternatives separated by "/".
class KeyCaps extends StatelessWidget {
  const KeyCaps(this.activators, {super.key});

  final List<SingleActivator> activators;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < activators.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('/', style: uiText(TypeSize.caption, color: c.textTertiary)),
            ),
          KeyCap.shortcut(activators[i]),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Activity view
// ---------------------------------------------------------------------------

/// The toolbar pill that shows the active connection (Xcode activity view):
/// 28pt, radius 6, `hover` fill, "name · status" centered, a spinner while
/// [busy], the environment [Tag] and ⌃⌄. [onPressed] opens the connection
/// menu (`showMacMenu` with `MenuEntry.connection` rows).
class ActivityView extends StatelessWidget {
  const ActivityView({
    super.key,
    required this.title,
    this.status,
    this.statusColor,
    this.dot,
    this.busy = false,
    this.environment,
    this.environmentColor,
    this.onPressed,
    this.tooltip,
    this.minWidth = 260,
    this.maxWidth = 420,
  });

  /// Connection name, or a placeholder ("Scegli una connessione").
  final String title;
  final String? status;

  /// Status text color (danger on errors); secondary when null.
  final Color? statusColor;

  /// Status dot before the name.
  final Color? dot;
  final bool busy;
  final String? environment;
  final Color? environmentColor;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double minWidth;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Pressable(
      onPressed: onPressed,
      focusable: false,
      tooltip: tooltip,
      semanticLabel: [title, ?status].join(', '),
      builder: (context, s) {
        var fill = c.hover;
        if (s.contains(WidgetState.pressed)) {
          fill = c.pressed;
        } else if (s.contains(WidgetState.hovered)) {
          fill = Color.alphaBlend(c.hover, c.hover);
        }
        return Container(
          height: ControlSize.toolbar,
          constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(Radii.menu)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (dot != null) ...[StatusDot(dot!, size: 8), const SizedBox(width: Gap.sm)],
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text),
                ),
              ),
              if (environment != null) ...[const SizedBox(width: 6), Tag(environment!, color: environmentColor)],
              if (status != null) ...[
                Text('  ·  ', style: uiText(TypeSize.small, color: c.textTertiary)),
                if (busy) ...[const Spinner(size: 10), const SizedBox(width: 6)],
                Flexible(
                  child: Text(
                    status!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(TypeSize.small, color: statusColor ?? c.textSecondary),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Icon(AppIcons.upDown, size: 11, color: c.textTertiary),
            ],
          ),
        );
      },
    );
  }
}
