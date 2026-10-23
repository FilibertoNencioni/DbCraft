// "Vincoli" and "Indici" pages of the table editor: the keys, constraints
// and indexes read from the DBMS catalog, with create / edit / drop actions.

import 'package:flutter/material.dart';

import '../../../model/db_objects.dart';
import '../../../state/db_connection.dart';
import '../../../ui/navigator/nav_nodes.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/schema_model.dart';
import '../capabilities.dart';
import '../catalog/design_catalog.dart';
import 'design_actions.dart' as actions;
import 'design_menu.dart';

/// Loads the complete definition of [table] and reloads it after DDL on it.
abstract class _TablePageState<W extends StatefulWidget> extends State<W> {
  DbConnection get dc;
  DbTable get table;

  Future<(TableDef, List<DbForeignKey>)>? _future;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _generation = dc.schemaGeneration;
    dc.addListener(_onConnection);
    _future = _read();
  }

  @override
  void dispose() {
    dc.removeListener(_onConnection);
    super.dispose();
  }

  void _onConnection() {
    if (dc.schemaGeneration == _generation) return;
    final changes = dc.schemaChangesSince(_generation);
    _generation = dc.schemaGeneration;
    if (changes.any((s) => s.coversObject(table.catalog, table.schema, table.name))) _load();
  }

  Future<(TableDef, List<DbForeignKey>)>? _read() {
    final cat = DesignCatalog.of(dc);
    if (cat == null) return null;
    return () async {
      final t = await cat.loadTable(table);
      final refs = await dc.metadata!.referencedBy(table);
      return (t, refs);
    }();
  }

  void _load() {
    setState(() {
      _future = _read();
    });
  }

  void reload() {
    dc.metadata?.clearCache();
    _load();
  }

  Widget buildWith(Widget Function(TableDef t, List<DbForeignKey> refs) builder) {
    final f = _future;
    if (f == null) return const Center(child: Spinner(size: Spinner.large));
    return FutureBuilder(
      future: f,
      builder: (context, snap) {
        if (snap.hasError) return EmptyState.error(snap.error!, title: 'Impossibile leggere i vincoli della tabella');
        final d = snap.data;
        if (d == null) return const Center(child: Spinner(size: Spinner.large));
        return builder(d.$1, d.$2);
      },
    );
  }
}

/// Section with a title, an "add" button and its rows.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows, this.onAdd, this.addTooltip, this.empty = 'Nessuno'});
  final String title;
  final List<Widget> rows;
  final VoidCallback? onAdd;
  final String? addTooltip;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text),
                    ),
                  ),
                  if (addTooltip != null) ToolButton(icon: AppIcons.add, tooltip: addTooltip!, onPressed: onAdd),
                ],
              ),
              const SizedBox(height: Gap.xs),
              InsetBox(
                child: rows.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(Gap.md),
                        child: Text(empty, style: uiText(TypeSize.small, color: c.textTertiary)),
                      )
                    : Column(mainAxisSize: MainAxisSize.min, children: rows),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Row of a constraint or index: double click edits, the menu has every
/// action of the navigator.
Widget _row(
  BuildContext context,
  DbConnection dc,
  DbTable table,
  Object def,
  int index, {
  required bool editable,
  required VoidCallback refresh,
  bool referencing = false,
}) {
  final c = DbColors.of(context);
  final node = ConstraintNode(dc, table, def, referencing: referencing);
  final ro = dc.config.readOnly || !editable;
  return ListRow(
    index: index,
    zebra: true,
    icon: node.icon,
    iconColor: !node.enabled
        ? c.textTertiary
        : node.isKey
        ? c.keyIcon
        : def is ForeignKeyDef
        ? c.foreignKeyIcon
        : c.textSecondary,
    title: node.label,
    subtitle: node.detail,
    titleColor: node.enabled ? null : c.textTertiary,
    onDoubleTap: ro || referencing ? null : () => actions.editConstraint(context, dc, table, def),
    onMenu: !editable
        ? null
        : (pos) => showMacMenu<void>(
            context,
            position: pos,
            entries: constraintMenu(context, node, refresh: refresh),
          ),
    trailingOnHover: ro || referencing
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ToolButton(
                icon: AppIcons.edit,
                extent: 18,
                tooltip: 'Modifica',
                onPressed: () => actions.editConstraint(context, dc, table, def),
              ),
              ToolButton(
                icon: AppIcons.delete,
                extent: 18,
                color: c.danger,
                tooltip: 'Elimina',
                onPressed: () => actions.dropConstraint(context, dc, table, def),
              ),
            ],
          ),
  );
}

class ConstraintsPage extends StatefulWidget {
  const ConstraintsPage({super.key, required this.connection, required this.table, this.editable = true});
  final DbConnection connection;
  final DbTable table;

  /// False in the simplified analyst view.
  final bool editable;

  @override
  State<ConstraintsPage> createState() => _ConstraintsPageState();
}

class _ConstraintsPageState extends _TablePageState<ConstraintsPage> {
  @override
  DbConnection get dc => widget.connection;
  @override
  DbTable get table => widget.table;

  @override
  Widget build(BuildContext context) => buildWith((t, refs) {
    final caps = DesignCapabilities.of(dc.dialect);
    final editable = widget.editable && dc.dialect.isSql;
    final ro = dc.config.readOnly || !editable;
    VoidCallback? add(ConstraintKind k) => ro ? null : () => actions.createConstraint(context, dc, table, k);
    Widget row(Object def, int i, {bool referencing = false, DbTable? on}) =>
        _row(context, dc, on ?? table, def, i, editable: editable, refresh: reload, referencing: referencing);
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        if (!caps.has(DesignFeature.enforcedConstraints))
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Notice(message: caps.reason(DesignFeature.enforcedConstraints)!),
          ),
        _Section(
          title: 'Chiave primaria',
          addTooltip: editable
              ? (t.primaryKey == null ? 'Aggiungi la chiave primaria' : 'Sostituisci la chiave primaria')
              : null,
          onAdd: add(ConstraintKind.primaryKey),
          empty: 'Nessuna chiave primaria',
          rows: [if (t.primaryKey != null) row(t.primaryKey!, 0)],
        ),
        _Section(
          title: 'Vincoli UNIQUE',
          addTooltip: editable ? 'Aggiungi un vincolo UNIQUE' : null,
          onAdd: add(ConstraintKind.unique),
          rows: [for (final (i, u) in t.uniques.indexed) row(u, i)],
        ),
        if (caps.has(DesignFeature.checkConstraints) || t.checks.isNotEmpty)
          _Section(
            title: 'Vincoli CHECK',
            addTooltip: editable && caps.has(DesignFeature.checkConstraints) ? 'Aggiungi un vincolo CHECK' : null,
            onAdd: add(ConstraintKind.check),
            rows: [for (final (i, c) in t.checks.indexed) row(c, i)],
          ),
        _Section(
          title: 'Chiavi esterne',
          addTooltip: editable ? 'Aggiungi una chiave esterna' : null,
          onAdd: add(ConstraintKind.foreignKey),
          empty: 'Nessuna',
          rows: [for (final (i, f) in t.foreignKeys.indexed) row(f, i)],
        ),
        _Section(
          title: 'Referenziata da',
          empty: 'Nessuna tabella',
          rows: [
            for (final (i, f) in refs.indexed)
              row(
                ForeignKeyDef.fromDb(f),
                i,
                referencing: true,
                on: DbTable(catalog: f.fkCatalog, schema: f.fkSchema, name: f.fkTable, type: 'TABLE'),
              ),
          ],
        ),
      ],
    );
  });
}

class IndexesPage extends StatefulWidget {
  const IndexesPage({super.key, required this.connection, required this.table, this.editable = true});
  final DbConnection connection;
  final DbTable table;
  final bool editable;

  @override
  State<IndexesPage> createState() => _IndexesPageState();
}

class _IndexesPageState extends _TablePageState<IndexesPage> {
  @override
  DbConnection get dc => widget.connection;
  @override
  DbTable get table => widget.table;

  @override
  Widget build(BuildContext context) => buildWith((t, _) {
    final caps = DesignCapabilities.of(dc.dialect);
    if (!caps.has(DesignFeature.indexes)) {
      return EmptyState(icon: AppIcons.sort, title: 'Nessun indice', message: caps.reason(DesignFeature.indexes)!);
    }
    final editable = widget.editable && dc.dialect.isSql;
    final ro = dc.config.readOnly || !editable;
    String details(IndexDef i) => [
      if (i.include.isNotEmpty) 'INCLUDE (${i.include.join(', ')})',
      if (i.where != null) 'WHERE ${i.where}',
      if (i.method != null) 'USING ${i.method}',
      if (i.clustered) 'CLUSTERED',
    ].join(' · ');
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        _Section(
          title: 'Indici',
          addTooltip: editable ? 'Nuovo indice' : null,
          onAdd: ro ? null : () => actions.createConstraint(context, dc, table, null),
          empty: 'Nessun indice oltre a quelli delle chiavi',
          rows: [
            for (final (i, ix) in t.indexes.indexed)
              Tooltip(
                message: details(ix),
                child: _row(context, dc, table, ix, i, editable: editable, refresh: reload),
              ),
          ],
        ),
        if (t.primaryKey != null || t.uniques.isNotEmpty)
          Builder(
            builder: (context) => Text(
              'Gli indici della chiave primaria e dei vincoli UNIQUE sono nella pagina Vincoli.',
              style: uiText(TypeSize.small, color: DbColors.of(context).textSecondary),
            ),
          ),
      ],
    );
  });
}
