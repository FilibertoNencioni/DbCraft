// Objects only some DBMS have: PostgreSQL extensions, enum types, row
// security policies and exclusion constraints; domains (PostgreSQL,
// Firebird); synonyms (SQL Server, Oracle); Oracle packages; MySQL events;
// Snowflake warehouses, stages and file formats.

/// Where the objects of a kind are listed in the navigator.
enum ExtraLevel { connection, schema, table }

/// A kind of DBMS specific object.
enum ExtraKind {
  extensions('Estensioni', 'estensione', ExtraLevel.connection),
  enumTypes('Tipi enumerati', 'tipo enumerato', ExtraLevel.schema),
  domains('Domini', 'dominio', ExtraLevel.schema),
  synonyms('Sinonimi', 'sinonimo', ExtraLevel.schema),
  packages('Package', 'package', ExtraLevel.schema),
  events('Eventi', 'evento', ExtraLevel.schema),
  warehouses('Warehouse', 'warehouse', ExtraLevel.connection),
  stages('Stage', 'stage', ExtraLevel.schema),
  fileFormats('Formati di file', 'formato di file', ExtraLevel.schema),
  policies('Policy di sicurezza', 'policy', ExtraLevel.table),
  exclusions('Vincoli di esclusione', 'vincolo di esclusione', ExtraLevel.table),

  /// Cassandra user defined types (in a keyspace).
  userTypes('Tipi definiti dall\'utente', 'tipo', ExtraLevel.schema);

  const ExtraKind(this.label, this.singular, this.level);

  /// Folder name.
  final String label;

  /// One object, lower case ("Nuovo dominio…").
  final String singular;
  final ExtraLevel level;

  /// "Nuovo …" / "Nuova …" for the menus.
  String get newLabel {
    const feminine = {ExtraKind.extensions, ExtraKind.policies};
    return '${feminine.contains(this) ? 'Nuova' : 'Nuovo'} $singular…';
  }
}

/// An object of an [ExtraKind] (shown as a navigator node).
abstract class ExtraObjectDef {
  const ExtraObjectDef();
  String get name;
  String? get catalog => null;
  String? get schema => null;

  /// Right-aligned detail in the navigator.
  String? get detail => null;
}

// ---------------------------------------------------------------------------
// PostgreSQL
// ---------------------------------------------------------------------------

class ExtensionDef extends ExtraObjectDef {
  const ExtensionDef({
    required this.name,
    this.catalog,
    this.schema,
    this.version,
    this.defaultVersion,
    this.comment,
    this.installed = true,
  });

  @override
  final String name;

  /// Database it is installed in (set with one session per database).
  @override
  final String? catalog;
  @override
  final String? schema;
  final String? version;

  /// Version installed by CREATE / ALTER … UPDATE without TO.
  final String? defaultVersion;
  final String? comment;

  /// Installed in the database (else only available on the server).
  final bool installed;

  bool get updatable => installed && defaultVersion != null && version != null && defaultVersion != version;

  @override
  String? get detail => [?version, if (updatable) 'aggiornabile a $defaultVersion'].join(' · ');
}

class EnumTypeDef extends ExtraObjectDef {
  const EnumTypeDef({required this.name, this.catalog, this.schema, this.values = const [], this.comment});
  @override
  final String name;
  @override
  final String? catalog;
  @override
  final String? schema;
  final List<String> values;
  final String? comment;

  @override
  String? get detail => '${values.length} valori';
}

/// A CHECK of a domain (Firebird: one, without name).
class DomainCheck {
  const DomainCheck(this.expression, {this.name});
  final String expression;
  final String? name;
}

class DomainDef extends ExtraObjectDef {
  const DomainDef({
    required this.name,
    required this.baseType,
    this.catalog,
    this.schema,
    this.notNull = false,
    this.defaultValue,
    this.checks = const [],
    this.collation,
    this.comment,
  });
  @override
  final String name;
  @override
  final String? catalog;
  @override
  final String? schema;

  /// Full SQL type (varchar(20), numeric(10,2)).
  final String baseType;
  final bool notNull;

  /// SQL expression.
  final String? defaultValue;
  final List<DomainCheck> checks;
  final String? collation;
  final String? comment;

  @override
  String? get detail => '$baseType${notNull ? ' NOT NULL' : ''}';
}

enum PolicyCommand {
  all('ALL', 'Tutte le operazioni'),
  select('SELECT', 'SELECT'),
  insert('INSERT', 'INSERT'),
  update('UPDATE', 'UPDATE'),
  delete('DELETE', 'DELETE');

  const PolicyCommand(this.sql, this.label);
  final String sql;
  final String label;

  /// USING applies (rows read or changed).
  bool get hasUsing => this != PolicyCommand.insert;

  /// WITH CHECK applies (rows written).
  bool get hasCheck => this != PolicyCommand.select && this != PolicyCommand.delete;
}

/// Row level security policy of a table.
class PolicyDef extends ExtraObjectDef {
  const PolicyDef({
    required this.name,
    required this.table,
    this.catalog,
    this.schema,
    this.command = PolicyCommand.all,
    this.permissive = true,
    this.roles = const [],
    this.using,
    this.withCheck,
  });
  @override
  final String name;
  final String table;
  @override
  final String? catalog;
  @override
  final String? schema;
  final PolicyCommand command;

  /// PERMISSIVE policies are OR-ed, RESTRICTIVE ones AND-ed.
  final bool permissive;

  /// Roles the policy applies to (empty: PUBLIC).
  final List<String> roles;
  final String? using;
  final String? withCheck;

  @override
  String? get detail => [command.sql, if (!permissive) 'restrittiva'].join(' · ');
}

/// Row level security switches of a table.
class RowSecurity {
  const RowSecurity({this.enabled = false, this.forced = false});
  final bool enabled;

  /// Applies to the table owner too (FORCE).
  final bool forced;
}

/// One element of an exclusion constraint: `expression WITH operator`.
class ExclusionElement {
  const ExclusionElement(this.expression, this.operator);
  final String expression;
  final String operator;
}

class ExclusionDef extends ExtraObjectDef {
  const ExclusionDef({
    required this.name,
    required this.table,
    this.catalog,
    this.schema,
    this.method = 'gist',
    this.elements = const [],
    this.where,
    this.deferrable = false,
    this.initiallyDeferred = false,
  });
  @override
  final String name;
  final String table;
  @override
  final String? catalog;
  @override
  final String? schema;
  final String method;
  final List<ExclusionElement> elements;

  /// Partial constraint predicate.
  final String? where;
  final bool deferrable;
  final bool initiallyDeferred;

  @override
  String? get detail => [for (final e in elements) '${e.expression} ${e.operator}'].join(', ');
}

// ---------------------------------------------------------------------------
// Synonyms, packages
// ---------------------------------------------------------------------------

class SynonymDef extends ExtraObjectDef {
  const SynonymDef({
    required this.name,
    required this.targetObject,
    this.catalog,
    this.schema,
    this.targetCatalog,
    this.targetSchema,
    this.dbLink,
    this.isPublic = false,
  });
  @override
  final String name;
  @override
  final String? catalog;
  @override
  final String? schema;
  final String? targetCatalog;
  final String? targetSchema;
  final String targetObject;

  /// Oracle database link of a remote object.
  final String? dbLink;

  /// Oracle PUBLIC synonym.
  final bool isPublic;

  String get target => [
    [?targetCatalog, ?targetSchema, targetObject].join('.'),
    if (dbLink != null) '@$dbLink',
  ].join();

  @override
  String? get detail => '→ $target';
}

class PackageDef extends ExtraObjectDef {
  const PackageDef({required this.name, this.schema, this.hasBody = false, this.valid = true});
  @override
  final String name;
  @override
  final String? schema;
  final bool hasBody;

  /// Spec and body compiled without errors.
  final bool valid;

  @override
  String? get detail => [if (!hasBody) 'senza corpo', if (!valid) 'non valido'].join(' · ');
}

/// Source of a package: specification and body.
class PackageSource {
  const PackageSource(this.spec, this.body);
  final String spec;

  /// Empty when the package has no body.
  final String body;
}

// ---------------------------------------------------------------------------
// MySQL events
// ---------------------------------------------------------------------------

enum EventStatus {
  enabled('Abilitato'),
  disabled('Disabilitato'),
  replicaDisabled('Disabilitato sulle repliche');

  const EventStatus(this.label);
  final String label;
}

const eventUnits = ['SECOND', 'MINUTE', 'HOUR', 'DAY', 'WEEK', 'MONTH', 'QUARTER', 'YEAR'];

class EventDef extends ExtraObjectDef {
  const EventDef({
    required this.name,
    required this.body,
    this.catalog,
    this.at,
    this.every,
    this.unit = 'DAY',
    this.starts,
    this.ends,
    this.preserve = false,
    this.status = EventStatus.enabled,
    this.comment,
  });
  @override
  final String name;

  /// Database of the event.
  @override
  final String? catalog;

  /// One-time event: timestamp (`2027-01-01 00:00:00`).
  final String? at;

  /// Recurring event: every [every] [unit].
  final int? every;
  final String unit;
  final String? starts;
  final String? ends;

  /// ON COMPLETION PRESERVE: kept after the last run.
  final bool preserve;
  final EventStatus status;
  final String? comment;

  /// The statement run (one statement or BEGIN … END).
  final String body;

  bool get recurring => at == null;

  /// Whether [o] has this schedule. An [o] without STARTS keeps the current
  /// one: MySQL sets it to the creation time when it is not given.
  bool sameSchedule(EventDef o) =>
      at == o.at &&
      every == o.every &&
      unit.toUpperCase() == o.unit.toUpperCase() &&
      (o.starts == null || starts == o.starts) &&
      ends == o.ends;

  @override
  String? get detail => [
    recurring ? 'ogni $every ${unit.toLowerCase()}' : 'il $at',
    if (status != EventStatus.enabled) 'disabilitato',
  ].join(' · ');
}

// ---------------------------------------------------------------------------
// Snowflake
// ---------------------------------------------------------------------------

const warehouseSizes = [
  'XSMALL', 'SMALL', 'MEDIUM', 'LARGE', 'XLARGE', 'XXLARGE', 'XXXLARGE', 'X4LARGE', 'X5LARGE', 'X6LARGE', //
];

class WarehouseDef extends ExtraObjectDef {
  const WarehouseDef({
    required this.name,
    this.size,
    this.type,
    this.autoSuspend,
    this.autoResume = true,
    this.minClusters,
    this.maxClusters,
    this.scalingPolicy,
    this.initiallySuspended = false,
    this.comment,
    this.state,
  });
  @override
  final String name;

  /// One of [warehouseSizes].
  final String? size;

  /// STANDARD or SNOWPARK-OPTIMIZED.
  final String? type;

  /// Seconds of inactivity before suspending (0: never).
  final int? autoSuspend;
  final bool autoResume;
  final int? minClusters;
  final int? maxClusters;

  /// STANDARD or ECONOMY.
  final String? scalingPolicy;

  /// Created suspended (CREATE only).
  final bool initiallySuspended;
  final String? comment;

  /// STARTED, SUSPENDED, RESIZING… (read only).
  final String? state;

  bool get suspended => (state ?? '').toUpperCase() == 'SUSPENDED';

  @override
  String? get detail => [?size, if (state != null) state!.toLowerCase()].join(' · ');
}

class StageDef extends ExtraObjectDef {
  const StageDef({
    required this.name,
    this.catalog,
    this.schema,
    this.url,
    this.storageIntegration,
    this.fileFormat,
    this.comment,
  });
  @override
  final String name;
  @override
  final String? catalog;
  @override
  final String? schema;

  /// External location (s3://…, azure://…, gcs://…); null for an internal stage.
  final String? url;
  final String? storageIntegration;

  /// Named file format.
  final String? fileFormat;
  final String? comment;

  bool get external => url != null;

  @override
  String? get detail => url ?? 'interno';
}

const fileFormatTypes = ['CSV', 'JSON', 'PARQUET', 'AVRO', 'ORC', 'XML'];

enum FileOptionKind { text, number, boolean, choice }

/// An option of a file format type.
class FileFormatOption {
  const FileFormatOption(this.key, this.label, this.kind, {this.choices = const [], this.hint});
  final String key;
  final String label;
  final FileOptionKind kind;
  final List<String> choices;
  final String? hint;
}

const _compression = ['AUTO', 'GZIP', 'BZ2', 'BROTLI', 'ZSTD', 'DEFLATE', 'RAW_DEFLATE', 'NONE'];

/// The options offered for each file format type.
List<FileFormatOption> fileFormatOptions(String type) => switch (type) {
  'CSV' => const [
    FileFormatOption('FIELD_DELIMITER', 'Separatore di campo', FileOptionKind.text, hint: ','),
    FileFormatOption('RECORD_DELIMITER', 'Separatore di record', FileOptionKind.text, hint: r'\n'),
    FileFormatOption('SKIP_HEADER', 'Righe di intestazione', FileOptionKind.number, hint: '0'),
    FileFormatOption('FIELD_OPTIONALLY_ENCLOSED_BY', 'Delimitatore di testo', FileOptionKind.text, hint: '"'),
    FileFormatOption('EMPTY_FIELD_AS_NULL', 'Campi vuoti come NULL', FileOptionKind.boolean),
    FileFormatOption('TRIM_SPACE', 'Rimuovi gli spazi', FileOptionKind.boolean),
    FileFormatOption('DATE_FORMAT', 'Formato data', FileOptionKind.text, hint: 'AUTO'),
    FileFormatOption('ENCODING', 'Codifica', FileOptionKind.text, hint: 'UTF8'),
    FileFormatOption('COMPRESSION', 'Compressione', FileOptionKind.choice, choices: _compression),
  ],
  'JSON' => const [
    FileFormatOption('STRIP_OUTER_ARRAY', 'Rimuovi l\'array esterno', FileOptionKind.boolean),
    FileFormatOption('STRIP_NULL_VALUES', 'Rimuovi i valori null', FileOptionKind.boolean),
    FileFormatOption('DATE_FORMAT', 'Formato data', FileOptionKind.text, hint: 'AUTO'),
    FileFormatOption('COMPRESSION', 'Compressione', FileOptionKind.choice, choices: _compression),
  ],
  'PARQUET' => const [
    FileFormatOption('BINARY_AS_TEXT', 'Binari come testo', FileOptionKind.boolean),
    FileFormatOption('COMPRESSION', 'Compressione', FileOptionKind.choice, choices: ['AUTO', 'SNAPPY', 'NONE']),
  ],
  _ => const [FileFormatOption('COMPRESSION', 'Compressione', FileOptionKind.choice, choices: _compression)],
};

class FileFormatDef extends ExtraObjectDef {
  const FileFormatDef({
    required this.name,
    this.catalog,
    this.schema,
    this.type = 'CSV',
    this.options = const {},
    this.comment,
  });
  @override
  final String name;
  @override
  final String? catalog;
  @override
  final String? schema;

  /// One of [fileFormatTypes].
  final String type;

  /// Option key → value as typed (text without quotes, TRUE/FALSE, numbers).
  final Map<String, String> options;
  final String? comment;

  @override
  String? get detail => type;
}
