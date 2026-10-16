// Visual filter bar for the table data editor (simplified analyst view):
// "column operator value" chips combined with AND plus a sort chooser. The
// WHERE / ORDER BY strings are generated with the dialect quoting.

import 'package:flutter/material.dart';

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
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.fromLTRB(Gap.sm, 6, Gap.sm, 6),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: Gap.sm),
            child: Icon(AppIcons.filter, size: 15, color: c.textSecondary),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (filter.customWhere.trim().isNotEmpty)
                  Tooltip(
                    message: filter.customWhere,
                    child: _Chip(
                      label: 'SQL: ${filter.customWhere.trim()}',
                      onTap: () {},
                      onRemove: () {
                        filter.customWhere = '';
                        onChanged();
                      },
                    ),
                  ),
                for (final (i, cond) in filter.conditions.indexed) ...[
                  if (i > 0)
                    Text(
                      'e',
                      style: TextStyle(fontSize: TypeSize.small, color: c.textTertiary),
                    ),
                  Builder(
                    builder: (ctx) => _Chip(
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
                Builder(
                  builder: (ctx) => _AddButton(
                    label: filter.conditions.isEmpty ? 'Aggiungi filtro' : 'Aggiungi',
                    onTap: columns.isEmpty
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
              ],
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

class _Chip extends StatefulWidget {
  const _Chip({required this.label, required this.onTap, required this.onRemove});
  final String label;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 26,
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: _hover ? 0.18 : 0.12),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.text, fontFeatures: kTabular),
                ),
              ),
              const SizedBox(width: 2),
              Tooltip(
                message: 'Rimuovi filtro',
                child: GestureDetector(
                  onTap: widget.onRemove,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(AppIcons.close, size: 13, color: c.textSecondary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) =>
      ToolButton(icon: AppIcons.add, tooltip: 'Aggiungi un filtro', label: label, onPressed: onTap);
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.columns, required this.current, required this.onChanged});
  final List<FilterColumn> columns;
  final SortKey? current;
  final ValueChanged<SortKey?> onChanged;

  @override
  Widget build(BuildContext context) {
    final cur = current;
    return PopupMenuButton<SortKey?>(
      tooltip: 'Ordina',
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (ctx) => [
        const PopupMenuItem<SortKey?>(height: 28, value: null, child: Text('Nessun ordinamento')),
        const PopupMenuDivider(height: 9),
        for (final col in columns) ...[
          PopupMenuItem<SortKey?>(
            height: 28,
            value: SortKey(col.name),
            child: Row(
              children: [
                const Icon(AppIcons.arrowUp, size: 14),
                const SizedBox(width: 8),
                Text('${col.name} crescente'),
              ],
            ),
          ),
          PopupMenuItem<SortKey?>(
            height: 28,
            value: SortKey(col.name, descending: true),
            child: Row(
              children: [
                const Icon(AppIcons.arrowDown, size: 14),
                const SizedBox(width: 8),
                Text('${col.name} decrescente'),
              ],
            ),
          ),
        ],
      ],
      child: IgnorePointer(
        child: ToolButton(
          icon: cur == null
              ? AppIcons.swapVertical
              : (cur.descending ? AppIcons.arrowDown : AppIcons.arrowUp),
          tooltip: 'Ordina',
          active: cur != null,
          label: cur == null ? 'Ordina' : cur.column,
          onPressed: () {},
        ),
      ),
    );
  }
}

/// Popover to create or edit a condition. Returns null when cancelled.
Future<FilterCondition?> showFilterPopover(
  BuildContext anchorContext,
  List<FilterColumn> columns, {
  FilterCondition? initial,
}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchorContext).context.findRenderObject() as RenderBox?;
  var anchor = Offset.zero;
  if (box != null && overlay != null) {
    anchor = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
  }
  final screen = overlay?.size ?? const Size(1200, 800);
  const width = 340.0;
  final left = anchor.dx.clamp(8.0, (screen.width - width - 8).clamp(8.0, double.infinity));
  final top = anchor.dy.clamp(8.0, (screen.height - 260).clamp(8.0, double.infinity));
  return showGeneralDialog<FilterCondition>(
    context: anchorContext,
    barrierDismissible: true,
    barrierLabel: 'Chiudi',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, _, _) => Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          child: _FilterPopover(columns: columns, initial: initial),
        ),
      ],
    ),
  );
}

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

  bool get _isDate => _col.kind == ValueKind.date || _col.kind == ValueKind.timestamp;

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

  Future<void> _pickDate(TextEditingController ctrl) async {
    final now = DateTime.now();
    final cur = DateTime.tryParse(ctrl.text.trim()) ?? now;
    final d = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year + 50),
    );
    if (d == null) return;
    String two(int n) => n.toString().padLeft(2, '0');
    setState(() => ctrl.text = '${d.year}-${two(d.month)}-${two(d.day)}');
  }

  Widget _valueField(TextEditingController ctrl, String hint) {
    final c = DbColors.of(context);
    if (_col.kind == ValueKind.boolean) {
      final v = ctrl.text.isEmpty ? 'sì' : ctrl.text;
      return Segmented<String>(
        value: v,
        items: const [('sì', 'Sì', null), ('no', 'No', null)],
        onChanged: (x) => setState(() => ctrl.text = x),
      );
    }
    return SizedBox(
      height: 28,
      child: TextField(
        controller: ctrl,
        autofocus: ctrl == _v1,
        style: const TextStyle(fontSize: TypeSize.body, fontFeatures: kTabular),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          suffixIcon: _isDate
              ? GestureDetector(
                  onTap: () => _pickDate(ctrl),
                  child: Icon(AppIcons.calendar, size: 14, color: c.textSecondary),
                )
              : null,
          suffixIconConstraints: const BoxConstraints(minWidth: 28),
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
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
    final label = TextStyle(fontSize: TypeSize.small, color: c.textSecondary);
    return Material(
      color: c.raised,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(Radii.panel + 2),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Colonna', style: label),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _col.name,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              items: [
                for (final col in widget.columns)
                  DropdownMenuItem(
                    value: col.name,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: col.name),
                          TextSpan(
                            text: '  ${col.typeName.toLowerCase()}',
                            style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
                          ),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
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
            DropdownButtonFormField<FilterOp>(
              initialValue: _op,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              items: [
                for (final o in ops) DropdownMenuItem(value: o, child: Text(o == FilterOp.like ? 'contiene' : o.label)),
              ],
              onChanged: (v) => setState(() => _op = v ?? _op),
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
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
                const SizedBox(width: Gap.sm),
                PrimaryButton(
                  label: widget.initial == null ? 'Aggiungi' : 'Applica',
                  onPressed: _valid ? _submit : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
