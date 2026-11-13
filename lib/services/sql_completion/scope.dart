// Stage 1 of the SQL completion: where the caret is. Isolates the statement
// under the caret, its query blocks (subqueries), the tables / aliases / CTEs
// in scope and the clause being written. Text based (no full parser), like
// pgcli and DBeaver's legacy engine, so it works the same for every database
// and on incomplete SQL.

import '../sql_splitter.dart';
import 'cte.dart';

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

/// A table (or CTE) referenced in a FROM / JOIN / UPDATE / INTO / USING.
class SqlTableRef {
  const SqlTableRef(this.name, {this.schema, this.alias, this.depth = 0, this.position = 0});

  /// Unquoted name and schema (the part before the name, if any).
  final String name;
  final String? schema;
  final String? alias;

  /// 0 = query block under the caret, 1 = the enclosing one, ...
  final int depth;

  /// Offset in its block (textual order).
  final int position;

  /// How the query refers to it: the alias, or the name.
  String get ref => alias ?? name;

  bool identifiedBy(String s) {
    final l = s.toLowerCase();
    return alias?.toLowerCase() == l || (alias == null && name.toLowerCase() == l) || name.toLowerCase() == l;
  }

  @override
  String toString() => 'SqlTableRef(${schema == null ? '' : '$schema.'}$name${alias == null ? '' : ' $alias'} d$depth)';
}

class SqlCompletionScope {
  const SqlCompletionScope({
    required this.clause,
    required this.refs,
    required this.ctes,
    required this.hasFrom,
    this.keyword,
    this.textBefore = '',
    this.allCtes = const {},
  });

  final SqlClause clause;

  /// Tables of the query block under the caret first (textual order), then
  /// those of the enclosing blocks (correlated subqueries).
  final List<SqlTableRef> refs;

  /// CTEs visible at the caret, by lower-case name: inside the body of a CTE
  /// only the ones defined before it (like pgcli), all of them elsewhere.
  final Map<String, SqlCte> ctes;

  /// Every CTE of the statement, by lower-case name.
  final Map<String, SqlCte> allCtes;

  /// The query block under the caret already has a FROM / JOIN source.
  final bool hasFrom;

  /// Last clause keyword before the caret (lower case), if any.
  final String? keyword;

  /// Statement text before the caret, literals and comments blanked.
  final String textBefore;

  /// Lower-case alias or table name -> table (or CTE) name, inner block first.
  Map<String, String> get aliases {
    final m = <String, String>{};
    for (final r in refs) {
      m.putIfAbsent(r.name.toLowerCase(), () => r.name);
      if (r.alias != null) m.putIfAbsent(r.alias!.toLowerCase(), () => r.name);
    }
    return m;
  }

  /// Tables / CTEs referenced by the query blocks in scope.
  Iterable<String> get tables => {for (final r in refs) r.name};

  /// The reference named or aliased [s] (inner block first).
  SqlTableRef? refFor(String s) {
    final l = s.toLowerCase();
    for (final r in refs) {
      if (r.alias?.toLowerCase() == l) return r;
    }
    for (final r in refs) {
      if (r.name.toLowerCase() == l) return r;
    }
    return null;
  }

  /// Resolves an alias, a CTE or a table name.
  String resolve(String ownerOrAlias) => refFor(ownerOrAlias)?.name ?? ownerOrAlias;

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

/// The identifier being typed at the end of a text (qualifiers included).
final partialWordPattern = RegExp(r'[\w$#@."\[\]`]*$');

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

  final refs = <SqlTableRef>[];
  var hasFrom = false;
  for (final (depth, (from, to)) in blocks.indexed) {
    final found = sqlTableRefs(_flatten(s.substring(from, to)), depth: depth);
    if (depth == 0) hasFrom = found.isNotEmpty;
    refs.addAll(found);
  }

  // Clause: text before the caret back to the innermost open parenthesis or
  // block start, without closed nested parentheses and the word being typed.
  final blockStart = blocks.first.$1;
  final innerOpen = open.isEmpty ? -1 : open.last;
  final inCall = innerOpen >= blockStart; // function call, IN list, column list
  final segStart = inCall ? innerOpen + 1 : blockStart;
  final before = _flatten(s.substring(segStart, caret)).replaceFirst(partialWordPattern, '');
  final (clause, keyword) = _clauseOf(before);

  final all = findCtes(text);
  return SqlCompletionScope(
    clause: clause ?? (inCall ? SqlClause.column : SqlClause.other),
    keyword: keyword,
    refs: refs,
    ctes: {for (final c in all) c.name.toLowerCase(): c},
    allCtes: {for (final c in all) c.name.toLowerCase(): c},
    hasFrom: hasFrom,
    textBefore: s.substring(0, caret),
  );
}

/// Clause and keyword from the last keyword of [before]; null clause when
/// there is no keyword.
(SqlClause?, String?) _clauseOf(String before) {
  final t = before.trimRight();
  // `a = |`, `x + |`
  if (RegExp(r'[=<>+\-*/%|]$').hasMatch(t)) return (SqlClause.column, null);
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
    if (rest.isEmpty || rest.endsWith(',')) return (kind, w);
    return (SqlClause.other, w);
  }
  return (null, null);
}

const _name = r'(?:"[^"]*"|\[[^\]]*\]|`[^`]*`|[\w$#@]+)';
final _nameRe = RegExp(_name);
final _sourceRe = RegExp(
  '\\b(?:from|join|update|into|using)\\s+((?:$_name\\s*\\.\\s*)*$_name)(?:\\s+(?:as\\s+)?([A-Za-z_][\\w\$]*))?',
  caseSensitive: false,
);
final _listRe = RegExp(
  '^\\s*,\\s*((?:$_name\\s*\\.\\s*)*$_name)(?:\\s+(?:as\\s+)?([A-Za-z_][\\w\$]*))?',
  caseSensitive: false,
);

/// Tables referenced in FROM / JOIN / UPDATE / INTO / USING of [text] (and the
/// comma separated lists after them), in textual order.
List<SqlTableRef> sqlTableRefs(String text, {int depth = 0}) {
  final out = <SqlTableRef>[];
  SqlTableRef? make(String path, String? alias, int pos) {
    final parts = _nameRe.allMatches(path).map((p) => _unquote(p[0]!)).toList();
    final table = parts.last;
    if (table.isEmpty || _notAlias.contains(table.toLowerCase())) return null;
    return SqlTableRef(
      table,
      schema: parts.length > 1 ? parts[parts.length - 2] : null,
      alias: alias != null && !_notAlias.contains(alias.toLowerCase()) ? alias : null,
      depth: depth,
      position: pos,
    );
  }

  for (final m in _sourceRe.allMatches(text)) {
    final r = make(m[1]!, m[2], m.start);
    if (r == null) continue;
    out.add(r);
    // FROM a, b c
    var at = m.end;
    while (true) {
      final l = _listRe.firstMatch(text.substring(at));
      if (l == null) break;
      final x = make(l[1]!, l[2], at);
      if (x == null) break;
      out.add(x);
      at += l.end;
    }
  }
  return out;
}

/// Lower-case alias and lower-case name -> table name, for [sqlTableRefs].
Map<String, String> sqlTableAliases(String text) {
  final map = <String, String>{};
  for (final r in sqlTableRefs(text)) {
    map[r.name.toLowerCase()] = r.name;
    if (r.alias != null) map[r.alias!.toLowerCase()] = r.name;
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
