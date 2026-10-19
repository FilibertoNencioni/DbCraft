import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'control_base.dart';
import 'menus.dart';

/// Role of a [PushButton].
enum PushButtonKind {
  /// Bezel button: Annulla, secondary actions.
  normal,

  /// The default button (accent fill, Invio). One per sheet or bar.
  defaultAction,

  /// Danger label on a normal bezel. Filled only in alerts ([PushButton.filled]).
  destructive,
}

/// AppKit push button (NSButton, rounded bezel).
///
/// 22pt high (small 19), radius 5, white bezel with a hairline and a soft
/// drop shadow. The default button takes the accent fill and turns gray when
/// the window is in the background.
class PushButton extends StatelessWidget {
  const PushButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = PushButtonKind.normal,
    this.icon,
    this.size = ControlScale.regular,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
    this.minWidth = 0,
    this.expand = false,
    this.filled = false,
  });

  /// The default button of a sheet or bar.
  const PushButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.size = ControlScale.regular,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
    this.minWidth = 0,
    this.expand = false,
  }) : kind = PushButtonKind.defaultAction,
       filled = false;

  final String label;
  final VoidCallback? onPressed;
  final PushButtonKind kind;
  final IconData? icon;
  final ControlScale size;
  final String? tooltip;
  final FocusNode? focusNode;
  final bool autofocus;
  final double minWidth;

  /// Fill the available width (stacked alert buttons).
  final bool expand;

  /// Solid danger fill for a destructive button inside an alert.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final h = size == ControlScale.toolbar ? ControlSize.toolbar : size.height;
    return Pressable(
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      tooltip: tooltip,
      semanticLabel: label,
      builder: (context, s) {
        final disabled = s.contains(WidgetState.disabled);
        final down = s.contains(WidgetState.pressed);
        final accentFill = switch (kind) {
          PushButtonKind.defaultAction => c.windowActive ? c.defaultButton : null,
          PushButtonKind.destructive when filled => c.windowActive ? c.danger : null,
          _ => null,
        };
        final Color fg;
        if (disabled) {
          fg = c.textTertiary;
        } else if (accentFill != null) {
          fg = c.onAccent;
        } else if (kind == PushButtonKind.destructive) {
          fg = c.danger;
        } else {
          fg = c.text;
        }
        Color fill = disabled ? c.controlBackground.withValues(alpha: 0.6) : (accentFill ?? c.controlBackground);
        if (down) fill = accentFill != null ? Color.lerp(fill, const Color(0xFF000000), 0.15)! : pressedFill(context, fill);
        final gradient = accentFill != null && !disabled && !down
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.lerp(fill, const Color(0xFFFFFFFF), 0.12)!, fill],
              )
            : null;
        final text = Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: uiText(size.fontSize, color: fg, weight: accentFill != null ? FontWeight.w500 : null),
        );
        return FocusRing(
          visible: s.contains(WidgetState.focused),
          child: Container(
            height: h,
            constraints: BoxConstraints(minWidth: minWidth),
            width: expand ? double.infinity : null,
            padding: EdgeInsets.symmetric(horizontal: size == ControlScale.small ? 8 : 11),
            decoration: BoxDecoration(
              color: fill,
              gradient: gradient,
              borderRadius: BorderRadius.circular(Radii.control),
              border: accentFill != null && !dark ? null : Border.all(color: c.controlBorder, width: 0.5),
              boxShadow: disabled ? null : Elevation.control(Theme.of(context).brightness),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: size.iconSize, color: fg),
                  const SizedBox(width: 5),
                ],
                Flexible(child: text),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Borderless icon button for toolbars and bars (NSButton, toolbar style):
/// the bezel appears only on hover and press. [active] keeps the pressed
/// bezel and tints the glyph with the accent (an "on" toggle).
///
/// Sizes: [ControlSize.toolbar] 28 in the window toolbar (glyph 18),
/// [ControlSize.regular] 22 inline (glyph 16), 18 for mini row accessories
/// (glyph 14).
class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
    this.active = false,
    this.size,
    this.extent = ControlSize.regular,
    this.label,
    this.focusable = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final bool active;

  /// Glyph size; defaults to the size that matches [extent].
  final double? size;

  /// Height and minimum width of the bezel.
  final double extent;

  /// Optional text shown next to the icon.
  final String? label;
  final bool focusable;

  static double glyphFor(double extent) => extent >= ControlSize.toolbar ? 18 : (extent >= ControlSize.regular ? 16 : 14);

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Pressable(
      onPressed: onPressed,
      tooltip: tooltip,
      focusable: focusable,
      toggled: active ? true : null,
      builder: (context, s) {
        final disabled = s.contains(WidgetState.disabled);
        final fg = disabled ? c.textTertiary : (active ? c.accent : (color ?? c.textSecondary));
        Color bg = const Color(0x00000000);
        if (s.contains(WidgetState.pressed) || active) {
          bg = c.pressed;
        } else if (s.contains(WidgetState.hovered)) {
          bg = c.hover;
        }
        return FocusRing(
          visible: s.contains(WidgetState.focused),
          child: Container(
            height: extent,
            constraints: BoxConstraints(minWidth: extent),
            padding: EdgeInsets.symmetric(horizontal: label == null ? 2 : 7),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.control)),
            // Shrink-wrap the content: an aligned Container would fill bounded parents.
            child: Center(
              widthFactor: 1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: size ?? glyphFor(extent), color: fg),
                  if (label != null) ...[
                    const SizedBox(width: 5),
                    Text(
                      label!,
                      style: uiText(
                        extent >= ControlSize.toolbar ? TypeSize.body : TypeSize.small,
                        weight: FontWeight.w500,
                        color: disabled ? c.textTertiary : (active ? c.accent : c.text),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 1×16 hairline between groups of tool buttons.
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

/// Pull-down button (NSPopUpButton, pullsDown): an icon or a title plus a
/// small ⌄ that opens a [showMacMenu] of commands. The title never changes
/// with the choice; use [PopUpButton] for picking a value.
///
/// [bordered] draws a permanent push-button bezel (window toolbar); inline
/// pull-downs are borderless until hovered.
class PulldownButton extends StatelessWidget {
  const PulldownButton({
    super.key,
    required this.entries,
    this.icon,
    this.label,
    this.tooltip,
    this.bordered = false,
    this.extent = ControlSize.regular,
    this.enabled = true,
  }) : assert(icon != null || label != null);

  /// Built when the menu opens, so it reflects the current state.
  final List<MenuEntry<Object?>> Function() entries;
  final IconData? icon;
  final String? label;
  final String? tooltip;
  final bool bordered;
  final double extent;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Builder(
      builder: (anchor) => Pressable(
        tooltip: tooltip,
        semanticLabel: label ?? tooltip,
        focusable: bordered,
        onPressed: enabled ? () => showMacMenu<Object?>(anchor, anchor: anchorRect(anchor), entries: entries()) : null,
        builder: (context, s) {
          final disabled = s.contains(WidgetState.disabled);
          final down = s.contains(WidgetState.pressed);
          final fg = disabled ? c.textTertiary : (label != null ? c.text : c.textSecondary);
          final Color bg;
          if (bordered) {
            bg = down ? pressedFill(context, c.controlBackground) : c.controlBackground;
          } else if (down) {
            bg = c.pressed;
          } else if (s.contains(WidgetState.hovered)) {
            bg = c.hover;
          } else {
            bg = const Color(0x00000000);
          }
          return FocusRing(
            visible: s.contains(WidgetState.focused),
            child: Container(
              height: extent,
              constraints: BoxConstraints(minWidth: extent),
              padding: EdgeInsets.only(left: label == null ? 4 : 8, right: 4),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(Radii.control),
                border: bordered ? Border.all(color: c.controlBorder, width: 0.5) : null,
                boxShadow: bordered && !dark ? Elevation.control(Brightness.light) : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) Icon(icon, size: ToolButton.glyphFor(extent), color: fg),
                  if (icon != null && label != null) const SizedBox(width: 5),
                  if (label != null)
                    Text(label!, style: uiText(extent >= ControlSize.toolbar ? TypeSize.body : TypeSize.small, color: fg)),
                  const SizedBox(width: 3),
                  Icon(AppIcons.chevronDown, size: 9, color: disabled ? c.textTertiary : c.textSecondary),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Text-only action that reads as a link: "Dettagli…", "Apri", "Carica
/// altri". Accent label, underlined on hover, no bezel.
class LinkButton extends StatelessWidget {
  const LinkButton({super.key, required this.label, required this.onPressed, this.small = false, this.tooltip});

  final String label;
  final VoidCallback? onPressed;
  final bool small;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Pressable(
      onPressed: onPressed,
      tooltip: tooltip,
      cursor: SystemMouseCursors.click,
      semanticLabel: label,
      builder: (context, s) {
        final disabled = s.contains(WidgetState.disabled);
        final color = disabled ? c.textTertiary : c.accent;
        return FocusRing(
          visible: s.contains(WidgetState.focused),
          radius: Radii.small,
          child: Text(
            label,
            style: uiText(small ? TypeSize.small : TypeSize.body, color: color).copyWith(
              decoration: s.contains(WidgetState.hovered) ? TextDecoration.underline : null,
              decorationColor: color,
            ),
          ),
        );
      },
    );
  }
}

/// Disclosure triangle that rotates 90° when expanded (NSButton, disclosure
/// style). Used by [DisclosureButton] and by outline rows.
class DisclosureChevron extends StatelessWidget {
  const DisclosureChevron({super.key, required this.expanded, this.color, this.size = 10});

  final bool expanded;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: expanded ? 0.25 : 0,
    duration: Motion.of(context, Motion.fast),
    child: Icon(AppIcons.chevronRight, size: size, color: color ?? DbColors.of(context).textTertiary),
  );
}

/// Section header that shows or hides its content: "Avanzate", driver
/// groups, comparison groups. Chevron plus a 13pt semibold label.
///
/// With an [icon] or a [subtitle] it is an item that discloses its details
/// (a driver and its library): regular label, 11 secondary subtitle
/// ([monoSubtitle] for paths), both ellipsized to the available width, which
/// must then be bounded. A null
/// [onChanged] disables it and hides the chevron, keeping its slot so rows
/// stay aligned; [contentIndent] is where the label starts, to indent the
/// disclosed content.
class DisclosureButton extends StatelessWidget {
  const DisclosureButton({
    super.key,
    required this.label,
    required this.expanded,
    required this.onChanged,
    this.trailing,
    this.icon,
    this.iconColor,
    this.subtitle,
    this.monoSubtitle = false,
  });

  final String label;
  final bool expanded;
  final ValueChanged<bool>? onChanged;

  /// Accessory after the label (count, status).
  final Widget? trailing;

  /// 16pt glyph between the chevron and the label.
  final IconData? icon;

  /// Secondary when null.
  final Color? iconColor;

  /// Second line under the label.
  final String? subtitle;
  final bool monoSubtitle;

  static const double _chevronSlot = 10;
  static const double _gap = 6;
  static const double _iconSize = 16;

  /// Offset of the label from the leading edge, with or without an icon.
  static double contentIndent({bool icon = false}) => _chevronSlot + _gap + (icon ? _iconSize + _gap : 0);

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final onChanged = this.onChanged;
    final sub = subtitle;
    final item = icon != null || sub != null;
    return Pressable(
      onPressed: onChanged == null ? null : () => onChanged(!expanded),
      toggled: expanded,
      semanticLabel: label,
      builder: (context, s) {
        final enabled = onChanged != null;
        final Widget title = Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: uiText(TypeSize.body, weight: item ? null : FontWeight.w600, color: c.text),
        );
        final Widget text = !item
            ? title
            : Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    if (sub != null)
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoSubtitle
                            ? TextStyle(
                                fontFamily: kMonoFamily,
                                fontFamilyFallback: kMonoFallback,
                                fontSize: TypeSize.monoSmall,
                                height: 1.35,
                                color: c.textSecondary,
                              )
                            : uiText(TypeSize.caption, color: c.textSecondary),
                      ),
                  ],
                ),
              );
        return FocusRing(
          visible: s.contains(WidgetState.focused),
          radius: Radii.small,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: ControlSize.regular),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: _chevronSlot,
                  child: enabled
                      ? DisclosureChevron(
                          expanded: expanded,
                          color: s.contains(WidgetState.hovered) ? c.textSecondary : null,
                        )
                      : null,
                ),
                const SizedBox(width: _gap),
                if (icon != null) ...[
                  Icon(icon, size: _iconSize, color: iconColor ?? c.textSecondary),
                  const SizedBox(width: _gap),
                ],
                text,
                if (trailing != null) ...[const SizedBox(width: Gap.sm), trailing!],
              ],
            ),
          ),
        );
      },
    );
  }
}
