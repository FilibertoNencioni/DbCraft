// Readers of the DBMS specific objects (see model/extra_defs.dart).

import 'dart:convert';

import '../../../model/db_objects.dart';
import '../../../services/sql_dialect.dart';
import '../model/extra_defs.dart';
import 'design_catalog.dart';
import 'nosql.dart';
import 'table_extras.dart';

/// Objects of [kind] in [catalog].[schema] (or of [table]).
Future<List<ExtraObjectDef>> readExtras(
  CatalogQueries q,
  SqlDialect d,
  ExtraKind kind, {
  String? catalog,
  String? schema,
  DbTable? table,
}) async {
  final s = lit(schema ?? '');
  switch (kind) {
    case ExtraKind.extensions:
      final rows = await q.first([
        'SELECT e.extname, n.nspname, e.extversion, a.default_version, '
            "obj_description(e.oid, 'pg_extension') AS comment FROM pg_extension e "
            'JOIN pg_namespace n ON n.oid = e.extnamespace '
            'LEFT JOIN pg_available_extensions a ON a.name = e.extname ORDER BY e.extname',
      ]);
      return [
        for (final r in rows)
          ExtensionDef(
            name: rowText(r, 'extname')!,
            catalog: catalog,
            schema: rowText(r, 'nspname'),
            version: rowText(r, 'extversion'),
            defaultVersion: rowText(r, 'default_version'),
            comment: rowText(r, 'comment'),
          ),
      ];
    case ExtraKind.enumTypes:
      final rows = await q.first([
        "SELECT t.typname, e.enumlabel, obj_description(t.oid, 'pg_type') AS comment FROM pg_type t "
            'JOIN pg_namespace n ON n.oid = t.typnamespace JOIN pg_enum e ON e.enumtypid = t.oid '
            'WHERE n.nspname = $s ORDER BY t.typname, e.enumsortorder',
      ]);
      return [
        for (final e in groupRows(rows, 'typname').entries)
          EnumTypeDef(
            name: e.key,
            catalog: catalog,
            schema: schema,
            values: [for (final r in e.value) r['enumlabel'].toString()],
            comment: rowText(e.value.first, 'comment'),
          ),
      ];
    case ExtraKind.domains:
      return d.family == DbFamily.firebird ? _firebirdDomains(q) : _pgDomains(q, catalog, schema);
    case ExtraKind.policies:
      final rows = await q.first([
        'SELECT policyname, permissive, roles::text AS roles, cmd, qual, with_check FROM pg_policies '
            'WHERE schemaname = ${lit(table!.schema ?? '')} AND tablename = ${lit(table.name)} ORDER BY policyname',
      ]);
      return [
        for (final r in rows)
          PolicyDef(
            name: rowText(r, 'policyname')!,
            table: table.name,
            catalog: table.catalog,
            schema: table.schema,
            command: PolicyCommand.values.firstWhere(
              (c) => c.sql == (rowText(r, 'cmd') ?? 'ALL').toUpperCase(),
              orElse: () => PolicyCommand.all,
            ),
            permissive: (rowText(r, 'permissive') ?? 'PERMISSIVE').toUpperCase() == 'PERMISSIVE',
            roles: [
              for (final x in pgArray(rowText(r, 'roles') ?? ''))
                if (x.toLowerCase() != 'public') x,
            ],
            using: rowText(r, 'qual'),
            withCheck: rowText(r, 'with_check'),
          ),
      ];
    case ExtraKind.exclusions:
      final rows = await q.first([
        'SELECT c.conname, pg_get_constraintdef(c.oid) AS def, c.condeferrable, c.condeferred FROM pg_constraint c '
            'JOIN pg_class r ON r.oid = c.conrelid JOIN pg_namespace n ON n.oid = r.relnamespace '
            "WHERE c.contype = 'x' AND n.nspname = ${lit(table!.schema ?? '')} AND r.relname = ${lit(table.name)} "
            'ORDER BY c.conname',
      ]);
      return [
        for (final r in rows)
          parseExclusion(
            rowText(r, 'def') ?? '',
            name: rowText(r, 'conname')!,
            table: table.name,
            catalog: table.catalog,
            schema: table.schema,
            deferrable: rowBool(r, 'condeferrable'),
            initiallyDeferred: rowBool(r, 'condeferred'),
          ),
      ];
    case ExtraKind.synonyms:
      if (d.family == DbFamily.sqlServer) {
        final db = catalog == null ? '' : '${d.quoteIdent(catalog)}.';
        final rows = await q.first([
          'SELECT s.name, s.base_object_name FROM ${db}sys.synonyms s '
              'JOIN ${db}sys.schemas sc ON sc.schema_id = s.schema_id WHERE sc.name = N$s ORDER BY s.name',
        ]);
        return [
          for (final r in rows)
            () {
              final parts = splitBracketed(rowText(r, 'base_object_name') ?? '');
              return SynonymDef(
                name: rowText(r, 'name')!,
                catalog: catalog,
                schema: schema,
                targetObject: parts.last,
                targetSchema: parts.length >= 2 ? parts[parts.length - 2] : null,
                targetCatalog: parts.length >= 3 ? parts[parts.length - 3] : null,
              );
            }(),
        ];
      }
      final rows = await q.first([
        'SELECT owner, synonym_name, table_owner, table_name, db_link FROM all_synonyms WHERE owner = $s '
            'ORDER BY synonym_name',
      ]);
      return [
        for (final r in rows)
          SynonymDef(
            name: rowText(r, 'synonym_name')!,
            schema: schema,
            targetSchema: rowText(r, 'table_owner'),
            targetObject: rowText(r, 'table_name') ?? '',
            dbLink: rowText(r, 'db_link'),
            isPublic: rowText(r, 'owner') == 'PUBLIC',
          ),
      ];
    case ExtraKind.packages:
      final rows = await q.first([
        'SELECT object_name, object_type, status FROM all_objects WHERE owner = $s '
            "AND object_type IN ('PACKAGE', 'PACKAGE BODY') ORDER BY object_name",
      ]);
      return [
        for (final e in groupRows(rows, 'object_name').entries)
          PackageDef(
            name: e.key,
            schema: schema,
            hasBody: e.value.any((r) => rowText(r, 'object_type') == 'PACKAGE BODY'),
            valid: e.value.every((r) => rowText(r, 'status') != 'INVALID'),
          ),
      ];
    case ExtraKind.events:
      final rows = await q.first([
        'SELECT EVENT_NAME, EVENT_DEFINITION, EVENT_TYPE, EXECUTE_AT, INTERVAL_VALUE, INTERVAL_FIELD, STARTS, ENDS, '
            'STATUS, ON_COMPLETION, EVENT_COMMENT FROM information_schema.EVENTS '
            'WHERE EVENT_SCHEMA = ${lit(catalog ?? schema ?? '')} ORDER BY EVENT_NAME',
      ]);
      return [
        for (final r in rows)
          () {
            final oneTime = (rowText(r, 'event_type') ?? '').toUpperCase().startsWith('ONE');
            return EventDef(
              name: rowText(r, 'event_name')!,
              catalog: catalog ?? schema,
              body: r['event_definition']?.toString() ?? '',
              at: oneTime ? _timestamp(rowText(r, 'execute_at')) : null,
              every: oneTime ? null : int.tryParse(rowText(r, 'interval_value') ?? ''),
              unit: rowText(r, 'interval_field') ?? 'DAY',
              starts: oneTime ? null : _timestamp(rowText(r, 'starts')),
              ends: oneTime ? null : _timestamp(rowText(r, 'ends')),
              preserve: (rowText(r, 'on_completion') ?? '').toUpperCase() == 'PRESERVE',
              status: switch ((rowText(r, 'status') ?? '').toUpperCase()) {
                'DISABLED' => EventStatus.disabled,
                'SLAVESIDE_DISABLED' || 'REPLICA_SIDE_DISABLED' => EventStatus.replicaDisabled,
                _ => EventStatus.enabled,
              },
              comment: rowText(r, 'event_comment'),
            );
          }(),
      ];
    case ExtraKind.warehouses:
      final rows = await q.first(['SHOW WAREHOUSES']);
      return [
        for (final r in rows)
          WarehouseDef(
            name: rowText(r, 'name')!,
            size: warehouseSize(rowText(r, 'size')),
            type: rowText(r, 'type'),
            autoSuspend: rowInt(r, 'auto_suspend'),
            autoResume: rowBool(r, 'auto_resume'),
            minClusters: rowInt(r, 'min_cluster_count'),
            maxClusters: rowInt(r, 'max_cluster_count'),
            scalingPolicy: rowText(r, 'scaling_policy'),
            comment: rowText(r, 'comment'),
            state: rowText(r, 'state'),
          ),
      ];
    case ExtraKind.stages:
      final rows = await q.first(['SHOW STAGES IN SCHEMA ${d.qualified(null, catalog, schema ?? '')}']);
      return [
        for (final r in rows)
          StageDef(
            name: rowText(r, 'name')!,
            catalog: catalog,
            schema: schema,
            url: rowText(r, 'url'),
            storageIntegration: rowText(r, 'storage_integration'),
            comment: rowText(r, 'comment'),
          ),
      ];
    case ExtraKind.userTypes:
      return readUserTypes(q, catalog ?? schema ?? '');
    case ExtraKind.fileFormats:
      final rows = await q.first(['SHOW FILE FORMATS IN SCHEMA ${d.qualified(null, catalog, schema ?? '')}']);
      return [
        for (final r in rows)
          () {
            final type = (rowText(r, 'type') ?? 'CSV').toUpperCase();
            return FileFormatDef(
              name: rowText(r, 'name')!,
              catalog: catalog,
              schema: schema,
              type: type,
              options: fileFormatOptionsFromJson(type, rowText(r, 'format_options')),
              comment: rowText(r, 'comment'),
            );
          }(),
      ];
  }
}

Future<List<ExtraObjectDef>> _pgDomains(CatalogQueries q, String? catalog, String? schema) async {
  final rows = await q.first([
    'SELECT t.typname, format_type(t.typbasetype, t.typtypmod) AS base_type, t.typnotnull, t.typdefault, '
        "co.collname, c.conname, pg_get_constraintdef(c.oid) AS check_def, obj_description(t.oid, 'pg_type') AS comment "
        'FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace '
        "LEFT JOIN pg_constraint c ON c.contypid = t.oid AND c.contype = 'c' "
        'LEFT JOIN pg_collation co ON co.oid = t.typcollation AND t.typcollation <> 100 '
        "WHERE t.typtype = 'd' AND n.nspname = ${lit(schema ?? '')} ORDER BY t.typname, c.conname",
  ]);
  return [
    for (final e in groupRows(rows, 'typname').entries)
      DomainDef(
        name: e.key,
        catalog: catalog,
        schema: schema,
        baseType: rowText(e.value.first, 'base_type') ?? '',
        notNull: rowBool(e.value.first, 'typnotnull'),
        defaultValue: rowText(e.value.first, 'typdefault'),
        collation: rowText(e.value.first, 'collname'),
        comment: rowText(e.value.first, 'comment'),
        checks: [
          for (final r in e.value)
            if (rowText(r, 'check_def') != null)
              DomainCheck(checkExpression(rowText(r, 'check_def')!), name: rowText(r, 'conname')),
        ],
      ),
  ];
}

Future<List<ExtraObjectDef>> _firebirdDomains(CatalogQueries q) async {
  final rows = await q.first([
    r'SELECT f.RDB$FIELD_NAME AS name, f.RDB$FIELD_TYPE AS ftype, f.RDB$FIELD_SUB_TYPE AS subtype, '
        r'f.RDB$FIELD_PRECISION AS fprecision, f.RDB$FIELD_SCALE AS fscale, f.RDB$CHARACTER_LENGTH AS charlen, '
        r'f.RDB$FIELD_LENGTH AS flength, f.RDB$NULL_FLAG AS notnull, f.RDB$DEFAULT_SOURCE AS default_source, '
        r'f.RDB$VALIDATION_SOURCE AS check_source, f.RDB$DESCRIPTION AS description, cl.RDB$COLLATION_NAME AS collation '
        r'FROM RDB$FIELDS f LEFT JOIN RDB$COLLATIONS cl ON cl.RDB$COLLATION_ID = f.RDB$COLLATION_ID '
        r'AND cl.RDB$CHARACTER_SET_ID = f.RDB$CHARACTER_SET_ID AND f.RDB$COLLATION_ID > 0 '
        r"WHERE COALESCE(f.RDB$SYSTEM_FLAG, 0) = 0 AND f.RDB$FIELD_NAME NOT STARTING WITH 'RDB$' "
        r'ORDER BY 1',
  ]);
  return [
    for (final r in rows)
      DomainDef(
        name: rowText(r, 'name')!,
        baseType: firebirdType(
          rowInt(r, 'ftype') ?? 0,
          subType: rowInt(r, 'subtype') ?? 0,
          precision: rowInt(r, 'fprecision') ?? 0,
          scale: rowInt(r, 'fscale') ?? 0,
          charLength: rowInt(r, 'charlen') ?? rowInt(r, 'flength'),
        ),
        notNull: rowBool(r, 'notnull'),
        defaultValue: rowText(r, 'default_source')?.replaceFirst(RegExp(r'^DEFAULT\s+', caseSensitive: false), ''),
        checks: [if (rowText(r, 'check_source') case final c?) DomainCheck(checkExpression(c))],
        collation: rowText(r, 'collation'),
        comment: rowText(r, 'description'),
      ),
  ];
}

/// `CHECK ((VALUE > 0))` → `VALUE > 0`.
String checkExpression(String def) =>
    stripParens(def.trim().replaceFirst(RegExp(r'^CHECK\s*', caseSensitive: false), ''));

/// SQL type of a Firebird RDB$FIELDS row.
String firebirdType(int type, {int subType = 0, int precision = 0, int scale = 0, int? charLength}) {
  String exact(String base) => scale < 0 || subType == 1 || subType == 2
      ? '${subType == 2 ? 'DECIMAL' : 'NUMERIC'}(${precision == 0 ? (type == 7 ? 4 : (type == 8 ? 9 : 18)) : precision},${-scale})'
      : base;
  return switch (type) {
    7 => exact('SMALLINT'),
    8 => exact('INTEGER'),
    16 => exact('BIGINT'),
    26 => exact('INT128'),
    10 => 'FLOAT',
    27 => 'DOUBLE PRECISION',
    12 => 'DATE',
    13 => 'TIME',
    35 => 'TIMESTAMP',
    28 => 'TIME WITH TIME ZONE',
    29 => 'TIMESTAMP WITH TIME ZONE',
    14 => 'CHAR(${charLength ?? 1})',
    37 => 'VARCHAR(${charLength ?? 1})',
    23 => 'BOOLEAN',
    24 => 'DECFLOAT(16)',
    25 => 'DECFLOAT(34)',
    261 => subType == 1 ? 'BLOB SUB_TYPE TEXT' : 'BLOB',
    _ => 'VARCHAR(${charLength ?? 1})',
  };
}

/// `{a,"b c"}` → [a, b c].
List<String> pgArray(String text) {
  var t = text.trim();
  if (t.startsWith('{') && t.endsWith('}')) t = t.substring(1, t.length - 1);
  if (t.isEmpty) return const [];
  final out = <String>[];
  final sb = StringBuffer();
  var quoted = false;
  for (var i = 0; i < t.length; i++) {
    final c = t[i];
    if (c == '"') {
      quoted = !quoted;
    } else if (c == '\\' && i + 1 < t.length) {
      sb.write(t[++i]);
    } else if (c == ',' && !quoted) {
      out.add(sb.toString());
      sb.clear();
    } else {
      sb.write(c);
    }
  }
  out.add(sb.toString());
  return out;
}

/// `[db].[dbo].[t]` → [db, dbo, t].
List<String> splitBracketed(String name) {
  final out = <String>[];
  final sb = StringBuffer();
  var inside = false;
  for (var i = 0; i < name.length; i++) {
    final c = name[i];
    if (c == '[' && !inside) {
      inside = true;
    } else if (c == ']' && inside) {
      if (i + 1 < name.length && name[i + 1] == ']') {
        sb.write(']');
        i++;
      } else {
        inside = false;
      }
    } else if (c == '.' && !inside) {
      out.add(sb.toString());
      sb.clear();
    } else {
      sb.write(c);
    }
  }
  out.add(sb.toString());
  return out;
}

/// Splits [text] at top-level [sep] (outside parentheses and quotes).
List<String> _topLevel(String text, String sep) {
  final out = <String>[];
  var depth = 0;
  var quote = '';
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quote.isNotEmpty) {
      if (c == quote) quote = '';
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    } else if (depth == 0 && text.startsWith(sep, i)) {
      out.add(text.substring(start, i).trim());
      start = i + sep.length;
    }
  }
  out.add(text.substring(start).trim());
  return out;
}

/// An exclusion constraint from `pg_get_constraintdef`:
/// `EXCLUDE USING gist (room WITH =, during WITH &&) WHERE ((active))`.
ExclusionDef parseExclusion(
  String def, {
  required String name,
  required String table,
  String? catalog,
  String? schema,
  bool deferrable = false,
  bool initiallyDeferred = false,
}) {
  final m = RegExp(r'^EXCLUDE\s+USING\s+(\w+)\s*\(', caseSensitive: false).firstMatch(def.trim());
  if (m == null) return ExclusionDef(name: name, table: table, catalog: catalog, schema: schema);
  final t = def.trim();
  var depth = 1;
  var i = m.end;
  for (; i < t.length && depth > 0; i++) {
    if (t[i] == '(') depth++;
    if (t[i] == ')') depth--;
  }
  final inner = t.substring(m.end, i - 1);
  final rest = t.substring(i).trim();
  final where = RegExp(r'^WHERE\s+(.*?)(\s+DEFERRABLE.*)?$', caseSensitive: false, dotAll: true).firstMatch(rest);
  return ExclusionDef(
    name: name,
    table: table,
    catalog: catalog,
    schema: schema,
    method: m.group(1)!.toLowerCase(),
    elements: [
      for (final part in _topLevel(inner, ','))
        () {
          final w = RegExp(r'^(.*)\s+WITH\s+(\S+)$', caseSensitive: false, dotAll: true).firstMatch(part);
          return w == null ? ExclusionElement(part, '=') : ExclusionElement(w.group(1)!.trim(), w.group(2)!);
        }(),
    ],
    where: where == null ? null : stripParens(where.group(1)!),
    deferrable: deferrable,
    initiallyDeferred: initiallyDeferred,
  );
}

/// SHOW WAREHOUSES size (`X-Small`, `2X-Large`) → CREATE value (`XSMALL`,
/// `XXLARGE`).
String? warehouseSize(String? shown) {
  if (shown == null) return null;
  final s = shown.toUpperCase().replaceAll('-', '').replaceAll(' ', '');
  final m = RegExp(r'^(\d)X(.*)$').firstMatch(s);
  if (m == null) return s;
  final n = int.parse(m.group(1)!);
  return n <= 3 ? '${'X' * n}${m.group(2)}' : 'X$n${m.group(2)}';
}

/// Known options of a SHOW FILE FORMATS `format_options` JSON.
Map<String, String> fileFormatOptionsFromJson(String type, String? json) {
  if (json == null) return const {};
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } catch (_) {
    return const {};
  }
  if (decoded is! Map) return const {};
  return {
    for (final o in fileFormatOptions(type))
      if (decoded[o.key] case final v? when v is! List && v is! Map) o.key: v is bool ? (v ? 'TRUE' : 'FALSE') : '$v',
  };
}

String? _timestamp(String? s) {
  if (s == null) return null;
  // Drivers may add fractional seconds or a 'T'.
  return s.replaceFirst('T', ' ').replaceFirst(RegExp(r'\.0+$'), '');
}

// ---------------------------------------------------------------------------
// Sources and states
// ---------------------------------------------------------------------------

/// Specification and body of an Oracle package (with CREATE OR REPLACE).
Future<PackageSource?> readPackageSource(CatalogQueries q, SqlDialect d, PackageDef p) async {
  final rows = await q.first([
    'SELECT type, text FROM all_source WHERE owner = ${lit(p.schema ?? '')} AND name = ${lit(p.name)} '
        "AND type IN ('PACKAGE', 'PACKAGE BODY') ORDER BY type, line",
  ]);
  if (rows.isEmpty) return null;
  String part(String type) {
    final text = [
      for (final r in rows)
        if (rowText(r, 'type') == type) r['text']?.toString() ?? '',
    ].join();
    return text.trim().isEmpty ? '' : 'CREATE OR REPLACE ${text.trimRight()}';
  }

  return PackageSource(part('PACKAGE'), part('PACKAGE BODY'));
}

/// Row level security switches of a PostgreSQL table.
Future<RowSecurity> readRowSecurity(CatalogQueries q, DbTable t) async {
  final rows = await q.first([
    'SELECT c.relrowsecurity, c.relforcerowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace '
        'WHERE n.nspname = ${lit(t.schema ?? '')} AND c.relname = ${lit(t.name)}',
  ]);
  if (rows.isEmpty) return const RowSecurity();
  return RowSecurity(
    enabled: rowBool(rows.first, 'relrowsecurity'),
    forced: rowBool(rows.first, 'relforcerowsecurity'),
  );
}

/// Whether the MySQL event scheduler runs (null: unknown).
Future<bool?> readEventScheduler(CatalogQueries q) async {
  try {
    final rows = await q.first(['SELECT @@event_scheduler AS state']);
    final v = rows.isEmpty ? null : rowText(rows.first, 'state');
    return v == null ? null : v.toUpperCase() == 'ON' || v == '1';
  } catch (_) {
    return null;
  }
}

/// Extensions the server can install (name, default version, comment).
Future<List<ExtensionDef>> readAvailableExtensions(CatalogQueries q) async {
  final rows = await q.first([
    'SELECT name, default_version, installed_version, comment FROM pg_available_extensions ORDER BY name',
  ]);
  return [
    for (final r in rows)
      ExtensionDef(
        name: rowText(r, 'name')!,
        version: rowText(r, 'installed_version'),
        defaultVersion: rowText(r, 'default_version'),
        comment: rowText(r, 'comment'),
        installed: rowText(r, 'installed_version') != null,
      ),
  ];
}
