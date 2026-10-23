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
import '../table_design.dart';
import 'constraint_dialogs.dart';
import 'design_actions.dart' as actions;
import 'design_menu.dart';

/// Loads the complete definition of [table] and reloads it after DDL on it.
abstract class _TablePageState<W extends StatefulWidget> extends State<W> {
  DbConnection get dc;
  DbTable get table;

  /// Table designer session: the page edits it instead of the database.
  TableDesign? get design;

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
    final d = design;
    if (d != null) {
      // Only the references come from the database; the design is live.
      return () async {
        final refs = d.isNew || dc.metadata == null ? const <DbForeignKey>[] : await dc.metadata!.referencedBy(table);
        return (d.working, refs);
      }();
    }
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
    final d = design;
    if (d != null) {
      return FutureBuilder(
        future: f,
        builder: (context, snap) =>
            ListenableBuilder(listenable: d, builder: (context, _) => builder(d.working, snap.data?.$2 ?? const [])),
      );
    }
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

/// Opens the sheet of [kind] (null: an index) on the design and applies the
/// result to its working definition; [old] is the edited item.
Future<void> designEdit(BuildContext context, DbConnection dc, TableDesign d, Object? old, Object kind) async {
  final t = d.working;
  final ctx = ConstraintContext(dialect: dc.dialect, table: t, connection: d.isNew ? null : dc, isNew: d.isNew);
  Object? now;
  switch (kind) {
    case ConstraintKind.primaryKey:
      now = (await showPrimaryKeyDialog(context, ctx, initial: old as PrimaryKeyDef? ?? t.primaryKey))?.value;
    case ConstraintKind.unique:
      now = (await showUniqueDialog(context, ctx, initial: old as UniqueDef?))?.value;
    case ConstraintKind.check:
      now = (await showCheckDialog(context, ctx, initial: old as CheckDef?))?.value;
    case ConstraintKind.foreignKey:
      final tables = await referenceCandidates(dc, t);
      if (!context.mounted) return;
      now = (await showForeignKeyDialog(
        context,
        ctx,
        initial: old as ForeignKeyDef?,
        tables: tables,
        loadTable: (x) => x.name == t.name && x.schema == t.schema ? Future.value(t) : loadDesignTable(dc, x),
      ))?.value;
    default:
      now = (await showIndexDialog(context, ctx, initial: old as IndexDef?))?.value;
  }
  if (now == null) return;
  d.replace(kind == ConstraintKind.primaryKey ? t.primaryKey : old, now);
}

ConstraintKind? _kindOf(Object c) => switch (c) {
  PrimaryKeyDef _ => ConstraintKind.primaryKey,
  UniqueDef _ => ConstraintKind.unique,
  CheckDef _ => ConstraintKind.check,
  ForeignKeyDef _ => ConstraintKind.foreignKey,
  _ => null,
};

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
  TableDesign? design,
}) {
  final c = DbColors.of(context);
  final node = ConstraintNode(dc, table, def, referencing: referencing);
  final ro = (dc.config.readOnly && design == null) || !editable;
  final mark = design == null || referencing ? ColumnMark.none : design.constraintMark(def);
  void edit() => design != null
      ? designEdit(context, dc, design, def, _kindOf(def) ?? 'index')
      : actions.editConstraint(context, dc, table, def);
  void drop() => design != null ? design.replace(def, null) : actions.dropConstraint(context, dc, table, def);
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
    subtitle: switch (mark) {
      ColumnMark.added => '${node.detail} · nuovo',
      ColumnMark.changed => '${node.detail} · modificato',
      ColumnMark.none => node.detail,
    },
    titleColor: switch (mark) {
      ColumnMark.added => c.diffAdded,
      ColumnMark.changed => c.diffChanged,
      ColumnMark.none => node.enabled ? null : c.textTertiary,
    },
    onDoubleTap: ro || referencing ? null : edit,
    onMenu: !editable || design != null
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
              ToolButton(icon: AppIcons.edit, extent: 18, tooltip: 'Modifica', onPressed: edit),
              ToolButton(icon: AppIcons.delete, extent: 18, color: c.danger, tooltip: 'Elimina', onPressed: drop),
            ],
          ),
  );
}

class ConstraintsPage extends StatefulWidget {
  const ConstraintsPage({super.key, required this.connection, required this.table, this.editable = true, this.design});
  final DbConnection connection;
  final DbTable table;
  final TableDesign? design;

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
  TableDesign? get design => widget.design;

  @override
  Widget build(BuildContext context) => buildWith((t, refs) {
    final caps = DesignCapabilities.of(dc.dialect);
    final editable = widget.editable && dc.dialect.isSql;
    final d = design;
    final ro = (dc.config.readOnly && d == null) || !editable;
    VoidCallback? add(ConstraintKind k) => ro
        ? null
        : d != null
        ? () => designEdit(context, dc, d, null, k)
        : () => actions.createConstraint(context, dc, table, k);
    Widget row(Object def, int i, {bool referencing = false, DbTable? on}) => _row(
      context,
      dc,
      on ?? table,
      def,
      i,
      editable: editable,
      refresh: reload,
      referencing: referencing,
      design: referencing ? null : d,
    );
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
  const IndexesPage({super.key, required this.connection, required this.table, this.editable = true, this.design});
  final DbConnection connection;
  final DbTable table;
  final TableDesign? design;
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
  TableDesign? get design => widget.design;

  @override
  Widget build(BuildContext context) => buildWith((t, _) {
    final caps = DesignCapabilities.of(dc.dialect);
    if (!caps.has(DesignFeature.indexes)) {
      return EmptyState(icon: AppIcons.sort, title: 'Nessun indice', message: caps.reason(DesignFeature.indexes)!);
    }
    final editable = widget.editable && dc.dialect.isSql;
    final d = design;
    final ro = (dc.config.readOnly && d == null) || !editable;
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
          onAdd: ro
              ? null
              : d != null
              ? () => designEdit(context, dc, d, null, 'index')
              : () => actions.createConstraint(context, dc, table, null),
          empty: 'Nessun indice oltre a quelli delle chiavi',
          rows: [
            for (final (i, ix) in t.indexes.indexed)
              Tooltip(
                message: details(ix),
                child: _row(context, dc, table, ix, i, editable: editable, refresh: reload, design: d),
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
