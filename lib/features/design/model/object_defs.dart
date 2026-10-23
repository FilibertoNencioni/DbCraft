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

/// WITH CHECK OPTION of an updatable view.
enum ViewCheckOption {
  none(''),
  local('LOCAL'),
  cascaded('CASCADED');

  const ViewCheckOption(this.sql);
  final String sql;
}

/// A view or materialized view. [definition] is the query (SELECT …)
/// without the CREATE VIEW header.
class ViewDef {
  const ViewDef({
    this.catalog,
    this.schema,
    required this.name,
    required this.definition,
    this.materialized = false,
    this.checkOption = ViewCheckOption.none,
    this.securityBarrier = false,
    this.schemaBinding = false,
    this.secure = false,
    this.force = false,
    this.algorithm,
    this.sqlSecurity,
    this.withData = true,
    this.comment,
    this.originalName,
  });

  final String? catalog;
  final String? schema;
  final String name;
  final String definition;
  final bool materialized;
  final ViewCheckOption checkOption;

  /// PostgreSQL security_barrier.
  final bool securityBarrier;

  /// SQL Server WITH SCHEMABINDING.
  final bool schemaBinding;

  /// Snowflake SECURE view.
  final bool secure;

  /// Oracle FORCE: created even when the query does not compile.
  final bool force;

  /// MySQL ALGORITHM: UNDEFINED, MERGE, TEMPTABLE.
  final String? algorithm;

  /// MySQL SQL SECURITY: DEFINER, INVOKER.
  final String? sqlSecurity;

  /// PostgreSQL materialized view filled at creation (WITH DATA).
  final bool withData;
  final String? comment;

  /// Name in the database when renamed in the editor.
  final String? originalName;

  String get dbName => originalName ?? name;

  ViewDef copyWith({
    Object? catalog = _unset,
    Object? schema = _unset,
    String? name,
    String? definition,
    bool? materialized,
    ViewCheckOption? checkOption,
    bool? securityBarrier,
    bool? schemaBinding,
    bool? secure,
    bool? force,
    Object? algorithm = _unset,
    Object? sqlSecurity = _unset,
    bool? withData,
    Object? comment = _unset,
    Object? originalName = _unset,
  }) => ViewDef(
    catalog: catalog == _unset ? this.catalog : catalog as String?,
    schema: schema == _unset ? this.schema : schema as String?,
    name: name ?? this.name,
    definition: definition ?? this.definition,
    materialized: materialized ?? this.materialized,
    checkOption: checkOption ?? this.checkOption,
    securityBarrier: securityBarrier ?? this.securityBarrier,
    schemaBinding: schemaBinding ?? this.schemaBinding,
    secure: secure ?? this.secure,
    force: force ?? this.force,
    algorithm: algorithm == _unset ? this.algorithm : algorithm as String?,
    sqlSecurity: sqlSecurity == _unset ? this.sqlSecurity : sqlSecurity as String?,
    withData: withData ?? this.withData,
    comment: comment == _unset ? this.comment : comment as String?,
    originalName: originalName == _unset ? this.originalName : originalName as String?,
  );

  /// Same options (everything but the name and the query).
  bool sameOptions(ViewDef o) =>
      materialized == o.materialized &&
      checkOption == o.checkOption &&
      securityBarrier == o.securityBarrier &&
      schemaBinding == o.schemaBinding &&
      secure == o.secure &&
      force == o.force &&
      (algorithm ?? '') == (o.algorithm ?? '') &&
      (sqlSecurity ?? '') == (o.sqlSecurity ?? '');
}

/// The query of a CREATE VIEW statement as stored by many catalogs (SQL
/// Server, Db2, SQLite, Snowflake GET_DDL): the text after the first AS
/// outside parentheses and quotes that follows the view name, without a
/// trailing WITH … CHECK OPTION and ';'. Text that is not a CREATE VIEW is
/// returned trimmed.
({String query, ViewCheckOption check}) splitViewSql(String sql) {
  var s = sql.trim();
  final head = RegExp(r'^\s*CREATE\b[\s\S]*?\bVIEW\b', caseSensitive: false).firstMatch(s);
  if (head != null) {
    // First top-level AS after the header.
    var depth = 0;
    String? quote;
    for (var i = head.end; i < s.length - 1; i++) {
      final ch = s[i];
      if (quote != null) {
        if (ch == quote) quote = null;
        continue;
      }
      if (ch == '"' || ch == '`' || ch == "'") {
        quote = ch;
      } else if (ch == '[') {
        quote = ']';
      } else if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
      } else if (depth == 0 &&
          (ch == 'A' || ch == 'a') &&
          (s[i + 1] == 'S' || s[i + 1] == 's') &&
          RegExp(r'\s').hasMatch(s[i - 1]) &&
          (i + 2 >= s.length || RegExp(r'\s').hasMatch(s[i + 2]))) {
        s = s.substring(i + 2).trim();
        break;
      }
    }
  }
  if (s.endsWith(';')) s = s.substring(0, s.length - 1).trimRight();
  var check = ViewCheckOption.none;
  final m = RegExp(r'\s+WITH\s+(LOCAL\s+|CASCADED\s+)?CHECK\s+OPTION\s*$', caseSensitive: false).firstMatch(s);
  if (m != null) {
    final kind = m.group(1)?.trim().toUpperCase();
    check = kind == 'LOCAL' ? ViewCheckOption.local : ViewCheckOption.cascaded;
    s = s.substring(0, m.start).trimRight();
  }
  return (query: s, check: check);
}

/// A sequence (Firebird: generator). Null fields take the DBMS default.
class SequenceDef {
  const SequenceDef({
    this.catalog,
    this.schema,
    required this.name,
    this.dataType,
    this.start,
    this.increment,
    this.minValue,
    this.maxValue,
    this.cycle = false,
    this.cache,
    this.ownedBy,
    this.currentValue,
    this.comment,
  });

  final String? catalog;
  final String? schema;
  final String name;

  /// PostgreSQL / SQL Server / Db2 type (bigint, integer…).
  final String? dataType;
  final int? start;
  final int? increment;
  final int? minValue;
  final int? maxValue;
  final bool cycle;

  /// Values kept in memory (0 or 1: no cache).
  final int? cache;

  /// PostgreSQL OWNED BY table.column.
  final String? ownedBy;

  /// Last value handed out, when the catalog tells (read only).
  final int? currentValue;
  final String? comment;

  SequenceDef copyWith({
    Object? catalog = _unset,
    Object? schema = _unset,
    String? name,
    Object? dataType = _unset,
    Object? start = _unset,
    Object? increment = _unset,
    Object? minValue = _unset,
    Object? maxValue = _unset,
    bool? cycle,
    Object? cache = _unset,
    Object? ownedBy = _unset,
    Object? currentValue = _unset,
    Object? comment = _unset,
  }) => SequenceDef(
    catalog: catalog == _unset ? this.catalog : catalog as String?,
    schema: schema == _unset ? this.schema : schema as String?,
    name: name ?? this.name,
    dataType: dataType == _unset ? this.dataType : dataType as String?,
    start: start == _unset ? this.start : start as int?,
    increment: increment == _unset ? this.increment : increment as int?,
    minValue: minValue == _unset ? this.minValue : minValue as int?,
    maxValue: maxValue == _unset ? this.maxValue : maxValue as int?,
    cycle: cycle ?? this.cycle,
    cache: cache == _unset ? this.cache : cache as int?,
    ownedBy: ownedBy == _unset ? this.ownedBy : ownedBy as String?,
    currentValue: currentValue == _unset ? this.currentValue : currentValue as int?,
    comment: comment == _unset ? this.comment : comment as String?,
  );
}

enum TriggerTiming {
  before('BEFORE'),
  after('AFTER'),
  insteadOf('INSTEAD OF');

  const TriggerTiming(this.sql);
  final String sql;
}

enum TriggerEvent {
  insert('INSERT'),
  update('UPDATE'),
  delete('DELETE');

  const TriggerEvent(this.sql);
  final String sql;
}

/// A trigger of a table. [source] is the complete DDL that creates it, as
/// the catalog returns it (PostgreSQL: the trigger function too); editing a
/// trigger means editing its source.
class TriggerDef {
  const TriggerDef({
    this.catalog,
    this.schema,
    required this.table,
    required this.name,
    this.timing = TriggerTiming.before,
    this.events = const {TriggerEvent.insert},
    this.forEachRow = true,
    this.enabled = true,
    this.source = '',
    this.function,
  });

  final String? catalog;
  final String? schema;
  final String table;
  final String name;
  final TriggerTiming timing;
  final Set<TriggerEvent> events;
  final bool forEachRow;
  final bool enabled;
  final String source;

  /// PostgreSQL trigger function (schema-qualified name).
  final String? function;

  String get summary =>
      '${timing.sql} ${events.map((e) => e.sql).join(' OR ')}${forEachRow ? ' · riga' : ' · istruzione'}';

  TriggerDef copyWith({String? name, bool? enabled, String? source}) => TriggerDef(
    catalog: catalog,
    schema: schema,
    table: table,
    name: name ?? this.name,
    timing: timing,
    events: events,
    forEachRow: forEachRow,
    enabled: enabled ?? this.enabled,
    source: source ?? this.source,
    function: function,
  );
}

enum RoutineKind {
  procedure('PROCEDURE', 'procedura'),
  function('FUNCTION', 'funzione');

  const RoutineKind(this.sql, this.label);
  final String sql;
  final String label;
}
