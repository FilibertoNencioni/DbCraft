import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'badges.dart';
import 'buttons.dart';
import 'lists.dart';

// ---------------------------------------------------------------------------
// Inspector
// ---------------------------------------------------------------------------

/// The side of the content area an [Inspector] sits on. The hairline goes on
/// the edge that faces the content.
enum InspectorSide { start, end }

/// Xcode-style inspector pane: a fixed-width column on `windowBackground`
/// with a 0.5 hairline towards the content, scrolling [children] (usually
/// [InspectorSection]s, split by hairlines). [width] is kept within
/// [minWidth]–[maxWidth].
class Inspector extends StatelessWidget {
  const Inspector({super.key, required this.children, this.width = defaultWidth, this.side = InspectorSide.end});

  static const double minWidth = 260;
  static const double maxWidth = 320;
  static const double defaultWidth = 280;

  final List<Widget> children;
  final double width;
  final InspectorSide side;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final hairline = BorderSide(color: c.separator, width: 0.5);
    return Container(
      width: width.clamp(minWidth, maxWidth),
      decoration: BoxDecoration(
        color: c.windowBackground,
        border: side == InspectorSide.end ? Border(left: hairline) : Border(right: hairline),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0 && children[i] is InspectorSection && children[i - 1] is InspectorSection)
              Divider(height: 1, thickness: 0.5, color: c.separator),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A group of an [Inspector]: a disclosure header (chevron and an 11
/// semibold secondary title, "Nascondi"/"Mostra" on hover) over compact
/// rows spaced by [spacing].
///
/// It keeps its own expanded state from [initiallyExpanded] unless
/// [expanded] is given, in which case the parent owns it through
/// [onExpandedChanged]. With `collapsible: false` the header is a plain
/// [SectionLabel].
class InspectorSection extends StatefulWidget {
  const InspectorSection({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.initiallyExpanded = true,
    this.expanded,
    this.onExpandedChanged,
    this.collapsible = true,
    this.spacing = Gap.sm,
  });

  final String title;
  final List<Widget> children;

  /// Accessory at the end of the header (count, mini action).
  final Widget? trailing;
  final bool initiallyExpanded;
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;
  final bool collapsible;

  /// Vertical gap between [children].
  final double spacing;

  @override
  State<InspectorSection> createState() => _InspectorSectionState();
}

class _InspectorSectionState extends State<InspectorSection> {
  late bool _expanded = widget.initiallyExpanded;

  bool get _isExpanded => !widget.collapsible || (widget.expanded ?? _expanded);

  void _set(bool v) {
    if (widget.expanded == null) setState(() => _expanded = v);
    widget.onExpandedChanged?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final expanded = _isExpanded;
    Widget header = SectionLabel(
      widget.title,
      padding: EdgeInsets.fromLTRB(widget.collapsible ? Gap.xs : 0, Gap.sm, 0, Gap.sm),
      trailing: widget.trailing,
      expanded: expanded,
      onToggle: widget.collapsible ? _set : null,
    );
    if (widget.collapsible) {
      // The label toggles itself; the chevron toggles through this detector.
      header = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _set(!expanded),
        child: Row(
          children: [
            DisclosureChevron(expanded: expanded),
            Expanded(child: header),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < widget.children.length; i++) ...[
                  if (i > 0) SizedBox(height: widget.spacing),
                  widget.children[i],
                ],
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Stat tile
// ---------------------------------------------------------------------------

/// KPI tile of a dashboard: radius 8 on `content` with a 0.5 hairline, the
/// [label] in 11 secondary, the [value] in 17 semibold tabular figures and
/// an optional [child] under it (a sparkline). [warning] turns the value
/// amber. [tooltip] adds a hover explanation (help, min and max).
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.child,
    this.warning = false,
    this.tooltip,
    this.width = defaultWidth,
  });

  static const double defaultWidth = 184;

  final String label;
  final String value;
  final Widget? child;
  final bool warning;
  final String? tooltip;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    Widget tile = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: c.content,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: c.separator, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: uiText(TypeSize.caption, color: c.textSecondary),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: uiText(
              TypeSize.sheetTitle,
              weight: FontWeight.w600,
              color: warning ? c.warning : c.text,
              features: kTabular,
            ),
          ),
          if (child != null) ...[const SizedBox(height: Gap.xs), child!],
        ],
      ),
    );
    tile = Semantics(
      container: true,
      label: label,
      value: value,
      child: ExcludeSemantics(child: tile),
    );
    return tooltip == null ? tile : Tooltip(message: tooltip, child: tile);
  }
}

// ---------------------------------------------------------------------------
// Inset box
// ---------------------------------------------------------------------------

/// Inset content container inside a sheet or a pane (list boxes, column
/// lists, detail headers): `content` fill, radius 8, 0.5 hairline, content
/// clipped to the corners.
class InsetBox extends StatelessWidget {
  const InsetBox({super.key, required this.child, this.width, this.height, this.padding});

  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: c.content,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: c.separator, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Drag chip
// ---------------------------------------------------------------------------

/// Drag feedback: a `raised` [Capsule] with a menu shadow, an optional
/// accent [icon] and a 12pt [label] (tables and columns dragged on a
/// canvas, tab proxies).
class DragChip extends StatelessWidget {
  const DragChip({super.key, required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    // Drag feedback lives in the overlay, outside any Material.
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ControlSize.regular / 2),
          boxShadow: Elevation.menu(Theme.of(context).brightness),
        ),
        child: Capsule(
          height: ControlSize.regular,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 14, color: c.accent), const SizedBox(width: 6)],
              Text(label, style: uiText(TypeSize.small, color: c.text)),
            ],
          ),
        ),
      ),
    );
  }
}
