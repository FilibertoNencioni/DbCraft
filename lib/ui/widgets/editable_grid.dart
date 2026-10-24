import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'buttons.dart';
import 'panels.dart';

/// Column of an [EditableGrid]: a fixed [width] or a share ([flex]) of the
/// free width.
class EditableGridColumn {
  const EditableGridColumn(this.label, {this.width, this.flex = 1, this.center = false, this.tooltip});
  final String label;
  final double? width;
  final int flex;
  final bool center;
  final String? tooltip;
}

/// Edit state of a row, drawn as a bar on its leading edge.
enum EditableRowMark { none, added, changed }

/// Table whose cells are controls (fields, pop-ups, checkboxes): the column
/// grid of a table designer, the pairs of a foreign key…
///
/// Rows are selected with a click on their margin or by focusing one of
/// their controls. With the grid focused, ⌘↑ / ⌘↓ (Ctrl on Windows and
/// Linux) move the selected row and ⌫ removes it.
class EditableGrid extends StatefulWidget {
  const EditableGrid({
    super.key,
    required this.columns,
    required this.rowCount,
    required this.cellBuilder,
    this.rowKey,
    this.mark,
    this.selected,
    this.onSelect,
    this.onAdd,
    this.addLabel = 'Aggiungi',
    this.onRemove,
    this.canRemove,
    this.onMove,
    this.removeTooltip = 'Elimina la riga',
    this.emptyText = 'Nessuna riga',
    this.trailing = const [],
  });

  final List<EditableGridColumn> columns;
  final int rowCount;
  final Widget Function(BuildContext context, int row, int column) cellBuilder;

  /// Stable identity of a row (keeps the state of its fields when rows move).
  final Key Function(int row)? rowKey;
  final EditableRowMark Function(int row)? mark;
  final int? selected;
  final ValueChanged<int>? onSelect;
  final VoidCallback? onAdd;
  final String addLabel;
  final ValueChanged<int>? onRemove;

  /// Rows that cannot be removed (their ⊖ is disabled); null: all can.
  final bool Function(int row)? canRemove;

  /// Moves a row from the first index to the second.
  final void Function(int from, int to)? onMove;
  final String removeTooltip;
  final String emptyText;

  /// Extra buttons next to the "add" one.
  final List<Widget> trailing;

  @override
  State<EditableGrid> createState() => _EditableGridState();
}

class _EditableGridState extends State<EditableGrid> {
  final _focus = FocusNode(debugLabel: 'EditableGrid');

  static const _rowHeight = 28.0;
  static const _markWidth = 3.0;
  static const _actionsWidth = 64.0;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _move(int d) {
    final s = widget.selected;
    if (s == null || widget.onMove == null) return;
    final to = s + d;
    if (to < 0 || to >= widget.rowCount) return;
    widget.onMove!(s, to);
    widget.onSelect?.call(to);
  }

  /// A cell, announced with its column name by assistive technologies.
  Widget _cell(EditableGridColumn col, Widget child, {bool body = false}) {
    if (body) child = Semantics(container: true, label: col.label, child: child);
    final aligned = col.center ? Center(child: child) : child;
    return col.width != null ? SizedBox(width: col.width, child: aligned) : Expanded(flex: col.flex, child: aligned);
  }

  Widget _header(BuildContext context) {
    final c = DbColors.of(context);
    final style = uiText(TypeSize.caption, weight: FontWeight.w600, color: c.textSecondary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(_markWidth + Gap.xs, 0, Gap.xs, Gap.xs),
      child: Row(
        children: [
          for (final (i, col) in widget.columns.indexed) ...[
            if (i > 0) const SizedBox(width: Gap.xs),
            _cell(
              col,
              Tooltip(
                message: col.tooltip ?? '',
                child: Text(col.label, style: style, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          if (widget.onRemove != null || widget.onMove != null) const SizedBox(width: _actionsWidth),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, int r) {
    final c = DbColors.of(context);
    final selected = widget.selected == r;
    final mark = widget.mark?.call(r) ?? EditableRowMark.none;
    final markColor = switch (mark) {
      EditableRowMark.added => c.diffAdded,
      EditableRowMark.changed => c.diffChanged,
      EditableRowMark.none => null,
    };
    return Focus(
      key: widget.rowKey?.call(r),
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (f && !selected) widget.onSelect?.call(r);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) {
          if (!selected) widget.onSelect?.call(r);
        },
        child: Semantics(
          container: true,
          selected: selected,
          label: [
            'Riga ${r + 1} di ${widget.rowCount}',
            if (mark == EditableRowMark.added) 'nuova',
            if (mark == EditableRowMark.changed) 'modificata',
          ].join(', '),
          child: Container(
            height: _rowHeight,
            color: selected ? c.selection.withValues(alpha: Tint.regular) : (r.isOdd ? c.zebra : null),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Container(width: _markWidth, height: _rowHeight, color: markColor),
                ),
                const SizedBox(width: Gap.xs),
                for (final (i, col) in widget.columns.indexed) ...[
                  if (i > 0) const SizedBox(width: Gap.xs),
                  _cell(col, widget.cellBuilder(context, r, i), body: true),
                ],
                if (widget.onRemove != null || widget.onMove != null)
                  SizedBox(
                    width: _actionsWidth,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (widget.onMove != null) ...[
                          ToolButton(
                            icon: AppIcons.arrowUp,
                            extent: 18,
                            tooltip: 'Sposta su',
                            onPressed: r == 0 ? null : () => widget.onMove!(r, r - 1),
                          ),
                          ToolButton(
                            icon: AppIcons.arrowDown,
                            extent: 18,
                            tooltip: 'Sposta giù',
                            onPressed: r == widget.rowCount - 1 ? null : () => widget.onMove!(r, r + 1),
                          ),
                        ],
                        if (widget.onRemove != null)
                          ToolButton(
                            icon: AppIcons.removeCircle,
                            extent: 18,
                            color: c.danger,
                            tooltip: widget.removeTooltip,
                            onPressed: widget.canRemove?.call(r) ?? true ? () => widget.onRemove!(r) : null,
                          ),
                      ],
                    ),
                  ),
                const SizedBox(width: Gap.xs),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final mod = defaultTargetPlatform == TargetPlatform.macOS;
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.arrowUp, meta: mod, control: !mod): () => _move(-1),
        SingleActivator(LogicalKeyboardKey.arrowDown, meta: mod, control: !mod): () => _move(1),
      },
      child: Focus(
        focusNode: _focus,
        onKeyEvent: (node, e) {
          // ⌫ / Canc remove the selected row only when the grid itself has
          // the focus (not one of its fields).
          if (e is! KeyDownEvent || !node.hasPrimaryFocus) return KeyEventResult.ignored;
          final s = widget.selected;
          if (s != null &&
              widget.onRemove != null &&
              (widget.canRemove?.call(s) ?? true) &&
              (e.logicalKey == LogicalKeyboardKey.backspace || e.logicalKey == LogicalKeyboardKey.delete)) {
            widget.onRemove!(s);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Tabella modificabile, ${widget.rowCount} ${widget.rowCount == 1 ? 'riga' : 'righe'}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(child: _header(context)),
              Flexible(
                child: InsetBox(
                  child: widget.rowCount == 0
                      ? Padding(
                          padding: const EdgeInsets.all(Gap.md),
                          child: Text(widget.emptyText, style: uiText(TypeSize.small, color: c.textTertiary)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: widget.rowCount,
                          itemExtent: _rowHeight,
                          itemBuilder: _row,
                        ),
                ),
              ),
              if (widget.onAdd != null || widget.trailing.isNotEmpty) ...[
                const SizedBox(height: Gap.xs),
                Row(
                  children: [
                    if (widget.onAdd != null)
                      ToolButton(
                        icon: AppIcons.add,
                        label: widget.addLabel,
                        tooltip: widget.addLabel,
                        onPressed: () {
                          widget.onAdd!();
                          _focus.requestFocus();
                        },
                      ),
                    ...widget.trailing,
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
