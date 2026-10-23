// SQLite keeps no catalog of constraints: they are read from the CREATE
// TABLE / CREATE INDEX statements stored in sqlite_master.

import '../../../model/db_objects.dart';
import '../../schema/schema_model.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

Future<TableExtras> readSqliteTable(CatalogQueries q, DbTable t) async {
  final schema = t.schema == null || t.schema!.isEmpty || t.schema == 'main' ? '' : '"${t.schema}".';
  final rows = await q.first([
    'SELECT type, name, sql FROM ${schema}sqlite_master '
        "WHERE tbl_name = ${lit(t.name)} AND type IN ('table', 'index') AND sql IS NOT NULL",
  ]);
  var extras = const TableExtras();
  final indexes = <String, IndexDef>{};
  for (final r in rows) {
    final sql = rowText(r, 'sql') ?? '';
    if (rowText(r, 'type') == 'table') {
      extras = parseSqliteCreateTable(sql);
    } else {
      final ix = parseSqliteCreateIndex(sql);
      if (ix != null) indexes[ix.name.toLowerCase()] = ix;
    }
  }
  return TableExtras(uniques: extras.uniques, checks: extras.checks, columns: extras.columns, indexes: indexes);
}

/// Index of the parenthesis closing the one at [open] (quotes skipped).
int _close(String s, int open) {
  var depth = 0;
  String? quote;
  for (var i = open; i < s.length; i++) {
    final ch = s[i];
    if (quote != null) {
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == "'" || ch == '"' || ch == '`') {
      quote = ch;
    } else if (ch == '[') {
      quote = ']';
    } else if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      if (--depth == 0) return i;
    }
  }
  return s.length - 1;
}

/// [body] split at the commas outside parentheses and quotes.
List<String> _split(String body) {
  final out = <String>[];
  var depth = 0, start = 0;
  String? quote;
  for (var i = 0; i < body.length; i++) {
    final ch = body[i];
    if (quote != null) {
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == "'" || ch == '"' || ch == '`') {
      quote = ch;
    } else if (ch == '[') {
      quote = ']';
    } else if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
    } else if (ch == ',' && depth == 0) {
      out.add(body.substring(start, i).trim());
      start = i + 1;
    }
  }
  out.add(body.substring(start).trim());
  return out.where((e) => e.isNotEmpty).toList();
}

final _ident = RegExp(r'^\s*("(?:[^"]|"")+"|`[^`]+`|\[[^\]]+\]|[A-Za-z_][A-Za-z0-9_$]*)');

/// Leading identifier of [s] and the rest.
(String, String) _token(String s) {
  final m = _ident.firstMatch(s);
  if (m == null) return ('', s);
  return (unquoteIdent(m.group(1)!), s.substring(m.end));
}

/// Parenthesized text right after [keyword] in [s] (case insensitive), with
/// its end offset.
(String, int)? _after(String s, RegExp keyword) {
  final m = keyword.firstMatch(s);
  if (m == null) return null;
  final open = s.indexOf('(', m.end - 1);
  if (open < 0) return null;
  final close = _close(s, open);
  return (s.substring(open + 1, close).trim(), close + 1);
}

/// Constraints and column extras of a CREATE TABLE statement.
TableExtras parseSqliteCreateTable(String sql) {
  final open = sql.indexOf('(');
  if (open < 0) return TableExtras.none;
  final body = sql.substring(open + 1, _close(sql, open));
  final uniques = <UniqueDef>[];
  final checks = <CheckDef>[];
  final columns = <String, ColumnExtra>{};
  final constraint = RegExp(r'^(CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN)\b', caseSensitive: false);
  final named = RegExp(r'^CONSTRAINT\s+', caseSensitive: false);

  for (final part in _split(body)) {
    if (constraint.hasMatch(part)) {
      var rest = part;
      String? name;
      if (named.hasMatch(rest)) {
        final (n, r) = _token(rest.replaceFirst(named, ''));
        name = n;
        rest = r.trim();
      }
      final upper = rest.toUpperCase();
      if (upper.startsWith('UNIQUE')) {
        final cols = _after(rest, RegExp(r'^UNIQUE\s*\(', caseSensitive: false));
        if (cols != null) uniques.add(UniqueDef(name: name, columns: _split(cols.$1).map(_indexColumn).toList()));
      } else if (upper.startsWith('CHECK')) {
        final e = _after(rest, RegExp(r'^CHECK\s*\(', caseSensitive: false));
        if (e != null) checks.add(CheckDef(name: name, expression: e.$1));
      }
      continue;
    }
    // Column definition: name, type, then constraints in any order.
    final (col, def) = _token(part);
    if (col.isEmpty) continue;
    final collate = RegExp(r'\bCOLLATE\s+("?[\w$]+"?)', caseSensitive: false).firstMatch(def)?.group(1);
    final gen = _after(def, RegExp(r'\b(GENERATED\s+ALWAYS\s+)?AS\s*\(', caseSensitive: false));
    final stored = gen != null && RegExp(r'^\s*STORED\b', caseSensitive: false).hasMatch(def.substring(gen.$2));
    // Inline CHECK and UNIQUE, possibly named.
    for (final m in RegExp(r'(?:\bCONSTRAINT\s+("?[\w$]+"?)\s+)?\bCHECK\s*\(', caseSensitive: false).allMatches(def)) {
      final open = def.indexOf('(', m.end - 1);
      checks.add(
        CheckDef(
          name: m.group(1) == null ? null : unquoteIdent(m.group(1)!),
          expression: def.substring(open + 1, _close(def, open)).trim(),
        ),
      );
    }
    final unique = RegExp(r'(?:\bCONSTRAINT\s+("?[\w$]+"?)\s+)?\bUNIQUE\b', caseSensitive: false).firstMatch(def);
    if (unique != null) {
      uniques.add(UniqueDef(name: unique.group(1) == null ? null : unquoteIdent(unique.group(1)!), columns: [col]));
    }
    columns[col.toLowerCase()] = ColumnExtra(
      collation: collate == null ? null : unquoteIdent(collate),
      computed: gen?.$1,
      computedStored: stored,
    );
  }
  return TableExtras(uniques: uniques, checks: checks, columns: columns);
}

/// Column of an index or UNIQUE list: a name (direction and collation
/// dropped) or an expression in parentheses.
String _indexColumn(String item) {
  final clean = item.replaceAll(RegExp(r'\s+(ASC|DESC)\s*$', caseSensitive: false), '').trim();
  final noCollate = clean.replaceAll(RegExp(r'\s+COLLATE\s+\S+$', caseSensitive: false), '').trim();
  final (name, rest) = _token(noCollate);
  if (name.isNotEmpty && rest.trim().isEmpty) return name;
  return '(${stripParens(noCollate)})';
}

/// Definition of a CREATE INDEX statement (null when not parsable).
IndexDef? parseSqliteCreateIndex(String sql) {
  final m = RegExp(
    r'^\s*CREATE\s+(UNIQUE\s+)?INDEX\s+(IF\s+NOT\s+EXISTS\s+)?(.+?)\s+ON\s+',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(sql);
  if (m == null) return null;
  // [schema.]name
  var (name, rest) = _token(m.group(3)!);
  if (rest.trimLeft().startsWith('.')) (name, rest) = _token(rest.trimLeft().substring(1));
  final open = sql.indexOf('(', m.end);
  if (open < 0) return null;
  final close = _close(sql, open);
  final items = _split(sql.substring(open + 1, close));
  final cols = <String>[], desc = <String>{};
  for (final i in items) {
    final c = _indexColumn(i);
    cols.add(c);
    if (RegExp(r'\s+DESC\s*$', caseSensitive: false).hasMatch(i)) desc.add(c);
  }
  final where = RegExp(r'^\s*WHERE\s+(.+)$', caseSensitive: false, dotAll: true).firstMatch(sql.substring(close + 1));
  return IndexDef(
    name: name,
    columns: cols,
    unique: m.group(1) != null,
    descending: desc,
    where: where?.group(1)?.trim(),
  );
}
