// Actions on the constraints and indexes of an existing table, run at once
// (navigator, object editor). Every action edits the table definition and
// lets the diff and the migration write the DDL, so the order of the
// statements and the foreign keys of other tables referencing a changed key
// are handled in one place.

import 'package:flutter/material.dart';

import '../../../model/db_objects.dart';
import '../../../state/db_connection.dart';
import '../../../ui/actions.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_builder.dart';
import '../../schema/ddl_execution.dart';
import '../../schema/schema_diff.dart';
import '../../schema/schema_migration.dart';
import '../../schema/schema_model.dart';
import '../../schema/schema_snapshot.dart';
import '../catalog/design_catalog.dart';
import '../ddl_script.dart';
import '../table_design.dart';
import 'constraint_dialogs.dart';

export '../table_design.dart' show replaceConstraint, constraintName;

/// Human name of a constraint or index.
String constraintLabel(Object c) => switch (c) {
  PrimaryKeyDef p => 'la chiave primaria${p.name == null ? '' : ' ${p.name}'}',
  UniqueDef u => 'il vincolo UNIQUE ${u.name ?? u.columns.join(', ')}',
  CheckDef k => 'il vincolo CHECK ${k.name ?? k.expression}',
  ForeignKeyDef f => 'la chiave esterna ${f.name ?? f.columns.join(', ')}',
  IndexDef i => 'l\'indice ${i.name}',
  _ => 'l\'oggetto',
};

/// Foreign keys of other tables referencing [t].
Future<List<IncomingForeignKey>> incomingForeignKeys(DbConnection dc, TableDef t) async {
  final md = dc.metadata;
  if (md == null) return const [];
  final refs = await md.referencedBy(t.toDbTable());
  return [
    for (final f in refs)
      if (f.fkTable.toLowerCase() != t.name.toLowerCase() || (f.fkSchema ?? '') != (t.schema ?? ''))
        IncomingForeignKey(
          TableDef(catalog: f.fkCatalog, schema: f.fkSchema, name: f.fkTable, columns: const []),
          ForeignKeyDef.fromDb(f),
        ),
  ];
}

/// Statements that turn [original] (in the database) into [wanted].
Future<List<String>> tableChangeStatements(DbConnection dc, TableDef original, TableDef wanted) async {
  final family = dc.dialect.family;
  final diff = SchemaDiff.compare(
    SchemaSnapshot(catalog: original.catalog, schema: original.schema, tables: [wanted], family: family),
    SchemaSnapshot(catalog: original.catalog, schema: original.schema, tables: [original], family: family),
    options: const CompareOptions(ignoreCase: false, ignoreComments: false, compareConstraintNames: true),
  );
  return SchemaMigration(dc.dialect).generate(
    diff,
    options: const MigrationOptions(dropExtra: true, relocate: false),
    incoming: await incomingForeignKeys(dc, original),
  );
}

/// Script sheet for [statements] on table [t]: one transaction where the DBMS
/// allows it (around a SQLite rebuild too: runDdlScript switches the foreign
/// key checks outside of it).
Future<bool> runTableScript(
  BuildContext context,
  DbConnection dc,
  TableDef t,
  List<String> statements, {
  required String title,
  bool autocommitOnly = false,
  ValueChanged<DdlResult>? onResult,
}) {
  return showDdlScriptDialog(
    context,
    dc: dc,
    title: title,
    onResult: onResult,
    script: DdlScript(
      statements,
      transactional: !autocommitOnly,
      autocommitOnly: autocommitOnly,
      scope: SchemaScope.object(t.catalog, t.schema, t.name),
    ),
  );
}

/// Applies the change from [original] to [wanted] at once.
Future<bool> applyTableChange(
  BuildContext context,
  DbConnection dc,
  TableDef original,
  TableDef wanted, {
  required String title,
}) async {
  final statements = await tableChangeStatements(dc, original, wanted);
  if (!context.mounted) return false;
  return runTableScript(context, dc, original, statements, title: title);
}

/// Complete definition of [table] (null, after an error message, when it
/// cannot be read).
Future<TableDef?> _load(BuildContext context, DbConnection dc, DbTable table) async {
  if (!await ensureConnected(context, dc) || !context.mounted) return null;
  final cat = DesignCatalog.of(dc);
  if (cat == null) return null;
  try {
    return await cat.loadTable(table);
  } catch (e) {
    if (context.mounted) await showErrorDialog(context, e, title: 'Impossibile leggere la tabella ${table.name}');
    return null;
  }
}

Future<Object?> _edit(BuildContext context, DbConnection dc, TableDef t, Object? initial, Object kind) async {
  final ctx = ConstraintContext(dialect: dc.dialect, table: t, connection: dc);
  switch (kind) {
    case ConstraintKind.primaryKey:
      final refs = await incomingForeignKeys(dc, t);
      if (!context.mounted) return null;
      return (await showPrimaryKeyDialog(
        context,
        ctx,
        initial: initial as PrimaryKeyDef?,
        referencedBy: [for (final r in refs) '${r.table.name}.${r.foreignKey.name ?? ''}'],
      ))?.value;
    case ConstraintKind.unique:
      return (await showUniqueDialog(context, ctx, initial: initial as UniqueDef?))?.value;
    case ConstraintKind.check:
      return (await showCheckDialog(context, ctx, initial: initial as CheckDef?))?.value;
    case ConstraintKind.foreignKey:
      final tables = await referenceCandidates(dc, t);
      if (!context.mounted) return null;
      return (await showForeignKeyDialog(
        context,
        ctx,
        initial: initial as ForeignKeyDef?,
        tables: tables,
        loadTable: (x) => loadDesignTable(dc, x),
      ))?.value;
    default:
      final r = await showIndexDialog(context, ctx, initial: initial as IndexDef?);
      return r == null ? null : (r.value, r.online);
  }
}

ConstraintKind? _kindOf(Object c) => switch (c) {
  PrimaryKeyDef _ => ConstraintKind.primaryKey,
  UniqueDef _ => ConstraintKind.unique,
  CheckDef _ => ConstraintKind.check,
  ForeignKeyDef _ => ConstraintKind.foreignKey,
  _ => null,
};

/// Creates a constraint of [kind] (null: an index) on [table].
Future<bool> createConstraint(BuildContext context, DbConnection dc, DbTable table, ConstraintKind? kind) async {
  final t = await _load(context, dc, table);
  if (t == null || !context.mounted) return false;
  final r = await _edit(context, dc, t, kind == ConstraintKind.primaryKey ? t.primaryKey : null, kind ?? 'index');
  if (r == null || !context.mounted) return false;
  if (r case (IndexDef ix, bool online)) {
    if (online) {
      // Built outside the transaction: not through the migration.
      return runTableScript(
        context,
        dc,
        t,
        DdlBuilder(dc.dialect).createIndex(t, ix, online: true),
        title: 'Nuovo indice ${ix.name}',
        autocommitOnly: true,
      );
    }
    return applyTableChange(context, dc, t, replaceConstraint(t, null, ix), title: 'Nuovo indice ${ix.name}');
  }
  final old = kind == ConstraintKind.primaryKey ? t.primaryKey : null;
  return applyTableChange(context, dc, t, replaceConstraint(t, old, r), title: 'Nuovo vincolo su ${t.name}');
}

/// Edits the constraint or index [c] of [table].
Future<bool> editConstraint(BuildContext context, DbConnection dc, DbTable table, Object c) async {
  final t = await _load(context, dc, table);
  if (t == null || !context.mounted) return false;
  final current = _find(t, c) ?? c;
  final r = await _edit(context, dc, t, current, _kindOf(current) ?? 'index');
  if (r == null || !context.mounted) return false;
  final now = r is (IndexDef, bool) ? r.$1 : r;
  return applyTableChange(
    context,
    dc,
    t,
    replaceConstraint(t, current, now),
    title: 'Modifica ${constraintLabel(current)}',
  );
}

/// The definition in [t] of [c] (as read now from the database).
Object? _find(TableDef t, Object c) => switch (c) {
  PrimaryKeyDef _ => t.primaryKey,
  UniqueDef _ => t.uniques.where((x) => sameConstraint(x, c)).firstOrNull,
  CheckDef _ => t.checks.where((x) => sameConstraint(x, c)).firstOrNull,
  ForeignKeyDef _ => t.foreignKeys.where((x) => sameConstraint(x, c)).firstOrNull,
  IndexDef _ => t.indexes.where((x) => sameConstraint(x, c)).firstOrNull,
  _ => null,
};

Future<bool> dropConstraint(BuildContext context, DbConnection dc, DbTable table, Object c) async {
  final t = await _load(context, dc, table);
  if (t == null || !context.mounted) return false;
  final current = _find(t, c) ?? c;
  return applyTableChange(
    context,
    dc,
    t,
    replaceConstraint(t, current, null),
    title: 'Elimina ${constraintLabel(current)}',
  );
}

Future<bool> renameConstraint(BuildContext context, DbConnection dc, DbTable table, Object c) async {
  final name = constraintName(c);
  final to = await promptText(context, 'Rinomina ${constraintLabel(c)}', label: 'Nuovo nome', initial: name ?? '');
  if (to == null || to.trim().isEmpty || to.trim() == name || !context.mounted) return false;
  final t = await _load(context, dc, table);
  if (t == null || !context.mounted) return false;
  final current = _find(t, c) ?? c;
  final renamed = switch (current) {
    PrimaryKeyDef x => x.copyWith(name: to.trim()),
    UniqueDef x => x.copyWith(name: to.trim()),
    CheckDef x => x.copyWith(name: to.trim()),
    ForeignKeyDef x => x.copyWith(name: to.trim()),
    IndexDef x => x.copyWith(name: to.trim()),
    _ => current,
  };
  return applyTableChange(
    context,
    dc,
    t,
    replaceConstraint(t, current, renamed),
    title: 'Rinomina ${constraintLabel(current)}',
  );
}

/// Disables or enables [c]; [validate] also checks the existing rows.
Future<bool> setConstraintEnabled(
  BuildContext context,
  DbConnection dc,
  DbTable table,
  Object c,
  bool enabled, {
  bool validate = true,
}) async {
  final t = await _load(context, dc, table);
  if (t == null || !context.mounted) return false;
  final current = _find(t, c) ?? c;
  final now = switch (current) {
    PrimaryKeyDef x => x.copyWith(
      state: x.state.copyWith(enabled: enabled, validated: validate),
    ),
    UniqueDef x => x.copyWith(
      state: x.state.copyWith(enabled: enabled, validated: validate),
    ),
    CheckDef x => x.copyWith(
      state: x.state.copyWith(enabled: enabled, validated: validate),
    ),
    ForeignKeyDef x => x.copyWith(
      state: x.state.copyWith(enabled: enabled, validated: validate),
    ),
    IndexDef x => x.copyWith(enabled: enabled),
    _ => current,
  };
  return applyTableChange(
    context,
    dc,
    t,
    replaceConstraint(t, current, now),
    title: '${enabled ? 'Abilita' : 'Disabilita'} ${constraintLabel(current)}',
  );
}

/// Checks the existing rows against [c] (added without validation).
Future<bool> validateConstraint(BuildContext context, DbConnection dc, DbTable table, Object c) =>
    setConstraintEnabled(context, dc, table, c, true);

Future<bool> rebuildIndex(BuildContext context, DbConnection dc, DbTable table, IndexDef ix) async {
  final t = TableDef(catalog: table.catalog, schema: table.schema, name: table.name, columns: const []);
  return runTableScript(context, dc, t, DdlBuilder(dc.dialect).rebuildIndex(t, ix), title: 'Ricostruisci ${ix.name}');
}
