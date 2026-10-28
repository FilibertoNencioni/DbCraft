// DDL of the NoSQL databases. MongoDB: shell statements the driver runs
// (`db.getSiblingDB("x").createCollection(…)`, `runCommand({collMod…})`).
// Cassandra: CQL. Same conventions as the SQL builders: one statement per
// entry, no terminators, comment-only entries for notes.

import 'dart:convert';

import '../../../services/sql_dialect.dart';
import '../model/nosql_defs.dart';

String _note(String text) => '-- $text (non supportato)';
bool _has(String? s) => s != null && s.trim().isNotEmpty;

// ---------------------------------------------------------------------------
// MongoDB
// ---------------------------------------------------------------------------

final _bareKey = RegExp(r'^[A-Za-z_$][\w$]*$');

/// A document key in shell syntax (bare when possible).
String shellKey(String k) => _bareKey.hasMatch(k) ? k : jsonEncode(k);

/// `{a: 1, "b.c": -1}` from entries whose values are already shell text.
String shellDoc(List<(String, String)> entries) =>
    entries.isEmpty ? '{}' : '{${[for (final (k, v) in entries) '${shellKey(k)}: $v'].join(', ')}}';

class MongoDdl {
  const MongoDdl();

  String _str(String s) => jsonEncode(s);
  String db(String database) => 'db.getSiblingDB(${_str(database)})';
  String coll(String database, String collection) => '${db(database)}.getCollection(${_str(collection)})';

  List<(String, String)> _options(MongoCollectionDef c) => [
    if (c.type == MongoCollectionType.capped) ...[
      ('capped', 'true'),
      ('size', '${c.cappedSize ?? 1048576}'),
      if (c.cappedMax != null) ('max', '${c.cappedMax}'),
    ],
    if (c.type == MongoCollectionType.timeseries) ...[
      (
        'timeseries',
        shellDoc([
          ('timeField', _str(c.timeField ?? 'timestamp')),
          if (_has(c.metaField)) ('metaField', _str(c.metaField!)),
          if (_has(c.granularity)) ('granularity', _str(c.granularity!)),
        ]),
      ),
      if (c.expireAfterSeconds != null) ('expireAfterSeconds', '${c.expireAfterSeconds}'),
    ],
    if (_has(c.collation)) ('collation', shellDoc([('locale', _str(c.collation!))])),
    if (_has(c.validator)) ('validator', c.validator!.trim()),
    if (_has(c.validationLevel)) ('validationLevel', _str(c.validationLevel!)),
    if (_has(c.validationAction)) ('validationAction', _str(c.validationAction!)),
  ];

  List<String> createCollection(MongoCollectionDef c) {
    final o = _options(c);
    return ['${db(c.database)}.createCollection(${_str(c.name)}${o.isEmpty ? '' : ', ${shellDoc(o)}'})'];
  }

  /// MongoDB creates a database with its first collection.
  List<String> createDatabase(String database, String firstCollection) =>
      createCollection(MongoCollectionDef(database: database, name: firstCollection));

  /// collMod for validation and expiry; rename; what MongoDB cannot change
  /// (type, collation, time field) as notes.
  List<String> alterCollection(MongoCollectionDef from, MongoCollectionDef to) {
    final out = <String>[];
    var name = from.name;
    if (from.name != to.name) {
      out.add('${coll(from.database, from.name)}.renameCollection(${_str(to.name)})');
      name = to.name;
    }
    final mod = <(String, String)>[
      if ((from.validator ?? '').trim() != (to.validator ?? '').trim())
        ('validator', _has(to.validator) ? to.validator!.trim() : '{}'),
      if (from.validationLevel != to.validationLevel && _has(to.validationLevel))
        ('validationLevel', _str(to.validationLevel!)),
      if (from.validationAction != to.validationAction && _has(to.validationAction))
        ('validationAction', _str(to.validationAction!)),
      if (to.type == MongoCollectionType.timeseries && from.expireAfterSeconds != to.expireAfterSeconds)
        ('expireAfterSeconds', to.expireAfterSeconds == null ? _str('off') : '${to.expireAfterSeconds}'),
      if (to.type == MongoCollectionType.capped && from.cappedSize != to.cappedSize && to.cappedSize != null)
        ('cappedSize', '${to.cappedSize}'),
      if (to.type == MongoCollectionType.capped && from.cappedMax != to.cappedMax && to.cappedMax != null)
        ('cappedMax', '${to.cappedMax}'),
    ];
    if (mod.isNotEmpty) out.add('${db(to.database)}.runCommand(${shellDoc([('collMod', _str(name)), ...mod])})');
    if (from.type != to.type) out.add(_note('Cambio del tipo di una collezione MongoDB'));
    if ((from.collation ?? '') != (to.collation ?? '')) out.add(_note('Cambio della collation di una collezione'));
    if (from.timeField != to.timeField || from.metaField != to.metaField) {
      out.add(_note('Cambio dei campi di una serie temporale'));
    }
    return out;
  }

  List<String> dropCollection(String database, String name) => ['${coll(database, name)}.drop()'];

  List<String> dropDatabase(String database) => ['${db(database)}.dropDatabase()'];

  List<(String, String)> _indexOptions(MongoIndexDef i) => [
    if (_has(i.name)) ('name', _str(i.name!)),
    if (i.unique) ('unique', 'true'),
    if (i.sparse) ('sparse', 'true'),
    if (i.hidden) ('hidden', 'true'),
    if (i.ttlSeconds != null) ('expireAfterSeconds', '${i.ttlSeconds}'),
    if (_has(i.partialFilter)) ('partialFilterExpression', i.partialFilter!.trim()),
  ];

  String _keyValue(String kind) => int.tryParse(kind) != null ? kind : _str(kind);

  List<String> createIndex(MongoIndexDef i) {
    final keys = shellDoc([for (final k in i.keys) (k.field, _keyValue(k.kind))]);
    final o = _indexOptions(i);
    return ['${coll(i.database, i.collection)}.createIndex($keys${o.isEmpty ? '' : ', ${shellDoc(o)}'})'];
  }

  List<String> dropIndex(MongoIndexDef i) => ['${coll(i.database, i.collection)}.dropIndex(${_str(i.effectiveName)})'];

  String _indexMod(MongoIndexDef i, List<(String, String)> what) =>
      '${db(i.database)}.runCommand(${shellDoc([
        ('collMod', _str(i.collection)),
        ('index', shellDoc([('name', _str(i.effectiveName)), ...what])),
      ])})';

  List<String> setIndexHidden(MongoIndexDef i, bool hidden) => [
    _indexMod(i, [('hidden', '$hidden')]),
  ];

  /// Hidden and TTL change in place (collMod); anything else recreates the
  /// index.
  List<String> alterIndex(MongoIndexDef from, MongoIndexDef to) {
    String shape(MongoIndexDef x) => [
      x.effectiveName,
      for (final k in x.keys) '${k.field}:${k.kind}',
      x.unique,
      x.sparse,
      (x.partialFilter ?? '').trim(),
      x.ttlSeconds == null,
    ].join('|');
    if (shape(from) != shape(to)) return [...dropIndex(from), ...createIndex(to)];
    return [
      if (from.hidden != to.hidden) ...setIndexHidden(to, to.hidden),
      if (from.ttlSeconds != to.ttlSeconds && to.ttlSeconds != null)
        _indexMod(to, [('expireAfterSeconds', '${to.ttlSeconds}')]),
    ];
  }

  List<String> createView(MongoViewDef v) => [
    '${db(v.database)}.createView(${_str(v.name)}, ${_str(v.viewOn)}, ${v.pipeline.trim().isEmpty ? '[]' : v.pipeline.trim()})',
  ];

  List<String> alterView(MongoViewDef from, MongoViewDef to) {
    if (from.name != to.name) return [...dropCollection(from.database, from.name), ...createView(to)];
    if (from.viewOn == to.viewOn && from.pipeline.trim() == to.pipeline.trim()) return const [];
    return [
      '${db(to.database)}.runCommand(${shellDoc([('collMod', _str(to.name)), ('viewOn', _str(to.viewOn)), ('pipeline', to.pipeline.trim().isEmpty ? '[]' : to.pipeline.trim())])})',
    ];
  }
}

// ---------------------------------------------------------------------------
// Cassandra
// ---------------------------------------------------------------------------

class CassandraDdl {
  CassandraDdl(this.dialect);
  final SqlDialect dialect;

  String q(String n) => dialect.quoteIdent(n);
  String lit(String s) => dialect.stringLiteral(s);
  String ref(String keyspace, String name) => '${q(keyspace)}.${q(name)}';

  String replication(KeyspaceDef k) {
    final entries = k.networkTopology
        ? ["'class': 'NetworkTopologyStrategy'", for (final e in k.datacenters.entries) '${lit(e.key)}: ${e.value}']
        : ["'class': 'SimpleStrategy'", "'replication_factor': ${k.replicationFactor}"];
    return '{${entries.join(', ')}}';
  }

  List<String> createKeyspace(KeyspaceDef k) => [
    'CREATE KEYSPACE ${q(k.name)} WITH replication = ${replication(k)}${k.durableWrites ? '' : ' AND durable_writes = false'}',
  ];

  List<String> alterKeyspace(KeyspaceDef from, KeyspaceDef to) {
    final parts = [
      if (replication(from) != replication(to)) 'replication = ${replication(to)}',
      if (from.durableWrites != to.durableWrites) 'durable_writes = ${to.durableWrites}',
    ];
    return [
      if (from.name != to.name) _note('Ridenominazione di un keyspace Cassandra'),
      if (parts.isNotEmpty) 'ALTER KEYSPACE ${q(from.name)} WITH ${parts.join(' AND ')}',
      if (parts.any((p) => p.startsWith('replication')))
        '-- Dopo aver cambiato la replica esegui nodetool repair sui nodi',
    ];
  }

  List<String> dropKeyspace(String name) => ['DROP KEYSPACE ${q(name)}'];

  String _primaryKey(CqlTableDef t) {
    final part = [for (final c in t.of(CqlColumnKind.partition)) q(c.name)];
    final clus = [for (final c in t.of(CqlColumnKind.clustering)) q(c.name)];
    final p = part.length == 1 ? part.first : '(${part.join(', ')})';
    return 'PRIMARY KEY (${[p, ...clus].join(', ')})';
  }

  List<String> _tableOptions(CqlTableDef t, {CqlTableDef? from}) {
    bool changed(Object? a, Object? b) => from == null ? a != null : a != b;
    return [
      if (changed(t.comment, from?.comment)) 'comment = ${lit(t.comment ?? '')}',
      if (changed(t.defaultTtl, from?.defaultTtl)) 'default_time_to_live = ${t.defaultTtl ?? 0}',
      if (changed(t.gcGraceSeconds, from?.gcGraceSeconds) && t.gcGraceSeconds != null)
        'gc_grace_seconds = ${t.gcGraceSeconds}',
      if (changed(t.compaction, from?.compaction) && _has(t.compaction))
        "compaction = {'class': ${lit(t.compaction!)}}",
    ];
  }

  List<String> createTable(CqlTableDef t) {
    final cols = [
      for (final c in t.columns) '  ${q(c.name)} ${c.type}${c.kind == CqlColumnKind.static ? ' STATIC' : ''}',
      '  ${_primaryKey(t)}',
    ];
    final clustering = t.of(CqlColumnKind.clustering);
    final withs = [
      if (clustering.any((c) => c.descending))
        'CLUSTERING ORDER BY (${[for (final c in clustering) '${q(c.name)} ${c.descending ? 'DESC' : 'ASC'}'].join(', ')})',
      ..._tableOptions(t),
    ];
    return [
      'CREATE TABLE ${ref(t.keyspace, t.name)} (\n${cols.join(',\n')}\n)${withs.isEmpty ? '' : ' WITH ${withs.join(' AND ')}'}',
    ];
  }

  /// Columns are added and dropped; the primary key, the clustering order
  /// and the types of existing columns cannot change.
  List<String> alterTable(CqlTableDef from, CqlTableDef to) {
    final t = ref(to.keyspace, from.name);
    final out = <String>[];
    if (from.name != to.name) out.add(_note('Ridenominazione di una tabella Cassandra'));
    String keyShape(CqlTableDef x) => [
      for (final c in x.columns)
        if (c.kind.key) '${c.name}:${c.kind.name}:${c.descending}',
    ].join(',');
    if (keyShape(from) != keyShape(to)) out.add(_note('Cambio della chiave primaria: ricrea la tabella'));
    final before = {for (final c in from.columns) c.name.toLowerCase(): c};
    final after = {for (final c in to.columns) c.name.toLowerCase(): c};
    for (final e in before.entries) {
      if (!after.containsKey(e.key) && !e.value.kind.key) out.add('ALTER TABLE $t DROP ${q(e.value.name)}');
    }
    for (final e in after.entries) {
      final old = before[e.key];
      if (old == null && !e.value.kind.key) {
        out.add(
          'ALTER TABLE $t ADD ${q(e.value.name)} ${e.value.type}${e.value.kind == CqlColumnKind.static ? ' STATIC' : ''}',
        );
      } else if (old != null && old.type.toLowerCase() != e.value.type.toLowerCase()) {
        out.add(_note('Cambio del tipo della colonna ${e.value.name}'));
      }
    }
    final opts = _tableOptions(to, from: from);
    if (opts.isNotEmpty) out.add('ALTER TABLE $t WITH ${opts.join(' AND ')}');
    return out;
  }

  List<String> dropTable(String keyspace, String name) => ['DROP TABLE ${ref(keyspace, name)}'];

  List<String> createIndex(CqlIndexDef i) => [
    'CREATE INDEX ${q(i.name)} ON ${ref(i.keyspace, i.table)} (${i.column})${_has(i.using) ? ' USING ${lit(i.using!)}' : ''}',
  ];

  List<String> dropIndex(CqlIndexDef i) => ['DROP INDEX ${ref(i.keyspace, i.name)}'];

  List<String> createType(UdtDef u) => [
    'CREATE TYPE ${ref(u.keyspace, u.name)} (${[for (final (n, t) in u.fields) '${q(n)} $t'].join(', ')})',
  ];

  /// Fields are added or renamed (same count); never removed.
  List<String> alterType(UdtDef from, UdtDef to) {
    final t = ref(to.keyspace, from.name);
    final out = <String>[if (from.name != to.name) _note('Ridenominazione di un tipo Cassandra')];
    final old = from.fields;
    final now = to.fields;
    for (var i = 0; i < now.length; i++) {
      if (i < old.length) {
        if (old[i].$1 != now[i].$1) out.add('ALTER TYPE $t RENAME ${q(old[i].$1)} TO ${q(now[i].$1)}');
        if (old[i].$2.toLowerCase() != now[i].$2.toLowerCase()) {
          out.add(_note('Cambio del tipo del campo ${now[i].$1}'));
        }
      } else {
        out.add('ALTER TYPE $t ADD ${q(now[i].$1)} ${now[i].$2}');
      }
    }
    if (now.length < old.length) out.add(_note('Rimozione di campi da un tipo Cassandra'));
    return out;
  }

  List<String> dropType(String keyspace, String name) => ['DROP TYPE ${ref(keyspace, name)}'];

  List<String> createMaterializedView(CqlMaterializedViewDef v) => [
    'CREATE MATERIALIZED VIEW ${ref(v.keyspace, v.name)} AS SELECT ${v.columns.trim().isEmpty ? '*' : v.columns.trim()} '
        'FROM ${ref(v.keyspace, v.baseTable)}${_has(v.where) ? ' WHERE ${v.where!.trim()}' : ''} '
        'PRIMARY KEY ${v.primaryKey.trim().startsWith('(') ? v.primaryKey.trim() : '(${v.primaryKey.trim()})'}',
  ];

  List<String> dropMaterializedView(String keyspace, String name) => ['DROP MATERIALIZED VIEW ${ref(keyspace, name)}'];
}
