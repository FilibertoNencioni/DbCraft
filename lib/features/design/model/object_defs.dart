// Definitions of database objects other than tables, edited by the design
// tools and turned into DDL by ObjectDdl.

const Object _unset = Object();

/// A database (catalog). Fields a DBMS does not have stay null.
class DatabaseDef {
  const DatabaseDef({
    required this.name,
    this.owner,
    this.encoding,
    this.collation,
    this.ctype,
    this.template,
    this.tablespace,
    this.connectionLimit,
    this.recoveryModel,
    this.transient = false,
    this.retentionDays,
    this.comment,
  });

  final String name;

  /// PostgreSQL owner role; SQL Server owner login.
  final String? owner;

  /// PostgreSQL encoding; MySQL character set.
  final String? encoding;

  /// PostgreSQL LC_COLLATE, SQL Server and MySQL collation.
  final String? collation;

  /// PostgreSQL LC_CTYPE.
  final String? ctype;

  /// PostgreSQL template database.
  final String? template;
  final String? tablespace;

  /// PostgreSQL connection limit (-1: none).
  final int? connectionLimit;

  /// SQL Server recovery model: FULL, SIMPLE, BULK_LOGGED.
  final String? recoveryModel;

  /// Snowflake transient database (no fail-safe).
  final bool transient;

  /// Snowflake Time Travel retention.
  final int? retentionDays;
  final String? comment;

  DatabaseDef copyWith({
    String? name,
    Object? owner = _unset,
    Object? encoding = _unset,
    Object? collation = _unset,
    Object? ctype = _unset,
    Object? template = _unset,
    Object? tablespace = _unset,
    Object? connectionLimit = _unset,
    Object? recoveryModel = _unset,
    bool? transient,
    Object? retentionDays = _unset,
    Object? comment = _unset,
  }) => DatabaseDef(
    name: name ?? this.name,
    owner: owner == _unset ? this.owner : owner as String?,
    encoding: encoding == _unset ? this.encoding : encoding as String?,
    collation: collation == _unset ? this.collation : collation as String?,
    ctype: ctype == _unset ? this.ctype : ctype as String?,
    template: template == _unset ? this.template : template as String?,
    tablespace: tablespace == _unset ? this.tablespace : tablespace as String?,
    connectionLimit: connectionLimit == _unset ? this.connectionLimit : connectionLimit as int?,
    recoveryModel: recoveryModel == _unset ? this.recoveryModel : recoveryModel as String?,
    transient: transient ?? this.transient,
    retentionDays: retentionDays == _unset ? this.retentionDays : retentionDays as int?,
    comment: comment == _unset ? this.comment : comment as String?,
  );
}

/// A schema of a database.
class SchemaDef {
  const SchemaDef({
    required this.name,
    this.catalog,
    this.owner,
    this.comment,
    this.transient = false,
    this.retentionDays,
  });

  final String name;

  /// Database the schema belongs to (null: the current one).
  final String? catalog;
  final String? owner;
  final String? comment;

  /// Snowflake transient schema.
  final bool transient;
  final int? retentionDays;

  SchemaDef copyWith({
    String? name,
    Object? catalog = _unset,
    Object? owner = _unset,
    Object? comment = _unset,
    bool? transient,
    Object? retentionDays = _unset,
  }) => SchemaDef(
    name: name ?? this.name,
    catalog: catalog == _unset ? this.catalog : catalog as String?,
    owner: owner == _unset ? this.owner : owner as String?,
    comment: comment == _unset ? this.comment : comment as String?,
    transient: transient ?? this.transient,
    retentionDays: retentionDays == _unset ? this.retentionDays : retentionDays as int?,
  );
}
