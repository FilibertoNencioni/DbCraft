// Readers of the NoSQL objects. MongoDB answers shell statements with
// documents (nested values as shell JSON text); Cassandra answers CQL on
// system_schema (maps and lists as JSON text).

import 'dart:convert';

import '../../../drivers/mongodb/bson.dart';
import '../ddl/nosql_ddl.dart';
import '../model/nosql_defs.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

// ---------------------------------------------------------------------------
// MongoDB
// ---------------------------------------------------------------------------

/// A shell JSON cell as a Dart value (null when it does not parse).
Object? _shell(Object? v) {
  if (v == null) return null;
  if (v is! String) return v;
  try {
    return parseMongoValue(v);
  } catch (_) {
    return v;
  }
}

int? _int(Object? v) => switch (v) {
  int() => v,
  num() => v.toInt(),
  BsonInt64() => v.value,
  String() => int.tryParse(v),
  _ => null,
};

String? _text(Object? v) => v == null ? null : (v is String ? v : shellJson(v));

/// Options of the collection or view [name] of [database] (null when it
/// does not exist).
Future<Object?> readMongoCollection(CatalogQueries q, String database, String name) async {
  final ddl = const MongoDdl();
  final rows = await q.first([
    '${ddl.db(database)}.getCollectionInfos(${shellDoc([('name', jsonEncode(name))])})',
  ]);
  if (rows.isEmpty) return null;
  final r = rows.first;
  final options = _shell(r['options']);
  final o = options is Map ? options : const {};
  if (rowText(r, 'type') == 'view') {
    return MongoViewDef(
      database: database,
      name: name,
      viewOn: o['viewOn']?.toString() ?? '',
      pipeline: o['pipeline'] == null ? '[]' : shellJson(o['pipeline']),
    );
  }
  final ts = o['timeseries'];
  final collation = o['collation'];
  return MongoCollectionDef(
    database: database,
    name: name,
    type: ts is Map
        ? MongoCollectionType.timeseries
        : (o['capped'] == true ? MongoCollectionType.capped : MongoCollectionType.normal),
    cappedSize: _int(o['size']),
    cappedMax: _int(o['max']),
    timeField: ts is Map ? ts['timeField']?.toString() : null,
    metaField: ts is Map ? ts['metaField']?.toString() : null,
    granularity: ts is Map ? ts['granularity']?.toString() : null,
    expireAfterSeconds: _int(o['expireAfterSeconds']),
    collation: collation is Map ? collation['locale']?.toString() : null,
    validator: o['validator'] == null ? null : _text(o['validator']),
    validationLevel: o['validationLevel']?.toString(),
    validationAction: o['validationAction']?.toString(),
  );
}

/// Indexes of a collection (the `_id_` index included).
Future<List<MongoIndexDef>> readMongoIndexes(CatalogQueries q, String database, String collection) async {
  final rows = await q.first(['${const MongoDdl().coll(database, collection)}.getIndexes()']);
  return [
    for (final r in rows)
      () {
        final key = _shell(r['key']);
        return MongoIndexDef(
          database: database,
          collection: collection,
          name: rowText(r, 'name'),
          keys: [
            if (key is Map)
              for (final e in key.entries) MongoIndexKey(e.key.toString(), '${_int(e.value) ?? e.value}'),
          ],
          unique: rowBool(r, 'unique'),
          sparse: rowBool(r, 'sparse'),
          hidden: rowBool(r, 'hidden'),
          ttlSeconds: _int(r['expireafterseconds']),
          partialFilter: _text(_shell(r['partialfilterexpression'])),
        );
      }(),
  ];
}

// ---------------------------------------------------------------------------
// Cassandra
// ---------------------------------------------------------------------------

Map<String, Object?> _jsonMap(Object? v) {
  if (v is Map) return v.cast<String, Object?>();
  if (v is String && v.trim().startsWith('{')) {
    try {
      return (jsonDecode(v) as Map).cast<String, Object?>();
    } catch (_) {}
  }
  return const {};
}

List<Object?> _jsonList(Object? v) {
  if (v is List) return v;
  if (v is String && v.trim().startsWith('[')) {
    try {
      return jsonDecode(v) as List;
    } catch (_) {}
  }
  return const [];
}

String _shortClass(String? c) => c == null ? '' : c.split('.').last;

Future<KeyspaceDef?> readKeyspace(CatalogQueries q, String name) async {
  final rows = await q.first([
    'SELECT keyspace_name, durable_writes, replication FROM system_schema.keyspaces '
        "WHERE keyspace_name = ${lit(name)}",
  ]);
  if (rows.isEmpty) return null;
  final r = rows.first;
  final rep = _jsonMap(r['replication']);
  final cls = _shortClass(rep['class']?.toString());
  return KeyspaceDef(
    name: name,
    strategy: cls.isEmpty ? 'SimpleStrategy' : cls,
    replicationFactor: int.tryParse('${rep['replication_factor'] ?? 1}') ?? 1,
    datacenters: {
      if (cls == 'NetworkTopologyStrategy')
        for (final e in rep.entries)
          if (e.key != 'class') e.key: int.tryParse('${e.value}') ?? 1,
    },
    durableWrites: r['durable_writes'] == null || rowBool(r, 'durable_writes'),
  );
}

CqlColumnKind _kind(String? k) => switch (k) {
  'partition_key' => CqlColumnKind.partition,
  'clustering' => CqlColumnKind.clustering,
  'static' => CqlColumnKind.static,
  _ => CqlColumnKind.regular,
};

/// Columns in key order: partition keys, clustering columns, the others.
Future<List<CqlColumn>> _columns(CatalogQueries q, String keyspace, String table) async {
  final rows = await q.first([
    'SELECT column_name, clustering_order, kind, position, type FROM system_schema.columns '
        'WHERE keyspace_name = ${lit(keyspace)} AND table_name = ${lit(table)}',
  ]);
  int rank(CqlColumnKind k) => k.index;
  final sorted = [...rows]
    ..sort((a, b) {
      final ka = _kind(rowText(a, 'kind')), kb = _kind(rowText(b, 'kind'));
      if (ka != kb) return rank(ka) - rank(kb);
      if (ka.key) return (rowInt(a, 'position') ?? 0) - (rowInt(b, 'position') ?? 0);
      return (rowText(a, 'column_name') ?? '').compareTo(rowText(b, 'column_name') ?? '');
    });
  return [
    for (final r in sorted)
      CqlColumn(
        rowText(r, 'column_name')!,
        rowText(r, 'type') ?? 'text',
        kind: _kind(rowText(r, 'kind')),
        descending: rowText(r, 'clustering_order') == 'desc',
      ),
  ];
}

Future<CqlTableDef?> readCqlTable(CatalogQueries q, String keyspace, String table) async {
  final rows = await q.first([
    'SELECT comment, default_time_to_live, gc_grace_seconds, compaction FROM system_schema.tables '
        'WHERE keyspace_name = ${lit(keyspace)} AND table_name = ${lit(table)}',
  ]);
  if (rows.isEmpty) return null;
  final r = rows.first;
  return CqlTableDef(
    keyspace: keyspace,
    name: table,
    columns: await _columns(q, keyspace, table),
    comment: rowText(r, 'comment'),
    defaultTtl: rowInt(r, 'default_time_to_live'),
    gcGraceSeconds: rowInt(r, 'gc_grace_seconds'),
    compaction: _shortClass(_jsonMap(r['compaction'])['class']?.toString()),
  );
}

Future<List<CqlIndexDef>> readCqlIndexes(CatalogQueries q, String keyspace, String table) async {
  final rows = await q.first([
    'SELECT index_name, kind, options FROM system_schema.indexes '
        'WHERE keyspace_name = ${lit(keyspace)} AND table_name = ${lit(table)}',
  ]);
  return [
    for (final r in rows)
      () {
        final o = _jsonMap(r['options']);
        final cls = _shortClass(o['class_name']?.toString());
        return CqlIndexDef(
          keyspace: keyspace,
          table: table,
          name: rowText(r, 'index_name')!,
          column: o['target']?.toString() ?? '',
          using: cls == 'StorageAttachedIndex' ? 'sai' : (cls.isEmpty ? null : o['class_name'].toString()),
        );
      }(),
  ];
}

Future<List<UdtDef>> readUserTypes(CatalogQueries q, String keyspace) async {
  final rows = await q.first([
    'SELECT type_name, field_names, field_types FROM system_schema.types WHERE keyspace_name = ${lit(keyspace)}',
  ]);
  return [
    for (final r in rows)
      () {
        final names = _jsonList(r['field_names']);
        final types = _jsonList(r['field_types']);
        return UdtDef(
          keyspace: keyspace,
          name: rowText(r, 'type_name')!,
          fields: [for (var i = 0; i < names.length; i++) ('${names[i]}', i < types.length ? '${types[i]}' : 'text')],
        );
      }(),
  ];
}

Future<CqlMaterializedViewDef?> readMaterializedView(CatalogQueries q, String keyspace, String name) async {
  final rows = await q.first([
    'SELECT view_name, base_table_name, where_clause FROM system_schema.views '
        'WHERE keyspace_name = ${lit(keyspace)} AND view_name = ${lit(name)}',
  ]);
  if (rows.isEmpty) return null;
  final cols = await _columns(q, keyspace, name);
  final part = [
    for (final c in cols)
      if (c.kind == CqlColumnKind.partition) c.name,
  ];
  final clus = [
    for (final c in cols)
      if (c.kind == CqlColumnKind.clustering) c.name,
  ];
  return CqlMaterializedViewDef(
    keyspace: keyspace,
    name: name,
    baseTable: rowText(rows.first, 'base_table_name') ?? '',
    where: rowText(rows.first, 'where_clause'),
    columns: [for (final c in cols) c.name].join(', '),
    primaryKey: '(${[part.length == 1 ? part.first : '(${part.join(', ')})', ...clus].join(', ')})',
  );
}
