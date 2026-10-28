// Databases and schemas with their properties, and the values offered by
// the database / schema sheets (encodings, collations, owners…).

import '../../../services/sql_dialect.dart';
import '../model/object_defs.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

/// Values offered by the sheets: free text is allowed anyway.
class DatabaseChoices {
  const DatabaseChoices({
    this.owners = const [],
    this.encodings = const [],
    this.collations = const [],
    this.templates = const [],
    this.tablespaces = const [],
  });

  static const none = DatabaseChoices();

  final List<String> owners;
  final List<String> encodings;
  final List<String> collations;
  final List<String> templates;
  final List<String> tablespaces;
}

const _pgEncodings = [
  'UTF8', 'LATIN1', 'LATIN9', 'WIN1252', 'SQL_ASCII', 'EUC_JP', 'SJIS', 'GB18030', 'BIG5', 'ISO_8859_5', //
];

Future<List<String>> _names(CatalogQueries q, List<String> alternatives) async {
  try {
    final rows = await q.first(alternatives);
    return [
      for (final r in rows)
        if (r.isNotEmpty && r.values.first != null) r.values.first.toString().trim(),
    ];
  } catch (_) {
    return const [];
  }
}

Future<List<DatabaseDef>> readDatabases(CatalogQueries q, SqlDialect d) async {
  switch (d.family) {
    case DbFamily.postgres:
      final rows = await q.first([
        'SELECT d.datname, pg_get_userbyid(d.datdba) AS owner, pg_encoding_to_char(d.encoding) AS encoding, '
            'd.datcollate, d.datctype, d.datconnlimit, t.spcname, shobj_description(d.oid, \'pg_database\') AS comment '
            'FROM pg_database d LEFT JOIN pg_tablespace t ON t.oid = d.dattablespace '
            'WHERE NOT d.datistemplate ORDER BY d.datname',
      ]);
      return [
        for (final r in rows)
          DatabaseDef(
            name: rowText(r, 'datname')!,
            owner: rowText(r, 'owner'),
            encoding: rowText(r, 'encoding'),
            collation: rowText(r, 'datcollate'),
            ctype: rowText(r, 'datctype'),
            connectionLimit: rowInt(r, 'datconnlimit'),
            tablespace: rowText(r, 'spcname'),
            comment: rowText(r, 'comment'),
          ),
      ];
    case DbFamily.sqlServer:
      final rows = await q.first([
        'SELECT name, collation_name, recovery_model_desc, SUSER_SNAME(owner_sid) AS owner FROM sys.databases ORDER BY name',
      ]);
      return [
        for (final r in rows)
          DatabaseDef(
            name: rowText(r, 'name')!,
            collation: rowText(r, 'collation_name'),
            recoveryModel: rowText(r, 'recovery_model_desc'),
            owner: rowText(r, 'owner'),
          ),
      ];
    case DbFamily.mysql:
      final rows = await q.first([
        'SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA '
            'ORDER BY SCHEMA_NAME',
      ]);
      return [
        for (final r in rows)
          DatabaseDef(
            name: rowText(r, 'schema_name')!,
            encoding: rowText(r, 'default_character_set_name'),
            collation: rowText(r, 'default_collation_name'),
          ),
      ];
    case DbFamily.snowflake:
      final rows = await q.first(['SHOW DATABASES']);
      return [
        for (final r in rows)
          DatabaseDef(
            name: rowText(r, 'name')!,
            owner: rowText(r, 'owner'),
            comment: rowText(r, 'comment'),
            retentionDays: rowInt(r, 'retention_time'),
            transient: (rowText(r, 'options') ?? '').toUpperCase().contains('TRANSIENT'),
          ),
      ];
    default:
      return const [];
  }
}

Future<List<SchemaDef>> readSchemas(CatalogQueries q, SqlDialect d, String? catalog) async {
  switch (d.family) {
    case DbFamily.postgres:
      final rows = await q.first([
        "SELECT n.nspname, pg_get_userbyid(n.nspowner) AS owner, obj_description(n.oid, 'pg_namespace') AS comment "
            "FROM pg_namespace n WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema' ORDER BY 1",
      ]);
      return [
        for (final r in rows)
          SchemaDef(
            name: rowText(r, 'nspname')!,
            catalog: catalog,
            owner: rowText(r, 'owner'),
            comment: rowText(r, 'comment'),
          ),
      ];
    case DbFamily.sqlServer:
      final db = catalog == null ? '' : '${d.quoteIdent(catalog)}.';
      final rows = await q.first([
        'SELECT s.name, p.name AS owner, CAST(ep.value AS nvarchar(4000)) AS comment FROM ${db}sys.schemas s '
            'LEFT JOIN ${db}sys.database_principals p ON p.principal_id = s.principal_id '
            "LEFT JOIN ${db}sys.extended_properties ep ON ep.class = 3 AND ep.major_id = s.schema_id AND ep.name = 'MS_Description' "
            // Not the schemas of the fixed database roles (db_owner…) nor guest.
            "WHERE s.schema_id < 16384 AND s.name <> 'guest' ORDER BY s.name",
      ]);
      return [
        for (final r in rows)
          SchemaDef(
            name: rowText(r, 'name')!,
            catalog: catalog,
            owner: rowText(r, 'owner'),
            comment: rowText(r, 'comment'),
          ),
      ];
    case DbFamily.db2:
      final rows = await q.first(['SELECT schemaname, owner, remarks FROM syscat.schemata ORDER BY schemaname']);
      return [
        for (final r in rows)
          SchemaDef(name: rowText(r, 'schemaname')!, owner: rowText(r, 'owner'), comment: rowText(r, 'remarks')),
      ];
    case DbFamily.snowflake:
      final rows = await q.first([
        catalog == null ? 'SHOW SCHEMAS' : 'SHOW SCHEMAS IN DATABASE ${d.quoteIdent(catalog)}',
      ]);
      return [
        for (final r in rows)
          SchemaDef(
            name: rowText(r, 'name')!,
            catalog: catalog,
            owner: rowText(r, 'owner'),
            comment: rowText(r, 'comment'),
            retentionDays: rowInt(r, 'retention_time'),
            transient: (rowText(r, 'options') ?? '').toUpperCase().contains('TRANSIENT'),
          ),
      ];
    default:
      return const [];
  }
}

Future<DatabaseChoices> readDatabaseChoices(CatalogQueries q, SqlDialect d) async {
  switch (d.family) {
    case DbFamily.postgres:
      return DatabaseChoices(
        owners: await _names(q, ["SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%' ORDER BY 1"]),
        encodings: _pgEncodings,
        collations: await _names(q, [
          "SELECT DISTINCT collcollate FROM pg_collation WHERE collcollate IS NOT NULL AND collcollate <> '' ORDER BY 1",
        ]),
        templates: await _names(q, [
          'SELECT datname FROM pg_database WHERE datallowconn ORDER BY datistemplate DESC, 1',
        ]),
        tablespaces: await _names(q, ['SELECT spcname FROM pg_tablespace ORDER BY 1']),
      );
    case DbFamily.sqlServer:
      return DatabaseChoices(
        owners: await _names(q, [
          "SELECT name FROM sys.server_principals WHERE type IN ('S', 'U', 'G', 'E', 'X') ORDER BY 1",
        ]),
        collations: await _names(q, ['SELECT name FROM sys.fn_helpcollations() ORDER BY 1']),
      );
    case DbFamily.mysql:
      return DatabaseChoices(
        encodings: await _names(q, ['SELECT CHARACTER_SET_NAME FROM information_schema.CHARACTER_SETS ORDER BY 1']),
        collations: await _names(q, ['SELECT COLLATION_NAME FROM information_schema.COLLATIONS ORDER BY 1']),
      );
    case DbFamily.db2:
      return DatabaseChoices(owners: await _names(q, ['SELECT DISTINCT grantee FROM syscat.dbauth ORDER BY 1']));
    case DbFamily.snowflake:
      return DatabaseChoices(owners: await _names(q, ['SHOW ROLES']));
    default:
      return DatabaseChoices.none;
  }
}

/// Owners offered for the schemas of [catalog] (SQL Server: the database
/// users and roles).
Future<List<String>> readSchemaOwners(CatalogQueries q, SqlDialect d, String? catalog) async {
  if (d.family != DbFamily.sqlServer) return (await readDatabaseChoices(q, d)).owners;
  final db = catalog == null ? '' : '${d.quoteIdent(catalog)}.';
  return _names(q, [
    "SELECT name FROM ${db}sys.database_principals WHERE type IN ('S', 'U', 'G', 'R', 'E', 'X') ORDER BY 1",
  ]);
}
