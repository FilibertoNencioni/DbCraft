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
}) => showSheet<TableEditResult>(
  context,
  size: SheetSize.xlarge,
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
    final head = uiText(TypeSize.caption, weight: FontWeight.w600, color: c.textSecondary);
    Widget check(bool v, ValueChanged<bool> on, {bool enabled = true, required String label}) => SizedBox(
      width: 46,
      child: Center(
        child: MacCheckbox(value: v, semanticLabel: label, onChanged: enabled ? (x) => setState(() => on(x)) : null),
      ),
    );
    return SheetScaffold(
      title: widget.initial == null ? 'Nuova tabella' : 'Modifica tabella',
      onSubmit: _save,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Nome', style: uiText(TypeSize.body, color: c.text)),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: MacTextField(controller: _name, autofocus: widget.initial == null),
              ),
              const SizedBox(width: Gap.lg),
              Text('Commento', style: uiText(TypeSize.body, color: c.text)),
              const SizedBox(width: Gap.sm),
              Expanded(flex: 2, child: MacTextField(controller: _comment)),
            ],
          ),
          const SizedBox(height: Gap.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
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
                const SizedBox(width: 60),
              ],
            ),
          ),
          const SizedBox(height: Gap.xs),
          Expanded(
            child: InsetBox(
              child: ListView.builder(
                itemCount: _rows.length,
                itemBuilder: (context, i) {
                  final r = _rows[i];
                  final isNew = r.initialName == null && widget.initial != null;
                  return Container(
                    key: ObjectKey(r),
                    color: i.isOdd ? c.zebra : null,
                    padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          // New column of an existing table: its name in the "added" color.
                          child: MacTextField(
                            controller: r.name,
                            small: true,
                            hint: 'nome',
                            color: isNew ? c.diffAdded : null,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          flex: 3,
                          child: ComboField(
                            controller: r.type,
                            small: true,
                            hint: 'tipo',
                            options: () => types,
                            // A type without size picked from the menu drops the size; typing
                            // (and its inline completion) leaves it alone.
                            onSelected: (t) {
                              if (!isSizedType(t) && !isScaledType(t)) setState(r.size.clear);
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(width: 78, child: MacTextField(controller: r.size, small: true, tabular: true)),
                        check(r.nullable && !r.pk, (v) => r.nullable = v, enabled: !r.pk, label: 'Null'),
                        const SizedBox(width: 6),
                        Expanded(
                          flex: 2,
                          child: MacTextField(controller: r.def, enabled: !r.auto, small: true, mono: true),
                        ),
                        check(r.pk, (v) => r.pk = v, label: 'Chiave primaria'),
                        check(r.auto, (v) => r.auto = v, label: 'Auto-incremento'),
                        SizedBox(
                          width: 60,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              ToolButton(
                                icon: AppIcons.arrowUp,
                                extent: 18,
                                tooltip: 'Sposta su',
                                onPressed: i == 0 ? null : () => setState(() => _rows.insert(i - 1, _rows.removeAt(i))),
                              ),
                              ToolButton(
                                icon: AppIcons.arrowDown,
                                extent: 18,
                                tooltip: 'Sposta giù',
                                onPressed: i == _rows.length - 1
                                    ? null
                                    : () => setState(() => _rows.insert(i + 1, _rows.removeAt(i))),
                              ),
                              ToolButton(
                                icon: AppIcons.removeCircle,
                                extent: 18,
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
          Align(
            alignment: Alignment.centerLeft,
            child: ToolButton(
              icon: AppIcons.add,
              label: 'Aggiungi colonna',
              tooltip: 'Aggiungi una colonna',
              onPressed: () => setState(() => _rows.add(_ColRow(type: types.first))),
            ),
          ),
        ],
      ),
      leading: [if (_error != null) Flexible(child: StatusLine(_error!, kind: StatusKind.danger))],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: widget.initial == null ? 'Crea' : 'Applica', onPressed: _save),
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
}) => showSheet<ForeignKeyDef>(
  context,
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

  void _create() {
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
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    Widget rule(FkRule v, ValueChanged<FkRule> on) => PopUpButton<FkRule>(
      value: v,
      items: [for (final r in FkRule.values) (r, r.sql, null)],
      onChanged: (x) => setState(() => on(x)),
    );
    return SheetScaffold(
      title: 'Nuova relazione',
      onSubmit: _create,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.child.name}.${widget.childColumn}  →  ${widget.parent.name}.${widget.parentColumn}',
            style: monoStyle(context, size: TypeSize.mono, color: c.textSecondary),
          ),
          const SizedBox(height: Gap.md),
          FormGroup(
            children: [
              FormRow(
                label: 'Nome',
                child: MacTextField(controller: _name),
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
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Notice(message: w),
            ),
        ],
      ),
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: 'Crea', onPressed: _create),
      ],
    );
  }
}
