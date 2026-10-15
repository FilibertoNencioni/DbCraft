// Dialogs of the ER diagram editor: table definition and new relationship.

import 'package:flutter/material.dart';

import '../../services/sql_dialect.dart';
import '../../ui/widgets/common.dart';
import 'schema_model.dart';

/// Result of [showTableDefDialog].
class TableEditResult {
  TableEditResult(this.table, this.renamedColumns, this.removedColumns);
  final TableDef table;

  /// Columns renamed in this edit (name before → name after).
  final Map<String, String> renamedColumns;

  /// Columns removed in this edit (names before the edit).
  final Set<String> removedColumns;
}

/// Creates ([initial] null) or edits a table definition: name, comment and a
/// grid of columns (name, type, size, null, default, PK, auto-increment).
/// [takenNames] are the names of the other tables of the diagram.
Future<TableEditResult?> showTableDefDialog(
  BuildContext context, {
  required SqlDialect dialect,
  TableDef? initial,
  String? catalog,
  String? schema,
  Set<String> takenNames = const {},
}) => showDialog<TableEditResult>(
  context: context,
  builder: (_) => _TableDefDialog(
    dialect: dialect,
    initial: initial,
    catalog: catalog,
    schema: schema,
    takenNames: takenNames.map((e) => e.toLowerCase()).toSet(),
  ),
);

class _ColRow {
  _ColRow({
    String name = '',
    String type = '',
    String size = '',
    String def = '',
    this.nullable = true,
    this.pk = false,
    this.auto = false,
    this.initialName,
    this.originalName,
    this.comment,
  }) : name = TextEditingController(text: name),
       type = TextEditingController(text: type),
       size = TextEditingController(text: size),
       def = TextEditingController(text: def);

  factory _ColRow.of(ColumnDef c, bool pk) => _ColRow(
    name: c.name,
    type: c.type,
    size: c.size == null
        ? ''
        : (c.size == -1 ? 'max' : (c.scale != null && c.scale! > 0 ? '${c.size},${c.scale}' : '${c.size}')),
    def: c.defaultValue ?? '',
    nullable: c.nullable,
    pk: pk,
    auto: c.autoIncrement,
    initialName: c.name,
    originalName: c.originalName,
    comment: c.comment,
  );

  final TextEditingController name, type, size, def;
  bool nullable, pk, auto;
  final String? initialName;
  final String? originalName;
  final String? comment;

  void dispose() {
    name.dispose();
    type.dispose();
    size.dispose();
    def.dispose();
  }
}

class _TableDefDialog extends StatefulWidget {
  const _TableDefDialog({
    required this.dialect,
    required this.initial,
    required this.catalog,
    required this.schema,
    required this.takenNames,
  });

  final SqlDialect dialect;
  final TableDef? initial;
  final String? catalog;
  final String? schema;
  final Set<String> takenNames;

  @override
  State<_TableDefDialog> createState() => _TableDefDialogState();
}

class _TableDefDialogState extends State<_TableDefDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _comment = TextEditingController(text: widget.initial?.comment ?? '');
  final List<_ColRow> _rows = [];

  /// Removed rows: disposed with the dialog (their fields may still be mounted).
  final List<_ColRow> _removed = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    if (t != null) {
      _rows.addAll(t.columns.map((c) => _ColRow.of(c, t.isPk(c.name))));
    } else {
      final types = commonTypes(widget.dialect.family);
      _rows.add(_ColRow(name: 'id', type: types.first, nullable: false, pk: true, auto: true));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _comment.dispose();
    for (final r in [..._rows, ..._removed]) {
      r.dispose();
    }
    super.dispose();
  }

  (int?, int?)? _parseSize(String s) {
    final t = s.trim().toLowerCase();
    if (t.isEmpty) return (null, null);
    if (t == 'max') return (-1, null);
    final m = RegExp(r'^(\d+)\s*(?:,\s*(\d+))?$').firstMatch(t);
    if (m == null) return null;
    return (int.parse(m.group(1)!), m.group(2) == null ? null : int.parse(m.group(2)!));
  }

  void _save() {
    final name = _name.text.trim();
    String? err;
    if (name.isEmpty) err = 'Inserisci il nome della tabella';
    if (err == null && widget.takenNames.contains(name.toLowerCase())) err = 'Esiste già una tabella "$name"';
    if (err == null && _rows.isEmpty) err = 'Aggiungi almeno una colonna';
    final seen = <String>{};
    final cols = <ColumnDef>[];
    for (final r in _rows) {
      if (err != null) break;
      final n = r.name.text.trim();
      final type = r.type.text.trim();
      final size = _parseSize(r.size.text);
      if (n.isEmpty) {
        err = 'Ogni colonna deve avere un nome';
      } else if (!seen.add(n.toLowerCase())) {
        err = 'Colonna "$n" duplicata';
      } else if (type.isEmpty) {
        err = 'Indica il tipo della colonna "$n"';
      } else if (size == null) {
        err = 'Dimensione non valida per "$n": usa 50, 10,2 oppure max';
      } else {
        final def = r.def.text.trim();
        cols.add(
          ColumnDef(
            name: n,
            type: type,
            size: size.$1,
            scale: size.$2,
            nullable: r.pk ? false : r.nullable,
            defaultValue: def.isEmpty || r.auto ? null : def,
            autoIncrement: r.auto,
            comment: r.comment,
            originalName: r.originalName,
          ),
        );
      }
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final pkCols = [
      for (final r in _rows)
        if (r.pk) r.name.text.trim(),
    ];
    final init = widget.initial;
    final comment = _comment.text.trim();
    final table = (init ?? TableDef(catalog: widget.catalog, schema: widget.schema, name: name, columns: const []))
        .copyWith(
          name: name,
          comment: comment.isEmpty ? null : comment,
          columns: cols,
          primaryKey: pkCols.isEmpty
              ? null
              : PrimaryKeyDef(name: init?.primaryKey?.name ?? (init == null ? '${name}_pk' : null), columns: pkCols),
        );
    final renamed = <String, String>{};
    final kept = <String>{};
    for (final r in _rows) {
      final before = r.initialName;
      if (before == null) continue;
      kept.add(before);
      if (before != r.name.text.trim()) renamed[before] = r.name.text.trim();
    }
    final removed = {
      for (final c in init?.columns ?? const <ColumnDef>[])
        if (!kept.contains(c.name)) c.name,
    };
    Navigator.pop(context, TableEditResult(table, renamed, removed));
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final types = commonTypes(widget.dialect.family);
    final head = TextStyle(fontSize: TypeSize.caption, fontWeight: FontWeight.w600, color: c.textTertiary);
    InputDecoration deco([String? hint]) =>
        InputDecoration(hintText: hint, contentPadding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7));
    const fieldStyle = TextStyle(fontSize: TypeSize.body);
    Widget check(bool v, ValueChanged<bool> on, {bool enabled = true}) => SizedBox(
      width: 46,
      child: Center(
        child: Checkbox(value: v, onChanged: enabled ? (x) => setState(() => on(x ?? false)) : null),
      ),
    );
    return AlertDialog(
      title: Text(widget.initial == null ? 'Nuova tabella' : 'Modifica tabella'),
      content: SizedBox(
        width: 900,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    autofocus: widget.initial == null,
                    style: fieldStyle,
                    decoration: const InputDecoration(labelText: 'Nome'),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _comment,
                    style: fieldStyle,
                    decoration: const InputDecoration(labelText: 'Commento'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                children: [
                  Expanded(flex: 3, child: Text('Nome', style: head)),
                  const SizedBox(width: 6),
                  Expanded(flex: 3, child: Text('Tipo', style: head)),
                  const SizedBox(width: 6),
                  SizedBox(width: 78, child: Text('Dimensione', style: head)),
                  SizedBox(
                    width: 46,
                    child: Center(child: Text('Null', style: head)),
                  ),
                  const SizedBox(width: 6),
                  Expanded(flex: 2, child: Text('Default', style: head)),
                  SizedBox(
                    width: 46,
                    child: Center(child: Text('PK', style: head)),
                  ),
                  SizedBox(
                    width: 46,
                    child: Center(child: Text('Auto', style: head)),
                  ),
                  const SizedBox(width: 90),
                ],
              ),
            ),
            const SizedBox(height: Gap.xs),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: c.separator),
                  borderRadius: BorderRadius.circular(Radii.panel),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                  itemCount: _rows.length,
                  itemBuilder: (context, i) {
                    final r = _rows[i];
                    final isNew = r.initialName == null && widget.initial != null;
                    return Container(
                      key: ObjectKey(r),
                      color: i.isOdd ? c.zebra : null,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: r.name,
                              style: fieldStyle.copyWith(color: isNew ? c.success : null),
                              decoration: deco('nome'),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: r.type,
                              style: fieldStyle,
                              decoration: deco('tipo').copyWith(
                                suffixIcon: PopupMenuButton<String>(
                                  tooltip: 'Tipi comuni',
                                  padding: EdgeInsets.zero,
                                  iconSize: 18,
                                  icon: const Icon(Icons.arrow_drop_down_rounded),
                                  itemBuilder: (_) => [
                                    for (final t in types)
                                      PopupMenuItem(
                                        value: t,
                                        height: 28,
                                        child: Text(t, style: monoStyle(context, size: 12)),
                                      ),
                                  ],
                                  onSelected: (t) => setState(() {
                                    r.type.text = t;
                                    if (!isSizedType(t) && !isScaledType(t)) r.size.clear();
                                  }),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 78,
                            child: TextField(controller: r.size, style: fieldStyle, decoration: deco()),
                          ),
                          check(r.nullable && !r.pk, (v) => r.nullable = v, enabled: !r.pk),
                          const SizedBox(width: 6),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: r.def,
                              enabled: !r.auto,
                              style: monoStyle(context, size: 12.5),
                              decoration: deco(),
                            ),
                          ),
                          check(r.pk, (v) => r.pk = v),
                          check(r.auto, (v) => r.auto = v),
                          SizedBox(
                            width: 90,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                ToolButton(
                                  icon: Icons.arrow_upward_rounded,
                                  size: 14,
                                  tooltip: 'Sposta su',
                                  onPressed: i == 0
                                      ? null
                                      : () => setState(() => _rows.insert(i - 1, _rows.removeAt(i))),
                                ),
                                ToolButton(
                                  icon: Icons.arrow_downward_rounded,
                                  size: 14,
                                  tooltip: 'Sposta giù',
                                  onPressed: i == _rows.length - 1
                                      ? null
                                      : () => setState(() => _rows.insert(i + 1, _rows.removeAt(i))),
                                ),
                                ToolButton(
                                  icon: Icons.remove_circle_outline_rounded,
                                  size: 14,
                                  color: c.danger,
                                  tooltip: 'Elimina colonna',
                                  onPressed: () => setState(() => _removed.add(_rows.removeAt(i))),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                ToolButton(
                  icon: Icons.add_rounded,
                  label: 'Aggiungi colonna',
                  tooltip: 'Aggiungi una colonna',
                  onPressed: () => setState(() => _rows.add(_ColRow(type: types.first))),
                ),
                const SizedBox(width: Gap.md),
                if (_error != null)
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: TypeSize.small, color: c.danger),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        FilledButton(onPressed: _save, child: Text(widget.initial == null ? 'Crea' : 'Applica')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Relationship
// ---------------------------------------------------------------------------

/// Confirms a new foreign key from [child].[childColumn] to
/// [parent].[parentColumn]: name and referential actions.
Future<ForeignKeyDef?> showRelationDialog(
  BuildContext context, {
  required TableDef child,
  required String childColumn,
  required TableDef parent,
  required String parentColumn,
  Set<String> takenNames = const {},
}) => showDialog<ForeignKeyDef>(
  context: context,
  builder: (_) => _RelationDialog(
    child: child,
    childColumn: childColumn,
    parent: parent,
    parentColumn: parentColumn,
    takenNames: takenNames,
  ),
);

class _RelationDialog extends StatefulWidget {
  const _RelationDialog({
    required this.child,
    required this.childColumn,
    required this.parent,
    required this.parentColumn,
    required this.takenNames,
  });

  final TableDef child;
  final String childColumn;
  final TableDef parent;
  final String parentColumn;
  final Set<String> takenNames;

  @override
  State<_RelationDialog> createState() => _RelationDialogState();
}

class _RelationDialogState extends State<_RelationDialog> {
  late final TextEditingController _name;
  FkRule _onDelete = FkRule.noAction;
  FkRule _onUpdate = FkRule.noAction;

  @override
  void initState() {
    super.initState();
    final base = 'fk_${widget.child.name}_${widget.parent.name}';
    var n = base;
    for (var i = 2; widget.takenNames.contains(n.toLowerCase()); i++) {
      n = '${base}_$i';
    }
    _name = TextEditingController(text: n);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<String> get _warnings {
    final w = <String>[];
    final p = widget.parent;
    final unique =
        (p.primaryKey?.columns.length == 1 && p.isPk(widget.parentColumn)) ||
        p.indexes.any((i) => i.unique && i.columns.length == 1 && i.columns.first == widget.parentColumn);
    if (!unique) {
      w.add(
        'La colonna ${p.name}.${widget.parentColumn} non è chiave primaria né univoca: il database potrebbe rifiutare la relazione.',
      );
    }
    final a = widget.child.column(widget.childColumn), b = p.column(widget.parentColumn);
    if (a != null && b != null && canonicalType(a.type) != canonicalType(b.type)) {
      w.add('I tipi non coincidono (${a.fullType} → ${b.fullType}).');
    }
    if (_onDelete == FkRule.setNull && a != null && !a.nullable) {
      w.add('SET NULL richiede che ${widget.childColumn} ammetta valori null.');
    }
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    DropdownButton<FkRule> rule(FkRule v, ValueChanged<FkRule> on) => DropdownButton<FkRule>(
      value: v,
      isDense: true,
      underline: const SizedBox(),
      style: TextStyle(fontSize: TypeSize.body, color: c.text),
      items: [for (final r in FkRule.values) DropdownMenuItem(value: r, child: Text(r.sql))],
      onChanged: (x) => setState(() => on(x ?? v)),
    );
    return AlertDialog(
      title: const Text('Nuova relazione'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.child.name}.${widget.childColumn}  →  ${widget.parent.name}.${widget.parentColumn}',
              style: monoStyle(context, size: 12.5),
            ),
            const SizedBox(height: Gap.md),
            FormGroup(
              children: [
                FormRow(
                  label: 'Nome',
                  child: TextField(
                    controller: _name,
                    style: const TextStyle(fontSize: TypeSize.body),
                  ),
                ),
                FormRow(
                  label: 'In eliminazione',
                  child: Align(alignment: Alignment.centerLeft, child: rule(_onDelete, (r) => _onDelete = r)),
                ),
                FormRow(
                  label: 'In aggiornamento',
                  child: Align(alignment: Alignment.centerLeft, child: rule(_onUpdate, (r) => _onUpdate = r)),
                ),
              ],
            ),
            for (final w in _warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 15, color: c.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        w,
                        style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        FilledButton(
          onPressed: () {
            final n = _name.text.trim();
            Navigator.pop(
              context,
              ForeignKeyDef(
                name: n.isEmpty ? null : n,
                columns: [widget.childColumn],
                refCatalog: widget.parent.catalog,
                refSchema: widget.parent.schema,
                refTable: widget.parent.name,
                refColumns: [widget.parentColumn],
                onDelete: _onDelete,
                onUpdate: _onUpdate,
              ),
            );
          },
          child: const Text('Crea'),
        ),
      ],
    );
  }
}
