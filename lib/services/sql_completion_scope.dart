// What the SQL editor autocompletion should propose at the caret: the clause
// being written, the tables / aliases / CTEs in scope. Text based (no full
// parser) so that it works the same for every database and on incomplete SQL.

import 'sql_cte.dart';
import 'sql_splitter.dart';

/// Kind of name expected at the caret.
enum SqlClause {
  /// After FROM / JOIN / UPDATE / INTO / USING (or a comma in that list).
  table,

  /// After SELECT, WHERE, ON, AND, OR, BY, SET, HAVING, CASE..., an operator
  /// or an open parenthesis (or a comma in those lists).
  column,

  /// Anything else (typically a keyword is expected: `SELECT a |`).
  other,
}

class SqlCompletionScope {
  const SqlCompletionScope(this.clause, this.aliases, this.ctes, this.hasFrom);

  final SqlClause clause;

  /// Lower-case alias or table name -> table (or CTE) name, for the query
  /// block under the caret first, then the enclosing ones (correlated
  /// subqueries).
  final Map<String, String> aliases;

  /// CTEs of the statement under the caret, by lower-case name.
  final Map<String, SqlCte> ctes;

  /// The query block under the caret already has a FROM / JOIN source.
  final bool hasFrom;

  /// Tables / CTEs referenced by the query blocks in scope.
  Iterable<String> get tables => aliases.values.toSet();

  /// Resolves an alias, a CTE or a table name.
  String resolve(String ownerOrAlias) => aliases[ownerOrAlias.toLowerCase()] ?? ownerOrAlias;

  SqlCte? cte(String name) => ctes[name.toLowerCase()];
}

const _tableKeywords = {'from', 'join', 'update', 'into', 'using', 'table'};
const _columnKeywords = {
  'select',
  'where',
  'on',
  'and',
  'or',
  'not',
  'by',
  'set',
  'having',
  'case',
  'when',
  'then',
  'else',
  'distinct',
  'in',
  'like',
  'between',
  'is',
  'return',
  'returning',
  'values',
};

/// Every keyword that ends the previous clause (to find the clause at the caret).
const _clauseKeywords = {
  ..._tableKeywords,
  ..._columnKeywords,
  'as',
  'with',
  'limit',
  'offset',
  'top',
  'union',
  'intersect',
  'except',
  'group',
  'order',
  'partition',
  'over',
  'end',
  'asc',
  'desc',
  'inner',
  'left',
  'right',
  'full',
  'outer',
  'cross',
};

/// Scope at [offset] of [script] (a whole editor text, possibly with several
/// statements).
SqlCompletionScope sqlCompletionScope(String script, int offset) {
  offset = offset.clamp(0, script.length);
  final stmt = SqlSplitter().statementAt(script, offset);
  var start = stmt?.start ?? 0;
  var end = stmt == null ? script.length : stmt.end.clamp(start, script.length);
  // The statement excludes trailing blanks: extend it to the caret, or start a
  // new (empty) one when a delimiter sits in between.
  if (offset > end) {
    final semi = script.substring(end, offset).lastIndexOf(';');
    if (semi >= 0) start = end + semi + 1;
    end = offset;
  }
  if (offset < start) start = offset;
  final text = script.substring(start, end);
  final caret = (offset - start).clamp(0, text.length);
  final s = maskSqlLiterals(text);

  // Open parentheses enclosing the caret, innermost last.
  final open = <int>[];
  for (var i = 0; i < caret; i++) {
    final c = s[i];
    if (c == '(') {
      open.add(i);
    } else if (c == ')' && open.isNotEmpty) {
      open.removeLast();
    } else if (c == '"' || c == '[' || c == '`') {
      final close = s.indexOf(c == '[' ? ']' : c, i + 1);
      if (close < 0 || close >= caret) break;
      i = close;
    }
  }

  // Query blocks: subqueries (parentheses whose content starts with SELECT or
  // WITH) enclosing the caret, then the statement itself.
  final blocks = <(int, int)>[];
  for (final o in open.reversed) {
    if (RegExp(r'^\s*(?:select|with)\b', caseSensitive: false).hasMatch(s.substring(o + 1))) {
      final close = _matchParen(s, o);
      blocks.add((o + 1, close < 0 ? s.length : close));
    }
  }
  blocks.add((0, s.length));

  final aliases = <String, String>{};
  var hasFrom = false;
  for (final (i, (from, to)) in blocks.indexed) {
    final flat = _flatten(s.substring(from, to));
    final a = sqlTableAliases(flat);
    if (i == 0) hasFrom = a.isNotEmpty;
    for (final e in a.entries) {
      aliases.putIfAbsent(e.key, () => e.value);
    }
  }

  // Clause: text before the caret back to the innermost open parenthesis or
  // block start, without closed nested parentheses and the word being typed.
  final blockStart = blocks.first.$1;
  final innerOpen = open.isEmpty ? -1 : open.last;
  final inCall = innerOpen >= blockStart; // function call, IN list, column list
  final segStart = inCall ? innerOpen + 1 : blockStart;
  final before = _flatten(s.substring(segStart, caret)).replaceFirst(RegExp(r'[\w$#@."\[\]`]*$'), '');
  final clause = _clauseOf(before) ?? (inCall ? SqlClause.column : SqlClause.other);

  return SqlCompletionScope(clause, aliases, {for (final c in findCtes(text)) c.name.toLowerCase(): c}, hasFrom);
}

/// Clause from the last keyword of [before]; null when there is none.
SqlClause? _clauseOf(String before) {
  final t = before.trimRight();
  // `a = |`, `x + |`
  if (RegExp(r'[=<>+\-*/%|]$').hasMatch(t)) return SqlClause.column;
  final words = RegExp(r'[A-Za-z_][\w$#@]*').allMatches(t).toList();
  for (var k = words.length - 1; k >= 0; k--) {
    final w = words[k][0]!.toLowerCase();
    if (!_clauseKeywords.contains(w)) continue;
    final rest = t.substring(words[k].end).trim();
    final kind = _tableKeywords.contains(w)
        ? SqlClause.table
        : _columnKeywords.contains(w)
        ? SqlClause.column
        : SqlClause.other;
    // Right after the keyword or after a comma of its list: a name is expected.
    if (rest.isEmpty || rest.endsWith(',')) return kind;
    return SqlClause.other;
  }
  return null;
}

/// Table names referenced in FROM / JOIN / UPDATE / INTO / USING, by lower-case
/// alias and lower-case name (schema and quotes removed).
Map<String, String> sqlTableAliases(String text) {
  final map = <String, String>{};
  const name = r'(?:"[^"]*"|\[[^\]]*\]|`[^`]*`|[\w$#@]+)';
  final re = RegExp(
    '\\b(?:from|join|update|into|using)\\s+((?:$name\\s*\\.\\s*)*$name)(?:\\s+(?:as\\s+)?([A-Za-z_][\\w\$]*))?',
    caseSensitive: false,
  );
  for (final m in re.allMatches(text)) {
    final parts = RegExp(name).allMatches(m[1]!).map((p) => p[0]!).toList();
    final table = _unquote(parts.last);
    if (table.isEmpty || _notAlias.contains(table.toLowerCase())) continue;
    map[table.toLowerCase()] = table;
    final alias = m[2];
    if (alias != null && !_notAlias.contains(alias.toLowerCase())) {
      map[alias.toLowerCase()] = table;
    }
    // FROM a, b c
    var rest = text.substring(m.end);
    final list = RegExp(
      '^\\s*,\\s*((?:$name\\s*\\.\\s*)*$name)(?:\\s+(?:as\\s+)?([A-Za-z_][\\w\$]*))?',
      caseSensitive: false,
    );
    while (true) {
      final l = list.firstMatch(rest);
      if (l == null) break;
      final t = _unquote(RegExp(name).allMatches(l[1]!).last[0]!);
      if (_notAlias.contains(t.toLowerCase())) break;
      map[t.toLowerCase()] = t;
      final a = l[2];
      if (a != null && !_notAlias.contains(a.toLowerCase())) map[a.toLowerCase()] = t;
      rest = rest.substring(l.end);
    }
  }
  return map;
}

const _notAlias = {
  'where',
  'on',
  'join',
  'left',
  'right',
  'inner',
  'outer',
  'full',
  'cross',
  'group',
  'order',
  'set',
  'values',
  'limit',
  'union',
  'having',
  'using',
  'natural',
  'select',
  'as',
  'with',
  'when',
  'then',
  'lateral',
  'apply',
  'pivot',
  'unpivot',
  'window',
  'offset',
  'fetch',
  'for',
  'except',
  'intersect',
  'minus',
  'returning',
  'output',
  'default',
  'top',
};

/// Replaces the content of every parenthesis (and the parentheses) with
/// spaces, so that nested subqueries do not leak their tables.
String _flatten(String s) {
  final b = StringBuffer();
  var depth = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '(') {
      depth++;
      b.write(' ');
    } else if (c == ')') {
      if (depth > 0) depth--;
      b.write(' ');
    } else {
      b.write(depth > 0 && c != '\n' ? ' ' : c);
    }
  }
  return b.toString();
}

int _matchParen(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == '(') {
      depth++;
    } else if (s[i] == ')') {
      if (--depth == 0) return i;
    }
  }
  return -1;
}

String _unquote(String s) {
  if (s.length >= 2 &&
      ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith('[') && s.endsWith(']')) ||
          (s.startsWith('`') && s.endsWith('`')))) {
    return s.substring(1, s.length - 1);
  }
  return s;
}
