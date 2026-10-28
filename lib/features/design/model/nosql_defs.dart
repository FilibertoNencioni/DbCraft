// Objects of the NoSQL databases edited by the design tools: MongoDB
// collections, indexes and views; Cassandra keyspaces, tables, indexes,
// user defined types and materialized views. (Users and roles of MongoDB,
// Cassandra and Redis are PrincipalDefs, see security_defs.dart.)

import 'extra_defs.dart';

// ---------------------------------------------------------------------------
// MongoDB
// ---------------------------------------------------------------------------

enum MongoCollectionType {
  normal('Normale'),
  capped('Limitata (capped)'),
  timeseries('Serie temporale');

  const MongoCollectionType(this.label);
  final String label;
}

const mongoGranularities = ['seconds', 'minutes', 'hours'];
const mongoValidationLevels = ['strict', 'moderate', 'off'];
const mongoValidationActions = ['error', 'warn'];

class MongoCollectionDef {
  const MongoCollectionDef({
    required this.database,
    required this.name,
    this.type = MongoCollectionType.normal,
    this.cappedSize,
    this.cappedMax,
    this.timeField,
    this.metaField,
    this.granularity,
    this.expireAfterSeconds,
    this.collation,
    this.validator,
    this.validationLevel,
    this.validationAction,
  });

  final String database;
  final String name;
  final MongoCollectionType type;

  /// Capped: maximum size in bytes and number of documents.
  final int? cappedSize;
  final int? cappedMax;

  // Time series.
  final String? timeField;
  final String? metaField;
  final String? granularity;

  /// Time series: documents expire after these seconds.
  final int? expireAfterSeconds;

  /// Default collation locale (it, en…).
  final String? collation;

  /// Validator document as shell JSON (`{$jsonSchema: {…}}`).
  final String? validator;
  final String? validationLevel;
  final String? validationAction;
}

/// One key of an index: field and kind (1, -1, text, 2dsphere, hashed).
class MongoIndexKey {
  const MongoIndexKey(this.field, [this.kind = '1']);
  final String field;
  final String kind;
}

const mongoIndexKinds = ['1', '-1', 'text', '2dsphere', 'hashed'];

class MongoIndexDef {
  const MongoIndexDef({
    required this.database,
    required this.collection,
    required this.keys,
    this.name,
    this.unique = false,
    this.sparse = false,
    this.hidden = false,
    this.ttlSeconds,
    this.partialFilter,
  });

  final String database;
  final String collection;
  final String? name;
  final List<MongoIndexKey> keys;
  final bool unique;
  final bool sparse;

  /// Kept up to date but not used by the planner.
  final bool hidden;

  /// TTL index: documents expire this many seconds after the indexed date.
  final int? ttlSeconds;

  /// Partial index filter as shell JSON.
  final String? partialFilter;

  /// MongoDB's default name: field_1_other_-1.
  String get effectiveName => name ?? [for (final k in keys) '${k.field}_${k.kind}'].join('_');
}

class MongoViewDef {
  const MongoViewDef({required this.database, required this.name, required this.viewOn, this.pipeline = '[]'});
  final String database;
  final String name;

  /// Source collection (or view).
  final String viewOn;

  /// Aggregation pipeline as shell JSON (`[{$match: {…}}]`).
  final String pipeline;
}

// ---------------------------------------------------------------------------
// Cassandra
// ---------------------------------------------------------------------------

class KeyspaceDef {
  const KeyspaceDef({
    required this.name,
    this.strategy = 'SimpleStrategy',
    this.replicationFactor = 1,
    this.datacenters = const {},
    this.durableWrites = true,
  });
  final String name;

  /// SimpleStrategy or NetworkTopologyStrategy.
  final String strategy;
  final int replicationFactor;

  /// NetworkTopologyStrategy: data center → replicas.
  final Map<String, int> datacenters;
  final bool durableWrites;

  bool get networkTopology => strategy.endsWith('NetworkTopologyStrategy');
}

enum CqlColumnKind {
  partition('Partizione'),
  clustering('Clustering'),
  static('Statica'),
  regular('Normale');

  const CqlColumnKind(this.label);
  final String label;

  bool get key => this == partition || this == clustering;
}

class CqlColumn {
  const CqlColumn(this.name, this.type, {this.kind = CqlColumnKind.regular, this.descending = false});
  final String name;
  final String type;
  final CqlColumnKind kind;

  /// Clustering column sorted descending.
  final bool descending;
}

const cqlCompactions = [
  'SizeTieredCompactionStrategy',
  'LeveledCompactionStrategy',
  'TimeWindowCompactionStrategy',
  'UnifiedCompactionStrategy',
];

const cqlTypes = [
  'text', 'int', 'bigint', 'smallint', 'tinyint', 'varint', 'decimal', 'double', 'float', 'boolean', //
  'uuid', 'timeuuid', 'timestamp', 'date', 'time', 'duration', 'blob', 'inet', 'counter', 'ascii',
  'list<text>', 'set<text>', 'map<text, text>', 'frozen<>',
];

class CqlTableDef {
  const CqlTableDef({
    required this.keyspace,
    required this.name,
    required this.columns,
    this.comment,
    this.defaultTtl,
    this.gcGraceSeconds,
    this.compaction,
  });
  final String keyspace;
  final String name;

  /// In order: partition keys, clustering columns, the others.
  final List<CqlColumn> columns;
  final String? comment;

  /// Seconds (0: no expiry).
  final int? defaultTtl;
  final int? gcGraceSeconds;

  /// Compaction strategy class (short name).
  final String? compaction;

  List<CqlColumn> of(CqlColumnKind k) => [
    for (final c in columns)
      if (c.kind == k) c,
  ];
}

class CqlIndexDef {
  const CqlIndexDef({
    required this.keyspace,
    required this.table,
    required this.name,
    required this.column,
    this.using,
  });
  final String keyspace;
  final String table;
  final String name;

  /// Indexed column, or an expression such as `keys(m)`.
  final String column;

  /// Custom index class ('sai' for storage attached indexes); null: legacy.
  final String? using;
}

class UdtDef extends ExtraObjectDef {
  const UdtDef({required this.keyspace, required this.name, this.fields = const []});
  final String keyspace;
  @override
  final String name;
  final List<(String, String)> fields;

  @override
  String? get catalog => keyspace;

  @override
  String? get detail => '${fields.length} campi';
}

class CqlMaterializedViewDef {
  const CqlMaterializedViewDef({
    required this.keyspace,
    required this.name,
    required this.baseTable,
    required this.primaryKey,
    this.columns = '*',
    this.where,
  });
  final String keyspace;
  final String name;
  final String baseTable;

  /// Selected columns (`*` or a list).
  final String columns;

  /// WHERE clause; every key column needs IS NOT NULL.
  final String? where;

  /// PRIMARY KEY content: `(a, b)` or `((a, b), c)`.
  final String primaryKey;
}
