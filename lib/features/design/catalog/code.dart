// Sequences, triggers and the source of procedures and functions, from the
// catalog of each DBMS.

import '../../../model/db_objects.dart';
import '../../../services/sql_dialect.dart';
import '../model/object_defs.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------

Future<List<SequenceDef>> readSequences(CatalogQueries q, SqlDialect d, String? catalog, String? schema) async {
  SequenceDef seq(
    String name,
    CatalogRow r, {
    String start = 'start',
    String inc = 'inc',
    String min = 'min',
    String max = 'max',
  }) => SequenceDef(
    catalog: catalog,
    schema: schema,
    name: name,
    dataType: rowText(r, 'type'),
    start: rowInt(r, start),
    increment: rowInt(r, inc),
    minValue: rowInt(r, min),
    maxValue: rowInt(r, max),
    cycle: rowBool(r, 'cycle'),
    cache: rowInt(r, 'cache'),
    currentValue: rowInt(r, 'cur_value'),
  );
  switch (d.family) {
    case DbFamily.postgres:
      final rows = await q.first([
        'SELECT sequencename AS name, data_type AS type, start_value AS start, increment_by AS inc, min_value AS min, '
            'max_value AS max, cycle, cache_size AS cache, last_value AS cur_value FROM pg_sequences '
            'WHERE schemaname = ${lit(schema ?? 'public')} ORDER BY 1',
      ]);
      return [for (final r in rows) seq(rowText(r, 'name')!, r)];
    case DbFamily.sqlServer:
      final db = catalog == null ? '' : '${d.quoteIdent(catalog)}.';
      final rows = await q.first([
        'SELECT s.name, TYPE_NAME(s.user_type_id) AS type, CAST(s.start_value AS bigint) AS start, '
            'CAST(s.increment AS bigint) AS inc, CAST(s.minimum_value AS bigint) AS min, CAST(s.maximum_value AS bigint) AS max, '
            's.is_cycling AS cycle, CASE WHEN s.is_cached = 0 THEN 1 ELSE s.cache_size END AS cache, '
            'CAST(s.current_value AS bigint) AS cur_value '
            'FROM ${db}sys.sequences s JOIN ${db}sys.schemas sc ON sc.schema_id = s.schema_id '
            'WHERE sc.name = ${lit(schema ?? 'dbo')} ORDER BY s.name',
      ]);
      return [for (final r in rows) seq(rowText(r, 'name')!, r)];
    case DbFamily.mysql:
      final db = catalog ?? schema;
      final names = await q.first([
        "SELECT TABLE_NAME AS name FROM information_schema.TABLES WHERE TABLE_TYPE = 'SEQUENCE' AND "
            'TABLE_SCHEMA = ${db == null ? 'DATABASE()' : lit(db)} ORDER BY 1',
      ]);
      final out = <SequenceDef>[];
      for (final n in names) {
        final name = rowText(n, 'name')!;
        final rows = await q.first([
          'SELECT start_value AS start, increment AS inc, minimum_value AS min, maximum_value AS max, '
              'cycle_option AS cycle, cache_size AS cache, next_not_cached_value AS cur_value '
              'FROM ${d.qualified(db, null, name)}',
        ]);
        out.add(rows.isEmpty ? SequenceDef(catalog: catalog, schema: schema, name: name) : seq(name, rows.first));
      }
      return out;
    case DbFamily.oracle:
      final owner = schema == null ? 'USER' : lit(schema);
      final rows = await q.first([
        'SELECT sequence_name AS name, min_value AS min, max_value AS max, increment_by AS inc, '
            "CASE cycle_flag WHEN 'Y' THEN 1 ELSE 0 END AS cycle, cache_size AS cache, last_number AS cur_value "
            'FROM all_sequences WHERE sequence_owner = $owner ORDER BY 1',
      ]);
      return [
        for (final r in rows)
          // ~10^27: the default "no maximum".
          seq(
            rowText(r, 'name')!,
            r,
          ).copyWith(maxValue: (rowText(r, 'max')?.length ?? 0) > 18 ? null : rowInt(r, 'max')),
      ];
    case DbFamily.db2:
      final rows = await q.first([
        "SELECT seqname AS name, start, increment AS inc, minvalue AS min, maxvalue AS max, "
            "CASE cycle WHEN 'Y' THEN 1 ELSE 0 END AS cycle, cache, lastassignedval AS cur_value "
            "FROM syscat.sequences WHERE seqtype = 'S' AND seqschema = ${schema == null ? 'CURRENT SCHEMA' : lit(schema)} ORDER BY 1",
      ]);
      return [for (final r in rows) seq(rowText(r, 'name')!, r)];
    case DbFamily.firebird:
      final rows = await q.first([
        r'SELECT RDB$GENERATOR_NAME AS name, RDB$INITIAL_VALUE AS start, RDB$GENERATOR_INCREMENT AS inc '
            r'FROM RDB$GENERATORS WHERE COALESCE(RDB$SYSTEM_FLAG, 0) = 0 ORDER BY 1',
        r'SELECT RDB$GENERATOR_NAME AS name FROM RDB$GENERATORS WHERE COALESCE(RDB$SYSTEM_FLAG, 0) = 0 ORDER BY 1',
      ]);
      return [for (final r in rows) seq(rowText(r, 'name')!, r)];
    case DbFamily.snowflake:
      final where = [if (catalog != null) d.quoteIdent(catalog), if (schema != null) d.quoteIdent(schema)].join('.');
      final rows = await q.first([where.isEmpty ? 'SHOW SEQUENCES' : 'SHOW SEQUENCES IN SCHEMA $where']);
      return [
        for (final r in rows)
          SequenceDef(
            catalog: catalog,
            schema: schema,
            name: rowText(r, 'name')!,
            increment: rowInt(r, 'interval'),
            currentValue: rowInt(r, 'next_value'),
            comment: rowText(r, 'comment'),
          ),
      ];
    default:
      return const [];
  }
}

// ---------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------

/// Timing, events and level from the text of a CREATE TRIGGER.
({TriggerTiming timing, Set<TriggerEvent> events, bool row}) parseTriggerHeader(String def) {
  final head = def.length > 600 ? def.substring(0, 600) : def;
  final timing = RegExp(r'\bINSTEAD\s+OF\b', caseSensitive: false).hasMatch(head)
      ? TriggerTiming.insteadOf
      : RegExp(r'\bBEFORE\b', caseSensitive: false).hasMatch(head)
      ? TriggerTiming.before
      : TriggerTiming.after;
  // Events between the timing keyword and ON / AS / FOR.
  final m = RegExp(
    r'\b(BEFORE|AFTER|INSTEAD\s+OF|FOR)\s+((?:INSERT|UPDATE|DELETE|TRUNCATE)(?:\s+OF\s+[^\n]*?)?(?:\s*(?:,|\bOR\b)\s*(?:INSERT|UPDATE|DELETE|TRUNCATE)(?:\s+OF\s+[^\n]*?)?)*)\s',
    caseSensitive: false,
  ).firstMatch(head);
  final ev = (m?.group(2) ?? '').toUpperCase();
  final events = {
    if (ev.contains('INSERT')) TriggerEvent.insert,
    if (ev.contains('UPDATE')) TriggerEvent.update,
    if (ev.contains('DELETE')) TriggerEvent.delete,
  };
  final statement = RegExp(r'FOR\s+EACH\s+STATEMENT', caseSensitive: false).hasMatch(head);
  final row =
      !statement &&
      (RegExp(r'FOR\s+EACH\s+ROW', caseSensitive: false).hasMatch(head) || !head.toUpperCase().contains(' ON '));
  return (timing: timing, events: events.isEmpty ? {TriggerEvent.insert} : events, row: row);
}

Future<List<TriggerDef>> readTriggers(CatalogQueries q, SqlDialect d, DbTable t) async {
  TriggerDef fromText(String name, String def, {bool enabled = true, String? function, bool? row}) {
    final h = parseTriggerHeader(def);
    return TriggerDef(
      catalog: t.catalog,
      schema: t.schema,
      table: t.name,
      name: name,
      timing: h.timing,
      events: h.events,
      forEachRow: row ?? h.row,
      enabled: enabled,
      source: def.trim(),
      function: function,
    );
  }

  final name = lit(t.name);
  switch (d.family) {
    case DbFamily.postgres:
      final rows = await q.first([
        'SELECT t.tgname, pg_get_triggerdef(t.oid, true) AS def, t.tgenabled, p.oid::regprocedure::text AS fn, '
            'pg_get_functiondef(p.oid) AS fdef '
            'FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_class c ON c.oid = t.tgrelid '
            'JOIN pg_namespace n ON n.oid = c.relnamespace '
            'WHERE NOT t.tgisinternal AND n.nspname = ${lit(t.schema ?? 'public')} AND c.relname = $name ORDER BY 1',
      ]);
      return [
        for (final r in rows)
          fromText(
            rowText(r, 'tgname')!,
            rowText(r, 'def') ?? '',
            enabled: rowText(r, 'tgenabled') != 'D',
            function: rowText(r, 'fn'),
          ).copyWith(source: '${(rowText(r, 'fdef') ?? '').trim()};\n\n${(rowText(r, 'def') ?? '').trim()};'),
      ];
    case DbFamily.sqlServer:
      final db = t.catalog == null ? '' : '${d.quoteIdent(t.catalog!)}.';
      final obj =
          'OBJECT_ID(N${lit([if (t.catalog != null) t.catalog!, t.schema ?? 'dbo', t.name].map((e) => '[${e.replaceAll(']', ']]')}]').join('.'))})';
      final rows = await q.first([
        'SELECT tr.name, m.definition, tr.is_disabled FROM ${db}sys.triggers tr '
            'JOIN ${db}sys.sql_modules m ON m.object_id = tr.object_id WHERE tr.parent_id = $obj ORDER BY tr.name',
      ]);
      return [
        for (final r in rows)
          fromText(
            rowText(r, 'name')!,
            rowText(r, 'definition') ?? '',
            enabled: !rowBool(r, 'is_disabled'),
            row: false,
          ),
      ];
    case DbFamily.mysql:
      final db = t.catalog ?? t.schema;
      final rows = await q.first([
        'SELECT TRIGGER_NAME, EVENT_MANIPULATION, ACTION_TIMING, ACTION_STATEMENT, ACTION_ORIENTATION '
            'FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA = ${db == null ? 'DATABASE()' : lit(db)} '
            'AND EVENT_OBJECT_TABLE = $name ORDER BY ACTION_ORDER',
      ]);
      return [
        for (final r in rows)
          fromText(
            rowText(r, 'trigger_name')!,
            'CREATE TRIGGER ${d.quoteIdent(rowText(r, 'trigger_name')!)} ${rowText(r, 'action_timing')} '
            '${rowText(r, 'event_manipulation')} ON ${d.qualified(db, null, t.name)}\n'
            'FOR EACH ${rowText(r, 'action_orientation') ?? 'ROW'}\n${rowText(r, 'action_statement') ?? ''}',
          ),
      ];
    case DbFamily.oracle:
      final owner = t.schema == null ? 'USER' : lit(t.schema!);
      final rows = await q.first([
        'SELECT trigger_name, trigger_type, status, description, when_clause, trigger_body FROM all_triggers '
            'WHERE table_owner = $owner AND table_name = $name ORDER BY 1',
      ]);
      return [
        for (final r in rows)
          fromText(
            rowText(r, 'trigger_name')!,
            'CREATE OR REPLACE TRIGGER ${(rowText(r, 'description') ?? '').trim()}'
            '${rowText(r, 'when_clause') == null ? '' : '\nWHEN (${rowText(r, 'when_clause')})'}\n'
            '${(rowText(r, 'trigger_body') ?? '').trim()}',
            enabled: rowText(r, 'status') == 'ENABLED',
            row: (rowText(r, 'trigger_type') ?? '').contains('EACH ROW'),
          ),
      ];
    case DbFamily.db2:
      final rows = await q.first([
        'SELECT trigname, text, granularity FROM syscat.triggers WHERE tabschema = '
            '${t.schema == null ? 'CURRENT SCHEMA' : lit(t.schema!)} AND tabname = $name ORDER BY 1',
      ]);
      return [
        for (final r in rows)
          fromText(rowText(r, 'trigname')!, rowText(r, 'text') ?? '', row: rowText(r, 'granularity') == 'R'),
      ];
    case DbFamily.sqlite:
      final schema = t.schema == null || t.schema == 'main' ? '' : '"${t.schema}".';
      final rows = await q.first([
        "SELECT name, sql FROM ${schema}sqlite_master WHERE type = 'trigger' AND tbl_name = $name ORDER BY 1",
      ]);
      return [for (final r in rows) fromText(rowText(r, 'name')!, rowText(r, 'sql') ?? '', row: true)];
    case DbFamily.firebird:
      final rows = await q.first([
        'SELECT RDB\$TRIGGER_NAME AS name, RDB\$TRIGGER_TYPE AS kind, RDB\$TRIGGER_SOURCE AS source, '
            'RDB\$TRIGGER_INACTIVE AS inactive FROM RDB\$TRIGGERS WHERE COALESCE(RDB\$SYSTEM_FLAG, 0) = 0 '
            'AND RDB\$RELATION_NAME = $name ORDER BY 1',
      ]);
      return [
        for (final r in rows)
          () {
            final n = rowText(r, 'name')!;
            final kind = rowInt(r, 'kind') ?? 1;
            // 1..6: before/after insert, update, delete (multi-event codes kept as insert).
            final timing = kind.isOdd ? 'BEFORE' : 'AFTER';
            final event = switch (kind) {
              1 || 2 => 'INSERT',
              3 || 4 => 'UPDATE',
              5 || 6 => 'DELETE',
              _ => 'INSERT OR UPDATE OR DELETE',
            };
            final inactive = rowInt(r, 'inactive') == 1;
            var body = (rowText(r, 'source') ?? '').trim();
            if (!body.toUpperCase().startsWith('AS')) body = 'AS\n$body';
            return fromText(
              n,
              'CREATE OR ALTER TRIGGER ${d.quoteIdent(n)} FOR ${d.quoteIdent(t.name)}\n'
              '${inactive ? 'INACTIVE' : 'ACTIVE'} $timing $event POSITION 0\n$body',
              enabled: !inactive,
              row: true,
            );
          }(),
      ];
    default:
      return const [];
  }
}

// ---------------------------------------------------------------------------
// Procedures and functions
// ---------------------------------------------------------------------------

/// Source of a routine as read from the catalog, ready to be edited.
class RoutineSource {
  const RoutineSource(this.source, this.kind, {this.arguments});
  final String source;
  final RoutineKind kind;

  /// PostgreSQL identity arguments (DROP FUNCTION needs them).
  final String? arguments;
}

/// Source of [p] (null when the catalog does not expose it). For PostgreSQL
/// overloads, the first one; [params] help rebuilding the Firebird header.
Future<RoutineSource?> readRoutineSource(
  CatalogQueries q,
  SqlDialect d,
  DbProcedure p, {
  List<DbProcedureParam> params = const [],
}) async {
  final name = lit(p.cleanName);
  final kind = p.type == 2 ? RoutineKind.function : RoutineKind.procedure;
  switch (d.family) {
    case DbFamily.postgres:
      final rows = await q.first([
        'SELECT pg_get_functiondef(p.oid) AS def, pg_get_function_identity_arguments(p.oid) AS args, p.prokind '
            'FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace '
            'WHERE n.nspname = ${lit(p.schema ?? 'public')} AND p.proname = $name ORDER BY p.oid',
        'SELECT pg_get_functiondef(p.oid) AS def, pg_get_function_identity_arguments(p.oid) AS args '
            'FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace '
            'WHERE n.nspname = ${lit(p.schema ?? 'public')} AND p.proname = $name ORDER BY p.oid',
      ]);
      if (rows.isEmpty) return null;
      final r = rows.first;
      return RoutineSource(
        rowText(r, 'def') ?? '',
        rowText(r, 'prokind') == 'p' ? RoutineKind.procedure : RoutineKind.function,
        arguments: rowText(r, 'args') ?? '',
      );
    case DbFamily.sqlServer:
      final db = p.catalog == null ? '' : '${d.quoteIdent(p.catalog!)}.';
      final obj =
          'OBJECT_ID(N${lit([if (p.catalog != null) p.catalog!, p.schema ?? 'dbo', p.cleanName].map((e) => '[${e.replaceAll(']', ']]')}]').join('.'))})';
      final rows = await q.first([
        'SELECT m.definition, o.type FROM ${db}sys.sql_modules m JOIN ${db}sys.objects o ON o.object_id = m.object_id '
            'WHERE m.object_id = $obj',
      ]);
      if (rows.isEmpty) return null;
      final type = rowText(rows.first, 'type') ?? 'P';
      return RoutineSource(
        rowText(rows.first, 'definition') ?? '',
        type.startsWith('P') ? RoutineKind.procedure : RoutineKind.function,
      );
    case DbFamily.mysql:
      final ref = d.qualified(p.catalog ?? p.schema, null, p.cleanName);
      for (final k
          in kind == RoutineKind.function
              ? [RoutineKind.function, RoutineKind.procedure]
              : [RoutineKind.procedure, RoutineKind.function]) {
        try {
          final rows = await q.rows('SHOW CREATE ${k.sql} $ref');
          if (rows.isEmpty) continue;
          final def = rowText(rows.first, 'create ${k.sql.toLowerCase()}');
          if (def != null) return RoutineSource(def, k);
        } catch (_) {
          // Not a routine of this kind.
        }
      }
      return null;
    case DbFamily.oracle:
      final owner = p.schema == null ? 'USER' : lit(p.schema!);
      final rows = await q.first([
        'SELECT DBMS_METADATA.GET_DDL(object_type, object_name, owner) AS def, object_type FROM all_objects '
            "WHERE owner = $owner AND object_name = $name AND object_type IN ('PROCEDURE', 'FUNCTION')",
      ]);
      if (rows.isNotEmpty) {
        final k = rowText(rows.first, 'object_type') == 'FUNCTION' ? RoutineKind.function : RoutineKind.procedure;
        return RoutineSource((rowText(rows.first, 'def') ?? '').trim(), k);
      }
      final lines = await q.first([
        "SELECT type, text FROM all_source WHERE owner = $owner AND name = $name AND type IN ('PROCEDURE', 'FUNCTION') ORDER BY line",
      ]);
      if (lines.isEmpty) return null;
      final k = rowText(lines.first, 'type') == 'FUNCTION' ? RoutineKind.function : RoutineKind.procedure;
      return RoutineSource('CREATE OR REPLACE ${lines.map((r) => r['text'] ?? '').join()}'.trim(), k);
    case DbFamily.db2:
      final rows = await q.first([
        'SELECT text, routinetype FROM syscat.routines WHERE routineschema = '
            '${p.schema == null ? 'CURRENT SCHEMA' : lit(p.schema!)} AND routinename = $name',
      ]);
      if (rows.isEmpty || rowText(rows.first, 'text') == null) return null;
      return RoutineSource(
        rowText(rows.first, 'text')!,
        rowText(rows.first, 'routinetype') == 'F' ? RoutineKind.function : RoutineKind.procedure,
      );
    case DbFamily.firebird:
      final proc = await q.first([
        'SELECT RDB\$PROCEDURE_SOURCE AS src FROM RDB\$PROCEDURES WHERE RDB\$PROCEDURE_NAME = $name',
      ]);
      final isFn = proc.isEmpty;
      final rows = isFn
          ? await q.first(['SELECT RDB\$FUNCTION_SOURCE AS src FROM RDB\$FUNCTIONS WHERE RDB\$FUNCTION_NAME = $name'])
          : proc;
      if (rows.isEmpty) return null;
      var body = (rowText(rows.first, 'src') ?? '').trim();
      if (!body.toUpperCase().startsWith('AS')) body = 'AS\n$body';
      String arg(DbProcedureParam x) => '${d.quoteIdent(x.name)} ${x.typeName}';
      final ins = params.where((x) => x.columnType == 1 || x.columnType == 2).map(arg).join(', ');
      final outs = params.where((x) => x.columnType == 3 || x.columnType == 4 || x.columnType == 5).map(arg).join(', ');
      final k = isFn ? RoutineKind.function : RoutineKind.procedure;
      return RoutineSource(
        'CREATE OR ALTER ${k.sql} ${d.quoteIdent(p.cleanName)}${ins.isEmpty ? '' : '($ins)'}'
        '${outs.isEmpty ? '' : '\nRETURNS ($outs)'}\n$body',
        k,
      );
    default:
      return null;
  }
}
