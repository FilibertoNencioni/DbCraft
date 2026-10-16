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
/// It fills its parent and scrolls, or with [shrinkWrap] sizes to its rows
/// (inside a scroll view). [bordered] adds the radius 8 outline used when
/// the table sits inside a page.
class MacTable extends StatefulWidget {
  const MacTable({
    super.key,
    required this.headers,
    required this.rowCount,
    required this.cell,
    this.cellBuilder,
    this.types,
    this.numeric,
    this.mono,
    this.leading,
    this.width,
    this.selected,
    this.onSelect,
    this.onDoubleTap,
    this.onContextMenu,
    this.rowTint,
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
    this.emphasis,
  });

  final List<String> headers;
  final int rowCount;

  /// Text of a cell; also used to size the columns.
  final String Function(int row, int col) cell;

  /// An inline control for a cell ([PopUpButton] inline, [MacCheckbox],
  /// small [MacTextField]), or null to show [cell].
  final Widget? Function(BuildContext context, int row, int col)? cellBuilder;

  /// Type label after a header name.
  final String? Function(int col)? types;

  /// Right aligned, tabular column.
  final bool Function(int col)? numeric;

  /// Monospaced column (SQL text).
  final bool Function(int col)? mono;

  /// Widget placed before the text of the first column (tree indentation).
  final Widget? Function(int row)? leading;
  final double? Function(int col)? width;
  final int? selected;
  final ValueChanged<int>? onSelect;
  final ValueChanged<int>? onDoubleTap;
  final void Function(int row, int col, Offset position)? onContextMenu;

  /// Row fill instead of the zebra (heat maps).
  final Color? Function(int row)? rowTint;

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

  /// Semibold column (the name column of a metadata list).
  final int? emphasis;

  @override
  State<MacTable> createState() => _MacTableState();
}

class _MacTableState extends State<MacTable> {
  final _h = ScrollController();
  final _v = ScrollController();
  final _focus = FocusNode(debugLabel: 'MacTable');
  final Map<int, double> _resized = {};
  DateTime? _lastTap;
  int? _lastRow;

  @override
  void didUpdateWidget(MacTable old) {
    super.didUpdateWidget(old);
    if (old.headers.length != widget.headers.length) _resized.clear();
  }

  @override
  void dispose() {
    _h.dispose();
    _v.dispose();
    _focus.dispose();
    super.dispose();
  }

  double get _fontSize => widget.dense ? TypeSize.small : TypeSize.body;

  List<double> _widths() {
    final w = <double>[];
    final sample = math.min(widget.rowCount, 60);
    final charW = _fontSize * 0.56;
    for (var c = 0; c < widget.headers.length; c++) {
      final fixed = _resized[c] ?? widget.width?.call(c);
      if (fixed != null) {
        w.add(fixed);
        continue;
      }
      final type = widget.types?.call(c);
      var chars = widget.headers[c].length + (type == null ? 0 : (type.length * 0.85).ceil() + 1) + 2;
      for (var r = 0; r < sample; r++) {
        chars = math.max(chars, widget.cell(r, c).length);
      }
      final mono = widget.mono?.call(c) ?? false;
      final max = mono ? 560.0 : 320.0;
      final lead = c == 0 && (widget.leading != null || widget.rowStatus != null) ? 40 : 0;
      w.add((chars * (mono ? charW * 1.1 : charW) + 24 + lead).clamp(56.0, max));
    }
    return w;
  }

  void _tap(int r) {
    _focus.requestFocus();
    final now = DateTime.now();
    final isDouble =
        widget.onDoubleTap != null &&
        _lastRow == r &&
        _lastTap != null &&
        now.difference(_lastTap!) <= kDoubleTapTimeout;
    _lastTap = isDouble ? null : now;
    _lastRow = r;
    widget.onSelect?.call(r);
    if (isDouble) widget.onDoubleTap!(r);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final n = widget.rowCount;
    final sel = widget.selected;
    if (n == 0) return KeyEventResult.ignored;
    int? next;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        next = sel == null ? 0 : math.min(sel + 1, n - 1);
      case LogicalKeyboardKey.arrowUp:
        next = sel == null ? n - 1 : math.max(sel - 1, 0);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter when sel != null && widget.onDoubleTap != null:
        widget.onDoubleTap!(sel);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
    if (widget.onSelect == null) return KeyEventResult.ignored;
    widget.onSelect!(next);
    if (!widget.shrinkWrap && _v.hasClients) {
      final top = next * GridMetrics.row;
      final pos = _v.position;
      if (top < pos.pixels) {
        _v.jumpTo(top);
      } else if (top + GridMetrics.row > pos.pixels + pos.viewportDimension) {
        _v.jumpTo(math.min(top + GridMetrics.row - pos.viewportDimension, pos.maxScrollExtent));
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final widths = _widths();
    final total = widths.fold<double>(0, (a, b) => a + b);
    final cellStyle = uiText(_fontSize, color: c.text, features: kTabular);
    final monoCell = TextStyle(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
      fontSize: widget.dense ? TypeSize.monoSmall : TypeSize.mono,
      color: c.text,
      fontFeatures: kTabular,
    );

    Widget cellBox(int col, Widget child, {bool right = false}) => Container(
      width: widths[col],
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      alignment: right ? Alignment.centerRight : Alignment.centerLeft,
      child: child,
    );

    final header = Container(
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

    Widget row(BuildContext context, int r) {
      final selected = widget.selected == r;
      final tint = widget.rowTint?.call(r);
      final zebra = widget.zebra && r.isOdd ? c.zebra : c.content;
      final bg = selected ? Color.alphaBlend(c.selection, tint ?? zebra) : (tint ?? zebra);
      final status = widget.rowStatus?.call(r);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect == null && widget.onDoubleTap == null ? null : () => _tap(r),
        child: Container(
          height: GridMetrics.row,
          color: bg,
          child: RowTint(
            background: bg,
            child: Row(
              children: [
                for (var i = 0; i < widget.headers.length; i++)
                  () {
                    final right = widget.numeric?.call(i) ?? false;
                    Widget t =
                        widget.cellBuilder?.call(context, r, i) ??
                        Text(
                          widget.cell(r, i),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: (widget.mono?.call(i) ?? false)
                              ? monoCell
                              : (widget.emphasis == i ? cellStyle.copyWith(fontWeight: FontWeight.w500) : cellStyle),
                        );
                    final tip = widget.tooltip?.call(r, i);
                    if (tip != null && tip.isNotEmpty) {
                      t = Tooltip(message: tip.length > 2000 ? '${tip.substring(0, 2000)}…' : tip, child: t);
                    }
                    final lead = i == 0 ? widget.leading?.call(r) : null;
                    if (lead != null) {
                      t = Row(
                        children: [
                          lead,
                          Expanded(child: t),
                        ],
                      );
                    }
                    Widget box = cellBox(i, t, right: right);
                    if (i == 0 && widget.rowStatus != null) {
                      box = Stack(
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
                        onSecondaryTapDown: (d) {
                          widget.onSelect?.call(r);
                          widget.onContextMenu!(r, i, d.globalPosition);
                        },
                        child: box,
                      );
                    }
                    return box;
                  }(),
              ],
            ),
          ),
        ),
      );
    }

    Widget table(double viewport) {
      final width = widget.shrinkWrap ? total : math.max(total, viewport);
      final Widget body;
      if (widget.shrinkWrap) {
        body = SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              header,
              for (var r = 0; r < widget.rowCount; r++) Builder(builder: (context) => row(context, r)),
            ],
          ),
        );
      } else {
        body = SizedBox(
          width: width,
          child: Column(
            children: [
              header,
              Expanded(
                child: Scrollbar(
                  controller: _v,
                  child: ListView.builder(
                    controller: _v,
                    itemExtent: GridMetrics.row,
                    itemCount: widget.rowCount,
                    itemBuilder: row,
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
      child: LayoutBuilder(
        builder: (context, box) => table(box.maxWidth.isFinite ? box.maxWidth - (widget.bordered ? 1 : 0) : total),
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
