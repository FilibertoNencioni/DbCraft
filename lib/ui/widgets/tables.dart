import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'badges.dart';
import 'feedback.dart';
import 'menus.dart';
import 'surfaces.dart';

/// Row and header heights shared by the data grid and [MacTable].
abstract final class GridMetrics {
  static const double header = 24;
  static const double row = 24;

  /// Width of the edit-state marker at the start of a row.
  static const double marker = 3;
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

/// Column resize grip at the right edge of a header cell: the separator
/// line (header only), a 7pt hit area with the resize cursor. Drag to
/// resize, double click to fit.
class ColumnResizeHandle extends StatelessWidget {
  const ColumnResizeHandle({super.key, required this.onDrag, this.onReset});

  final ValueChanged<double> onDrag;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      onDoubleTap: onReset,
      child: const SizedBox(width: 7, height: double.infinity),
    ),
  );
}

/// One header cell of a table: 12 semibold name, an optional [TypeLabel],
/// the sort chevron (˄ ˅) on the right, the column separator and, with
/// [onResize], a [ColumnResizeHandle].
class TableHeaderCell extends StatelessWidget {
  const TableHeaderCell({
    super.key,
    required this.label,
    this.type,
    this.leading,
    this.sorted,
    this.alignEnd = false,
    this.onTap,
    this.onSecondaryTapDown,
    this.onResize,
    this.onResetWidth,
    this.fontSize = TypeSize.small,
    this.separator = true,
  });

  final String label;
  final String? type;

  /// A mark before the name (primary key).
  final Widget? leading;

  /// Sort direction (true ascending), or null when not sorted.
  final bool? sorted;

  /// Right-align the name (numeric columns).
  final bool alignEnd;
  final VoidCallback? onTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final ValueChanged<double>? onResize;
  final VoidCallback? onResetWidth;
  final double fontSize;
  final bool separator;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final name = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: uiText(fontSize, weight: FontWeight.w600, color: c.text),
    );
    final content = Row(
      children: [
        Expanded(
          child: Row(
            mainAxisAlignment: alignEnd && type == null ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 4)],
              Flexible(child: name),
              if (type != null) ...[const SizedBox(width: 5), Flexible(child: TypeLabel(type!, size: fontSize - 1))],
            ],
          ),
        ),
        if (sorted != null) ...[
          const SizedBox(width: 4),
          Icon(sorted! ? AppIcons.chevronUp : AppIcons.chevronDown, size: 9, color: c.textSecondary),
        ],
      ],
    );
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            onSecondaryTapDown: onSecondaryTapDown,
            child: Padding(
              padding: const EdgeInsets.only(left: Gap.sm, right: Gap.sm + 2),
              child: content,
            ),
          ),
        ),
        if (separator) Positioned(right: 0, top: 5, bottom: 5, child: Container(width: 1, color: c.separator)),
        if (onResize != null)
          Positioned(
            right: -3,
            top: 0,
            bottom: 0,
            child: ColumnResizeHandle(onDrag: onResize!, onReset: onResetWidth),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// MacTable
// ---------------------------------------------------------------------------

/// Read-only table with the data grid tokens (dashboards, plan nodes,
/// debugger panes, comparison results, metadata lists, markdown): 24pt
/// header with sortable, resizable columns, 24pt zebra rows, tabular numbers
/// on the right, single row selection with ↑/↓, a 3pt status [rowStatus]
/// marker, a [leading] slot in the first column (indent, tree glyphs) and
/// inline controls via [cellBuilder].
///
/// With [onSelectionChanged] the table selects several rows, as in Finder:
/// click, ⇧-click for a range, ⌘-click to toggle, ⇧↑/↓ to extend and ⌘A.
/// ⌘C copies the selected rows as tab-separated [cell] texts, one per line.
///
/// It fills its parent and scrolls, or with [shrinkWrap] sizes to its rows
/// (inside a scroll view). [bordered] adds the radius 8 outline used when
/// the table sits inside a page. Columns with a [flex] weight share the
/// width left by the others, so the table fills its parent.
class MacTable extends StatefulWidget {
  const MacTable({
    super.key,
    required this.headers,
    required this.rowCount,
    required this.cell,
    this.cellBuilder,
    this.types,
    this.headerLeading,
    this.numeric,
    this.mono,
    this.leading,
    this.width,
    this.flex,
    this.selected,
    this.onSelect,
    this.selection,
    this.onSelectionChanged,
    this.emphasizeSelection = false,
    this.onDoubleTap,
    this.onContextMenu,
    this.rowTint,
    this.cellTint,
    this.rowStatus,
    this.tooltip,
    this.sortColumn,
    this.sortAscending = true,
    this.onSort,
    this.resizable = true,
    this.bordered = false,
    this.shrinkWrap = false,
    this.zebra = true,
    this.dense = false,
    this.wrap = false,
    this.emphasis,
    this.footer,
  });

  final List<String> headers;
  final int rowCount;

  /// Text of a cell; also used to size the columns and by ⌘C.
  final String Function(int row, int col) cell;

  /// An inline control for a cell ([PopUpButton] inline, [MacCheckbox],
  /// small [MacTextField]), or null to show [cell]. The context sits inside
  /// the row, so [RowTint.emphasizedOf] tells a selected row on the accent.
  final Widget? Function(BuildContext context, int row, int col)? cellBuilder;

  /// Type label after a header name.
  final String? Function(int col)? types;

  /// A mark before a header name (the key icon of key columns).
  final Widget? Function(int col)? headerLeading;

  /// Right aligned, tabular column.
  final bool Function(int col)? numeric;

  /// Monospaced column (SQL text).
  final bool Function(int col)? mono;

  /// Widget placed before the text of the first column (tree indentation).
  final Widget? Function(int row)? leading;

  /// Fixed width of a column, or null to fit its content. For a [flex]
  /// column it is the minimum width (80 by default).
  final double? Function(int col)? width;

  /// Flex weight of a column that takes a share of the width left by the
  /// other columns, or null for a content-sized column. A resized column
  /// keeps its new fixed width.
  final double? Function(int col)? flex;

  /// The selected row, in single selection mode.
  final int? selected;
  final ValueChanged<int>? onSelect;

  /// The selected rows, in multiple selection mode ([onSelectionChanged]).
  final Set<int>? selection;

  /// Turns on multiple selection; the caller stores the rows and passes
  /// them back as [selection].
  final ValueChanged<Set<int>>? onSelectionChanged;

  /// Draws the selection as a source list does (Finder): the solid accent
  /// with white text while the table has focus in the key window,
  /// `selectionMuted` otherwise. By default it is the grid's `selection`.
  final bool emphasizeSelection;
  final ValueChanged<int>? onDoubleTap;
  final void Function(int row, int col, Offset position)? onContextMenu;

  /// Row fill instead of the zebra (heat maps).
  final Color? Function(int row)? rowTint;

  /// Fill of a single cell over the row (a changed value at `diffChanged`
  /// with [Tint.strong]), or null.
  final Color? Function(int row, int col)? cellTint;

  /// Color of the 3pt marker at the start of a row (`diffAdded`,
  /// `diffRemoved`, `diffChanged`), or null.
  final Color? Function(int row)? rowStatus;

  /// Tooltip of a cell (e.g. the full query text).
  final String? Function(int row, int col)? tooltip;
  final int? sortColumn;
  final bool sortAscending;

  /// Header click; the caller sorts and passes [sortColumn] back.
  final ValueChanged<int>? onSort;
  final bool resizable;
  final bool bordered;
  final bool shrinkWrap;
  final bool zebra;

  /// 12pt cells instead of 13 (dense monitoring panes).
  final bool dense;

  /// Cell text wraps and rows grow to fit it (at least 24pt), top aligned
  /// (markdown tables, long messages).
  final bool wrap;

  /// Semibold column (the name column of a metadata list).
  final int? emphasis;

  /// A row-height line after the last row ("Carica altri elementi").
  final Widget? footer;

  @override
  State<MacTable> createState() => _MacTableState();
}

class _MacTableState extends State<MacTable> {
  final _h = ScrollController();
  final _v = ScrollController();
  final _focus = FocusNode(debugLabel: 'MacTable');
  final Map<int, double> _resized = {};
  bool _focused = false;

  // A first click starts the timer; a second click on the same row while
  // it runs is a double click.
  Timer? _clickTimer;
  int? _clickRow;

  // Multiple selection: the fixed end of a range and the row moved last.
  int? _anchor;
  int? _lead;

  bool get _multi => widget.onSelectionChanged != null;

  Set<int> get _selection => _multi
      ? (widget.selection ?? const <int>{})
      : {if (widget.selected != null && widget.selected! < widget.rowCount) widget.selected!};

  @override
  void didUpdateWidget(MacTable old) {
    super.didUpdateWidget(old);
    if (old.headers.length != widget.headers.length) _resized.clear();
  }

  @override
  void dispose() {
    _clickTimer?.cancel();
    _h.dispose();
    _v.dispose();
    _focus.dispose();
    super.dispose();
  }

  double get _fontSize => widget.dense ? TypeSize.small : TypeSize.body;

  /// Width that fits the header and the first rows of a column.
  double _natural(int c) {
    final sample = math.min(widget.rowCount, 60);
    final charW = _fontSize * 0.56;
    final type = widget.types?.call(c);
    var chars =
        widget.headers[c].length +
        (type == null ? 0 : (type.length * 0.85).ceil() + 1) +
        (widget.headerLeading?.call(c) == null ? 0 : 2) +
        2;
    for (var r = 0; r < sample; r++) {
      chars = math.max(chars, widget.cell(r, c).length);
    }
    final mono = widget.mono?.call(c) ?? false;
    final max = mono ? 560.0 : 320.0;
    final lead = c == 0 && (widget.leading != null || widget.rowStatus != null) ? 40 : 0;
    return (chars * (mono ? charW * 1.1 : charW) + 24 + lead).clamp(56.0, max);
  }

  /// Column widths; [flex] columns share what is left of [viewport].
  List<double> _widths(double? viewport) {
    final w = List<double>.filled(widget.headers.length, 0);
    final flexes = <int, double>{};
    for (var c = 0; c < widget.headers.length; c++) {
      final f = _resized.containsKey(c) ? null : widget.flex?.call(c);
      if (f != null && f > 0 && viewport != null) {
        flexes[c] = f;
        continue;
      }
      w[c] = _resized[c] ?? widget.width?.call(c) ?? _natural(c);
    }
    if (flexes.isNotEmpty) {
      final fixed = w.fold<double>(0, (a, b) => a + b);
      final free = viewport! - fixed;
      final weights = flexes.values.fold<double>(0, (a, b) => a + b);
      for (final MapEntry(key: c, value: f) in flexes.entries) {
        w[c] = math.max(widget.width?.call(c) ?? 80, free * f / weights);
      }
    }
    return w;
  }

  void _emit(Set<int> rows) => widget.onSelectionChanged!(rows);

  Set<int> _range(int a, int b) => {for (var i = math.min(a, b); i <= math.max(a, b); i++) i};

  bool get _commandPressed => HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed;

  void _clickSelect(int r) {
    final sel = _selection;
    if (HardwareKeyboard.instance.isShiftPressed && _anchor != null) {
      _lead = r;
      _emit(_range(_anchor!.clamp(0, widget.rowCount - 1), r));
    } else if (_commandPressed) {
      _anchor = _lead = r;
      final next = {...sel};
      if (!next.remove(r)) next.add(r);
      _emit(next);
    } else {
      _anchor = _lead = r;
      _emit({r});
    }
  }

  void _tap(int r) {
    _focus.requestFocus();
    final isDouble = widget.onDoubleTap != null && _clickRow == r && (_clickTimer?.isActive ?? false);
    _clickTimer?.cancel();
    if (isDouble) {
      _clickTimer = null;
      _clickRow = null;
    } else {
      _clickRow = r;
      _clickTimer = Timer(kDoubleTapTimeout, () => _clickRow = null);
    }
    if (_multi) {
      // The second click of a double click keeps the selection it opens.
      if (!isDouble) _clickSelect(r);
    } else {
      widget.onSelect?.call(r);
    }
    if (isDouble) widget.onDoubleTap!(r);
  }

  void _contextMenu(int r, int col, Offset position) {
    _focus.requestFocus();
    if (_multi) {
      if (!_selection.contains(r)) {
        _anchor = _lead = r;
        _emit({r});
      }
    } else {
      widget.onSelect?.call(r);
    }
    widget.onContextMenu!(r, col, position);
  }

  /// The row the keyboard acts on: the one moved or clicked last, or the
  /// first selected.
  int? get _current {
    final sel = _selection;
    if (sel.isEmpty) return null;
    if (!_multi) return sel.first;
    final lead = _lead;
    return lead != null && sel.contains(lead) ? lead : sel.reduce(math.min);
  }

  void _copy() {
    final rows = _selection.toList()..sort();
    if (rows.isEmpty) return;
    final cols = widget.headers.length;
    final text = rows.map((r) => [for (var c = 0; c < cols; c++) widget.cell(r, c)].join('\t')).join('\n');
    Clipboard.setData(ClipboardData(text: text));
  }

  void _reveal(int r) {
    if (widget.shrinkWrap || widget.wrap || !_v.hasClients) return;
    final top = r * GridMetrics.row;
    final pos = _v.position;
    if (top < pos.pixels) {
      _v.jumpTo(top);
    } else if (top + GridMetrics.row > pos.pixels + pos.viewportDimension) {
      _v.jumpTo(math.min(top + GridMetrics.row - pos.viewportDimension, pos.maxScrollExtent));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final n = widget.rowCount;
    if (n == 0) return KeyEventResult.ignored;
    final cur = _current;
    final key = e.logicalKey;
    switch (key) {
      case LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.arrowUp:
        final down = key == LogicalKeyboardKey.arrowDown;
        final next = cur == null ? (down ? 0 : n - 1) : (cur + (down ? 1 : -1)).clamp(0, n - 1);
        if (_multi) {
          if (HardwareKeyboard.instance.isShiftPressed && cur != null) {
            _anchor ??= cur;
            _lead = next;
            _emit(_range(_anchor!.clamp(0, n - 1), next));
          } else {
            _anchor = _lead = next;
            _emit({next});
          }
        } else {
          if (widget.onSelect == null) return KeyEventResult.ignored;
          widget.onSelect!(next);
        }
        _reveal(next);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter when cur != null && widget.onDoubleTap != null:
        widget.onDoubleTap!(cur);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyA when _multi && _commandPressed:
        _anchor = 0;
        _lead = n - 1;
        _emit(_range(0, n - 1));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyC when cur != null && _commandPressed:
        _copy();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final cellStyle = uiText(_fontSize, color: c.text, features: kTabular);
    final monoCell = TextStyle(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
      fontSize: widget.dense ? TypeSize.monoSmall : TypeSize.mono,
      color: c.text,
      fontFeatures: kTabular,
    );
    final selection = _selection;
    final wrap = widget.wrap;

    Widget header(List<double> widths) => Container(
      height: GridMetrics.header,
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < widget.headers.length; i++)
            SizedBox(
              width: widths[i],
              child: TableHeaderCell(
                label: widget.headers[i],
                type: widget.types?.call(i),
                leading: widget.headerLeading?.call(i),
                alignEnd: widget.numeric?.call(i) ?? false,
                sorted: widget.sortColumn == i ? widget.sortAscending : null,
                onTap: widget.onSort == null ? null : () => widget.onSort!(i),
                separator: i < widget.headers.length - 1,
                onResize: widget.resizable
                    ? (dx) => setState(() => _resized[i] = (widths[i] + dx).clamp(40.0, 2000.0))
                    : null,
                onResetWidth: widget.resizable ? () => setState(() => _resized.remove(i)) : null,
              ),
            ),
        ],
      ),
    );

    Widget row(List<double> widths, int r) {
      final selected = selection.contains(r);
      final tint = widget.rowTint?.call(r);
      final base = tint ?? (widget.zebra && r.isOdd ? c.zebra : c.content);
      final Color bg;
      var emphasized = false;
      if (!selected) {
        bg = base;
      } else if (widget.emphasizeSelection) {
        bg = Color.alphaBlend(_focused ? c.selectionEmphasized : c.selectionMuted, base);
        emphasized = _focused && c.windowActive;
      } else {
        bg = Color.alphaBlend(c.selection, base);
      }
      final fg = emphasized ? c.onSelectionEmphasized : c.text;
      final status = widget.rowStatus?.call(r);
      final interactive = widget.onSelect != null || widget.onDoubleTap != null || _multi;
      final cells = <Widget>[
        for (var i = 0; i < widget.headers.length; i++)
          () {
            final right = widget.numeric?.call(i) ?? false;
            Widget t = Builder(
              builder: (context) =>
                  widget.cellBuilder?.call(context, r, i) ??
                  Text(
                    widget.cell(r, i),
                    maxLines: wrap ? null : 1,
                    softWrap: wrap,
                    overflow: wrap ? null : TextOverflow.ellipsis,
                    textAlign: right ? TextAlign.right : null,
                    style: (widget.mono?.call(i) ?? false)
                        ? monoCell.copyWith(color: fg)
                        : (widget.emphasis == i ? cellStyle.copyWith(fontWeight: FontWeight.w500) : cellStyle).copyWith(
                            color: fg,
                          ),
                  ),
            );
            final tip = widget.tooltip?.call(r, i);
            if (tip != null && tip.isNotEmpty) {
              t = Tooltip(message: tip.length > 2000 ? '${tip.substring(0, 2000)}…' : tip, child: t);
            }
            final lead = i == 0 ? widget.leading?.call(r) : null;
            if (lead != null) {
              t = Row(
                crossAxisAlignment: wrap ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                children: [
                  lead,
                  Expanded(child: t),
                ],
              );
            }
            final cellTint = emphasized ? null : widget.cellTint?.call(r, i);
            Widget box = Container(
              width: widths[i],
              color: cellTint,
              padding: EdgeInsets.symmetric(horizontal: Gap.sm, vertical: wrap ? Gap.xs : 0),
              alignment: wrap
                  ? (right ? Alignment.topRight : Alignment.topLeft)
                  : (right ? Alignment.centerRight : Alignment.centerLeft),
              child: t,
            );
            if (i == 0 && widget.rowStatus != null) {
              box = Stack(
                fit: StackFit.passthrough,
                children: [
                  box,
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(width: GridMetrics.marker, color: status ?? const Color(0x00000000)),
                  ),
                ],
              );
            }
            if (widget.onContextMenu != null) {
              box = GestureDetector(
                behavior: HitTestBehavior.opaque,
                onSecondaryTapDown: (d) => _contextMenu(r, i, d.globalPosition),
                child: box,
              );
            }
            return box;
          }(),
      ];
      Widget content = Row(
        crossAxisAlignment: wrap ? CrossAxisAlignment.stretch : CrossAxisAlignment.center,
        children: cells,
      );
      if (wrap) content = IntrinsicHeight(child: content);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: interactive ? () => _tap(r) : null,
        child: Container(
          height: wrap ? null : GridMetrics.row,
          constraints: wrap ? const BoxConstraints(minHeight: GridMetrics.row) : null,
          color: bg,
          child: RowTint(background: bg, emphasized: emphasized, child: content),
        ),
      );
    }

    Widget table(double? viewport) {
      final widths = _widths(viewport);
      final total = widths.fold<double>(0, (a, b) => a + b);
      final width = widget.shrinkWrap || viewport == null ? total : math.max(total, viewport);
      final footer = widget.footer == null ? null : SizedBox(height: GridMetrics.row, child: widget.footer);
      final Widget body;
      if (widget.shrinkWrap) {
        body = SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [header(widths), for (var r = 0; r < widget.rowCount; r++) row(widths, r), ?footer],
          ),
        );
      } else {
        body = SizedBox(
          width: width,
          child: Column(
            children: [
              header(widths),
              Expanded(
                child: Scrollbar(
                  controller: _v,
                  child: ListView.builder(
                    controller: _v,
                    itemExtent: wrap ? null : GridMetrics.row,
                    itemCount: widget.rowCount + (footer == null ? 0 : 1),
                    itemBuilder: (context, r) => r == widget.rowCount ? footer! : row(widths, r),
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return Scrollbar(
        controller: _h,
        notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(controller: _h, scrollDirection: Axis.horizontal, child: body),
      );
    }

    Widget result = Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      onFocusChange: widget.emphasizeSelection ? (v) => setState(() => _focused = v) : null,
      child: LayoutBuilder(
        builder: (context, box) => table(box.maxWidth.isFinite ? box.maxWidth - (widget.bordered ? 1 : 0) : null),
      ),
    );
    if (widget.bordered) {
      result = Container(
        decoration: BoxDecoration(
          color: c.content,
          borderRadius: BorderRadius.circular(Radii.panel),
          border: Border.all(color: c.separator, width: 0.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: result,
      );
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Metadata tables
// ---------------------------------------------------------------------------

/// Key/value list of properties: a read-only [FormGroup] with the labels
/// in secondary and selectable values. The label column fits the widest
/// label (at most 40%) unless [labelWidth] fixes it.
class PropertyTable extends StatelessWidget {
  const PropertyTable({super.key, required this.entries, this.labelWidth, this.title});

  final List<(String, String)> entries;
  final double? labelWidth;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final width =
            labelWidth ??
            measureLabelWidth(context, [
              for (final e in entries) (e.$1, TypeSize.body),
            ], max: (box.maxWidth - Gap.md * 2) * 0.4);
        return FormGroup(
          title: title,
          labelWidth: width,
          children: [
            for (final (label, value) in entries)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: width,
                    child: Text(label, style: uiText(TypeSize.body, color: c.textSecondary)),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: SelectableText(
                      value.isEmpty ? '—' : value,
                      style: uiText(TypeSize.body, color: value.isEmpty ? c.textTertiary : c.text, features: kTabular),
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Read-only zebra table for metadata lists (columns, indexes, …): a
/// bordered, content-sized [MacTable] in a padded scroll view. The second
/// column (the name) is semibold. Right click copies a value or the row.
class SimpleGrid extends StatelessWidget {
  const SimpleGrid({super.key, required this.headers, required this.rows, this.onRowDoubleTap});
  final List<String> headers;
  final List<List<String>> rows;
  final void Function(int row)? onRowDoubleTap;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const EmptyState(icon: AppIcons.empty, title: 'Nessun elemento');
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Align(
        alignment: Alignment.topLeft,
        child: MacTable(
          headers: headers,
          rowCount: rows.length,
          cell: (r, c) => c < rows[r].length ? rows[r][c] : '',
          emphasis: headers.length > 1 ? 1 : null,
          shrinkWrap: true,
          bordered: true,
          onDoubleTap: onRowDoubleTap,
          onContextMenu: (r, col, pos) {
            final value = col < rows[r].length ? rows[r][col] : '';
            showMacMenu<void>(
              context,
              position: pos,
              entries: [
                MenuEntry(
                  value.isEmpty
                      ? 'Copia valore'
                      : 'Copia «${value.length > 40 ? '${value.substring(0, 40)}…' : value}»',
                  onSelected: () => Clipboard.setData(ClipboardData(text: value)),
                ),
                MenuEntry('Copia riga', onSelected: () => Clipboard.setData(ClipboardData(text: rows[r].join('\t')))),
              ],
            );
          },
        ),
      ),
    );
  }
}
