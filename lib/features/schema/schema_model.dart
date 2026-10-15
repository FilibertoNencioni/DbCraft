// Editable, dialect independent schema model shared by the DDL builder, the
// schema compare and the ER diagram editor.

import '../../model/db_objects.dart';
import '../../services/sql_dialect.dart';

const Object _unset = Object();

/// Referential action of a foreign key (ON DELETE / ON UPDATE).
enum FkRule {
  noAction('NO ACTION'),
  restrict('RESTRICT'),
  cascade('CASCADE'),
  setNull('SET NULL'),
  setDefault('SET DEFAULT');

  const FkRule(this.sql);
  final String sql;

  /// Maps the ODBC SQLForeignKeys UPDATE_RULE / DELETE_RULE codes.
  static FkRule fromOdbc(int? r) => switch (r) {
    0 => cascade,
    1 => restrict,
    2 => setNull,
    4 => setDefault,
    _ => noAction,
  };

  /// RESTRICT and NO ACTION behave the same for an immediate check.
  bool get isDefault => this == noAction || this == restrict;
}

/// Types whose declaration carries a length.
const _sizedTypes = {'varchar', 'nvarchar', 'char', 'nchar', 'varbinary', 'binary'};

/// Types whose declaration carries precision and scale.
const _scaledTypes = {'numeric'};

const _synonyms = {
  'int': 'integer',
  'int4': 'integer',
  'integer': 'integer',
  'serial': 'integer',
  'serial4': 'integer',
  'int8': 'bigint',
  'bigint': 'bigint',
  'bigserial': 'bigint',
  'serial8': 'bigint',
  'int64': 'bigint',
  'int2': 'smallint',
  'smallint': 'smallint',
  'smallserial': 'smallint',
  'serial2': 'smallint',
  'bool': 'boolean',
  'boolean': 'boolean',
  'bit': 'boolean',
  'varchar': 'varchar',
  'character varying': 'varchar',
  'varchar2': 'varchar',
  'nvarchar': 'nvarchar',
  'nvarchar2': 'nvarchar',
  'national character varying': 'nvarchar',
  'char': 'char',
  'character': 'char',
  'bpchar': 'char',
  'nchar': 'nchar',
  'national character': 'nchar',
  'text': 'text',
  'clob': 'text',
  'longtext': 'text',
  'mediumtext': 'text',
  'ntext': 'text',
  'nclob': 'text',
  'string': 'text',
  'blob sub_type text': 'text',
  'decimal': 'numeric',
  'numeric': 'numeric',
  'number': 'numeric',
  'dec': 'numeric',
  'real': 'real',
  'float4': 'real',
  'binary_float': 'real',
  'float': 'double',
  'float8': 'double',
  'float64': 'double',
  'double': 'double',
  'double precision': 'double',
  'binary_double': 'double',
  'date': 'date',
  'time': 'time',
  'time without time zone': 'time',
  'timestamp': 'timestamp',
  'timestamp without time zone': 'timestamp',
  'datetime': 'timestamp',
  'datetime2': 'timestamp',
  'smalldatetime': 'timestamp',
  'timestamptz': 'timestamptz',
  'timestamp with time zone': 'timestamptz',
  'datetimeoffset': 'timestamptz',
  'bytea': 'blob',
  'blob': 'blob',
  'longblob': 'blob',
  'mediumblob': 'blob',
  'image': 'blob',
  'bytes': 'blob',
  'varbinary': 'varbinary',
  'binary': 'binary',
  'raw': 'varbinary',
  'uuid': 'uuid',
  'uniqueidentifier': 'uuid',
  'json': 'json',
  'jsonb': 'json',
};

/// Canonical, dialect independent name of [type] used to compare columns
/// across DBMS: int / integer / int4 → integer, character varying / varchar2 →
/// varchar, decimal / number → numeric… Unknown types are returned lower case.
String canonicalType(String type) {
  var t = type.toLowerCase().replaceAll(RegExp(r'\(.*?\)'), ' ');
  t = t.replaceAll(RegExp(r'\bidentity\b'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  var suffix = '';
  if (t.endsWith(' unsigned')) {
    suffix = ' unsigned';
    t = t.substring(0, t.length - suffix.length);
  }
  return '${_synonyms[t] ?? t}$suffix';
}

/// True when [type] (any dialect) takes a length.
bool isSizedType(String type) => _sizedTypes.contains(canonicalType(type));

/// True when [type] (any dialect) takes precision and scale.
bool isScaledType(String type) => _scaledTypes.contains(canonicalType(type));

/// Removes the decorations DBMS add to default expressions so that the same
/// default compares equal: SQL Server parentheses `((0))`, PostgreSQL casts
/// `'a'::character varying`, surrounding blanks and case of keywords.
String? normalizeDefault(String? def) {
  if (def == null) return null;
  var s = def.trim();
  if (s.isEmpty || s.toUpperCase() == 'NULL') return null;
  for (var i = 0; i < 5; i++) {
    if (s.startsWith('(') && s.endsWith(')') && _balanced(s.substring(1, s.length - 1))) {
      s = s.substring(1, s.length - 1).trim();
    } else {
      break;
    }
  }
  s = s.replaceAll(RegExp(r'::[a-zA-Z_ ]+(\[\])?(\(\d+(,\d+)?\))?$'), '');
  if (s.startsWith("'")) return s;
  return s.toLowerCase();
}

bool _balanced(String s) {
  var depth = 0;
  for (final ch in s.split('')) {
    if (ch == '(') depth++;
    if (ch == ')' && --depth < 0) return false;
  }
  return depth == 0;
}

/// A column definition. [originalName] is the name of the column in the
/// database when it was renamed in an editor (null for compare snapshots and
/// new columns).
class ColumnDef {
  const ColumnDef({
    required this.name,
    required this.type,
    this.size,
    this.scale,
    this.nullable = true,
    this.defaultValue,
    this.autoIncrement = false,
    this.comment,
    this.originalName,
  });

  final String name;

  /// Base type name without size (VARCHAR, int4, NUMBER…); may contain an
  /// explicit declaration such as `TINYINT(1)`.
  final String type;

  /// Length or precision; -1 means MAX (SQL Server varchar(max)).
  final int? size;
  final int? scale;
  final bool nullable;
  final String? defaultValue;
  final bool autoIncrement;
  final String? comment;
  final String? originalName;

  factory ColumnDef.fromDbColumn(DbColumn c) {
    var type = c.typeName.trim();
    var auto = c.autoIncrement;
    var def = c.defaultValue?.trim();
    // SQL Server reports "int identity", PostgreSQL may report serial types.
    final identity = RegExp(r'\s+identity\b', caseSensitive: false);
    if (identity.hasMatch(type)) {
      type = type.replaceAll(identity, '').trim();
      auto = true;
    }
    final lower = type.toLowerCase();
    if (lower.contains('serial')) {
      type = canonicalType(type);
      auto = true;
    }
    if (def != null && def.toLowerCase().contains('nextval(')) {
      auto = true;
      def = null;
    }
    if (def != null && (def.isEmpty || def.toUpperCase() == 'NULL')) def = null;
    if (auto) def = null;
    int? size, scale;
    if (!type.contains('(')) {
      if (isSizedType(type) && c.size != null && c.size! > 0) {
        size = c.size! >= 1073741823 ? -1 : c.size;
      } else if (isScaledType(type) && c.size != null && c.size! > 0) {
        size = c.size;
        scale = c.decimals != null && c.decimals! > 0 ? c.decimals : null;
      }
    }
    return ColumnDef(
      name: c.name,
      type: type,
      size: size,
      scale: scale,
      nullable: c.nullable,
      defaultValue: def,
      autoIncrement: auto,
      comment: c.remarks == null || c.remarks!.isEmpty ? null : c.remarks,
    );
  }

  /// Type declaration for display (dialect independent).
  String get fullType {
    if (type.contains('(') || size == null) return type;
    if (size == -1) return '$type(MAX)';
    if (scale != null && scale! > 0) return '$type($size,$scale)';
    return '$type($size)';
  }

  /// Name of the column in the database (before any rename).
  String get dbName => originalName ?? name;

  ColumnDef copyWith({
    String? name,
    String? type,
    Object? size = _unset,
    Object? scale = _unset,
    bool? nullable,
    Object? defaultValue = _unset,
    bool? autoIncrement,
    Object? comment = _unset,
    Object? originalName = _unset,
  }) => ColumnDef(
    name: name ?? this.name,
    type: type ?? this.type,
    size: size == _unset ? this.size : size as int?,
    scale: scale == _unset ? this.scale : scale as int?,
    nullable: nullable ?? this.nullable,
    defaultValue: defaultValue == _unset ? this.defaultValue : defaultValue as String?,
    autoIncrement: autoIncrement ?? this.autoIncrement,
    comment: comment == _unset ? this.comment : comment as String?,
    originalName: originalName == _unset ? this.originalName : originalName as String?,
  );

  /// Display model used by the ER diagram.
  DbColumn toDbColumn(int position) => DbColumn(
    name: name,
    dataType: 0,
    typeName: fullType,
    size: null,
    decimals: null,
    nullable: nullable,
    position: position,
    defaultValue: defaultValue,
    remarks: comment,
    autoIncrement: autoIncrement,
  );
}

class PrimaryKeyDef {
  const PrimaryKeyDef({this.name, required this.columns});
  final String? name;
  final List<String> columns;

  PrimaryKeyDef copyWith({Object? name = _unset, List<String>? columns}) =>
      PrimaryKeyDef(name: name == _unset ? this.name : name as String?, columns: columns ?? this.columns);
}

class ForeignKeyDef {
  const ForeignKeyDef({
    this.name,
    required this.columns,
    this.refCatalog,
    this.refSchema,
    required this.refTable,
    required this.refColumns,
    this.onDelete = FkRule.noAction,
    this.onUpdate = FkRule.noAction,
  });

  final String? name;
  final List<String> columns;
  final String? refCatalog;
  final String? refSchema;
  final String refTable;
  final List<String> refColumns;
  final FkRule onDelete;
  final FkRule onUpdate;

  factory ForeignKeyDef.fromDb(DbForeignKey f) => ForeignKeyDef(
    name: f.name,
    columns: List.of(f.columns),
    refCatalog: f.pkCatalog,
    refSchema: f.pkSchema,
    refTable: f.pkTable,
    refColumns: List.of(f.refColumns),
    onDelete: FkRule.fromOdbc(f.deleteRule),
    onUpdate: FkRule.fromOdbc(f.updateRule),
  );

  /// Structural identity (names of constraints differ across databases).
  String signature({bool ignoreCase = true}) {
    final s = '${columns.join(',')}>$refTable(${refColumns.join(',')})';
    return ignoreCase ? s.toLowerCase() : s;
  }

  ForeignKeyDef copyWith({
    Object? name = _unset,
    List<String>? columns,
    Object? refCatalog = _unset,
    Object? refSchema = _unset,
    String? refTable,
    List<String>? refColumns,
    FkRule? onDelete,
    FkRule? onUpdate,
  }) => ForeignKeyDef(
    name: name == _unset ? this.name : name as String?,
    columns: columns ?? this.columns,
    refCatalog: refCatalog == _unset ? this.refCatalog : refCatalog as String?,
    refSchema: refSchema == _unset ? this.refSchema : refSchema as String?,
    refTable: refTable ?? this.refTable,
    refColumns: refColumns ?? this.refColumns,
    onDelete: onDelete ?? this.onDelete,
    onUpdate: onUpdate ?? this.onUpdate,
  );
}

class IndexDef {
  const IndexDef({required this.name, required this.columns, this.unique = false});
  final String name;
  final List<String> columns;
  final bool unique;

  factory IndexDef.fromDb(DbIndex i) => IndexDef(name: i.name, columns: List.of(i.columns), unique: i.unique);

  String signature({bool ignoreCase = true}) {
    final s = '${unique ? 'u' : ''}(${columns.join(',')})';
    return ignoreCase ? s.toLowerCase() : s;
  }

  IndexDef copyWith({String? name, List<String>? columns, bool? unique}) =>
      IndexDef(name: name ?? this.name, columns: columns ?? this.columns, unique: unique ?? this.unique);
}

/// A table definition. [originalName] is the name of the table in the
/// database when it was renamed in an editor.
class TableDef {
  const TableDef({
    this.catalog,
    this.schema,
    required this.name,
    required this.columns,
    this.primaryKey,
    this.foreignKeys = const [],
    this.indexes = const [],
    this.comment,
    this.originalName,
  });

  final String? catalog;
  final String? schema;
  final String name;
  final List<ColumnDef> columns;
  final PrimaryKeyDef? primaryKey;
  final List<ForeignKeyDef> foreignKeys;
  final List<IndexDef> indexes;
  final String? comment;
  final String? originalName;

  /// Builds the definition from metadata. The index backing the primary key
  /// and SQLite automatic indexes are left out.
  factory TableDef.fromMetadata(
    DbTable t,
    List<DbColumn> columns, {
    DbPrimaryKey? primaryKey,
    List<DbForeignKey> foreignKeys = const [],
    List<DbIndex> indexes = const [],
  }) {
    final pkCols = primaryKey?.columns.map((e) => e.toLowerCase()).join(',');
    return TableDef(
      catalog: t.catalog,
      schema: t.schema,
      name: t.name,
      comment: t.remarks == null || t.remarks!.isEmpty ? null : t.remarks,
      columns: columns.map(ColumnDef.fromDbColumn).toList(),
      primaryKey: primaryKey == null || primaryKey.columns.isEmpty
          ? null
          : PrimaryKeyDef(name: primaryKey.name, columns: List.of(primaryKey.columns)),
      foreignKeys: foreignKeys.map(ForeignKeyDef.fromDb).toList(),
      indexes: [
        for (final i in indexes)
          if (i.columns.isNotEmpty &&
              !i.name.toLowerCase().startsWith('sqlite_autoindex') &&
              !(i.unique && i.columns.map((e) => e.toLowerCase()).join(',') == pkCols) &&
              !(primaryKey?.name != null && i.name == primaryKey!.name))
            IndexDef.fromDb(i),
      ],
    );
  }

  factory TableDef.fromDetails(TableDetails d) => TableDef.fromMetadata(
    d.table,
    d.columns,
    primaryKey: d.primaryKey,
    foreignKeys: d.foreignKeys,
    indexes: d.indexes,
  );

  /// Name of the table in the database (before any rename).
  String get dbName => originalName ?? name;

  ColumnDef? column(String name, {bool ignoreCase = false}) {
    for (final c in columns) {
      if (ignoreCase ? c.name.toLowerCase() == name.toLowerCase() : c.name == name) return c;
    }
    return null;
  }

  bool isPk(String column) => primaryKey?.columns.contains(column) ?? false;

  DbTable toDbTable() => DbTable(catalog: catalog, schema: schema, name: name, type: 'TABLE', remarks: comment);

  TableDef copyWith({
    Object? catalog = _unset,
    Object? schema = _unset,
    String? name,
    List<ColumnDef>? columns,
    Object? primaryKey = _unset,
    List<ForeignKeyDef>? foreignKeys,
    List<IndexDef>? indexes,
    Object? comment = _unset,
    Object? originalName = _unset,
  }) => TableDef(
    catalog: catalog == _unset ? this.catalog : catalog as String?,
    schema: schema == _unset ? this.schema : schema as String?,
    name: name ?? this.name,
    columns: columns ?? this.columns,
    primaryKey: primaryKey == _unset ? this.primaryKey : primaryKey as PrimaryKeyDef?,
    foreignKeys: foreignKeys ?? this.foreignKeys,
    indexes: indexes ?? this.indexes,
    comment: comment == _unset ? this.comment : comment as String?,
    originalName: originalName == _unset ? this.originalName : originalName as String?,
  );
}

// ---------------------------------------------------------------------------
// Types per dialect
// ---------------------------------------------------------------------------

/// Common column types offered by the table editor for [family].
List<String> commonTypes(DbFamily family) => switch (family) {
  DbFamily.sqlServer => const [
    'int', 'bigint', 'smallint', 'tinyint', 'bit', 'decimal', 'numeric', 'money', 'float', 'real', //
    'varchar', 'nvarchar', 'char', 'nchar', 'text', 'date', 'time', 'datetime', 'datetime2',
    'datetimeoffset', 'uniqueidentifier', 'varbinary', 'xml',
  ],
  DbFamily.postgres => const [
    'integer', 'bigint', 'smallint', 'boolean', 'numeric', 'real', 'double precision', 'varchar', 'char', //
    'text', 'date', 'time', 'timestamp', 'timestamptz', 'interval', 'uuid', 'json', 'jsonb', 'bytea',
  ],
  DbFamily.mysql => const [
    'int', 'bigint', 'smallint', 'tinyint', 'decimal', 'float', 'double', 'varchar', 'char', 'text', //
    'longtext', 'date', 'time', 'datetime', 'timestamp', 'json', 'blob', 'longblob', 'enum',
  ],
  DbFamily.oracle => const [
    'NUMBER', 'INTEGER', 'FLOAT', 'BINARY_DOUBLE', 'VARCHAR2', 'NVARCHAR2', 'CHAR', 'CLOB', 'DATE', //
    'TIMESTAMP', 'TIMESTAMP WITH TIME ZONE', 'BLOB', 'RAW',
  ],
  DbFamily.sqlite => const ['INTEGER', 'REAL', 'TEXT', 'NUMERIC', 'BLOB'],
  DbFamily.db2 => const [
    'INTEGER', 'BIGINT', 'SMALLINT', 'DECIMAL', 'DOUBLE', 'VARCHAR', 'CHAR', 'CLOB', 'DATE', 'TIME', //
    'TIMESTAMP', 'BLOB', 'BOOLEAN',
  ],
  DbFamily.firebird => const [
    'INTEGER', 'BIGINT', 'SMALLINT', 'BOOLEAN', 'DECIMAL', 'NUMERIC', 'DOUBLE PRECISION', 'VARCHAR', //
    'CHAR', 'BLOB SUB_TYPE TEXT', 'DATE', 'TIME', 'TIMESTAMP', 'BLOB',
  ],
  DbFamily.snowflake => const [
    'NUMBER', 'INTEGER', 'FLOAT', 'BOOLEAN', 'VARCHAR', 'TEXT', 'DATE', 'TIME', 'TIMESTAMP_NTZ', //
    'TIMESTAMP_TZ', 'VARIANT', 'BINARY',
  ],
  _ => const [
    'INTEGER', 'BIGINT', 'SMALLINT', 'BOOLEAN', 'DECIMAL', 'NUMERIC', 'REAL', 'DOUBLE PRECISION', //
    'VARCHAR', 'CHAR', 'TEXT', 'DATE', 'TIME', 'TIMESTAMP', 'BLOB',
  ],
};

/// Translates the type of [c] (declared for [from]) into the closest type of
/// [to]. Used when a schema is migrated to a different DBMS.
ColumnDef mapColumnType(ColumnDef c, DbFamily from, DbFamily to) {
  if (from == to) return c;
  final canon = canonicalType(c.type);
  ColumnDef t(String type, {Object? size = _unset, Object? scale = _unset}) =>
      c.copyWith(type: type, size: size, scale: scale);
  const noSize = null;
  switch (canon) {
    case 'integer':
      return switch (to) {
        DbFamily.sqlServer || DbFamily.mysql => t('int', size: noSize, scale: noSize),
        DbFamily.postgres => t('integer', size: noSize, scale: noSize),
        DbFamily.oracle => t('NUMBER', size: 10, scale: noSize),
        _ => t('INTEGER', size: noSize, scale: noSize),
      };
    case 'bigint':
      return switch (to) {
        DbFamily.oracle => t('NUMBER', size: 19, scale: noSize),
        DbFamily.sqlite => t('INTEGER', size: noSize, scale: noSize),
        DbFamily.postgres || DbFamily.sqlServer || DbFamily.mysql => t('bigint', size: noSize, scale: noSize),
        _ => t('BIGINT', size: noSize, scale: noSize),
      };
    case 'smallint':
      return switch (to) {
        DbFamily.oracle => t('NUMBER', size: 5, scale: noSize),
        DbFamily.sqlite => t('INTEGER', size: noSize, scale: noSize),
        DbFamily.postgres || DbFamily.sqlServer || DbFamily.mysql => t('smallint', size: noSize, scale: noSize),
        _ => t('SMALLINT', size: noSize, scale: noSize),
      };
    case 'tinyint' || 'tinyint unsigned':
      return to == DbFamily.mysql || to == DbFamily.sqlServer
          ? c
          : mapColumnType(c.copyWith(type: 'smallint', size: null, scale: null), DbFamily.generic, to);
    case 'boolean':
      return switch (to) {
        DbFamily.sqlServer => t('bit', size: noSize, scale: noSize),
        DbFamily.mysql => t('tinyint(1)', size: noSize, scale: noSize),
        DbFamily.oracle => t('NUMBER', size: 1, scale: noSize),
        DbFamily.sqlite => t('INTEGER', size: noSize, scale: noSize),
        DbFamily.postgres => t('boolean', size: noSize, scale: noSize),
        _ => t('BOOLEAN', size: noSize, scale: noSize),
      };
    case 'varchar' || 'nvarchar':
      final n = canon == 'nvarchar';
      return switch (to) {
        DbFamily.oracle => t(n ? 'NVARCHAR2' : 'VARCHAR2', size: c.size == null || c.size == -1 ? 4000 : c.size),
        DbFamily.sqlite => t('TEXT', size: noSize),
        DbFamily.postgres => t('varchar', size: c.size == -1 ? null : c.size),
        DbFamily.mysql => c.size == null || c.size == -1 ? t('longtext', size: noSize) : t('varchar'),
        DbFamily.sqlServer => t(n ? 'nvarchar' : 'varchar', size: c.size ?? -1),
        _ => t('VARCHAR', size: c.size == -1 ? 4000 : c.size ?? 255),
      };
    case 'char' || 'nchar':
      return switch (to) {
        DbFamily.sqlite => t('TEXT', size: noSize),
        DbFamily.sqlServer => t(canon, size: c.size),
        DbFamily.postgres || DbFamily.mysql => t('char', size: c.size),
        _ => t(canon == 'nchar' && to == DbFamily.oracle ? 'NCHAR' : 'CHAR', size: c.size),
      };
    case 'text':
      return switch (to) {
        DbFamily.sqlServer => t('nvarchar', size: -1),
        DbFamily.oracle || DbFamily.db2 => t('CLOB', size: noSize),
        DbFamily.firebird => t('BLOB SUB_TYPE TEXT', size: noSize),
        DbFamily.postgres || DbFamily.mysql => t('text', size: noSize),
        _ => t('TEXT', size: noSize),
      };
    case 'numeric':
      return switch (to) {
        DbFamily.oracle => t('NUMBER'),
        DbFamily.sqlite => t('NUMERIC'),
        DbFamily.postgres => t('numeric'),
        DbFamily.sqlServer || DbFamily.mysql => t('decimal'),
        _ => t('DECIMAL'),
      };
    case 'real':
      return switch (to) {
        DbFamily.oracle => t('BINARY_FLOAT', size: noSize, scale: noSize),
        DbFamily.mysql => t('float', size: noSize, scale: noSize),
        DbFamily.sqlServer || DbFamily.postgres => t('real', size: noSize, scale: noSize),
        _ => t('REAL', size: noSize, scale: noSize),
      };
    case 'double':
      return switch (to) {
        DbFamily.sqlServer => t('float', size: noSize, scale: noSize),
        DbFamily.postgres => t('double precision', size: noSize, scale: noSize),
        DbFamily.mysql => t('double', size: noSize, scale: noSize),
        DbFamily.oracle => t('BINARY_DOUBLE', size: noSize, scale: noSize),
        DbFamily.sqlite => t('REAL', size: noSize, scale: noSize),
        DbFamily.db2 => t('DOUBLE', size: noSize, scale: noSize),
        _ => t('DOUBLE PRECISION', size: noSize, scale: noSize),
      };
    case 'timestamp':
      return switch (to) {
        DbFamily.sqlServer => t('datetime2', size: noSize, scale: noSize),
        DbFamily.mysql => t('datetime', size: noSize, scale: noSize),
        DbFamily.postgres => t('timestamp', size: noSize, scale: noSize),
        DbFamily.snowflake => t('TIMESTAMP_NTZ', size: noSize, scale: noSize),
        _ => t('TIMESTAMP', size: noSize, scale: noSize),
      };
    case 'timestamptz':
      return switch (to) {
        DbFamily.sqlServer => t('datetimeoffset', size: noSize, scale: noSize),
        DbFamily.mysql => t('timestamp', size: noSize, scale: noSize),
        DbFamily.postgres => t('timestamptz', size: noSize, scale: noSize),
        DbFamily.snowflake => t('TIMESTAMP_TZ', size: noSize, scale: noSize),
        _ => t('TIMESTAMP WITH TIME ZONE', size: noSize, scale: noSize),
      };
    case 'blob':
      return switch (to) {
        DbFamily.postgres => t('bytea', size: noSize, scale: noSize),
        DbFamily.sqlServer => t('varbinary', size: -1, scale: noSize),
        DbFamily.mysql => t('longblob', size: noSize, scale: noSize),
        DbFamily.snowflake => t('BINARY', size: noSize, scale: noSize),
        _ => t('BLOB', size: noSize, scale: noSize),
      };
    case 'uuid':
      return switch (to) {
        DbFamily.sqlServer => t('uniqueidentifier', size: noSize, scale: noSize),
        DbFamily.postgres => t('uuid', size: noSize, scale: noSize),
        DbFamily.oracle => t('RAW', size: 16, scale: noSize),
        _ => t('CHAR', size: 36, scale: noSize),
      };
    case 'json':
      return switch (to) {
        DbFamily.postgres => t('jsonb', size: noSize, scale: noSize),
        DbFamily.mysql => t('json', size: noSize, scale: noSize),
        DbFamily.sqlServer => t('nvarchar', size: -1, scale: noSize),
        DbFamily.oracle || DbFamily.db2 => t('CLOB', size: noSize, scale: noSize),
        DbFamily.snowflake => t('VARIANT', size: noSize, scale: noSize),
        _ => t('TEXT', size: noSize, scale: noSize),
      };
    case 'date':
    case 'time':
      return to == DbFamily.oracle && canon == 'time' ? t('TIMESTAMP', size: noSize, scale: noSize) : c;
  }
  return c;
}
