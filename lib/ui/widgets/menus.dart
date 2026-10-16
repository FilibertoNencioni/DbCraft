import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'badges.dart';

// ---------------------------------------------------------------------------
// Shortcuts
// ---------------------------------------------------------------------------

/// Text for a key combination, the one format used by menus, tooltips and
/// sheets: "⌘⇧S", "⌘Invio" on macOS, "Ctrl+Shift+S" elsewhere.
String shortcutLabel(SingleActivator a, {bool? mac}) {
  final isMac = mac ?? Platform.isMacOS;
  final key = _keyName(a.trigger, isMac);
  if (isMac) {
    return [
      if (a.control) '⌃',
      if (a.alt) '⌥',
      if (a.shift) '⇧',
      if (a.meta) '⌘',
      key,
    ].join();
  }
  return [
    if (a.control || a.meta) 'Ctrl',
    if (a.alt) 'Alt',
    if (a.shift) 'Shift',
    key,
  ].join('+');
}

String _keyName(LogicalKeyboardKey k, bool mac) {
  if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) return 'Invio';
  if (k == LogicalKeyboardKey.escape) return 'Esc';
  if (k == LogicalKeyboardKey.space) return 'Spazio';
  if (k == LogicalKeyboardKey.tab) return 'Tab';
  if (k == LogicalKeyboardKey.backspace) return '⌫';
  if (k == LogicalKeyboardKey.delete) return mac ? '⌦' : 'Canc';
  if (k == LogicalKeyboardKey.insert) return 'Ins';
  if (k == LogicalKeyboardKey.arrowUp) return '↑';
  if (k == LogicalKeyboardKey.arrowDown) return '↓';
  if (k == LogicalKeyboardKey.arrowLeft) return '←';
  if (k == LogicalKeyboardKey.arrowRight) return '→';
  final l = k.keyLabel;
  return l.length == 1 ? l.toUpperCase() : l;
}

// ---------------------------------------------------------------------------
// Menu model
// ---------------------------------------------------------------------------

enum _EntryKind { item, divider, header, submenu }

/// One row of a [showMacMenu] menu.
///
/// Items carry a [value] (returned by [showMacMenu]) and/or an [onSelected]
/// callback (run after the menu closes). Sonoma menus show state, not icons:
/// [checked] puts a ✓ in the left column; [leading] is reserved for small
/// state marks such as a connection's status dot.
class MenuEntry<T> {
  const MenuEntry(
    this.label, {
    this.value,
    this.onSelected,
    this.shortcut,
    this.checked = false,
    this.enabled = true,
    this.destructive = false,
    this.leading,
    this.trailing,
  }) : _kind = _EntryKind.item,
       children = const [];

  const MenuEntry.divider()
    : _kind = _EntryKind.divider,
      label = '',
      value = null,
      onSelected = null,
      shortcut = null,
      checked = false,
      enabled = false,
      destructive = false,
      leading = null,
      trailing = null,
      children = const [];

  /// Section title inside a menu (not selectable).
  const MenuEntry.header(this.label)
    : _kind = _EntryKind.header,
      value = null,
      onSelected = null,
      shortcut = null,
      checked = false,
      enabled = false,
      destructive = false,
      leading = null,
      trailing = null,
      children = const [];

  const MenuEntry.submenu(this.label, {required this.children, this.enabled = true})
    : _kind = _EntryKind.submenu,
      value = null,
      onSelected = null,
      shortcut = null,
      checked = false,
      destructive = false,
      leading = null,
      trailing = null;

  /// A connection row: status dot, name and, for test and production, the
  /// environment label on the right.
  factory MenuEntry.connection({
    required String name,
    required Color status,
    String? environment,
    Color? environmentColor,
    T? value,
    VoidCallback? onSelected,
    bool checked = false,
  }) => MenuEntry<T>(
    name,
    value: value,
    onSelected: onSelected,
    checked: checked,
    leading: StatusDot(status),
    trailing: environment == null ? null : Tag(environment, color: environmentColor),
  );

  final _EntryKind _kind;
  final String label;
  final T? value;
  final VoidCallback? onSelected;
  final SingleActivator? shortcut;
  final bool checked;
  final bool enabled;
  final bool destructive;
  final Widget? leading;
  final Widget? trailing;
  final List<MenuEntry<T>> children;

  bool get _selectable => enabled && (_kind == _EntryKind.item || _kind == _EntryKind.submenu);

  double get _height => switch (_kind) {
    _EntryKind.divider => _kDividerHeight,
    _ => _kItemHeight,
  };
}

const double _kItemHeight = 22;
const double _kDividerHeight = 11;
const double _kMenuPadding = 5;
const double _kCheckColumn = 18;
const double _kScreenMargin = 6;

/// Global rect of the widget that owns [context] (anchor for menus and
/// popovers).
Rect anchorRect(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Opens an AppKit-style menu and returns the chosen entry's value.
///
/// Place it with either [position] (context menus: top-left at the pointer)
/// or [anchor] (pull-downs: below the control). With [anchor] and an
/// [initial] value, the menu opens over the control with the current item
/// aligned to it, like NSPopUpButton.
///
/// Keyboard: ↑↓ move, → opens a submenu and ← closes it, Invio or Spazio
/// choose, Esc closes, typing jumps to the first matching item.
Future<T?> showMacMenu<T>(
  BuildContext context, {
  Offset? position,
  Rect? anchor,
  required List<MenuEntry<T>> entries,
  T? initial,
  double minWidth = 0,
  bool alignInitial = true,
}) async {
  assert(position != null || anchor != null);
  if (entries.isEmpty) return null;
  final navigator = Navigator.of(context, rootNavigator: true);
  final initialIndex = initial == null ? -1 : entries.indexWhere((e) => e._kind == _EntryKind.item && e.value == initial);
  final chosen = await navigator.push(
    _MacMenuRoute<T>(
      entries: entries,
      position: position,
      anchor: anchor,
      initialIndex: initialIndex,
      alignInitial: alignInitial && anchor != null && initialIndex >= 0,
      minWidth: minWidth,
      capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
  if (chosen == null) return null;
  chosen.onSelected?.call();
  return chosen.value;
}

class _MacMenuRoute<T> extends PopupRoute<MenuEntry<T>> {
  _MacMenuRoute({
    required this.entries,
    required this.position,
    required this.anchor,
    required this.initialIndex,
    required this.alignInitial,
    required this.minWidth,
    required this.capturedThemes,
  });

  final List<MenuEntry<T>> entries;
  final Offset? position;
  final Rect? anchor;
  final int initialIndex;
  final bool alignInitial;
  final double minWidth;
  final CapturedThemes capturedThemes;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Chiudi menu';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      capturedThemes.wrap(MediaQuery.removePadding(
        context: context,
        removeTop: true,
        removeBottom: true,
        removeLeft: true,
        removeRight: true,
        child: _MenuStack<T>(route: this),
      ));

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => animation.status == AnimationStatus.reverse ? FadeTransition(opacity: animation, child: child) : child;
}

class _Level<T> {
  _Level(this.entries, this.layout, {this.highlight = -1});
  final List<MenuEntry<T>> entries;
  final _MenuLayout layout;
  int highlight;
  final keys = <int, GlobalKey>{};
}

class _MenuStack<T> extends StatefulWidget {
  const _MenuStack({super.key, required this.route});
  final _MacMenuRoute<T> route;

  @override
  State<_MenuStack<T>> createState() => _MenuStackState<T>();
}

class _MenuStackState<T> extends State<_MenuStack<T>> {
  late final List<_Level<T>> _levels;
  final _focus = FocusNode(debugLabel: 'MacMenu');
  String _typed = '';
  Timer? _typedReset;
  Timer? _submenuTimer;

  @override
  void initState() {
    super.initState();
    final r = widget.route;
    final layout = r.alignInitial
        ? _MenuLayout.alignTo(r.anchor!, _offsetOf(r.entries, r.initialIndex), r.minWidth)
        : r.anchor != null
        ? _MenuLayout.below(r.anchor!, r.minWidth)
        : _MenuLayout.at(r.position!, r.minWidth);
    _levels = [_Level<T>(r.entries, layout, highlight: r.alignInitial ? r.initialIndex : -1)];
  }

  @override
  void dispose() {
    _focus.dispose();
    _typedReset?.cancel();
    _submenuTimer?.cancel();
    super.dispose();
  }

  static double _offsetOf(List<MenuEntry<Object?>> entries, int index) {
    var y = _kMenuPadding;
    for (var i = 0; i < index; i++) {
      y += entries[i]._height;
    }
    return y;
  }

  void _choose(MenuEntry<T> e) {
    if (!e.enabled) return;
    if (e._kind == _EntryKind.submenu) return;
    Navigator.of(context).pop(e);
  }

  void _openSubmenu(int level, int index) {
    final e = _levels[level].entries[index];
    if (e._kind != _EntryKind.submenu || !e.enabled || e.children.isEmpty) return;
    final box = _levels[level].keys[index]?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    setState(() {
      _levels.removeRange(level + 1, _levels.length);
      _levels.add(_Level<T>(e.children, _MenuLayout.beside(rect)));
    });
  }

  void _hover(int level, int index) {
    _submenuTimer?.cancel();
    final l = _levels[level];
    final e = l.entries[index];
    setState(() {
      l.highlight = e._selectable ? index : -1;
      if (_levels.length > level + 1 && e._kind != _EntryKind.submenu) {
        _levels.removeRange(level + 1, _levels.length);
      }
    });
    if (e._kind == _EntryKind.submenu && e.enabled) {
      _submenuTimer = Timer(const Duration(milliseconds: 120), () {
        if (mounted && _levels.length <= level + 1) _openSubmenu(level, index);
      });
    }
  }

  void _move(int delta) {
    final l = _levels.last;
    final n = l.entries.length;
    var i = l.highlight;
    for (var step = 0; step < n; step++) {
      i = i < 0 ? (delta > 0 ? 0 : n - 1) : (i + delta) % n;
      if (i < 0) i += n;
      if (l.entries[i]._selectable) {
        setState(() => l.highlight = i);
        return;
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    final l = _levels.last;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      if (l.highlight >= 0) _openSubmenu(_levels.length - 1, l.highlight);
      if (_levels.length > 1 && _levels.last.highlight < 0) _move(1);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.escape) {
      if (_levels.length > 1) {
        setState(() => _levels.removeLast());
      } else {
        Navigator.of(context).pop();
      }
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      if (l.highlight < 0) return KeyEventResult.handled;
      final e = l.entries[l.highlight];
      if (e._kind == _EntryKind.submenu) {
        _openSubmenu(_levels.length - 1, l.highlight);
        _move(1);
      } else {
        _choose(e);
      }
    } else if (event.character case final ch? when ch.trim().isNotEmpty) {
      _typedReset?.cancel();
      _typed += ch.toLowerCase();
      _typedReset = Timer(const Duration(seconds: 1), () => _typed = '');
      final i = l.entries.indexWhere((e) => e._selectable && e.label.toLowerCase().startsWith(_typed));
      if (i >= 0) setState(() => l.highlight = i);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _onKey,
    child: Stack(
      children: [
        for (var i = 0; i < _levels.length; i++)
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _levels[i].layout,
              child: _MenuPanel<T>(
                level: _levels[i],
                onHover: (index) => _hover(i, index),
                onChoose: _choose,
                onOpenSubmenu: (index) => _openSubmenu(i, index),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A menu panel drawn in place, not in an overlay: for the control gallery
/// and screenshots. [highlight] is the row shown under the pointer.
class MacMenuPreview extends StatelessWidget {
  const MacMenuPreview({super.key, required this.entries, this.highlight = -1});

  final List<MenuEntry<Object?>> entries;
  final int highlight;

  @override
  Widget build(BuildContext context) => IntrinsicWidth(
    child: _MenuPanel<Object?>(
      level: _Level(entries, _MenuLayout.at(Offset.zero, 0), highlight: highlight),
      onHover: (_) {},
      onChoose: (_) {},
      onOpenSubmenu: (_) {},
    ),
  );
}

/// Places a menu panel: at a point, below an anchor, beside a submenu item,
/// or over an anchor with a given vertical offset aligned to it.
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout.at(Offset p, this.minWidth) : point = p, anchor = null, alignOffset = null, beside = false;
  _MenuLayout.below(Rect r, this.minWidth) : point = null, anchor = r, alignOffset = null, beside = false;
  _MenuLayout.alignTo(Rect r, double offset, this.minWidth) : point = null, anchor = r, alignOffset = offset, beside = false;
  _MenuLayout.beside(Rect r) : point = null, anchor = r, alignOffset = null, beside = true, minWidth = 0;

  final Offset? point;
  final Rect? anchor;
  final double? alignOffset;
  final bool beside;
  final double minWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxW = constraints.maxWidth - 2 * _kScreenMargin;
    final maxH = constraints.maxHeight - 2 * _kScreenMargin;
    final minW = alignOffset != null ? anchor!.width + _kCheckColumn : minWidth;
    return BoxConstraints(minWidth: math.min(minW, maxW), maxWidth: maxW, maxHeight: maxH);
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    double x;
    double y;
    if (point case final p?) {
      x = p.dx;
      y = p.dy;
      if (x + child.width > size.width - _kScreenMargin) x = p.dx - child.width;
      if (y + child.height > size.height - _kScreenMargin) y = p.dy - child.height;
    } else if (beside) {
      final a = anchor!;
      x = a.right + _kMenuPadding - 1;
      y = a.top - _kMenuPadding;
      if (x + child.width > size.width - _kScreenMargin) x = a.left - _kMenuPadding - child.width + 1;
    } else if (alignOffset case final off?) {
      final a = anchor!;
      // The item's text lines up with the control's title.
      x = a.left - _kMenuPadding - _kCheckColumn + 2;
      y = a.center.dy - off - _kItemHeight / 2;
    } else {
      final a = anchor!;
      x = a.left;
      y = a.bottom + 3;
      if (y + child.height > size.height - _kScreenMargin && a.top - child.height - 3 > _kScreenMargin) {
        y = a.top - child.height - 3;
      }
    }
    x = x.clamp(_kScreenMargin, math.max(_kScreenMargin, size.width - child.width - _kScreenMargin));
    y = y.clamp(_kScreenMargin, math.max(_kScreenMargin, size.height - child.height - _kScreenMargin));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout old) =>
      old.point != point || old.anchor != anchor || old.alignOffset != alignOffset || old.beside != beside;
}

/// Shared look of menus and completion lists.
BoxDecoration menuDecoration(BuildContext context) {
  final c = DbColors.of(context);
  return BoxDecoration(
    color: c.menuBackground,
    borderRadius: BorderRadius.circular(Radii.menu),
    border: Border.all(color: c.separator, width: 0.5),
    boxShadow: Elevation.menu(Theme.of(context).brightness),
  );
}

class _MenuPanel<T> extends StatelessWidget {
  const _MenuPanel({
    super.key,
    required this.level,
    required this.onHover,
    required this.onChoose,
    required this.onOpenSubmenu,
  });

  final _Level<T> level;
  final ValueChanged<int> onHover;
  final ValueChanged<MenuEntry<T>> onChoose;
  final ValueChanged<int> onOpenSubmenu;

  @override
  Widget build(BuildContext context) {
    final entries = level.entries;
    final checkColumn = entries.any((e) => e.checked || e.leading != null);
    return Container(
      decoration: menuDecoration(context),
      constraints: const BoxConstraints(minWidth: 120),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.menu),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(_kMenuPadding),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < entries.length; i++)
                  _MenuRow<T>(
                    key: level.keys.putIfAbsent(i, GlobalKey.new),
                    entry: entries[i],
                    highlighted: level.highlight == i,
                    checkColumn: checkColumn,
                    onHover: () => onHover(i),
                    onTap: () => entries[i]._kind == _EntryKind.submenu ? onOpenSubmenu(i) : onChoose(entries[i]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({
    super.key,
    required this.entry,
    required this.highlighted,
    required this.checkColumn,
    required this.onHover,
    required this.onTap,
  });

  final MenuEntry<T> entry;
  final bool highlighted;
  final bool checkColumn;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    switch (entry._kind) {
      case _EntryKind.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          child: Container(height: 1, color: c.separator),
        );
      case _EntryKind.header:
        return Container(
          height: _kItemHeight,
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.only(left: checkColumn ? _kCheckColumn + 2 : 9, right: 9),
          child: Text(entry.label, style: uiText(TypeSize.caption, weight: FontWeight.w600, color: c.textSecondary)),
        );
      case _EntryKind.item:
      case _EntryKind.submenu:
        break;
    }
    final on = highlighted && entry.enabled;
    final fg = !entry.enabled
        ? c.textTertiary
        : on
        ? c.onAccent
        : (entry.destructive ? c.danger : c.text);
    final secondary = on ? c.onAccent.withValues(alpha: 0.85) : c.textSecondary;
    return MouseRegion(
      onEnter: (_) => onHover(),
      onHover: (_) {
        if (!highlighted) onHover();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: entry.enabled ? onTap : null,
        child: Container(
          height: _kItemHeight,
          padding: const EdgeInsets.only(right: 9),
          decoration: BoxDecoration(
            color: on ? c.accent : null,
            borderRadius: BorderRadius.circular(Radii.small),
          ),
          child: RowTint(
            background: on ? c.accent : c.menuBackground,
            emphasized: on,
            child: Row(
              children: [
                SizedBox(
                  width: checkColumn ? _kCheckColumn + 2 : 9,
                  child: !checkColumn
                      ? null
                      : Center(
                          child: entry.checked
                              ? Icon(AppIcons.check, size: 12, color: fg)
                              : entry.leading,
                        ),
                ),
                Expanded(
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(TypeSize.body, color: fg),
                  ),
                ),
                if (entry.trailing != null) ...[const SizedBox(width: Gap.md), entry.trailing!],
                if (entry.shortcut != null) ...[
                  const SizedBox(width: Gap.xl),
                  Text(shortcutLabel(entry.shortcut!), style: uiText(TypeSize.body, color: entry.enabled ? secondary : c.textTertiary)),
                ],
                if (entry._kind == _EntryKind.submenu) ...[
                  const SizedBox(width: Gap.xl),
                  Icon(AppIcons.chevronRight, size: 10, color: on ? c.onAccent : c.textSecondary),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Popover
// ---------------------------------------------------------------------------

/// Opens a popover (NSPopover) attached to [anchor]: raised panel, radius
/// 10, an arrow pointing at the anchor. Closes on Esc or a click outside.
Future<T?> showPopover<T>(
  BuildContext context, {
  required Rect anchor,
  required WidgetBuilder builder,
  AxisDirection preferred = AxisDirection.down,
  bool arrow = true,
  EdgeInsets padding = const EdgeInsets.all(Gap.md),
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push(
    _PopoverRoute<T>(
      anchor: anchor,
      builder: builder,
      preferred: preferred,
      arrow: arrow,
      padding: padding,
      capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}

class _PopoverRoute<T> extends PopupRoute<T> {
  _PopoverRoute({
    required this.anchor,
    required this.builder,
    required this.preferred,
    required this.arrow,
    required this.padding,
    required this.capturedThemes,
  });

  final Rect anchor;
  final WidgetBuilder builder;
  final AxisDirection preferred;
  final bool arrow;
  final EdgeInsets padding;
  final CapturedThemes capturedThemes;

  /// Side the popover opened on, decided at layout, read by the arrow.
  final _direction = ValueNotifier(AxisDirection.down);

  @override
  void dispose() {
    _direction.dispose();
    super.dispose();
  }

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Chiudi';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final c = DbColors.of(context);
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(Radii.sheet),
        border: Border.all(color: c.separator, width: 0.5),
        boxShadow: Elevation.popover(Theme.of(context).brightness),
      ),
      child: Builder(builder: builder),
    );
    return capturedThemes.wrap(
      CustomMultiChildLayout(
        delegate: _PopoverLayout(anchor, preferred, arrow, _direction),
        children: [
          LayoutId(id: _PopoverPart.body, child: Material(type: MaterialType.transparency, child: body)),
          if (arrow)
            LayoutId(
              id: _PopoverPart.arrow,
              child: CustomPaint(painter: _ArrowPainter(c.raised, c.separator, _direction)),
            ),
        ],
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut), child: child);
}

enum _PopoverPart { body, arrow }

const double _kArrowWidth = 16;
const double _kArrowHeight = 7;

class _PopoverLayout extends MultiChildLayoutDelegate {
  _PopoverLayout(this.anchor, this.preferred, this.arrow, this.direction);
  final Rect anchor;
  final AxisDirection preferred;
  final bool arrow;
  final ValueNotifier<AxisDirection> direction;

  @override
  void performLayout(Size size) {
    const m = _kScreenMargin * 2;
    final gap = arrow ? _kArrowHeight : 4.0;
    final body = layoutChild(
      _PopoverPart.body,
      BoxConstraints.loose(Size(size.width - 2 * m, size.height - 2 * m)),
    );
    final vertical = preferred == AxisDirection.down || preferred == AxisDirection.up;
    var dir = preferred;
    if (vertical) {
      final roomBelow = size.height - anchor.bottom - m;
      final roomAbove = anchor.top - m;
      if (dir == AxisDirection.down && body.height + gap > roomBelow && roomAbove > roomBelow) dir = AxisDirection.up;
      if (dir == AxisDirection.up && body.height + gap > roomAbove && roomBelow > roomAbove) dir = AxisDirection.down;
    } else {
      final roomRight = size.width - anchor.right - m;
      final roomLeft = anchor.left - m;
      if (dir == AxisDirection.right && body.width + gap > roomRight && roomLeft > roomRight) dir = AxisDirection.left;
      if (dir == AxisDirection.left && body.width + gap > roomLeft && roomRight > roomLeft) dir = AxisDirection.right;
    }
    direction.value = dir;
    double x;
    double y;
    switch (dir) {
      case AxisDirection.down:
        x = anchor.center.dx - body.width / 2;
        y = anchor.bottom + gap;
      case AxisDirection.up:
        x = anchor.center.dx - body.width / 2;
        y = anchor.top - gap - body.height;
      case AxisDirection.right:
        x = anchor.right + gap;
        y = anchor.center.dy - body.height / 2;
      case AxisDirection.left:
        x = anchor.left - gap - body.width;
        y = anchor.center.dy - body.height / 2;
    }
    x = x.clamp(m, math.max(m, size.width - body.width - m));
    y = y.clamp(m, math.max(m, size.height - body.height - m));
    positionChild(_PopoverPart.body, Offset(x, y));
    if (!hasChild(_PopoverPart.arrow)) return;
    final horizontalArrow = dir == AxisDirection.down || dir == AxisDirection.up;
    final arrowSize = layoutChild(
      _PopoverPart.arrow,
      BoxConstraints.tight(horizontalArrow ? const Size(_kArrowWidth, _kArrowHeight) : const Size(_kArrowHeight, _kArrowWidth)),
    );
    const inset = Radii.sheet + 2;
    final ax = (anchor.center.dx - arrowSize.width / 2).clamp(x + inset, x + body.width - inset - arrowSize.width);
    final ay = (anchor.center.dy - arrowSize.height / 2).clamp(y + inset, y + body.height - inset - arrowSize.height);
    positionChild(_PopoverPart.arrow, switch (dir) {
      // Overlap the body by 1px so the arrow covers its hairline.
      AxisDirection.down => Offset(ax, y - _kArrowHeight + 1),
      AxisDirection.up => Offset(ax, y + body.height - 1),
      AxisDirection.right => Offset(x - _kArrowHeight + 1, ay),
      AxisDirection.left => Offset(x + body.width - 1, ay),
    });
  }

  @override
  bool shouldRelayout(_PopoverLayout old) => old.anchor != anchor || old.preferred != preferred || old.arrow != arrow;
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.fill, this.stroke, this.direction) : super(repaint: direction);
  final Color fill;
  final Color stroke;
  final ValueNotifier<AxisDirection> direction;

  @override
  void paint(Canvas canvas, Size size) {
    final dir = direction.value;
    // Points: base start, tip, base end, in the arrow's own box.
    final (a, tip, b) = switch (dir) {
      AxisDirection.down => (Offset(0, size.height), Offset(size.width / 2, 0), Offset(size.width, size.height)),
      AxisDirection.up => (Offset.zero, Offset(size.width / 2, size.height), Offset(size.width, 0)),
      AxisDirection.right => (Offset(size.width, 0), Offset(0, size.height / 2), Offset(size.width, size.height)),
      AxisDirection.left => (Offset.zero, Offset(size.width, size.height / 2), Offset(0, size.height)),
    };
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(b.dx, b.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(b.dx, b.dy),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = stroke,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.fill != fill || old.stroke != stroke || old.direction != direction;
}

// ---------------------------------------------------------------------------
// Completion list
// ---------------------------------------------------------------------------

/// Kind of a completion, shown as a letter badge (Xcode style).
enum CompletionKind {
  keyword('K'),
  function('F'),
  table('T'),
  view('V'),
  column('C'),
  type('Y');

  const CompletionKind(this.letter);
  final String letter;

  Color color(DbColors c) => switch (this) {
    CompletionKind.keyword => c.codeKeyword,
    CompletionKind.function => c.codeFunction,
    CompletionKind.table || CompletionKind.view => c.codeTable,
    CompletionKind.column => c.codeColumn,
    CompletionKind.type => c.codeType,
  };
}

/// Letter in a 14pt rounded square, tinted with the kind's code color.
class CompletionBadge extends StatelessWidget {
  const CompletionBadge(this.kind, {super.key, this.onAccent = false});
  final CompletionKind kind;

  /// Drawn on a selected (accent) row: white letter on a white tint.
  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final color = onAccent ? c.onAccent : kind.color(c);
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withValues(alpha: Tint.strong), borderRadius: BorderRadius.circular(3)),
      child: Text(kind.letter, style: uiText(TypeSize.mini, weight: FontWeight.w700, color: color, height: 1)),
    );
  }
}

class CompletionItem {
  const CompletionItem(this.label, this.kind, {this.detail});
  final String label;
  final CompletionKind kind;

  /// Right-aligned hint (column type, owner table).
  final String? detail;
}

/// Autocomplete popup of the SQL editor: menu surface, 20pt rows, letter
/// badge, monospaced name, tertiary detail, accent selection.
class CompletionList extends StatefulWidget {
  const CompletionList({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelect,
    this.width = 380,
    this.maxHeight = 240,
  });

  final List<CompletionItem> items;
  final int selected;
  final ValueChanged<int> onSelect;
  final double width;
  final double maxHeight;

  static const double rowHeight = 20;

  /// Height for [count] rows, including the frame.
  static double heightFor(int count, {double maxHeight = 240}) =>
      math.min(rowHeight * count + 2 * 4, maxHeight) + 1;

  @override
  State<CompletionList> createState() => _CompletionListState();
}

class _CompletionListState extends State<CompletionList> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(CompletionList old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  void _reveal() {
    if (!_scroll.hasClients) return;
    final top = widget.selected * CompletionList.rowHeight;
    final vh = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + CompletionList.rowHeight > _scroll.offset + vh) {
      _scroll.jumpTo(top + CompletionList.rowHeight - vh);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      width: widget.width,
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      decoration: menuDecoration(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.menu),
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(4),
          shrinkWrap: true,
          itemExtent: CompletionList.rowHeight,
          itemCount: widget.items.length,
          itemBuilder: (context, i) {
            final it = widget.items[i];
            final on = i == widget.selected;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onSelect(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: on ? c.accent : null,
                  borderRadius: BorderRadius.circular(Radii.small),
                ),
                child: Row(
                  children: [
                    CompletionBadge(it.kind, onAccent: on),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        it.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                          fontSize: TypeSize.mono,
                          color: on ? c.onAccent : c.text,
                        ),
                      ),
                    ),
                    if (it.detail != null)
                      Padding(
                        padding: const EdgeInsets.only(left: Gap.sm),
                        child: Text(
                          it.detail!,
                          style: uiText(TypeSize.caption, color: on ? c.onAccent.withValues(alpha: 0.85) : c.textTertiary),
                        ),
                      ),
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
// Tooltips
// ---------------------------------------------------------------------------

/// Tooltip with a semibold title and key/value lines (grid column headers,
/// chart points). Uses the app tooltip style and delay.
class RichTooltip extends StatelessWidget {
  const RichTooltip({super.key, required this.title, this.rows = const [], this.footer, required this.child});

  final String title;
  final List<(String, String)> rows;
  final String? footer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final label = uiText(TypeSize.caption, color: c.textSecondary);
    final value = uiText(TypeSize.caption, color: c.text, features: kTabular);
    return Tooltip(
      richMessage: TextSpan(
        children: [
          TextSpan(text: title, style: uiText(TypeSize.caption, weight: FontWeight.w600, color: c.text)),
          for (final (k, v) in rows) ...[
            const TextSpan(text: '\n'),
            TextSpan(text: '$k  ', style: label),
            TextSpan(text: v, style: value),
          ],
          if (footer != null) ...[const TextSpan(text: '\n'), TextSpan(text: footer, style: label)],
        ],
      ),
      child: child,
    );
  }
}
