import 'dart:typed_data';

import '../model/db_objects.dart';
import 'sql_keywords.dart';

enum DbFamily {
  sqlServer,
  postgres,
  mysql,
  oracle,
  db2,
  sqlite,
  firebird,
  snowflake,
  bigquery,
  cassandra,
  mongodb,
  redis,
  generic,
}

/// Small SQL dialect abstraction derived from the SQLGetInfo values.
class SqlDialect {
  SqlDialect({
    required this.dbmsName,
    this.quote = '"',
    this.catalogSeparator = '.',
    this.extraKeywords = const {},
  }) : family = _detect(dbmsName);

  final String dbmsName;
  final DbFamily family;

  /// Identifier quote character (empty when quoting is not supported).
  final String quote;
  final String catalogSeparator;
  final Set<String> extraKeywords;

  factory SqlDialect.fromInfo(Map<String, Object?> info) {
    var q = (info['identifierQuote'] as String?) ?? '"';
    if (q.trim().isEmpty) q = '';
    final sep = (info['catalogSeparator'] as String?) ?? '.';
    final kw = ((info['keywords'] as String?) ?? '')
        .split(',')
        .map((e) => e.trim().toUpperCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    return SqlDialect(
      dbmsName: (info['dbmsName'] as String?) ?? '',
      quote: q,
      catalogSeparator: sep.isEmpty ? '.' : sep,
      extraKeywords: kw,
    );
  }

  static DbFamily _detect(String n) {
    final s = n.toLowerCase();
    if (s.contains('sql server') || s.contains('sybase') || s.contains('adaptive')) {
      return DbFamily.sqlServer;
    }
    if (s.contains('postgres') || s.contains('redshift') || s.contains('greenplum')) {
      return DbFamily.postgres;
    }
    if (s.contains('mysql') || s.contains('maria')) return DbFamily.mysql;
    if (s.contains('oracle')) return DbFamily.oracle;
    if (s.contains('db2')) return DbFamily.db2;
    if (s.contains('sqlite')) return DbFamily.sqlite;
    if (s.contains('firebird') || s.contains('interbase')) return DbFamily.firebird;
    if (s.contains('snowflake')) return DbFamily.snowflake;
    if (s.contains('bigquery')) return DbFamily.bigquery;
    if (s.contains('cassandra') || s.contains('scylla')) return DbFamily.cassandra;
    if (s.contains('mongo') || s.contains('documentdb') || s.contains('cosmos')) return DbFamily.mongodb;
    if (s.contains('redis') || s.contains('valkey')) return DbFamily.redis;
    return DbFamily.generic;
  }

  /// False for document / key-value stores whose query language is not SQL
  /// (MongoDB shell commands, Redis commands): SQL generators, the query
  /// builder and schema tools are hidden for them.
  bool get isSql => family != DbFamily.mongodb && family != DbFamily.redis;

  /// NoSQL engine (no foreign keys, no transactions).
  bool get isNoSql => !isSql || family == DbFamily.cassandra;

  bool get _upperCaseIdentifiers =>
      family == DbFamily.oracle ||
      family == DbFamily.db2 ||
      family == DbFamily.firebird ||
      family == DbFamily.snowflake;

  bool get _lowerCaseIdentifiers => family == DbFamily.postgres;

  static final _plain = RegExp(r'^[A-Za-z_][A-Za-z0-9_$#@]*$');

  /// Quotes [name] only when necessary.
  String quoteIdent(String name) {
    if (quote.isEmpty) return name;
    var needs = !_plain.hasMatch(name) || isSqlKeyword(name) || extraKeywords.contains(name.toUpperCase());
    if (!needs && _lowerCaseIdentifiers && name != name.toLowerCase()) needs = true;
    if (!needs && _upperCaseIdentifiers && name != name.toUpperCase()) needs = true;
    if (!needs) return name;
    final close = quote == '[' ? ']' : quote;
    return '$quote${name.replaceAll(close, '$close$close')}$close';
  }

  String qualified(String? catalog, String? schema, String name) {
    final hasCatalog = catalog != null && catalog.isNotEmpty;
    final hasSchema = schema != null && schema.isNotEmpty;
    // SQL Server allows catalog..table when the schema is missing.
    if (hasCatalog && !hasSchema && family == DbFamily.sqlServer) {
      return '${quoteIdent(catalog)}..${quoteIdent(name)}';
    }
    final path = [if (hasSchema) quoteIdent(schema), quoteIdent(name)].join('.');
    if (!hasCatalog) return path;
    // Catalogs placed at the end use a different separator (e.g. Informix '@').
    return catalogSeparator == '.'
        ? '${quoteIdent(catalog)}.$path'
        : '$path$catalogSeparator${quoteIdent(catalog)}';
  }

  String tableName(DbTable t) => qualified(t.catalog, t.schema, t.name);

  String stringLiteral(String s) => "'${s.replaceAll("'", "''")}'";

  String literal(Object? v) {
    if (v == null) return 'NULL';
    if (v is num) return v.toString();
    if (v is bool) return v ? '1' : '0';
    if (v is Uint8List) {
      final hex = v.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return switch (family) {
        DbFamily.sqlServer => '0x$hex',
        DbFamily.postgres => "'\\x$hex'::bytea",
        DbFamily.oracle => "HEXTORAW('$hex')",
        _ => "X'$hex'",
      };
    }
    final s = v.toString();
    return family == DbFamily.sqlServer && s.runes.any((r) => r > 127)
        ? 'N${stringLiteral(s)}'
        : stringLiteral(s);
  }

  /// Replaces the positional `?` markers of [sql] with the literals of
  /// [params] (markers inside quoted strings or identifiers are kept).
  String inlineParams(String sql, List<Object?> params) {
    if (params.isEmpty) return sql;
    final sb = StringBuffer();
    var next = 0;
    String? close;
    for (var i = 0; i < sql.length; i++) {
      final ch = sql[i];
      if (close != null) {
        if (ch == close) close = null;
      } else if (ch == "'" || ch == '"' || ch == '`') {
        close = ch;
      } else if (ch == '[') {
        close = ']';
      } else if (ch == '?' && next < params.length) {
        sb.write(literal(params[next++]));
        continue;
      }
      sb.write(ch);
    }
    return sb.toString();
  }

  /// Wraps [sql] to return at most [n] rows.
  String limit(String sql, int n) {
    switch (family) {
      case DbFamily.sqlServer:
        return sql.replaceFirst(RegExp(r'^\s*select\s', caseSensitive: false), 'SELECT TOP $n ');
      case DbFamily.oracle:
      case DbFamily.db2:
        return '$sql FETCH FIRST $n ROWS ONLY';
      case DbFamily.firebird:
        return sql.replaceFirst(RegExp(r'^\s*select\s', caseSensitive: false), 'SELECT FIRST $n ');
      default:
        return '$sql LIMIT $n';
    }
  }

  String? explainPrefix() => switch (family) {
    DbFamily.postgres => 'EXPLAIN ',
    DbFamily.mysql => 'EXPLAIN ',
    DbFamily.sqlite => 'EXPLAIN QUERY PLAN ',
    DbFamily.oracle => 'EXPLAIN PLAN FOR ',
    DbFamily.snowflake => 'EXPLAIN ',
    DbFamily.db2 => null,
    DbFamily.sqlServer => null,
    _ => 'EXPLAIN ',
  };

  /// SQL to obtain the server side plan (SQL Server uses SHOWPLAN).
  List<String> explainStatements(String sql) {
    if (family == DbFamily.sqlServer) {
      return ['SET SHOWPLAN_ALL ON', sql, 'SET SHOWPLAN_ALL OFF'];
    }
    final p = explainPrefix();
    return [if (p != null) '$p$sql' else sql];
  }

  // -------------------------------------------------------------------------
  // SQL generation (Generate SQL menu)
  // -------------------------------------------------------------------------

  String selectSql(DbTable t, List<DbColumn> cols) {
    final c = cols.isEmpty ? '*' : cols.map((e) => quoteIdent(e.name)).join(', ');
    return 'SELECT $c\nFROM ${tableName(t)}';
  }

  String insertSql(DbTable t, List<DbColumn> cols) {
    final ins = cols.where((c) => !c.autoIncrement).toList();
    return 'INSERT INTO ${tableName(t)}\n'
        '(${ins.map((e) => quoteIdent(e.name)).join(', ')})\n'
        'VALUES (${ins.map((e) => '?').join(', ')})';
  }

  String updateSql(DbTable t, List<DbColumn> cols, List<String> keys) {
    final k = keys.isEmpty ? cols.take(1).map((e) => e.name).toList() : keys;
    final set = cols.where((c) => !k.contains(c.name)).map((e) => '${quoteIdent(e.name)} = ?');
    return 'UPDATE ${tableName(t)}\nSET ${set.join(',\n    ')}\n'
        'WHERE ${k.map((e) => '${quoteIdent(e)} = ?').join(' AND ')}';
  }

  String deleteSql(DbTable t, List<DbColumn> cols, List<String> keys) {
    final k = keys.isEmpty ? cols.take(1).map((e) => e.name).toList() : keys;
    return 'DELETE FROM ${tableName(t)}\n'
        'WHERE ${k.map((e) => '${quoteIdent(e)} = ?').join(' AND ')}';
  }

  /// Reconstructs a CREATE TABLE statement from ODBC metadata.
  String ddl(TableDetails d) {
    final t = d.table;
    final sb = StringBuffer();
    if (t.isView) {
      sb.writeln('-- Vista ${tableName(t)}: la definizione non è esposta via ODBC.');
      sb.writeln('-- Colonne:');
      for (final c in d.columns) {
        sb.writeln('--   ${c.name} ${c.fullType}');
      }
      return sb.toString();
    }
    sb.writeln('CREATE TABLE ${tableName(t)} (');
    final lines = <String>[];
    for (final c in d.columns) {
      final l = StringBuffer('\t${quoteIdent(c.name)} ${c.fullType}');
      final def = c.defaultValue?.trim();
      if (def != null && def.isNotEmpty && def.toUpperCase() != 'NULL') {
        l.write(' DEFAULT $def');
      }
      if (!c.nullable) l.write(' NOT NULL');
      lines.add(l.toString());
    }
    final pk = d.primaryKey;
    if (pk != null && pk.columns.isNotEmpty) {
      final name = pk.name != null && pk.name!.isNotEmpty ? 'CONSTRAINT ${quoteIdent(pk.name!)} ' : '';
      lines.add('\t${name}PRIMARY KEY (${pk.columns.map(quoteIdent).join(', ')})');
    }
    for (final fk in d.foreignKeys) {
      final name = fk.name != null && fk.name!.isNotEmpty ? 'CONSTRAINT ${quoteIdent(fk.name!)} ' : '';
      final buf = StringBuffer(
        '\t${name}FOREIGN KEY (${fk.columns.map(quoteIdent).join(', ')}) '
        'REFERENCES ${qualified(fk.pkCatalog, fk.pkSchema, fk.pkTable)} '
        '(${fk.refColumns.map(quoteIdent).join(', ')})',
      );
      final del = DbForeignKey.ruleName(fk.deleteRule);
      final upd = DbForeignKey.ruleName(fk.updateRule);
      if (del.isNotEmpty && del != 'NO ACTION' && del != 'RESTRICT') {
        buf.write(' ON DELETE $del');
      }
      if (upd.isNotEmpty && upd != 'NO ACTION' && upd != 'RESTRICT') {
        buf.write(' ON UPDATE $upd');
      }
      lines.add(buf.toString());
    }
    sb.writeln(lines.join(',\n'));
    sb.writeln(');');
    final pkCols = pk?.columns.join(',');
    for (final ix in d.indexes) {
      if (ix.columns.join(',') == pkCols && ix.unique) continue;
      if (ix.name.toLowerCase().startsWith('sqlite_autoindex')) continue;
      sb.writeln();
      sb.write(
        'CREATE ${ix.unique ? 'UNIQUE ' : ''}INDEX ${quoteIdent(ix.name)} '
        'ON ${tableName(t)} (${ix.columns.map(quoteIdent).join(', ')});',
      );
    }
    if (t.remarks != null && t.remarks!.isNotEmpty) {
      sb.writeln();
      sb.writeln('-- ${t.remarks}');
    }
    return sb.toString().trimRight();
  }

  String dropSql(DbTable t) => 'DROP ${t.isView ? 'VIEW' : 'TABLE'} ${tableName(t)}';

  String truncateSql(DbTable t) =>
      family == DbFamily.sqlite ? 'DELETE FROM ${tableName(t)}' : 'TRUNCATE TABLE ${tableName(t)}';

  String countSql(DbTable t) => 'SELECT COUNT(*) FROM ${tableName(t)}';

  String procedureCall(DbProcedure p, List<DbProcedureParam> params) {
    final ins = params.where((e) => e.columnType == 1 || e.columnType == 2 || e.columnType == 4);
    final name = qualified(p.catalog, p.schema, p.cleanName);
    final args = ins.map((e) => '?').join(', ');
    if (family == DbFamily.sqlServer) {
      return 'EXEC $name ${ins.map((e) => e.name.startsWith('@') ? '${e.name} = ?' : '?').join(', ')}';
    }
    if (p.type == 2) return 'SELECT $name($args)';
    return '{CALL $name($args)}';
  }
}
