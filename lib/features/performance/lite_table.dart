import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/widgets/common.dart';

/// Light read-only table (26px rows, zebra, single selection, horizontal
/// scrolling) used by the dashboard, the plan table and the debugger panes.
class LiteTable extends StatefulWidget {
  const LiteTable({
    super.key,
    required this.headers,
    required this.rowCount,
    required this.cell,
    this.numeric,
    this.mono,
    this.leading,
    this.width,
    this.selected,
    this.onSelect,
    this.onDoubleTap,
    this.onContextMenu,
    this.rowTint,
    this.tooltip,
  });

  final List<String> headers;
  final int rowCount;
  final String Function(int row, int col) cell;

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
  final void Function(int row, Offset position)? onContextMenu;
  final Color? Function(int row)? rowTint;

  /// Tooltip of a cell (e.g. the full query text).
  final String? Function(int row, int col)? tooltip;

  @override
  State<LiteTable> createState() => _LiteTableState();
}

class _LiteTableState extends State<LiteTable> {
  final _h = ScrollController();
  final _v = ScrollController();

  @override
  void dispose() {
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  List<double> _widths() {
    final w = <double>[];
    final sample = math.min(widget.rowCount, 60);
    for (var c = 0; c < widget.headers.length; c++) {
      final fixed = widget.width?.call(c);
      if (fixed != null) {
        w.add(fixed);
        continue;
      }
      var chars = widget.headers[c].length + 2;
      for (var r = 0; r < sample; r++) {
        chars = math.max(chars, widget.cell(r, c).length);
      }
      final mono = widget.mono?.call(c) ?? false;
      final max = mono ? 560.0 : 300.0;
      w.add((chars * (mono ? 7.4 : 7.0) + 20 + (c == 0 && widget.leading != null ? 40 : 0)).clamp(56.0, max));
    }
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final widths = _widths();
    final total = widths.fold<double>(0, (a, b) => a + b);
    final headerStyle = TextStyle(fontSize: TypeSize.small, fontWeight: FontWeight.w600, color: c.textSecondary);
    final cellStyle = TextStyle(fontSize: TypeSize.small + 0.5, color: c.text, fontFeatures: kTabular);
    final mono = monoStyle(context, size: TypeSize.small);

    Widget cellBox(int col, Widget child, {bool right = false}) => Container(
      width: widths[col],
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      alignment: right ? Alignment.centerRight : Alignment.centerLeft,
      child: child,
    );

    final header = Container(
      height: 28,
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < widget.headers.length; i++)
            cellBox(
              i,
              Text(widget.headers[i], style: headerStyle, overflow: TextOverflow.ellipsis),
              right: widget.numeric?.call(i) ?? false,
            ),
        ],
      ),
    );

    Widget row(int r) {
      final selected = widget.selected == r;
      final tint = widget.rowTint?.call(r);
      final bg = selected ? c.selection : (tint ?? (r.isOdd ? c.zebra : c.content));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect == null ? null : () => widget.onSelect!(r),
        onDoubleTap: widget.onDoubleTap == null ? null : () => widget.onDoubleTap!(r),
        onSecondaryTapDown: widget.onContextMenu == null
            ? null
            : (d) {
                widget.onSelect?.call(r);
                widget.onContextMenu!(r, d.globalPosition);
              },
        child: Container(
          height: 26,
          color: bg,
          child: Row(
            children: [
              for (var i = 0; i < widget.headers.length; i++)
                () {
                  final text = widget.cell(r, i);
                  final isMono = widget.mono?.call(i) ?? false;
                  Widget t = Text(
                    text,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: isMono ? mono : cellStyle,
                  );
                  final tip = widget.tooltip?.call(r, i);
                  if (tip != null && tip.isNotEmpty) {
                    t = Tooltip(
                      message: tip.length > 2000 ? '${tip.substring(0, 2000)}…' : tip,
                      waitDuration: const Duration(milliseconds: 600),
                      child: t,
                    );
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
                  return cellBox(i, t, right: widget.numeric?.call(i) ?? false);
                }(),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final width = math.max(total, box.maxWidth);
        return Scrollbar(
          controller: _h,
          child: SingleChildScrollView(
            controller: _h,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                children: [
                  header,
                  Expanded(
                    child: Scrollbar(
                      controller: _v,
                      child: ListView.builder(
                        controller: _v,
                        itemExtent: 26,
                        itemCount: widget.rowCount,
                        itemBuilder: (context, r) => row(r),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
