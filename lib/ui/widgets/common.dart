import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'buttons.dart';
import 'feedback.dart';

export '../theme/app_theme.dart';
export 'buttons.dart';
export 'control_base.dart';
export 'feedback.dart';
export 'fields.dart';
export 'menus.dart';
export 'selection.dart';
export 'sheets.dart';
export 'surfaces.dart';

const kMono = kMonoFamily;

TextStyle monoStyle(BuildContext context, {double size = 13, Color? color}) => TextStyle(
  fontFamily: kMonoFamily,
  fontFamilyFallback: kMonoFallback,
  fontSize: size,
  color: color ?? DbColors.of(context).text,
  height: 1.35,
  fontFeatures: kTabular,
);

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
