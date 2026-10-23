// DDL of the objects made of code: triggers, procedures, functions. They
// are edited as source text; this file turns a source into the statements
// that (re)create the object, writes templates for new ones and the drops.

import '../../../services/sql_dialect.dart';
import '../../../services/sql_splitter.dart';
import '../capabilities.dart';
import '../model/object_defs.dart';

class CodeDdl {
  CodeDdl(this.dialect) : caps = DesignCapabilities.of(dialect);

  final SqlDialect dialect;
  final DesignCapabilities caps;

  DbFamily get family => dialect.family;
  String q(String n) => dialect.quoteIdent(n);

  /// Name of an object of [schema] in its DDL (SQL Server: no database
  /// prefix, the script runs in the database).
  String ref(String? catalog, String? schema, String name) =>
      dialect.qualified(family == DbFamily.sqlServer || family == DbFamily.postgres ? null : catalog, schema, name);

  static final _create = RegExp(
    r'^\s*CREATE\s+(OR\s+(REPLACE|ALTER)\s+)?((NO)?EDITIONABLE\s+)?(DEFINER\s*=\s*\S+\s+)?',
    caseSensitive: false,
  );

  /// The header of [source] rewritten to replace an existing object where
  /// the DBMS can (CREATE OR REPLACE / OR ALTER); [replace] false leaves it.
  String withReplace(String source, String kind, {bool replace = true}) {
    final m = _create.firstMatch(source);
    if (m == null) return source;
    final rest = source.substring(m.end);
    final definer = m.group(5) ?? '';
    final head = switch (family) {
      DbFamily.sqlServer => replace ? 'CREATE OR ALTER ' : 'CREATE ',
      DbFamily.oracle => replace ? 'CREATE OR REPLACE ' : 'CREATE ',
      DbFamily.firebird => replace ? 'CREATE OR ALTER ' : 'CREATE ',
      DbFamily.db2 || DbFamily.snowflake => replace ? 'CREATE OR REPLACE ' : 'CREATE ',
      DbFamily.postgres =>
        // Triggers have OR REPLACE since PostgreSQL 14, functions always.
        replace && (kind != 'TRIGGER' || (dialect.version?.atLeast(14) ?? true)) ? 'CREATE OR REPLACE ' : 'CREATE ',
      DbFamily.mysql => replace && dialect.isMariaDb ? 'CREATE OR REPLACE $definer' : 'CREATE $definer',
      _ => 'CREATE ',
    };
    return '$head$rest';
  }

  /// [source] as statements: PostgreSQL sources may hold the trigger
  /// function and the trigger; elsewhere the source is one statement (its
  /// body has semicolons of its own). Oracle PL/SQL keeps the final ';'.
  List<String> statementsOf(String source) {
    var s = source.trim();
    if (s.isEmpty) return const [];
    if (family == DbFamily.postgres) return [for (final st in SqlSplitter().split(s)) st.text];
    if (family == DbFamily.oracle) {
      // A trailing "/" line ends a block in SQL*Plus scripts.
      s = s.replaceFirst(RegExp(r'\n\s*/\s*$'), '').trimRight();
      if (RegExp(r'\bEND(\s+\w+)?$', caseSensitive: false).hasMatch(s)) s = '$s;';
      return [s];
    }
    // The SQLite ODBC driver cuts a trigger at a "--" comment of its body.
    if (family == DbFamily.sqlite) s = blockComments(s);
    // The final delimiter is not part of the statement (only PL/SQL wants it).
    return [s.replaceFirst(RegExp(r';\s*$'), '')];
  }

  /// Whether the DBMS replaces this kind of object in place.
  bool replacesInPlace(String kind) => switch (family) {
    DbFamily.sqlServer || DbFamily.oracle || DbFamily.firebird || DbFamily.db2 || DbFamily.snowflake => true,
    DbFamily.postgres => kind != 'TRIGGER' || (dialect.version?.atLeast(14) ?? true),
    DbFamily.mysql => dialect.isMariaDb,
    _ => false,
  };

  // -------------------------------------------------------------------------
  // Triggers
  // -------------------------------------------------------------------------

  /// Source of a new trigger with the given header, to be completed.
  String triggerTemplate(TriggerDef t) {
    final table = dialect.qualified(family == DbFamily.sqlServer ? null : t.catalog, t.schema, t.table);
    final events = t.events.map((e) => e.sql).join(' OR ');
    final row = t.forEachRow ? 'FOR EACH ROW' : 'FOR EACH STATEMENT';
    final name = q(t.name);
    switch (family) {
      case DbFamily.postgres:
        final fn = dialect.qualified(null, t.schema, '${t.name}_fn');
        final ret = t.forEachRow && t.timing != TriggerTiming.after
            ? (t.events.contains(TriggerEvent.delete) ? 'OLD' : 'NEW')
            : 'NULL';
        return 'CREATE OR REPLACE FUNCTION $fn() RETURNS trigger LANGUAGE plpgsql AS \$\$\n'
            'BEGIN\n  -- NEW e OLD contengono la riga\n  RETURN $ret;\nEND;\n\$\$;\n\n'
            'CREATE TRIGGER $name ${t.timing.sql} $events ON $table\n$row EXECUTE FUNCTION $fn();';
      case DbFamily.sqlServer:
        final timing = t.timing == TriggerTiming.before ? 'AFTER' : t.timing.sql;
        return 'CREATE TRIGGER ${dialect.qualified(null, t.schema, t.name)} ON $table\n$timing '
            '${t.events.map((e) => e.sql).join(', ')}\nAS\nBEGIN\n  SET NOCOUNT ON;\n  -- inserted e deleted contengono le righe\nEND';
      case DbFamily.mysql:
        return 'CREATE TRIGGER $name ${t.timing == TriggerTiming.insteadOf ? 'BEFORE' : t.timing.sql} '
            '${t.events.first.sql} ON $table\nFOR EACH ROW\nBEGIN\n  -- NEW e OLD contengono la riga\nEND';
      case DbFamily.oracle:
        return 'CREATE OR REPLACE TRIGGER ${dialect.qualified(null, t.schema, t.name)}\n${t.timing.sql} $events ON $table\n'
            '${t.forEachRow ? 'FOR EACH ROW\n' : ''}BEGIN\n  NULL; -- :NEW e :OLD contengono la riga\nEND;';
      case DbFamily.db2:
        return 'CREATE TRIGGER ${dialect.qualified(null, t.schema, t.name)}\n${t.timing.sql} $events ON $table\n'
            'REFERENCING NEW AS n OLD AS o\n$row\nBEGIN ATOMIC\n  -- n e o contengono la riga\nEND';
      case DbFamily.sqlite:
        return 'CREATE TRIGGER $name ${t.timing.sql} ${t.events.first.sql} ON $table\nFOR EACH ROW\nBEGIN\n'
            '  SELECT 1; -- NEW e OLD contengono la riga\nEND';
      case DbFamily.firebird:
        return 'CREATE TRIGGER $name FOR $table\nACTIVE ${t.timing == TriggerTiming.insteadOf ? 'BEFORE' : t.timing.sql} $events\n'
            'AS\nBEGIN\n  /* NEW e OLD contengono la riga */\nEND';
      default:
        return 'CREATE TRIGGER $name ${t.timing.sql} $events ON $table\n$row\nBEGIN\nEND';
    }
  }

  /// Statements that (re)create the trigger from [source]: the old one
  /// ([original], when it exists) is dropped first where the DBMS cannot
  /// replace it or when the name changed.
  List<String> saveTrigger(TriggerDef? original, String name, String source) {
    if (!caps.has(DesignFeature.triggers)) {
      return ['-- Trigger: ${caps.reason(DesignFeature.triggers)} (non supportato)'];
    }
    final renamed = original != null && original.name.toLowerCase() != name.toLowerCase();
    final inPlace = replacesInPlace('TRIGGER') && !renamed;
    return [
      if (original != null && !inPlace) ...dropTrigger(original),
      ...statementsOf(original != null && inPlace ? withReplace(source, 'TRIGGER') : source),
    ];
  }

  List<String> dropTrigger(TriggerDef t) {
    final table = dialect.qualified(family == DbFamily.sqlServer ? null : t.catalog, t.schema, t.table);
    return switch (family) {
      DbFamily.postgres => ['DROP TRIGGER ${q(t.name)} ON $table'],
      DbFamily.sqlite || DbFamily.firebird => ['DROP TRIGGER ${q(t.name)}'],
      DbFamily.mysql => ['DROP TRIGGER ${dialect.qualified(t.catalog, null, t.name)}'],
      _ => ['DROP TRIGGER ${dialect.qualified(null, t.schema, t.name)}'],
    };
  }

  /// Disables or enables [t] where the DBMS can.
  List<String> setTriggerEnabled(TriggerDef t, bool enabled) {
    final table = dialect.qualified(family == DbFamily.sqlServer ? null : t.catalog, t.schema, t.table);
    final name = family == DbFamily.postgres || family == DbFamily.firebird
        ? q(t.name)
        : dialect.qualified(null, t.schema, t.name);
    return switch (family) {
      DbFamily.postgres => ['ALTER TABLE $table ${enabled ? 'ENABLE' : 'DISABLE'} TRIGGER $name'],
      DbFamily.sqlServer => ['${enabled ? 'ENABLE' : 'DISABLE'} TRIGGER $name ON $table'],
      DbFamily.oracle => ['ALTER TRIGGER $name ${enabled ? 'ENABLE' : 'DISABLE'}'],
      DbFamily.firebird => ['ALTER TRIGGER $name ${enabled ? 'ACTIVE' : 'INACTIVE'}'],
      _ => ['-- ${dialect.dbmsName} non disabilita i trigger: eliminalo e crealo di nuovo (non supportato)'],
    };
  }

  bool get canDisableTriggers => switch (family) {
    DbFamily.postgres || DbFamily.sqlServer || DbFamily.oracle || DbFamily.firebird => true,
    _ => false,
  };

  // -------------------------------------------------------------------------
  // Procedures and functions
  // -------------------------------------------------------------------------

  /// Source of a new procedure or function named [name].
  String routineTemplate(RoutineKind kind, String? catalog, String? schema, String name) {
    final n = ref(catalog, schema, name);
    final fn = kind == RoutineKind.function;
    switch (family) {
      case DbFamily.postgres:
        return fn
            ? 'CREATE OR REPLACE FUNCTION $n(p_id integer)\nRETURNS integer\nLANGUAGE plpgsql\nAS \$\$\nBEGIN\n  RETURN p_id;\nEND;\n\$\$'
            : 'CREATE OR REPLACE PROCEDURE $n(p_id integer)\nLANGUAGE plpgsql\nAS \$\$\nBEGIN\n  -- istruzioni\nEND;\n\$\$';
      case DbFamily.sqlServer:
        return fn
            ? 'CREATE FUNCTION $n (@id int)\nRETURNS int\nAS\nBEGIN\n  RETURN @id;\nEND'
            : 'CREATE PROCEDURE $n\n  @id int\nAS\nBEGIN\n  SET NOCOUNT ON;\n  SELECT @id AS id;\nEND';
      case DbFamily.mysql:
        return fn
            ? 'CREATE FUNCTION $n(p_id INT)\nRETURNS INT\nDETERMINISTIC\nBEGIN\n  RETURN p_id;\nEND'
            : 'CREATE PROCEDURE $n(IN p_id INT)\nBEGIN\n  SELECT p_id;\nEND';
      case DbFamily.oracle:
        return fn
            ? 'CREATE OR REPLACE FUNCTION $n(p_id IN NUMBER)\nRETURN NUMBER\nIS\nBEGIN\n  RETURN p_id;\nEND;'
            : 'CREATE OR REPLACE PROCEDURE $n(p_id IN NUMBER)\nIS\nBEGIN\n  NULL;\nEND;';
      case DbFamily.db2:
        return fn
            ? 'CREATE OR REPLACE FUNCTION $n(p_id INTEGER)\nRETURNS INTEGER\nLANGUAGE SQL\nBEGIN ATOMIC\n  RETURN p_id;\nEND'
            : 'CREATE OR REPLACE PROCEDURE $n(IN p_id INTEGER)\nLANGUAGE SQL\nBEGIN\n  -- istruzioni\nEND';
      case DbFamily.firebird:
        return fn
            ? 'CREATE OR ALTER FUNCTION $n(p_id INTEGER)\nRETURNS INTEGER\nAS\nBEGIN\n  RETURN p_id;\nEND'
            : 'CREATE OR ALTER PROCEDURE $n(p_id INTEGER)\nRETURNS (r_id INTEGER)\nAS\nBEGIN\n  r_id = p_id;\n  SUSPEND;\nEND';
      case DbFamily.snowflake:
        return fn
            ? 'CREATE OR REPLACE FUNCTION $n(p_id NUMBER)\nRETURNS NUMBER\nAS\n\'p_id\''
            : 'CREATE OR REPLACE PROCEDURE $n(p_id NUMBER)\nRETURNS VARCHAR\nLANGUAGE SQL\nAS\n\$\$\nBEGIN\n  RETURN \'ok\';\nEND;\n\$\$';
      default:
        return 'CREATE ${kind.sql} $n()\nBEGIN\nEND';
    }
  }

  /// Statements that (re)create a routine from [source]. [existing] is the
  /// routine in the database (dropped first where the DBMS cannot replace
  /// it in place: MySQL).
  List<String> saveRoutine(
    String source,
    RoutineKind kind, {
    ({String? catalog, String? schema, String name})? existing,
  }) {
    if (!caps.has(DesignFeature.routines)) {
      return ['-- Procedure: ${caps.reason(DesignFeature.routines)} (non supportato)'];
    }
    final inPlace = replacesInPlace(kind.sql);
    return [
      if (existing != null && !inPlace)
        ...dropRoutine(kind, existing.catalog, existing.schema, existing.name, ifExists: true),
      ...statementsOf(existing != null && inPlace ? withReplace(source, kind.sql) : source),
    ];
  }

  /// DROP PROCEDURE / FUNCTION; PostgreSQL needs [arguments] (the identity
  /// arguments) to pick an overload.
  List<String> dropRoutine(
    RoutineKind kind,
    String? catalog,
    String? schema,
    String name, {
    String? arguments,
    bool ifExists = false,
  }) {
    final n = family == DbFamily.mysql ? dialect.qualified(catalog, null, name) : ref(catalog, schema, name);
    final exists = ifExists && family != DbFamily.oracle && family != DbFamily.db2 ? 'IF EXISTS ' : '';
    final args = family == DbFamily.postgres || family == DbFamily.snowflake ? '(${arguments ?? ''})' : '';
    return ['DROP ${kind.sql} $exists$n$args'];
  }
}

/// [sql] with its "-- …" line comments turned into "/* … */" (strings and
/// quoted names left alone).
String blockComments(String sql) {
  final sb = StringBuffer();
  String? quote;
  for (var i = 0; i < sql.length; i++) {
    final ch = sql[i];
    if (quote != null) {
      sb.write(ch);
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == "'" || ch == '"' || ch == '`') {
      quote = ch;
      sb.write(ch);
      continue;
    }
    if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      final end = sql.indexOf('\n', i);
      final text = sql.substring(i + 2, end < 0 ? sql.length : end).replaceAll('*/', '* /').trim();
      sb.write('/* $text */');
      i = (end < 0 ? sql.length : end) - 1;
      continue;
    }
    sb.write(ch);
  }
  return sb.toString();
}
