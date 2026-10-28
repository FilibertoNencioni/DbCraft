// Navigator actions of the NoSQL design tools: MongoDB databases,
// collections, indexes and views; Cassandra keyspaces, tables, indexes and
// materialized views (user defined types are an ExtraKind folder).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../model/db_objects.dart';
import '../../../services/sql_dialect.dart';
import '../../../state/db_connection.dart';
import '../../../ui/actions.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_execution.dart';
import '../catalog/design_catalog.dart';
import '../catalog/nosql.dart';
import '../ddl/nosql_ddl.dart';
import '../ddl_script.dart';
import '../model/extra_defs.dart';
import '../model/nosql_defs.dart';
import 'nosql_dialogs.dart';
import 'object_dialogs.dart' show showDropDialog;

/// The NoSQL design tools apply to [dc] (MongoDB, Cassandra).
bool nosqlDesign(DbConnection dc) =>
    dc.isConnected && (dc.dialect.family == DbFamily.mongodb || dc.dialect.family == DbFamily.cassandra);

bool _mongo(DbConnection dc) => dc.dialect.family == DbFamily.mongodb;

Future<bool> _run(BuildContext context, DbConnection dc, List<String> statements, String title, SchemaScope scope) {
  if (statements.isEmpty) return Future.value(false);
  return showDdlScriptDialog(
    context,
    dc: dc,
    title: title,
    script: DdlScript(statements, scope: scope),
  );
}

Future<T> _orElse<T>(Future<T> f, T fallback) async {
  try {
    return await f;
  } catch (_) {
    return fallback;
  }
}

CatalogQueries _q(DbConnection dc) => DesignCatalog.of(dc)!.queries;

Future<List<String>> _tables(DbConnection dc, String? catalog, {bool views = false}) async => [
  for (final t in await _orElse(dc.metadata!.tables(catalog, null), const <DbTable>[]))
    if (views || !t.isView)
      if (!t.type.toUpperCase().contains('SYSTEM')) t.name,
];

Future<List<String>> _columns(DbConnection dc, DbTable t) async => [
  for (final c in await _orElse(dc.metadata!.columns(t), const <DbColumn>[])) c.name,
];

// ---------------------------------------------------------------------------
// Databases / keyspaces
// ---------------------------------------------------------------------------

Future<bool> createNosqlDatabase(BuildContext context, DbConnection dc) async {
  if (!await ensureConnected(context, dc) || !context.mounted) return false;
  if (_mongo(dc)) {
    final name = await promptText(context, 'Nuovo database', label: 'Nome del database');
    if (name == null || name.trim().isEmpty || !context.mounted) return false;
    // MongoDB creates the database with its first collection.
    final c = await showMongoCollectionDialog(context, database: name.trim());
    if (c == null || !context.mounted) return false;
    return _run(
      context,
      dc,
      const MongoDdl().createCollection(c),
      'Nuovo database ${c.database}',
      SchemaScope.connection,
    );
  }
  final k = await showKeyspaceDialog(context, dialect: dc.dialect);
  if (k == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    CassandraDdl(dc.dialect).createKeyspace(k),
    'Nuovo keyspace ${k.name}',
    SchemaScope.connection,
  );
}

Future<bool> editKeyspace(BuildContext context, DbConnection dc, String keyspace) async {
  final k = await _orElse(readKeyspace(_q(dc), keyspace), null);
  if (k == null || !context.mounted) return false;
  final to = await showKeyspaceDialog(context, dialect: dc.dialect, initial: k);
  if (to == null || !context.mounted) return false;
  return _run(context, dc, CassandraDdl(dc.dialect).alterKeyspace(k, to), 'Keyspace $keyspace', SchemaScope.connection);
}

Future<bool> dropNosqlDatabase(BuildContext context, DbConnection dc, String name) async {
  final what = _mongo(dc) ? 'database' : 'keyspace';
  final ok = await showDropDialog(
    context,
    title: 'Elimina $what',
    objectLabel: 'il $what $name con tutto il suo contenuto',
    confirmName: name,
  );
  if (ok == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    _mongo(dc) ? const MongoDdl().dropDatabase(name) : CassandraDdl(dc.dialect).dropKeyspace(name),
    'Elimina $name',
    SchemaScope.connection,
  );
}

// ---------------------------------------------------------------------------
// Collections, tables, views
// ---------------------------------------------------------------------------

Future<bool> createNosqlTable(BuildContext context, DbConnection dc, String catalog) async {
  if (_mongo(dc)) {
    final c = await showMongoCollectionDialog(context, database: catalog);
    if (c == null || !context.mounted) return false;
    return _run(
      context,
      dc,
      const MongoDdl().createCollection(c),
      'Nuova collezione ${c.name}',
      SchemaScope.schema(catalog, null),
    );
  }
  final types = await _orElse(
    DesignCatalog.of(dc)!.extras(ExtraKind.userTypes, catalog: catalog),
    const <ExtraObjectDef>[],
  );
  if (!context.mounted) return false;
  final t = await showCqlTableDialog(
    context,
    dialect: dc.dialect,
    keyspace: catalog,
    userTypes: [for (final u in types) u.name],
  );
  if (t == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    CassandraDdl(dc.dialect).createTable(t),
    'Nuova tabella ${t.name}',
    SchemaScope.schema(catalog, null),
  );
}

Future<bool> createNosqlView(BuildContext context, DbConnection dc, String catalog) async {
  final tables = await _tables(dc, catalog, views: _mongo(dc));
  if (!context.mounted) return false;
  if (_mongo(dc)) {
    final v = await showMongoViewDialog(context, database: catalog, collections: tables);
    if (v == null || !context.mounted) return false;
    return _run(
      context,
      dc,
      const MongoDdl().createView(v),
      'Nuova vista ${v.name}',
      SchemaScope.schema(catalog, null),
    );
  }
  final v = await showCqlViewDialog(context, dialect: dc.dialect, keyspace: catalog, tables: tables);
  if (v == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    CassandraDdl(dc.dialect).createMaterializedView(v),
    'Nuova vista ${v.name}',
    SchemaScope.schema(catalog, null),
  );
}

/// Options and validation of a collection, pipeline of a view, structure
/// of a Cassandra table.
Future<bool> editNosqlTable(BuildContext context, DbConnection dc, DbTable t) async {
  final catalog = t.catalog ?? '';
  final scope = SchemaScope.object(t.catalog, t.schema, t.name);
  if (_mongo(dc)) {
    final def = await _orElse(readMongoCollection(_q(dc), catalog, t.name), null);
    if (def == null || !context.mounted) return false;
    if (def is MongoViewDef) {
      final collections = await _tables(dc, catalog, views: true);
      if (!context.mounted) return false;
      final v = await showMongoViewDialog(context, database: catalog, collections: collections, initial: def);
      if (v == null || !context.mounted) return false;
      return _run(
        context,
        dc,
        const MongoDdl().alterView(def, v),
        'Vista ${t.name}',
        SchemaScope.schema(t.catalog, null),
      );
    }
    final from = def as MongoCollectionDef;
    final c = await showMongoCollectionDialog(context, database: catalog, initial: from);
    if (c == null || !context.mounted) return false;
    return _run(
      context,
      dc,
      const MongoDdl().alterCollection(from, c),
      'Collezione ${t.name}',
      SchemaScope.schema(t.catalog, null),
    );
  }
  if (t.isView) return false;
  final cat = DesignCatalog.of(dc)!;
  final from = await _orElse(readCqlTable(cat.queries, catalog, t.name), null);
  final types = await _orElse(cat.extras(ExtraKind.userTypes, catalog: catalog), const <ExtraObjectDef>[]);
  if (from == null || !context.mounted) return false;
  final to = await showCqlTableDialog(
    context,
    dialect: dc.dialect,
    keyspace: catalog,
    initial: from,
    userTypes: [for (final u in types) u.name],
  );
  if (to == null || !context.mounted) return false;
  return _run(context, dc, CassandraDdl(dc.dialect).alterTable(from, to), 'Tabella ${t.name}', scope);
}

Future<bool> renameCollection(BuildContext context, DbConnection dc, DbTable t) async {
  final to = await promptText(context, 'Rinomina la collezione ${t.name}', label: 'Nuovo nome', initial: t.name);
  if (to == null || to.trim().isEmpty || to.trim() == t.name || !context.mounted) return false;
  return _run(
    context,
    dc,
    ['${const MongoDdl().coll(t.catalog ?? '', t.name)}.renameCollection(${jsonQuote(to.trim())})'],
    'Rinomina ${t.name}',
    SchemaScope.schema(t.catalog, null),
  );
}

String jsonQuote(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

Future<bool> dropNosqlTable(BuildContext context, DbConnection dc, DbTable t) async {
  final kind = _mongo(dc) ? (t.isView ? 'vista' : 'collezione') : (t.isView ? 'vista materializzata' : 'tabella');
  final ok = await showDropDialog(context, title: 'Elimina $kind', objectLabel: 'la $kind ${t.name}');
  if (ok == null || !context.mounted) return false;
  final catalog = t.catalog ?? '';
  final statements = _mongo(dc)
      ? const MongoDdl().dropCollection(catalog, t.name)
      : (t.isView
            ? CassandraDdl(dc.dialect).dropMaterializedView(catalog, t.name)
            : CassandraDdl(dc.dialect).dropTable(catalog, t.name));
  return _run(context, dc, statements, 'Elimina ${t.name}', SchemaScope.schema(t.catalog, null));
}

// ---------------------------------------------------------------------------
// Indexes
// ---------------------------------------------------------------------------

Future<bool> createNosqlIndex(BuildContext context, DbConnection dc, DbTable t) async {
  final cols = await _columns(dc, t);
  if (!context.mounted) return false;
  final catalog = t.catalog ?? '';
  final scope = SchemaScope.object(t.catalog, t.schema, t.name);
  if (_mongo(dc)) {
    final i = await showMongoIndexDialog(context, database: catalog, collection: t.name, fields: cols);
    if (i == null || !context.mounted) return false;
    return _run(context, dc, const MongoDdl().createIndex(i), 'Nuovo indice su ${t.name}', scope);
  }
  final i = await showCqlIndexDialog(context, dialect: dc.dialect, keyspace: catalog, table: t.name, columns: cols);
  if (i == null || !context.mounted) return false;
  return _run(context, dc, CassandraDdl(dc.dialect).createIndex(i), 'Nuovo indice su ${t.name}', scope);
}

Future<MongoIndexDef?> _mongoIndex(DbConnection dc, DbTable t, String name) async {
  final all = await _orElse(readMongoIndexes(_q(dc), t.catalog ?? '', t.name), const <MongoIndexDef>[]);
  return all.where((i) => i.effectiveName == name).firstOrNull;
}

Future<bool> editMongoIndex(BuildContext context, DbConnection dc, DbTable t, String name) async {
  final from = await _mongoIndex(dc, t, name);
  if (from == null || !context.mounted) return false;
  final fields = await _columns(dc, t);
  if (!context.mounted) return false;
  final to = await showMongoIndexDialog(
    context,
    database: from.database,
    collection: from.collection,
    fields: fields,
    initial: from,
  );
  if (to == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    const MongoDdl().alterIndex(from, to),
    'Indice $name',
    SchemaScope.object(t.catalog, t.schema, t.name),
  );
}

Future<bool> setMongoIndexHidden(BuildContext context, DbConnection dc, DbTable t, String name, bool hidden) async {
  final i = await _mongoIndex(dc, t, name);
  if (i == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    const MongoDdl().setIndexHidden(i, hidden),
    'Indice $name',
    SchemaScope.object(t.catalog, t.schema, t.name),
  );
}

Future<bool> dropNosqlIndex(BuildContext context, DbConnection dc, DbTable t, String name) async {
  final ok = await showDropDialog(context, title: 'Elimina indice', objectLabel: 'l\'indice $name');
  if (ok == null || !context.mounted) return false;
  final catalog = t.catalog ?? '';
  final statements = _mongo(dc)
      ? const MongoDdl().dropIndex(MongoIndexDef(database: catalog, collection: t.name, name: name, keys: const []))
      : CassandraDdl(dc.dialect).dropIndex(CqlIndexDef(keyspace: catalog, table: t.name, name: name, column: ''));
  return _run(context, dc, statements, 'Elimina $name', SchemaScope.object(t.catalog, t.schema, t.name));
}

// ---------------------------------------------------------------------------
// Navigator menus
// ---------------------------------------------------------------------------

MenuEntry<void> _item(String label, VoidCallback? action, {bool destructive = false}) =>
    MenuEntry(label, onSelected: action, enabled: action != null, destructive: destructive);

List<MenuEntry<void>> nosqlConnectionMenu(BuildContext context, DbConnection dc) => [
  _item(
    _mongo(dc) ? 'Nuovo database…' : 'Nuovo keyspace…',
    dc.config.readOnly ? null : () => createNosqlDatabase(context, dc),
  ),
];

List<MenuEntry<void>> nosqlCatalogMenu(BuildContext context, DbConnection dc, String catalog) {
  final ro = dc.config.readOnly;
  return [
    _item(
      _mongo(dc) ? 'Nuova collezione…' : 'Nuova tabella…',
      ro ? null : () => createNosqlTable(context, dc, catalog),
    ),
    _item(
      _mongo(dc) ? 'Nuova vista…' : 'Nuova vista materializzata…',
      ro ? null : () => createNosqlView(context, dc, catalog),
    ),
    if (!_mongo(dc)) _item('Proprietà del keyspace…', ro ? null : () => editKeyspace(context, dc, catalog)),
    const MenuEntry.divider(),
    _item(
      _mongo(dc) ? 'Elimina database…' : 'Elimina keyspace…',
      ro ? null : () => dropNosqlDatabase(context, dc, catalog),
      destructive: true,
    ),
  ];
}

/// "Nuova …" of the Tabelle / Viste folders of [catalog].
List<MenuEntry<void>> nosqlFolderMenu(BuildContext context, DbConnection dc, String catalog, {required bool views}) {
  final ro = dc.config.readOnly;
  return [
    if (views)
      _item(
        _mongo(dc) ? 'Nuova vista…' : 'Nuova vista materializzata…',
        ro ? null : () => createNosqlView(context, dc, catalog),
      )
    else
      _item(
        _mongo(dc) ? 'Nuova collezione…' : 'Nuova tabella…',
        ro ? null : () => createNosqlTable(context, dc, catalog),
      ),
  ];
}

List<MenuEntry<void>> nosqlTableMenu(BuildContext context, DbConnection dc, DbTable t) {
  final ro = dc.config.readOnly;
  final mongo = _mongo(dc);
  return [
    if (mongo || !t.isView)
      _item(
        mongo ? (t.isView ? 'Modifica pipeline…' : 'Opzioni e validazione…') : 'Modifica tabella…',
        ro ? null : () => editNosqlTable(context, dc, t),
      ),
    if (mongo && !t.isView) _item('Rinomina…', ro ? null : () => renameCollection(context, dc, t)),
    if (!t.isView) _item('Nuovo indice…', ro ? null : () => createNosqlIndex(context, dc, t)),
    _item('Elimina…', ro ? null : () => dropNosqlTable(context, dc, t), destructive: true),
  ];
}

/// Actions on the index [name] of [t] (navigator index nodes).
List<MenuEntry<void>> nosqlIndexMenu(BuildContext context, DbConnection dc, DbTable t, String name) {
  final ro = dc.config.readOnly;
  final mongo = _mongo(dc);
  final primary = mongo && name == '_id_';
  return [
    if (mongo && !primary) ...[
      _item('Modifica…', ro ? null : () => editMongoIndex(context, dc, t, name)),
      _item('Nascondi al pianificatore', ro ? null : () => setMongoIndexHidden(context, dc, t, name, true)),
      _item('Rendi visibile', ro ? null : () => setMongoIndexHidden(context, dc, t, name, false)),
    ],
    _item('Copia nome', () => Clipboard.setData(ClipboardData(text: name))),
    if (!primary) ...[
      const MenuEntry.divider(),
      _item('Elimina…', ro ? null : () => dropNosqlIndex(context, dc, t, name), destructive: true),
    ],
  ];
}
