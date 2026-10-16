import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'badges.dart';
import 'buttons.dart';
import 'progress.dart';
import 'surfaces.dart';

/// Height of a source-list row (macOS medium sidebar size).
const double kSidebarRowHeight = 28;

/// Height of a dense outline row (diff trees, file lists, inspectors).
const double kDenseRowHeight = 24;

// ---------------------------------------------------------------------------
// Section label
// ---------------------------------------------------------------------------

/// Group title in a sidebar or list: 11 semibold secondary, optional
/// [trailing] on the right.
///
/// With [onToggle] the group collapses like a Finder sidebar section: the
/// title toggles it and "Mostra" / "Nascondi" appears on hover.
class SectionLabel extends StatefulWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.padding, this.expanded = true, this.onToggle});

  final String text;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;
  final bool expanded;
  final ValueChanged<bool>? onToggle;

  @override
  State<SectionLabel> createState() => _SectionLabelState();
}

class _SectionLabelState extends State<SectionLabel> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final toggle = widget.onToggle;
    Widget row = Padding(
      padding: widget.padding ?? const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.sm, Gap.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: uiText(TypeSize.caption, weight: FontWeight.w600, color: c.textSecondary),
            ),
          ),
          if (toggle != null && (_hover || !widget.expanded))
            Padding(
              padding: const EdgeInsets.only(left: Gap.sm),
              child: Text(
                widget.expanded ? 'Nascondi' : 'Mostra',
                style: uiText(TypeSize.caption, weight: FontWeight.w500, color: c.textTertiary),
              ),
            ),
          ?widget.trailing,
        ],
      ),
    );
    if (toggle == null) return row;
    row = GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => toggle(!widget.expanded), child: row);
    return Semantics(
      button: true,
      expanded: widget.expanded,
      label: widget.text,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: row,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Source list
// ---------------------------------------------------------------------------

/// Focus state of the enclosing [SourceList]. Rows read it to pick their
/// selection: the solid accent while the list has focus, `selectionMuted`
/// otherwise.
class SourceListScope extends InheritedWidget {
  const SourceListScope({
    super.key,
    required this.focused,
    required this.background,
    this.requestFocus,
    required super.child,
  });

  final bool focused;

  /// The list fill (rows ring their icon badges with it).
  final Color background;

  /// Gives the list keyboard focus (rows call it on click).
  final VoidCallback? requestFocus;

  static SourceListScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SourceListScope>();

  @override
  bool updateShouldNotify(SourceListScope old) => old.focused != focused || old.background != background;
}

/// A sidebar or outline list (NSOutlineView, source list style) with fixed
/// height rows ([OutlineRow], [SectionLabel]), keyboard navigation and the
/// focus-dependent selection.
///
/// ↑/↓ move [selectedIndex] (skipping rows [selectable] rejects), →/←
/// expand and collapse via [onExpand], Invio calls [onActivate]. Rows are
/// inset [Gap.sm] + 2 from the edges, as in Finder.
class SourceList extends StatefulWidget {
  const SourceList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.selectedIndex,
    this.onSelect,
    this.onActivate,
    this.onExpand,
    this.selectable,
    this.dense = false,
    this.focusNode,
    this.autofocus = false,
    this.controller,
    this.background,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: Gap.xs),
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final int? selectedIndex;
  final ValueChanged<int>? onSelect;
  final ValueChanged<int>? onActivate;

  /// Expand (true) or collapse (false) the row at an index.
  final void Function(int index, bool expand)? onExpand;

  /// Whether the keyboard can select a row (false for headers).
  final bool Function(int index)? selectable;

  /// 24pt rows instead of 28.
  final bool dense;
  final FocusNode? focusNode;
  final bool autofocus;
  final ScrollController? controller;

  /// List fill, `sidebar` by default.
  final Color? background;
  final EdgeInsets padding;

  double get rowHeight => dense ? kDenseRowHeight : kSidebarRowHeight;

  @override
  State<SourceList> createState() => _SourceListState();
}

class _SourceListState extends State<SourceList> {
  FocusNode? _ownFocus;
  ScrollController? _ownScroll;
  bool _focused = false;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'SourceList'));
  ScrollController get _scroll => widget.controller ?? (_ownScroll ??= ScrollController());

  @override
  void dispose() {
    _ownFocus?.dispose();
    _ownScroll?.dispose();
    super.dispose();
  }

  void _reveal(int i) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final top = widget.padding.top + i * widget.rowHeight;
    final bottom = top + widget.rowHeight;
    if (top < pos.pixels) {
      _scroll.jumpTo(top - widget.padding.top);
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(math.min(bottom - pos.viewportDimension + widget.padding.bottom, pos.maxScrollExtent));
    }
  }

  void _step(int delta) {
    final n = widget.itemCount;
    if (n == 0 || widget.onSelect == null) return;
    var i = widget.selectedIndex ?? (delta > 0 ? -1 : n);
    for (;;) {
      i += delta;
      if (i < 0 || i >= n) return;
      if (widget.selectable?.call(i) ?? true) break;
    }
    widget.onSelect!(i);
    _reveal(i);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final sel = widget.selectedIndex;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _step(1);
      case LogicalKeyboardKey.arrowUp:
        _step(-1);
      case LogicalKeyboardKey.arrowRight when sel != null && widget.onExpand != null:
        widget.onExpand!(sel, true);
      case LogicalKeyboardKey.arrowLeft when sel != null && widget.onExpand != null:
        widget.onExpand!(sel, false);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter when sel != null && widget.onActivate != null:
        widget.onActivate!(sel);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.background ?? DbColors.of(context).sidebar;
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      onFocusChange: (v) => setState(() => _focused = v),
      child: SourceListScope(
        focused: _focused,
        background: bg,
        requestFocus: _focus.requestFocus,
        child: ColoredBox(
          color: bg,
          child: ListView.builder(
            controller: _scroll,
            padding: widget.padding,
            itemExtent: widget.rowHeight,
            itemCount: widget.itemCount,
            itemBuilder: widget.itemBuilder,
          ),
        ),
      ),
    );
  }
}

/// Fires [onTap] at once and [onDoubleTap] on a second click within the
/// double-tap timeout. A GestureDetector `onDoubleTap` would instead delay
/// every single click by that timeout.
mixin _DoubleClick<T extends StatefulWidget> on State<T> {
  DateTime? _lastTap;

  void handleTap(VoidCallback? onTap, VoidCallback? onDoubleTap) {
    final now = DateTime.now();
    final last = _lastTap;
    final isDouble = onDoubleTap != null && last != null && now.difference(last) <= kDoubleTapTimeout;
    _lastTap = isDouble ? null : now;
    if (isDouble) {
      onDoubleTap();
    } else {
      onTap?.call();
    }
  }
}

/// Selection look shared by [OutlineRow] and [ListRow].
({Color? fill, Color fg, Color secondary, bool emphasized}) _rowColors(
  BuildContext context, {
  required bool selected,
  required bool hover,
}) {
  final c = DbColors.of(context);
  final focused = SourceListScope.maybeOf(context)?.focused ?? false;
  if (selected && focused) {
    final on = c.windowActive;
    return (
      fill: c.selectionEmphasized,
      fg: on ? c.onSelectionEmphasized : c.text,
      secondary: on ? c.onSelectionEmphasized.withValues(alpha: 0.8) : c.textSecondary,
      emphasized: on,
    );
  }
  return (
    fill: selected ? c.selectionMuted : (hover ? c.hover : null),
    fg: c.text,
    secondary: c.textSecondary,
    emphasized: false,
  );
}

/// A row of a [SourceList]: disclosure chevron (16pt slot, 16pt indent per
/// [depth]), 16pt icon, 13pt title, tertiary tabular [detail] on the right,
/// [accessories] ([CountBadge], [EnvDot], [StatusLetter], [Tag]) and a "…"
/// on hover when [onMenu] is set.
///
/// The selection is the solid accent with white text while the list has
/// focus in the key window, `selectionMuted` otherwise; radius 5.
class OutlineRow extends StatefulWidget {
  const OutlineRow({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
    this.iconBadge,
    this.leading,
    this.depth = 0,
    this.expanded,
    this.onExpand,
    this.busy = false,
    this.reserveDisclosure = false,
    this.detail,
    this.accessories = const [],
    this.selected = false,
    this.dense = false,
    this.muted = false,
    this.strong = false,
    this.titleColor,
    this.onTap,
    this.onDoubleTap,
    this.onMenu,
    this.tooltip,
  });

  final String title;
  final IconData? icon;
  final Color? iconColor;

  /// Status dot over the icon ([IconBadge]).
  final Color? iconBadge;

  /// Replaces the icon (a spinner while loading, a checkbox).
  final Widget? leading;
  final int depth;

  /// Disclosure state; null for a leaf.
  final bool? expanded;
  final ValueChanged<bool>? onExpand;

  /// A small [Spinner] replaces the chevron (children loading, connecting);
  /// the row still selects but does not toggle.
  final bool busy;

  /// Keeps the chevron slot on a root leaf, to align with expandable rows.
  final bool reserveDisclosure;
  final String? detail;
  final List<Widget> accessories;
  final bool selected;
  final bool dense;

  /// Secondary title (disconnected, unavailable).
  final bool muted;

  /// Semibold title (the current catalog, an open connection).
  final bool strong;

  /// Title color when the row is not on the accent (`danger` for errors).
  final Color? titleColor;
  final VoidCallback? onTap;

  /// Defaults to toggling [expanded] for parent rows.
  final VoidCallback? onDoubleTap;

  /// Opens the row's context menu at a global position.
  final void Function(Offset globalPosition)? onMenu;
  final String? tooltip;

  @override
  State<OutlineRow> createState() => _OutlineRowState();
}

class _OutlineRowState extends State<OutlineRow> with _DoubleClick {
  bool _hover = false;
  final _menuKey = GlobalKey();

  void _openMenuFromButton() {
    final box = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    widget.onMenu!(box.localToGlobal(Offset(0, box.size.height + 2)));
  }

  VoidCallback? get _toggle {
    final e = widget.expanded;
    final f = widget.onExpand;
    return e == null || f == null || widget.busy ? null : () => f(!e);
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final scope = SourceListScope.maybeOf(context);
    final look = _rowColors(context, selected: widget.selected, hover: _hover);
    final listBg = scope?.background ?? c.sidebar;
    final showMenu = widget.onMenu != null && _hover;
    final slot = widget.expanded != null || widget.busy || widget.reserveDisclosure || widget.depth > 0;

    Widget? icon = widget.leading;
    if (icon == null && widget.icon != null) {
      icon = Icon(
        widget.icon,
        size: 16,
        color: look.emphasized ? look.fg : (widget.iconColor ?? (widget.muted ? c.textTertiary : c.textSecondary)),
      );
      if (widget.iconBadge != null) icon = IconBadge(color: widget.iconBadge, child: icon);
    }

    final row = Container(
      height: widget.dense ? kDenseRowHeight : kSidebarRowHeight,
      padding: EdgeInsets.only(left: 4.0 + widget.depth * 16, right: 4),
      decoration: BoxDecoration(color: look.fill, borderRadius: BorderRadius.circular(Radii.control)),
      child: RowTint(
        background: look.fill == null ? listBg : Color.alphaBlend(look.fill!, listBg),
        emphasized: look.emphasized,
        child: Row(
          children: [
            if (slot)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggle,
                child: SizedBox(
                  width: 16,
                  height: double.infinity,
                  child: widget.busy
                      ? Center(
                          child: Spinner(size: Spinner.small, color: look.emphasized ? look.secondary : null),
                        )
                      : widget.expanded == null
                      ? null
                      : Center(
                          child: DisclosureChevron(
                            expanded: widget.expanded!,
                            color: look.emphasized ? look.secondary : null,
                          ),
                        ),
                ),
              )
            else
              const SizedBox(width: 2),
            if (icon != null) ...[SizedBox(width: 18, child: Center(child: icon)), const SizedBox(width: 6)],
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: uiText(
                  TypeSize.body,
                  weight: widget.strong ? FontWeight.w600 : null,
                  color: look.emphasized ? look.fg : (widget.titleColor ?? (widget.muted ? c.textSecondary : c.text)),
                ),
              ),
            ),
            if (showMenu)
              SizedBox(
                key: _menuKey,
                child: ToolButton(
                  icon: AppIcons.more,
                  tooltip: 'Azioni',
                  extent: 20,
                  color: look.emphasized ? look.fg : null,
                  onPressed: _openMenuFromButton,
                ),
              )
            else ...[
              for (final a in widget.accessories) Padding(padding: const EdgeInsets.only(left: 6), child: a),
              // Shares the free space with the title, so a long detail ends
              // in an ellipsis instead of overflowing the row.
              if (widget.detail != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: Gap.sm, right: 2),
                    child: Text(
                      widget.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: uiText(
                        TypeSize.small,
                        color: look.emphasized ? look.secondary : c.textTertiary,
                        features: kTabular,
                      ),
                    ),
                  ),
                ),
            ],
            const SizedBox(width: 2),
          ],
        ),
      ),
    );

    Widget child = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => scope?.requestFocus?.call(),
        onTap: () => handleTap(widget.onTap, widget.onDoubleTap ?? _toggle),
        onSecondaryTapDown: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
        child: row,
      ),
    );
    if (widget.tooltip != null) child = Tooltip(message: widget.tooltip!, child: child);
    return Semantics(selected: widget.selected, expanded: widget.expanded, label: widget.title, child: child);
  }
}

/// Kept for the sidebar call sites: a root [OutlineRow] with an icon.
class SidebarRow extends StatelessWidget {
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
  Widget build(BuildContext context) => OutlineRow(
    icon: icon,
    iconColor: iconColor,
    title: title,
    detail: detail,
    selected: selected,
    onTap: onTap,
    onMenu: onMenu,
    tooltip: tooltip,
  );
}

// ---------------------------------------------------------------------------
// List rows
// ---------------------------------------------------------------------------

/// A row in a content list (history, log, commits, pickers, catalogs): 24pt
/// single line, 38pt with a [subtitle] (11 secondary), 16pt leading icon,
/// a [trailing] accessory (small [PushButton], [LinkButton], [Tag], text).
///
/// Selection follows [SourceList]; with [zebra] the rows alternate the
/// `zebra` fill edge to edge (pass [index]).
class ListRow extends StatefulWidget {
  const ListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.leading,
    this.trailing,
    this.selected = false,
    this.zebra = false,
    this.index = 0,
    this.mono = false,
    this.titleColor,
    this.onTap,
    this.onDoubleTap,
    this.onMenu,
    this.tooltip,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;

  /// Replaces the icon (a status dot, a spinner).
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final bool zebra;
  final int index;

  /// Monospaced title (SQL, log lines).
  final bool mono;
  final Color? titleColor;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final void Function(Offset globalPosition)? onMenu;
  final String? tooltip;

  static const double height = 24;
  static const double doubleHeight = 38;

  @override
  State<ListRow> createState() => _ListRowState();
}

class _ListRowState extends State<ListRow> with _DoubleClick {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final interactive = widget.onTap != null || widget.onDoubleTap != null;
    final look = _rowColors(context, selected: widget.selected, hover: _hover && interactive);
    final zebraFill = widget.zebra && widget.index.isOdd ? c.zebra : null;
    final fill = look.fill ?? zebraFill;
    final fg = look.emphasized ? look.fg : (widget.titleColor ?? c.text);
    final titleStyle = widget.mono
        ? TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: TypeSize.mono, color: fg)
        : uiText(TypeSize.body, color: fg);

    Widget? lead = widget.leading;
    if (lead == null && widget.icon != null) {
      lead = Icon(widget.icon, size: 16, color: look.emphasized ? look.fg : (widget.iconColor ?? c.textSecondary));
    }

    final row = Container(
      height: widget.subtitle == null ? ListRow.height : ListRow.doubleHeight,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(color: fill, borderRadius: widget.zebra ? null : BorderRadius.circular(Radii.control)),
      child: RowTint(
        background: fill,
        emphasized: look.emphasized,
        child: Row(
          children: [
            if (lead != null) ...[SizedBox(width: 18, child: Center(child: lead)), const SizedBox(width: Gap.sm)],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                  if (widget.subtitle != null)
                    Text(
                      widget.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: uiText(TypeSize.caption, color: look.emphasized ? look.secondary : c.textSecondary),
                    ),
                ],
              ),
            ),
            if (widget.trailing != null) ...[const SizedBox(width: Gap.sm), widget.trailing!],
          ],
        ),
      ),
    );

    Widget child = row;
    if (interactive || widget.onMenu != null) {
      final scope = SourceListScope.maybeOf(context);
      child = MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => scope?.requestFocus?.call(),
          onTap: interactive ? () => handleTap(widget.onTap, widget.onDoubleTap) : null,
          onSecondaryTapDown: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
          child: row,
        ),
      );
    }
    if (widget.tooltip != null) child = Tooltip(message: widget.tooltip!, child: child);
    return Semantics(selected: widget.selected, label: widget.title, child: child);
  }
}

// ---------------------------------------------------------------------------
// Record view
// ---------------------------------------------------------------------------

/// One field of a [RecordView].
class RecordField {
  const RecordField(this.name, this.value, {this.type, this.changed = false, this.mono = false});

  final String name;

  /// Display text; null shows NULL.
  final String? value;

  /// Column type under the name ([TypeLabel], mono).
  final String? type;

  /// Edited and not saved yet: tinted with `diffChanged`.
  final bool changed;
  final bool mono;
}

/// A row shown as a form (record view of the results): read-only
/// [FormGroup] with the name and its type on the left (200pt) and the
/// selectable value on the right. Changed values take `diffChanged`.
class RecordView extends StatelessWidget {
  const RecordView({super.key, required this.fields, this.title, this.labelWidth = 200, this.nullText = 'NULL'});

  final List<RecordField> fields;
  final String? title;
  final double labelWidth;
  final String nullText;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return FormGroup(
      title: title,
      labelWidth: labelWidth,
      children: [
        for (final f in fields)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: labelWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: uiText(TypeSize.body, color: c.text),
                    ),
                    if (f.type != null) TypeLabel(f.type!.toLowerCase(), mono: true),
                  ],
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Container(
                  padding: f.changed ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1) : null,
                  decoration: f.changed
                      ? BoxDecoration(
                          color: c.diffChanged.withValues(alpha: Tint.regular),
                          borderRadius: BorderRadius.circular(Radii.small),
                        )
                      : null,
                  child: SelectableText(
                    f.value ?? nullText,
                    minLines: 1,
                    maxLines: 8,
                    style: f.value == null
                        ? uiText(TypeSize.small, color: c.textTertiary, style: FontStyle.italic)
                        : f.mono
                        ? TextStyle(
                            fontFamily: kMonoFamily,
                            fontFamilyFallback: kMonoFallback,
                            fontSize: TypeSize.mono,
                            color: c.text,
                            height: 1.35,
                          )
                        : uiText(TypeSize.body, color: c.text, features: kTabular),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
