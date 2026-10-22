import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'badges.dart';
import 'control_base.dart';
import 'menus.dart';
import 'progress.dart';
import 'selection.dart';

// ---------------------------------------------------------------------------
// Window tabs
// ---------------------------------------------------------------------------

/// Fill of the tab strip and of the tabs in the background: `chrome`, one
/// step darker (Safari, Finder and Xcode tab bars).
Color _stripFill(DbColors c) => Color.alphaBlend(c.hover, c.chrome);

/// A document tab (Safari, Finder, Xcode): centered title, the close ⓧ on
/// the left while hovered, otherwise the unsaved dot or a spinner there.
/// The active tab takes `content` and merges with the editor below; the
/// others stay on the darker strip, split by 1px separators.
///
/// Right click calls [onMenu], a middle click closes the tab.
class WindowTab extends StatefulWidget {
  const WindowTab({
    super.key,
    required this.title,
    required this.active,
    this.icon,
    this.dirty = false,
    this.busy = false,
    this.accessory,
    this.tooltip,
    this.onSelect,
    this.onClose,
    this.onMenu,
  });

  final String title;
  final bool active;
  final IconData? icon;
  final bool dirty;
  final bool busy;

  /// Mark after the title (the environment [EnvDot]).
  final Widget? accessory;
  final String? tooltip;
  final VoidCallback? onSelect;
  final VoidCallback? onClose;
  final void Function(Offset globalPosition)? onMenu;

  @override
  State<WindowTab> createState() => _WindowTabState();
}

class _WindowTabState extends State<WindowTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final active = widget.active;
    final Color fill;
    if (active) {
      fill = c.content;
    } else if (_hover) {
      fill = c.chrome;
    } else {
      fill = _stripFill(c);
    }

    final Widget? lead;
    if (_hover && widget.onClose != null) {
      lead = Pressable(
        onPressed: widget.onClose,
        focusable: false,
        tooltip: 'Chiudi scheda',
        builder: (context, s) => Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: s.contains(WidgetState.pressed) ? c.pressed : (s.contains(WidgetState.hovered) ? c.hover : null),
            borderRadius: BorderRadius.circular(Radii.small),
          ),
          child: Icon(AppIcons.close, size: 10, color: c.textSecondary),
        ),
      );
    } else if (widget.busy) {
      lead = const Spinner(size: Spinner.small);
    } else if (widget.dirty) {
      lead = const DirtyDot(tooltip: null);
    } else {
      lead = null;
    }

    final fg = active ? c.text : c.textSecondary;
    final tab = Container(
      height: BarHeight.tabStrip,
      decoration: BoxDecoration(
        color: fill,
        border: Border(
          right: BorderSide(color: c.separator, width: 0.5),
          bottom: active ? BorderSide.none : BorderSide(color: c.separator, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          SizedBox(width: 16, child: Center(child: lead)),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 14, color: active ? c.accent : c.textTertiary),
                  const SizedBox(width: 5),
                ],
                Flexible(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(TypeSize.small, color: fg, weight: active ? FontWeight.w500 : null),
                  ),
                ),
                if (widget.accessory != null) ...[const SizedBox(width: 5), widget.accessory!],
              ],
            ),
          ),
          // Balances the left slot so the title stays centered.
          const SizedBox(width: 16),
        ],
      ),
    );

    Widget child = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        onTertiaryTapUp: widget.onClose == null ? null : (_) => widget.onClose!(),
        onSecondaryTapDown: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
        child: tab,
      ),
    );
    if (widget.tooltip != null) child = Tooltip(message: widget.tooltip!, child: child);
    return Semantics(selected: active, button: true, label: widget.title, child: child);
  }
}

/// The document tab strip (`tabStrip` 30): [WindowTab]s that share the
/// width (110–240 each, scrolling past that), drag to reorder, and a
/// [trailing] accessory (the "+" for a new editor).
class WindowTabBar extends StatelessWidget {
  const WindowTabBar({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.itemKey,
    this.onReorder,
    this.trailing,
  });

  final int itemCount;

  /// Builds the [WindowTab] at an index.
  final IndexedWidgetBuilder itemBuilder;

  /// Stable key of the tab at an index (reordering needs it).
  final Key Function(int index) itemKey;

  /// Moves a tab; the target index already accounts for the removed tab.
  final void Function(int from, int to)? onReorder;
  final Widget? trailing;

  static const double minTabWidth = 110;
  static const double maxTabWidth = 240;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final line = BorderSide(color: c.separator, width: 0.5);
    return Container(
      height: BarHeight.tabStrip,
      color: _stripFill(c),
      child: Stack(
        children: [
          Positioned(left: 0, right: 0, bottom: 0, child: Container(height: 0.5, color: line.color)),
          Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final w = itemCount == 0
                        ? maxTabWidth
                        : (box.maxWidth / itemCount).clamp(minTabWidth, maxTabWidth).toDouble();
                    Widget item(BuildContext context, int i) {
                      final tab = SizedBox(width: w, child: itemBuilder(context, i));
                      return onReorder == null
                          ? KeyedSubtree(key: itemKey(i), child: tab)
                          : ReorderableDragStartListener(key: itemKey(i), index: i, child: tab);
                    }

                    if (onReorder == null) {
                      return ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: itemCount,
                        itemBuilder: item,
                      );
                    }
                    return ReorderableListView.builder(
                      scrollDirection: Axis.horizontal,
                      buildDefaultDragHandles: false,
                      itemCount: itemCount,
                      onReorderItem: onReorder!,
                      proxyDecorator: (child, _, _) => DecoratedBox(
                        decoration: BoxDecoration(boxShadow: Elevation.menu(Theme.of(context).brightness)),
                        child: child,
                      ),
                      itemBuilder: item,
                    );
                  },
                ),
              ),
              if (trailing != null)
                Container(
                  height: BarHeight.tabStrip,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                  decoration: BoxDecoration(border: Border(bottom: line)),
                  child: Center(child: trailing),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pane tabs
// ---------------------------------------------------------------------------

class PaneTab<T> {
  const PaneTab(this.value, this.label, {this.count, this.icon, this.iconColor, this.onClose, this.tooltip});

  final T value;
  final String label;

  /// Shown as a [CountBadge].
  final Object? count;
  final IconData? icon;

  /// Tints [icon] (`danger` for a result in error); the label color
  /// otherwise.
  final Color? iconColor;

  /// Shows ⓧ on hover; a middle click closes the tab too.
  final VoidCallback? onClose;
  final String? tooltip;
}

/// Tabs inside a pane (result sets, Output / Log): small recessed buttons
/// as in a scope bar, with a [CountBadge] and a ⓧ on hover (or a middle
/// click) to close, in a `subbar` strip (unless [bar] is false).
class PaneTabs<T> extends StatelessWidget {
  const PaneTabs({
    super.key,
    required this.tabs,
    required this.value,
    required this.onChanged,
    this.trailing,
    this.bar = true,
  });

  final List<PaneTab<T>> tabs;
  final T value;
  final ValueChanged<T> onChanged;

  /// Actions on the right of the strip.
  final Widget? trailing;
  final bool bar;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final row = Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final t in tabs)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: _PaneTabButton<T>(tab: t, selected: t.value == value, onTap: () => onChanged(t.value)),
                  ),
              ],
            ),
          ),
        ),
        ?trailing,
      ],
    );
    if (!bar) return row;
    return Container(
      height: BarHeight.subbar,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: row,
    );
  }
}

class _PaneTabButton<T> extends StatefulWidget {
  const _PaneTabButton({super.key, required this.tab, required this.selected, required this.onTap});

  final PaneTab<T> tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PaneTabButton<T>> createState() => _PaneTabButtonState<T>();
}

class _PaneTabButtonState<T> extends State<_PaneTabButton<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final t = widget.tab;
    final selected = widget.selected;
    final close = t.onClose;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTertiaryTapUp: close == null ? null : (_) => close(),
        child: Pressable(
          onPressed: widget.onTap,
          toggled: selected,
          tooltip: t.tooltip,
          semanticLabel: t.label,
          builder: (context, s) {
            Color? bg;
            if (selected || s.contains(WidgetState.pressed)) {
              bg = c.pressed;
            } else if (s.contains(WidgetState.hovered)) {
              bg = c.hover;
            }
            final fg = selected ? c.text : c.textSecondary;
            return FocusRing(
              visible: s.contains(WidgetState.focused),
              child: Container(
                height: ControlSize.small,
                padding: EdgeInsets.only(left: 8, right: t.onClose == null ? 8 : 4),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.control)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (t.icon != null) ...[Icon(t.icon, size: 13, color: t.iconColor ?? fg), const SizedBox(width: 5)],
                    Text(
                      t.label,
                      style: uiText(TypeSize.small, color: fg, weight: selected ? FontWeight.w500 : null),
                    ),
                    if (t.count != null) ...[const SizedBox(width: 5), CountBadge(t.count!)],
                    if (t.onClose != null) ...[
                      const SizedBox(width: 2),
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: _hover
                            ? Pressable(
                                onPressed: t.onClose,
                                focusable: false,
                                tooltip: 'Chiudi',
                                builder: (context, cs) => Container(
                                  decoration: BoxDecoration(
                                    color: cs.contains(WidgetState.hovered) ? c.pressed : null,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Icon(AppIcons.close, size: 9, color: c.textSecondary),
                                ),
                              )
                            : null,
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sidebar tabs
// ---------------------------------------------------------------------------

class SidebarTab<T> {
  const SidebarTab(this.value, this.label, this.icon, {this.selectedIcon});

  final T value;
  final String label;

  /// Regular glyph.
  final IconData icon;

  /// Fill glyph shown when selected.
  final IconData? selectedIcon;
}

/// Navigator selector at the top of the sidebar (Xcode style): plain 16pt
/// glyphs in a `subbar`, the selected one in Fill and accent, the others
/// Regular and secondary. No pill, no background.
class SidebarTabs<T> extends StatelessWidget {
  const SidebarTabs({super.key, required this.value, required this.items, required this.onChanged});

  final T value;
  final List<SidebarTab<T>> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      height: BarHeight.subbar,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final it in items)
            Pressable(
              onPressed: () => onChanged(it.value),
              focusable: false,
              tooltip: it.label,
              toggled: it.value == value,
              builder: (context, s) {
                final on = it.value == value;
                final color = on
                    ? (c.windowActive ? c.accent : c.textSecondary)
                    : (s.contains(WidgetState.pressed) ? c.text : c.textSecondary);
                return SizedBox(
                  width: ControlSize.regular + 6,
                  height: ControlSize.regular,
                  child: Center(child: Icon(on ? (it.selectedIcon ?? it.icon) : it.icon, size: 16, color: color)),
                );
              },
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page switcher
// ---------------------------------------------------------------------------

/// Pages of an editor (NSTabView, top tabs): a [Segmented] centered on the
/// hairline that separates the header from the page below.
///
/// [trailing] sits right after the control, on the same backing (the
/// "Dettagli" pull-down of the simple table editor).
class PageSwitcher<T> extends StatelessWidget {
  const PageSwitcher({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.background,
    this.small = false,
    this.trailing,
  });

  final T value;
  final List<(T, String, IconData?)> items;
  final ValueChanged<T>? onChanged;

  /// Fill behind the control, so the hairline does not show through the
  /// recessed track; `content` by default.
  final Color? background;
  final bool small;

  /// Accessory after the [Segmented] (a [PulldownButton]).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final h = small ? ControlSize.small : ControlSize.regular;
    final Widget control = Segmented<T>(value: value, items: items, onChanged: onChanged, small: small);
    return SizedBox(
      height: h,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(left: 0, right: 0, child: Container(height: 0.5, color: c.separator)),
          DecoratedBox(
            decoration: BoxDecoration(
              color: background ?? c.content,
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: trailing == null
                ? control
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      control,
                      const SizedBox(width: Gap.sm),
                      trailing!,
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Path bar
// ---------------------------------------------------------------------------

class PathSegment {
  const PathSegment(this.label, {this.icon, this.iconColor, this.onTap, this.menu, this.tooltip});

  final String label;
  final IconData? icon;
  final Color? iconColor;
  final VoidCallback? onTap;

  /// Siblings to jump to, shown in a menu under the segment.
  final List<MenuEntry<Object?>> Function()? menu;
  final String? tooltip;
}

/// Xcode jump bar / NSPathControl: 22pt, segments with a 14pt icon and a
/// 12pt label split by tertiary ›, the last one semibold. Segments with
/// [PathSegment.onTap] or [PathSegment.menu] are clickable.
class PathBar extends StatelessWidget {
  const PathBar({super.key, required this.segments});

  final List<PathSegment> segments;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return SizedBox(
      height: ControlSize.regular,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(AppIcons.chevronRight, size: 8, color: c.textTertiary),
              ),
            Flexible(
              child: _PathSegmentButton(segment: segments[i], last: i == segments.length - 1),
            ),
          ],
        ],
      ),
    );
  }
}

class _PathSegmentButton extends StatelessWidget {
  const _PathSegmentButton({required this.segment, required this.last});

  final PathSegment segment;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final seg = segment;
    final clickable = seg.onTap != null || seg.menu != null;
    return Builder(
      builder: (anchor) => Pressable(
        focusable: false,
        tooltip: seg.tooltip,
        semanticLabel: seg.label,
        onPressed: !clickable
            ? null
            : () {
                if (seg.menu != null) {
                  showMacMenu<Object?>(anchor, anchor: anchorRect(anchor), entries: seg.menu!());
                } else {
                  seg.onTap!();
                }
              },
        builder: (context, s) {
          Color? bg;
          if (s.contains(WidgetState.pressed)) {
            bg = c.pressed;
          } else if (s.contains(WidgetState.hovered)) {
            bg = c.hover;
          }
          return Container(
            height: ControlSize.regular - 4,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.small)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (seg.icon != null) ...[
                  Icon(seg.icon, size: 14, color: seg.iconColor ?? c.textSecondary),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    seg.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(TypeSize.small, color: c.text, weight: last ? FontWeight.w600 : null),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
