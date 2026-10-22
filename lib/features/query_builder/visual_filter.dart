// Visual filter bar for the table data editor (simplified analyst view):
// "column operator value" chips combined with AND plus a sort chooser. The
// WHERE / ORDER BY strings are generated with the dialect quoting.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/sql_dialect.dart';
import '../../ui/widgets/common.dart';
import 'query_model.dart';

/// One "column operator value" condition.
class FilterCondition {
  FilterCondition({required this.column, required this.kind, this.op = FilterOp.eq, this.value = '', this.value2 = ''});

  String column;
  ValueKind kind;
  FilterOp op;
  String value;
  String value2;

  String sql(SqlDialect d) => buildCondition(d, d.quoteIdent(column), op, kind, value, value2) ?? '';

  /// Human readable chip label.
  String get label => switch (op.arity) {
    0 => '$column ${op.label}',
    2 => '$column tra $value e $value2',
    _ => '$column ${op == FilterOp.like ? 'contiene' : op.label} ${op == FilterOp.like ? '"$value"' : value}',
  };
}

class SortKey {
  const SortKey(this.column, {this.descending = false});
  final String column;
  final bool descending;
}

/// Conditions (AND) + sort keys.
class VisualFilter {
  final List<FilterCondition> conditions = [];
  final List<SortKey> sort = [];

  /// Free SQL condition kept from the raw WHERE field (shown as a chip).
  String customWhere = '';

  bool get isEmpty => conditions.isEmpty && sort.isEmpty && customWhere.trim().isEmpty;

  String whereSql(SqlDialect d) {
    final parts = conditions.map((c) => c.sql(d)).where((s) => s.isNotEmpty).toList();
    final custom = customWhere.trim();
    if (custom.isNotEmpty) parts.insert(0, parts.isEmpty ? custom : '($custom)');
    return parts.join(' AND ');
  }

  String orderSql(SqlDialect d) =>
      sort.map((s) => '${d.quoteIdent(s.column)}${s.descending ? ' DESC' : ''}').join(', ');

  void clear() {
    conditions.clear();
    sort.clear();
    customWhere = '';
  }
}

/// Column offered by the filter bar.
class FilterColumn {
  const FilterColumn(this.name, this.kind, [this.typeName = '']);
  final String name;
  final ValueKind kind;
  final String typeName;
}

/// Chip bar editing a [VisualFilter]; [onChanged] fires after every edit.
class VisualFilterBar extends StatelessWidget {
  const VisualFilterBar({
    super.key,
    required this.filter,
    required this.columns,
    required this.onChanged,
    this.trailing = const [],
  });

  final VisualFilter filter;
  final List<FilterColumn> columns;
  final VoidCallback onChanged;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final sort = filter.sort.isEmpty ? null : filter.sort.first;
    // A pane bar that grows when the tokens wrap.
    return Container(
      constraints: const BoxConstraints(minHeight: BarHeight.bar),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 7),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: ControlSize.regular,
            child: Padding(
              padding: const EdgeInsets.only(left: 2, right: Gap.sm),
              child: Icon(AppIcons.filter, size: 14, color: c.textSecondary),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1.5),
              child: TokenField(
                joiner: 'e',
                tokens: [
                  if (filter.customWhere.trim().isNotEmpty)
                    FilterToken(
                      label: 'SQL: ${filter.customWhere.trim()}',
                      mono: true,
                      tooltip: filter.customWhere,
                      onRemove: () {
                        filter.customWhere = '';
                        onChanged();
                      },
                    ),
                  for (final (i, cond) in filter.conditions.indexed)
                    Builder(
                      builder: (ctx) => FilterToken(
                        label: cond.label,
                        onTap: () async {
                          final r = await showFilterPopover(ctx, columns, initial: cond);
                          if (r != null) {
                            filter.conditions[i] = r;
                            onChanged();
                          }
                        },
                        onRemove: () {
                          filter.conditions.removeAt(i);
                          onChanged();
                        },
                      ),
                    ),
                ],
                trailing: Builder(
                  builder: (ctx) => ToolButton(
                    icon: AppIcons.add,
                    tooltip: 'Aggiungi un filtro',
                    label: filter.conditions.isEmpty ? 'Aggiungi filtro' : 'Aggiungi',
                    extent: ControlSize.small,
                    onPressed: columns.isEmpty
                        ? null
                        : () async {
                            final r = await showFilterPopover(ctx, columns);
                            if (r != null) {
                              filter.conditions.add(r);
                              onChanged();
                            }
                          },
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          _SortButton(
            columns: columns,
            current: sort,
            onChanged: (k) {
              filter.sort
                ..clear()
                ..addAll([?k]);
              onChanged();
            },
          ),
          if (!filter.isEmpty)
            ToolButton(
              icon: AppIcons.filterOff,
              tooltip: 'Rimuovi filtri e ordinamento',
              onPressed: () {
                filter.clear();
                onChanged();
              },
            ),
          ...trailing,
        ],
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.columns, required this.current, required this.onChanged});
  final List<FilterColumn> columns;
  final SortKey? current;
  final ValueChanged<SortKey?> onChanged;

  @override
  Widget build(BuildContext context) {
    final cur = current;
    bool on(String col, bool desc) => cur != null && cur.column == col && cur.descending == desc;
    return PulldownButton(
      icon: cur == null ? AppIcons.swapVertical : (cur.descending ? AppIcons.arrowDown : AppIcons.arrowUp),
      label: cur == null ? 'Ordina' : cur.column,
      tooltip: 'Ordina',
      entries: () => [
        MenuEntry('Nessun ordinamento', checked: cur == null, onSelected: () => onChanged(null)),
        const MenuEntry.divider(),
        for (final col in columns) ...[
          MenuEntry(
            '${col.name} crescente',
            checked: on(col.name, false),
            onSelected: () => onChanged(SortKey(col.name)),
          ),
          MenuEntry(
            '${col.name} decrescente',
            checked: on(col.name, true),
            onSelected: () => onChanged(SortKey(col.name, descending: true)),
          ),
        ],
      ],
    );
  }
}

/// Popover to create or edit a condition. Returns null when cancelled.
Future<FilterCondition?> showFilterPopover(
  BuildContext anchorContext,
  List<FilterColumn> columns, {
  FilterCondition? initial,
}) => showPopover<FilterCondition>(
  anchorContext,
  anchor: anchorRect(anchorContext),
  builder: (_) => SizedBox(
    width: 300,
    child: _FilterPopover(columns: columns, initial: initial),
  ),
);

class _FilterPopover extends StatefulWidget {
  const _FilterPopover({required this.columns, this.initial});
  final List<FilterColumn> columns;
  final FilterCondition? initial;

  @override
  State<_FilterPopover> createState() => _FilterPopoverState();
}

class _FilterPopoverState extends State<_FilterPopover> {
  late FilterColumn _col = widget.columns.firstWhere(
    (c) => c.name == widget.initial?.column,
    orElse: () => widget.columns.first,
  );
  late FilterOp _op = widget.initial?.op ?? _defaultOp(_col.kind);
  late final _v1 = TextEditingController(text: widget.initial?.value ?? '');
  late final _v2 = TextEditingController(text: widget.initial?.value2 ?? '');

  static FilterOp _defaultOp(ValueKind k) => k == ValueKind.text ? FilterOp.like : FilterOp.eq;

  @override
  void dispose() {
    _v1.dispose();
    _v2.dispose();
    super.dispose();
  }

  bool get _valid => switch (_op.arity) {
    0 => true,
    2 => _v1.text.trim().isNotEmpty && _v2.text.trim().isNotEmpty,
    _ =>
      _v1.text.trim().isNotEmpty ||
          _col.kind == ValueKind.boolean ||
          (_col.kind == ValueKind.text && _op != FilterOp.inList),
  };

  void _submit() {
    if (_col.kind == ValueKind.boolean && _v1.text.isEmpty) _v1.text = 'sì';
    if (!_valid) return;
    Navigator.pop(
      context,
      FilterCondition(column: _col.name, kind: _col.kind, op: _op, value: _v1.text.trim(), value2: _v2.text.trim()),
    );
  }

  static String _day(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// A timestamp literal: "aaaa-mm-gg hh:mm", with the seconds when set.
  static String _stamp(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${_day(d)} ${two(d.hour)}:${two(d.minute)}${d.second == 0 ? '' : ':${two(d.second)}'}';
  }

  Widget _valueField(TextEditingController ctrl, String hint) {
    if (_col.kind == ValueKind.boolean) {
      final v = ctrl.text.isEmpty ? 'sì' : ctrl.text;
      return Align(
        alignment: Alignment.centerLeft,
        child: Segmented<String>(
          value: v,
          items: const [('sì', 'Sì', null), ('no', 'No', null)],
          onChanged: (x) => setState(() => ctrl.text = x),
        ),
      );
    }
    final stamp = _col.kind == ValueKind.timestamp;
    if ((stamp || _col.kind == ValueKind.date) && _op != FilterOp.inList) {
      return Align(
        alignment: Alignment.centerLeft,
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.enter): _submit},
          child: DateField(
            value: DateTime.tryParse(ctrl.text.trim()),
            time: stamp,
            onChanged: (d) => setState(() => ctrl.text = d == null ? '' : (stamp ? _stamp(d) : _day(d))),
          ),
        ),
      );
    }
    return MacTextField(
      controller: ctrl,
      autofocus: ctrl == _v1,
      hint: hint,
      tabular: true,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    );
  }

  String get _hint => switch (_col.kind) {
    _ when _op == FilterOp.inList => 'valori separati da virgola',
    ValueKind.number => 'numero',
    ValueKind.date => 'aaaa-mm-gg',
    ValueKind.timestamp => 'aaaa-mm-gg hh:mm',
    _ when _op == FilterOp.like || _op == FilterOp.notLike => 'testo (% e _ come jolly)',
    _ => 'valore',
  };

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final ops = FilterOp.forKind(_col.kind);
    if (!ops.contains(_op)) _op = ops.first;
    final label = uiText(TypeSize.small, color: c.textSecondary);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Colonna', style: label),
        const SizedBox(height: 4),
        PopUpButton<String>(
          value: _col.name,
          expand: true,
          items: [for (final col in widget.columns) (col.name, col.name, null)],
          entries: () => [
            for (final col in widget.columns)
              MenuEntry(
                col.name,
                value: col.name,
                checked: col.name == _col.name,
                trailing: col.typeName.isEmpty ? null : TypeLabel(col.typeName.toLowerCase()),
              ),
          ],
          onChanged: (v) => setState(() {
            final prev = _col.kind;
            _col = widget.columns.firstWhere((e) => e.name == v);
            if (prev != _col.kind) {
              _op = _defaultOp(_col.kind);
              _v1.clear();
              _v2.clear();
            }
          }),
        ),
        const SizedBox(height: Gap.sm),
        Text('Condizione', style: label),
        const SizedBox(height: 4),
        PopUpButton<FilterOp>(
          value: _op,
          expand: true,
          items: [for (final o in ops) (o, o == FilterOp.like ? 'contiene' : o.label, null)],
          onChanged: (v) => setState(() => _op = v),
        ),
        if (_op.arity > 0) ...[
          const SizedBox(height: Gap.sm),
          Text(_op.arity == 2 ? 'Da' : 'Valore', style: label),
          const SizedBox(height: 4),
          _valueField(_v1, _hint),
        ],
        if (_op.arity == 2) ...[
          const SizedBox(height: Gap.sm),
          Text('A', style: label),
          const SizedBox(height: 4),
          _valueField(_v2, _hint),
        ],
        const SizedBox(height: Gap.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
            const SizedBox(width: Gap.sm),
            PushButton.primary(
              label: widget.initial == null ? 'Aggiungi' : 'Applica',
              onPressed: _valid ? _submit : null,
            ),
          ],
        ),
      ],
    );
  }
}
