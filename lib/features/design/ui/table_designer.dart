// Editable pages of the table designer (object editor of a table): general
// properties, columns, pending changes. The constraint and index pages are
// in constraints_page.dart (with a TableDesign they edit the design).

import 'package:flutter/material.dart';

import '../../../services/sql_dialect.dart';
import '../../../state/db_connection.dart';
import '../../../state/editor_tabs.dart';
import '../../../ui/editors/sql_code_editor.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_builder.dart';
import '../../schema/schema_model.dart';
import '../capabilities.dart';
import '../catalog/design_catalog.dart';
import '../ddl_script.dart';
import '../table_design.dart';
import 'design_actions.dart';

/// Text controllers of the editable rows, kept in step with the model:
/// typing updates the model, undo / redo and moves update the fields.
class _Fields {
  final List<Map<String, TextEditingController>> _rows = [];

  TextEditingController of(int row, String field, String value) {
    while (_rows.length <= row) {
      _rows.add({});
    }
    final c = _rows[row].putIfAbsent(field, () => TextEditingController(text: value));
    if (c.text != value) {
      c.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length.clamp(0, value.length)),
      );
    }
    return c;
  }

  void dispose() {
    for (final r in _rows) {
      for (final c in r.values) {
        c.dispose();
      }
    }
  }
}

String _sizeText(ColumnDef c) => c.size == null
    ? ''
    : c.size == -1
    ? 'max'
    : (c.scale != null && c.scale! > 0 ? '${c.size},${c.scale}' : '${c.size}');

/// Parses "50", "10,2" or "max"; null when not valid.
(int?, int?)? parseColumnSize(String s) {
  final t = s.trim().toLowerCase();
  if (t.isEmpty) return (null, null);
  if (t == 'max') return (-1, null);
  final m = RegExp(r'^(\d+)\s*(?:,\s*(\d+))?$').firstMatch(t);
  if (m == null) return null;
  return (int.parse(m.group(1)!), m.group(2) == null ? null : int.parse(m.group(2)!));
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

class DesignPropertiesPage extends StatefulWidget {
  const DesignPropertiesPage({super.key, required this.design, required this.connection, this.footer});
  final TableDesign design;
  final DbConnection connection;

  /// Read-only details shown below the form (existing tables).
  final Widget? footer;

  @override
  State<DesignPropertiesPage> createState() => _DesignPropertiesPageState();
}

class _DesignPropertiesPageState extends State<DesignPropertiesPage> {
  final _fields = _Fields();

  TableDesign get d => widget.design;

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  void _option(String key, String value) {
    final o = Map.of(d.working.options);
    value.trim().isEmpty ? o.remove(key) : o[key] = value.trim();
    d.update(d.working.copyWith(options: o), coalesce: 'opt:$key');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final t = d.working;
        final family = widget.connection.dialect.family;
        final caps = DesignCapabilities.of(widget.connection.dialect);
        final c = DbColors.of(context);
        return ListView(
          padding: const EdgeInsets.all(Gap.lg),
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: FormGroup(
                  children: [
                    FormRow(
                      label: 'Nome',
                      child: MacTextField(
                        controller: _fields.of(0, 'name', t.name),
                        autofocus: d.isNew && t.name.isEmpty,
                        hint: 'nome della tabella',
                        onChanged: (v) => d.rename(v.trim()),
                      ),
                    ),
                    if (t.catalog != null)
                      FormRow(
                        label: 'Database',
                        child: Text(t.catalog!, style: uiText(TypeSize.body, color: c.text)),
                      ),
                    if (t.schema != null)
                      FormRow(
                        label: 'Schema',
                        child: Text(t.schema!, style: uiText(TypeSize.body, color: c.text)),
                      ),
                    if (caps.has(DesignFeature.comments) || family == DbFamily.mysql)
                      FormRow(
                        label: 'Commento',
                        child: MacTextField(
                          controller: _fields.of(0, 'comment', t.comment ?? ''),
                          maxLines: 3,
                          onChanged: (v) =>
                              d.update(t.copyWith(comment: v.trim().isEmpty ? null : v), coalesce: 'comment'),
                        ),
                      ),
                    if (family == DbFamily.mysql) ...[
                      FormRow(
                        label: 'Motore',
                        child: MacTextField(
                          controller: _fields.of(0, 'engine', t.options['engine'] ?? ''),
                          hint: 'InnoDB',
                          enabled: d.isNew,
                          onChanged: (v) => _option('engine', v),
                        ),
                      ),
                      FormRow(
                        label: 'Set di caratteri',
                        child: MacTextField(
                          controller: _fields.of(0, 'charset', t.options['charset'] ?? ''),
                          hint: 'utf8mb4',
                          enabled: d.isNew,
                          onChanged: (v) => _option('charset', v),
                        ),
                      ),
                    ],
                    if (family == DbFamily.postgres && d.isNew)
                      FormRow(
                        label: 'Registrazione',
                        help: 'Più veloce, ma i dati si perdono dopo un arresto anomalo',
                        child: CheckboxRow(
                          value: t.options['unlogged'] == 'true',
                          label: 'Tabella non registrata nel WAL (UNLOGGED)',
                          onChanged: (v) => _option('unlogged', v ? 'true' : ''),
                        ),
                      ),
                    if ((family == DbFamily.postgres || family == DbFamily.oracle || family == DbFamily.db2) && d.isNew)
                      FormRow(
                        label: 'Tablespace',
                        child: MacTextField(
                          controller: _fields.of(0, 'tablespace', t.options['tablespace'] ?? ''),
                          hint: 'predefinito',
                          onChanged: (v) => _option('tablespace', v),
                        ),
                      ),
                    if (family == DbFamily.bigquery && d.isNew) ...[
                      FormRow(
                        label: 'Partizionamento',
                        help: 'Espressione di PARTITION BY: DATE(creato), _PARTITIONDATE…',
                        child: MacTextField(
                          controller: _fields.of(0, 'partitionBy', t.options['partitionBy'] ?? ''),
                          mono: true,
                          hint: 'nessuno',
                          onChanged: (v) => _option('partitionBy', v),
                        ),
                      ),
                      FormRow(
                        label: 'Clustering',
                        help: 'Fino a 4 colonne, separate da virgola',
                        child: MacTextField(
                          controller: _fields.of(0, 'clusterBy', t.options['clusterBy'] ?? ''),
                          mono: true,
                          hint: 'nessuno',
                          onChanged: (v) => _option('clusterBy', v),
                        ),
                      ),
                    ],
                    if (family == DbFamily.sqlServer && d.isNew)
                      FormRow(
                        label: 'Filegroup',
                        child: MacTextField(
                          controller: _fields.of(0, 'filegroup', t.options['filegroup'] ?? ''),
                          hint: 'PRIMARY',
                          onChanged: (v) => _option('filegroup', v),
                        ),
                      ),
                    FormRow(
                      label: 'Riepilogo',
                      child: Text(
                        '${t.columns.length} colonne · ${t.primaryKey == null ? 'nessuna chiave primaria' : 'chiave (${t.primaryKey!.columns.join(', ')})'}'
                        ' · ${t.foreignKeys.length} chiavi esterne · ${t.indexes.length} indici',
                        style: uiText(TypeSize.small, color: c.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.footer != null) ...[
              const SizedBox(height: Gap.lg),
              const SectionLabel('Dettagli', padding: EdgeInsets.only(bottom: Gap.sm)),
              widget.footer!,
            ],
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Columns
// ---------------------------------------------------------------------------

class DesignColumnsPage extends StatefulWidget {
  const DesignColumnsPage({super.key, required this.design, required this.connection});
  final TableDesign design;
  final DbConnection connection;

  @override
  State<DesignColumnsPage> createState() => _DesignColumnsPageState();
}

class _DesignColumnsPageState extends State<DesignColumnsPage> {
  final _fields = _Fields();
  int? _selected;
  final Map<int, String> _sizeErrors = {};

  TableDesign get d => widget.design;

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  void _set(int i, ColumnDef c, String field) => d.setColumn(i, c, coalesce: 'col:$i:$field');

  Widget _check(bool value, ValueChanged<bool>? on, String label) =>
      MacCheckbox(value: value, semanticLabel: label, onChanged: on == null ? null : (v) => on(v));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final t = d.working;
        final dialect = widget.connection.dialect;
        final types = commonTypes(dialect.family);
        final sel = _selected != null && _selected! < t.columns.length ? _selected : null;
        final removed = d.removedColumns;
        final grid = EditableGrid(
          columns: const [
            EditableGridColumn('Nome', flex: 3),
            EditableGridColumn('Tipo', flex: 3),
            EditableGridColumn('Dimensione', width: 78, tooltip: 'Lunghezza o precisione: 50, 10,2 oppure max'),
            EditableGridColumn('Null', width: 40, center: true),
            EditableGridColumn('Default', flex: 2),
            EditableGridColumn('PK', width: 36, center: true, tooltip: 'Chiave primaria'),
            EditableGridColumn('Auto', width: 40, center: true, tooltip: 'Auto-incremento / identity'),
          ],
          rowCount: t.columns.length,
          selected: sel,
          onSelect: (i) => setState(() => _selected = i),
          mark: (i) => switch (d.columnMark(t.columns[i])) {
            ColumnMark.added => EditableRowMark.added,
            ColumnMark.changed => EditableRowMark.changed,
            ColumnMark.none => EditableRowMark.none,
          },
          addLabel: 'Aggiungi colonna',
          onAdd: () => setState(() => _selected = d.addColumn(after: sel)),
          onRemove: (i) {
            d.removeColumn(i);
            setState(() => _selected = null);
          },
          removeTooltip: 'Elimina la colonna',
          onMove: (a, b) {
            d.moveColumn(a, b);
            setState(() => _selected = b);
          },
          emptyText: 'Nessuna colonna',
          cellBuilder: (context, i, col) {
            final c = t.columns[i];
            final pk = t.isPk(c.name);
            switch (col) {
              case 0:
                return MacTextField(
                  controller: _fields.of(i, 'name', c.name),
                  small: true,
                  hint: 'nome',
                  onChanged: (v) => _set(i, c.copyWith(name: v.trim()), 'name'),
                );
              case 1:
                return ComboField(
                  controller: _fields.of(i, 'type', c.type),
                  small: true,
                  hint: 'tipo',
                  options: () => types,
                  onChanged: (v) => _set(i, c.copyWith(type: v.trim()), 'type'),
                  onSelected: (v) {
                    final keep = isSizedType(v) || isScaledType(v);
                    _set(i, c.copyWith(type: v, size: keep ? c.size : null, scale: keep ? c.scale : null), 'type');
                  },
                );
              case 2:
                return MacTextField(
                  controller: _fields.of(i, 'size', _sizeText(c)),
                  small: true,
                  tabular: true,
                  error: _sizeErrors[i],
                  onChanged: (v) {
                    final s = parseColumnSize(v);
                    setState(() => s == null ? _sizeErrors[i] = 'Usa 50, 10,2 oppure max' : _sizeErrors.remove(i));
                    if (s != null) _set(i, c.copyWith(size: s.$1, scale: s.$2), 'size');
                  },
                );
              case 3:
                return _check(c.nullable && !pk, pk ? null : (v) => _set(i, c.copyWith(nullable: v), 'null'), 'Null');
              case 4:
                return MacTextField(
                  controller: _fields.of(i, 'default', c.defaultValue ?? ''),
                  small: true,
                  mono: true,
                  enabled: !c.autoIncrement && !c.isComputed,
                  onChanged: (v) => _set(i, c.copyWith(defaultValue: v.trim().isEmpty ? null : v.trim()), 'default'),
                );
              case 5:
                return _check(pk, (v) => d.togglePrimaryKey(c.name, v), 'Chiave primaria');
              default:
                return _check(
                  c.autoIncrement,
                  c.isComputed
                      ? null
                      : (v) => _set(i, c.copyWith(autoIncrement: v, defaultValue: v ? null : c.defaultValue), 'auto'),
                  'Auto-incremento',
                );
            }
          },
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(child: grid),
                    if (removed.isNotEmpty) ...[
                      const SizedBox(height: Gap.md),
                      Notice(
                        message:
                            'Colonne eliminate (i loro dati andranno persi): ${removed.map((c) => c.name).join(', ')}',
                      ),
                      Wrap(
                        spacing: Gap.sm,
                        children: [
                          for (final c in removed)
                            LinkButton(label: 'Ripristina ${c.name}', onPressed: () => d.restoreColumn(c)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (sel != null)
              _ColumnInspector(key: ValueKey(sel), design: d, index: sel, dialect: widget.connection.dialect),
          ],
        );
      },
    );
  }
}

/// Details of the selected column: comment, collation, computed value,
/// identity start and step.
class _ColumnInspector extends StatefulWidget {
  const _ColumnInspector({super.key, required this.design, required this.index, required this.dialect});
  final TableDesign design;
  final int index;
  final SqlDialect dialect;

  @override
  State<_ColumnInspector> createState() => _ColumnInspectorState();
}

class _ColumnInspectorState extends State<_ColumnInspector> {
  final _fields = _Fields();

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.design;
    final i = widget.index;
    final c = d.working.columns[i];
    final caps = DesignCapabilities.of(widget.dialect);
    final family = widget.dialect.family;
    void set(ColumnDef x, String field) => d.setColumn(i, x, coalesce: 'col:$i:$field');
    int? number(String v) => v.trim().isEmpty ? null : int.tryParse(v.trim());
    return Inspector(
      children: [
        InspectorSection(
          title: c.name.isEmpty ? 'Colonna' : c.name,
          children: [
            if (caps.has(DesignFeature.comments) || family == DbFamily.mysql)
              FormRow(
                label: 'Commento',
                labelWidth: 90,
                child: MacTextField(
                  controller: _fields.of(0, 'comment', c.comment ?? ''),
                  small: true,
                  maxLines: 3,
                  onChanged: (v) => set(c.copyWith(comment: v.trim().isEmpty ? null : v), 'comment'),
                ),
              ),
            if (family != DbFamily.db2)
              FormRow(
                label: 'Collation',
                labelWidth: 90,
                child: MacTextField(
                  controller: _fields.of(0, 'collation', c.collation ?? ''),
                  small: true,
                  hint: 'predefinita',
                  onChanged: (v) => set(c.copyWith(collation: v.trim().isEmpty ? null : v.trim()), 'collation'),
                ),
              ),
          ],
        ),
        InspectorSection(
          title: 'Colonna calcolata',
          children: [
            MacTextField(
              controller: _fields.of(0, 'computed', c.computed ?? ''),
              small: true,
              mono: true,
              maxLines: 3,
              hint: 'espressione, ad esempio qty * prezzo',
              onChanged: (v) => set(
                c.copyWith(
                  computed: v.trim().isEmpty ? null : v.trim(),
                  autoIncrement: v.trim().isEmpty ? c.autoIncrement : false,
                  defaultValue: v.trim().isEmpty ? c.defaultValue : null,
                ),
                'computed',
              ),
            ),
            if (family == DbFamily.mysql || family == DbFamily.sqlite || family == DbFamily.sqlServer)
              CheckboxRow(
                value: c.computedStored,
                label: family == DbFamily.sqlServer ? 'Memorizzata (PERSISTED)' : 'Memorizzata (STORED)',
                onChanged: c.isComputed ? (v) => set(c.copyWith(computedStored: v), 'stored') : null,
              ),
          ],
        ),
        if (c.autoIncrement && family != DbFamily.mysql && family != DbFamily.sqlite)
          InspectorSection(
            title: 'Identity',
            children: [
              FormRow(
                label: 'Valore iniziale',
                labelWidth: 90,
                child: MacTextField(
                  controller: _fields.of(0, 'seed', '${c.identitySeed ?? ''}'),
                  small: true,
                  tabular: true,
                  hint: '1',
                  onChanged: (v) => set(c.copyWith(identitySeed: number(v)), 'seed'),
                ),
              ),
              FormRow(
                label: 'Incremento',
                labelWidth: 90,
                child: MacTextField(
                  controller: _fields.of(0, 'step', '${c.identityIncrement ?? ''}'),
                  small: true,
                  tabular: true,
                  hint: '1',
                  onChanged: (v) => set(c.copyWith(identityIncrement: number(v)), 'step'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pending changes
// ---------------------------------------------------------------------------

class DesignChangesPage extends StatelessWidget {
  const DesignChangesPage({super.key, required this.design, required this.connection});
  final TableDesign design;
  final DbConnection connection;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: design,
      builder: (context, _) {
        final c = DbColors.of(context);
        final changes = design.changes;
        final script = DdlBuilder(connection.dialect).render(design.statements);
        final errors = design.errors;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 340,
              child: ListView(
                padding: const EdgeInsets.all(Gap.lg),
                children: [
                  Text(
                    design.isNew ? 'Nuova tabella' : '${changes.length} modifiche',
                    style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text),
                  ),
                  const SizedBox(height: Gap.sm),
                  for (final e in errors)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.xs),
                      child: StatusLine(e, kind: StatusKind.danger),
                    ),
                  if (!design.isNew && changes.isEmpty)
                    Text('Nessuna modifica in sospeso', style: uiText(TypeSize.small, color: c.textTertiary)),
                  for (final ch in changes)
                    CheckboxRow(
                      value: !design.excluded.contains(ch.id),
                      label: ch.label,
                      labelColor: ch.destructive ? c.danger : null,
                      onChanged: (v) => design.setExcluded(ch.id, !v),
                    ),
                  if (changes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.sm),
                      child: Text(
                        'Le modifiche deselezionate restano in sospeso e non vengono eseguite.',
                        style: uiText(TypeSize.small, color: c.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
            VerticalDivider(width: 1, thickness: 0.5, color: c.separator),
            Expanded(child: SqlCodeView(text: script.isEmpty ? '-- Nessuna modifica' : script)),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------

/// Applies the design of [tab]: script sheet, execution, then the table is
/// read again (it may have been created or renamed) and becomes the new
/// starting point. Returns true when the script ran.
Future<bool> saveTableDesign(BuildContext context, TableEditorTab tab) async {
  final d = tab.design;
  final dc = tab.connection;
  if (d == null || !d.isDirty) return false;
  final errors = d.errors;
  if (errors.isNotEmpty) {
    await showErrorDialog(context, errors.join('\n'), title: 'Impossibile salvare la struttura');
    return false;
  }
  final w = d.working;
  final target = d.original ?? w;
  DdlResult? result;
  final ok = await runTableScript(
    context,
    dc,
    target,
    d.statements,
    title: d.isNew ? 'Crea la tabella ${w.name}' : 'Modifiche alla tabella ${target.name}',
    onResult: (r) => result = r,
  );
  if (!ok) {
    // Without transactional DDL the statements before the failing one stay
    // applied: read the table again so that only the rest is pending.
    final r = result;
    if (r != null && r.executed > 0 && !r.rolledBack) await _reloadDesign(tab, keepPending: true);
    return false;
  }
  await _reloadDesign(tab, keepPending: d.excluded.isNotEmpty);
  return true;
}

Future<void> _reloadDesign(TableEditorTab tab, {required bool keepPending}) async {
  final d = tab.design!;
  final dc = tab.connection;
  final w = d.working;
  final md = dc.metadata;
  final cat = DesignCatalog.of(dc);
  final found = await md?.findTable(w.catalog, w.schema, w.name);
  if (found == null || cat == null) return;
  try {
    final def = await cat.loadTable(found);
    tab.table = found;
    d.saved(def, keepPending: keepPending);
    d.incoming = await incomingForeignKeys(dc, def);
    d.refresh();
  } catch (_) {
    tab.table = found;
  }
  tab.refresh();
}
