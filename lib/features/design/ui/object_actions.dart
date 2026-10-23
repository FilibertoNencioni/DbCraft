// Actions on databases and schemas (navigator): sheets, script, refresh.

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../services/sql_dialect.dart';
import '../../../state/app_state.dart';
import '../../../state/db_connection.dart';
import '../../../ui/actions.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_execution.dart';
import '../catalog/databases.dart';
import '../catalog/design_catalog.dart';
import '../ddl/object_ddl.dart';
import '../ddl_script.dart';
import '../model/object_defs.dart';
import 'object_dialogs.dart';

Future<DesignCatalog?> _catalog(BuildContext context, DbConnection dc) async {
  if (!await ensureConnected(context, dc)) return null;
  return DesignCatalog.of(dc);
}

Future<T> _orElse<T>(Future<T> f, T fallback) async {
  try {
    return await f;
  } catch (_) {
    return fallback;
  }
}

/// Database the connection is attached to: PostgreSQL cannot drop it, the
/// others need the session moved elsewhere first.
String? connectedDatabase(DbConnection dc) {
  final n = (dc.info['databaseName'] as String?)?.trim();
  return n == null || n.isEmpty ? dc.defaultCatalog : n;
}

Future<bool> _run(
  BuildContext context,
  DbConnection dc,
  List<String> statements,
  String title, {
  SchemaScope scope = SchemaScope.connection,
  bool autocommitOnly = false,
  String? catalog,
}) => showDdlScriptDialog(
  context,
  dc: dc,
  title: title,
  script: DdlScript(
    statements,
    scope: scope,
    autocommitOnly: autocommitOnly,
    catalog: catalog,
    transactional: !autocommitOnly,
  ),
);

// ---------------------------------------------------------------------------
// Databases
// ---------------------------------------------------------------------------

Future<bool> createDatabase(BuildContext context, DbConnection dc) async {
  if (dc.dialect.family == DbFamily.sqlite) return createSqliteDatabase(context, dc);
  final cat = await _catalog(context, dc);
  if (cat == null || !context.mounted) return false;
  final choices = await _orElse(cat.databaseChoices(), DatabaseChoices.none);
  final existing = await _orElse(cat.databases(), const <DatabaseDef>[]);
  if (!context.mounted) return false;
  final d = await showDatabaseDialog(
    context,
    dialect: dc.dialect,
    choices: choices,
    taken: {for (final x in existing) x.name.toLowerCase()},
  );
  if (d == null || !context.mounted) return false;
  return _run(context, dc, ObjectDdl(dc.dialect).createDatabase(d), 'Nuovo database ${d.name}', autocommitOnly: true);
}

Future<bool> editDatabase(BuildContext context, DbConnection dc, String name) async {
  final cat = await _catalog(context, dc);
  if (cat == null || !context.mounted) return false;
  final current = await _orElse(cat.database(name), null) ?? DatabaseDef(name: name);
  final choices = await _orElse(cat.databaseChoices(), DatabaseChoices.none);
  final existing = await _orElse(cat.databases(), const <DatabaseDef>[]);
  if (!context.mounted) return false;
  final d = await showDatabaseDialog(
    context,
    dialect: dc.dialect,
    initial: current,
    choices: choices,
    taken: {for (final x in existing) x.name.toLowerCase()},
  );
  if (d == null || !context.mounted) return false;
  final statements = ObjectDdl(dc.dialect).alterDatabase(current, d);
  if (statements.isEmpty) return false;
  return _run(context, dc, statements, 'Proprietà del database $name', autocommitOnly: true);
}

Future<bool> renameDatabase(BuildContext context, DbConnection dc, String name) async {
  if (name == connectedDatabase(dc) && dc.dialect.family == DbFamily.postgres) {
    await showErrorDialog(
      context,
      'La connessione usa il database $name: PostgreSQL non lo può rinominare. Connettiti a un altro database.',
      title: 'Impossibile rinominare',
    );
    return false;
  }
  final to = await promptText(context, 'Rinomina il database $name', label: 'Nuovo nome', initial: name);
  if (to == null || to.trim().isEmpty || to.trim() == name || !context.mounted) return false;
  if (dc.dialect.family == DbFamily.sqlServer) await _leaveDatabase(dc, name);
  if (!context.mounted) return false;
  final ok = await _run(
    context,
    dc,
    ObjectDdl(dc.dialect).renameDatabase(name, to.trim()),
    'Rinomina $name',
    autocommitOnly: true,
  );
  if (ok && dc.defaultCatalog == name) dc.defaultCatalog = to.trim();
  return ok;
}

/// SQL Server: moves the sessions of [dc] out of [name] (to master), which
/// needs exclusive access to be renamed or dropped.
Future<void> _leaveDatabase(DbConnection dc, String name) async {
  try {
    if (dc.mainCatalog == name) await dc.useCatalog('master');
    await dc.meta?.setCurrentCatalog('master');
  } catch (_) {}
}

Future<bool> dropDatabase(BuildContext context, DbConnection dc, String name) async {
  final family = dc.dialect.family;
  final inUse = name == connectedDatabase(dc) || name == dc.mainCatalog;
  if (inUse && family == DbFamily.postgres) {
    await showErrorDialog(
      context,
      'La connessione è collegata al database $name: PostgreSQL non può eliminarlo. Connettiti a un altro database (ad esempio postgres).',
      title: 'Impossibile eliminare',
    );
    return false;
  }
  final options = <DropOption>[
    if (family == DbFamily.postgres || family == DbFamily.sqlServer)
      const DropOption(
        'force',
        'Chiudi le sessioni attive sul database',
        help: 'Le transazioni in corso degli altri utenti vengono annullate',
      ),
  ];
  final chosen = await showDropDialog(
    context,
    title: 'Elimina database',
    objectLabel: 'il database $name con tutti i suoi oggetti e i dati',
    confirmName: name,
    options: options,
  );
  if (chosen == null || !context.mounted) return false;
  // SQL Server: the sessions of this connection must leave the database.
  if (family == DbFamily.sqlServer) {
    await _leaveDatabase(dc, name);
    if (!context.mounted) return false;
  }
  final ok = await _run(
    context,
    dc,
    ObjectDdl(dc.dialect).dropDatabase(name, force: chosen.contains('force')),
    'Elimina $name',
    autocommitOnly: true,
  );
  if (ok && dc.defaultCatalog == name) dc.defaultCatalog = null;
  return ok;
}

/// SQLite: a database is a file. Creates it and a connection to it, made
/// like the current one.
Future<bool> createSqliteDatabase(BuildContext context, DbConnection dc) async {
  final loc = await getSaveLocation(
    suggestedName: 'nuovo.db',
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Database SQLite', extensions: ['db', 'sqlite', 'sqlite3']),
    ],
  );
  if (loc == null || !context.mounted) return false;
  final path = loc.path;
  final name = path.split(RegExp(r'[\\/]')).last;
  final copy = dc.config.copy(id: DateTime.now().microsecondsSinceEpoch.toString(), name: name);
  if (copy.connectionString.trim().isNotEmpty) {
    final re = RegExp(r'Database=[^;]*', caseSensitive: false);
    copy.connectionString = re.hasMatch(copy.connectionString)
        ? copy.connectionString.replaceFirst(re, 'Database=$path')
        : '${copy.connectionString};Database=$path';
  }
  copy.database = path;
  final app = AppScope.read(context);
  final added = await app.addConnection(copy);
  if (!context.mounted) return false;
  // Connecting creates the file.
  final ok = await ensureConnected(context, added);
  if (ok && context.mounted) showToast(context, 'Database $name creato');
  return ok;
}

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

Future<bool> createSchema(BuildContext context, DbConnection dc, String? catalog) async {
  final cat = await _catalog(context, dc);
  if (cat == null || !context.mounted) return false;
  final owners = await _orElse(cat.schemaOwners(catalog), const <String>[]);
  final existing = await _orElse(cat.schemaDefs(catalog), const <SchemaDef>[]);
  if (!context.mounted) return false;
  final s = await showSchemaDialog(
    context,
    dialect: dc.dialect,
    catalog: catalog,
    owners: owners,
    taken: {for (final x in existing) x.name.toLowerCase()},
  );
  if (s == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    ObjectDdl(dc.dialect).createSchema(s),
    'Nuovo schema ${s.name}',
    scope: SchemaScope.catalog(catalog),
    catalog: catalog,
  );
}

Future<bool> editSchema(BuildContext context, DbConnection dc, String? catalog, String name) async {
  final cat = await _catalog(context, dc);
  if (cat == null || !context.mounted) return false;
  final current = await _orElse(cat.schemaDef(catalog, name), null) ?? SchemaDef(name: name, catalog: catalog);
  final owners = await _orElse(cat.schemaOwners(catalog), const <String>[]);
  if (!context.mounted) return false;
  final s = await showSchemaDialog(context, dialect: dc.dialect, catalog: catalog, initial: current, owners: owners);
  if (s == null || !context.mounted) return false;
  final statements = ObjectDdl(dc.dialect).alterSchema(current, s);
  if (statements.isEmpty) return false;
  return _run(
    context,
    dc,
    statements,
    'Proprietà dello schema $name',
    scope: SchemaScope.catalog(catalog),
    catalog: catalog,
  );
}

Future<bool> renameSchema(BuildContext context, DbConnection dc, String? catalog, String name) async {
  final to = await promptText(context, 'Rinomina lo schema $name', label: 'Nuovo nome', initial: name);
  if (to == null || to.trim().isEmpty || to.trim() == name || !context.mounted) return false;
  return _run(
    context,
    dc,
    ObjectDdl(dc.dialect).renameSchema(SchemaDef(name: name, catalog: catalog), to.trim()),
    'Rinomina lo schema $name',
    scope: SchemaScope.catalog(catalog),
    catalog: catalog,
  );
}

Future<bool> dropSchema(BuildContext context, DbConnection dc, String? catalog, String name) async {
  final ddl = ObjectDdl(dc.dialect);
  var objects = 0;
  try {
    objects = (await dc.metadata!.tables(catalog, name)).length;
  } catch (_) {}
  if (!context.mounted) return false;
  final chosen = await showDropDialog(
    context,
    title: 'Elimina schema',
    objectLabel: 'lo schema $name${catalog == null ? '' : ' del database $catalog'}',
    confirmName: objects > 0 ? name : null,
    details: [if (objects > 0) 'Lo schema contiene $objects tabelle o viste'],
    options: [
      if (ddl.canDropSchemaCascade)
        DropOption(
          'cascade',
          'Elimina anche gli oggetti contenuti (CASCADE)',
          help: objects > 0 ? 'Senza questa opzione lo schema deve essere vuoto' : null,
        ),
    ],
  );
  if (chosen == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    ddl.dropSchema(
      SchemaDef(name: name, catalog: catalog),
      cascade: chosen.contains('cascade'),
    ),
    'Elimina lo schema $name',
    scope: SchemaScope.catalog(catalog),
    catalog: catalog,
  );
}
