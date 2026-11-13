// Common table expressions (WITH name [(cols)] AS (...)) found in a script,
// used by the SQL editor autocompletion.

class SqlCte {
  const SqlCte(this.name, this.columns, this.starSources, this.body, {this.bodyStart = 0, this.bodyEnd = 0});

  final String name;

  /// Column names: the explicit list or the aliases of the body's select list.
  final List<String> columns;

  /// `*` / `x.*` items of the body's select list: null for a bare `*`,
  /// otherwise the qualifier. Their columns come from the body's tables.
  final List<String?> starSources;
  final String body;

  /// Offsets of [body] in the text given to [findCtes] (inside the parentheses).
  final int bodyStart;
  final int bodyEnd;
}

/// CTEs defined anywhere in [sql] (strings and comments ignored).
List<SqlCte> findCtes(String sql) {
  final s = maskSqlLiterals(sql);
  final out = <SqlCte>[];
  for (final m in RegExp(r'\bwith\b', caseSensitive: false).allMatches(s)) {
    var i = m.end;
    var first = true;
    while (true) {
      i = _skipWs(s, i);
      var id = _readIdent(s, i);
      if (id == null) break;
      if (first && id.$1.toLowerCase() == 'recursive') {
        i = _skipWs(s, id.$2);
        id = _readIdent(s, i);
        if (id == null) break;
      }
      first = false;
      final name = id.$1;
      i = _skipWs(s, id.$2);
      List<String>? cols;
      if (i < s.length && s[i] == '(') {
        final close = _matchParen(s, i);
        if (close < 0) break;
        cols = [
          for (final c in _splitTopLevel(s.substring(i + 1, close)))
            if (_readIdent(c.trim(), 0) case final r? when r.$2 == c.trim().length) r.$1,
        ];
        i = _skipWs(s, close + 1);
      }
      final as = _readIdent(s, i);
      if (as == null || as.$1.toLowerCase() != 'as') break;
      i = _skipWs(s, as.$2);
      // PostgreSQL: AS [NOT] MATERIALIZED (...)
      for (final w in const ['not', 'materialized']) {
        final r = _readIdent(s, i);
        if (r != null && r.$1.toLowerCase() == w) i = _skipWs(s, r.$2);
      }
      if (i >= s.length || s[i] != '(') break;
      final close = _matchParen(s, i);
      // An unclosed body (still being typed) extends to the end of the text.
      final body = s.substring(i + 1, close < 0 ? s.length : close);
      final sel = _selectList(body);
      out.add(
        SqlCte(
          name,
          cols ?? sel.$1,
          cols == null ? sel.$2 : const [],
          body,
          bodyStart: i + 1,
          bodyEnd: close < 0 ? s.length : close,
        ),
      );
      if (close < 0) break;
      i = _skipWs(s, close + 1);
      if (i < s.length && s[i] == ',') {
        i++;
        continue;
      }
      break;
    }
  }
  return out;
}

/// Replaces comments and string literals with spaces (same length), so that
/// offsets are preserved and their content is never parsed as SQL.
String maskSqlLiterals(String sql) {
  final b = StringBuffer();
  var i = 0;
  final n = sql.length;
  void blank(int to) {
    for (var k = i; k < to; k++) {
      b.write(sql[k] == '\n' ? '\n' : ' ');
    }
    i = to;
  }

  while (i < n) {
    final c = sql[i];
    if (c == '-' && i + 1 < n && sql[i + 1] == '-') {
      final e = sql.indexOf('\n', i);
      blank(e < 0 ? n : e);
    } else if (c == '/' && i + 1 < n && sql[i + 1] == '*') {
      final e = sql.indexOf('*/', i + 2);
      blank(e < 0 ? n : e + 2);
    } else if (c == "'") {
      var j = i + 1;
      while (j < n) {
        if (sql[j] == "'") {
          if (j + 1 < n && sql[j + 1] == "'") {
            j += 2;
            continue;
          }
          j++;
          break;
        }
        j++;
      }
      blank(j);
    } else {
      b.write(c);
      i++;
    }
  }
  return b.toString();
}

const _selectEnd = {
  'from',
  'into',
  'where',
  'group',
  'having',
  'order',
  'union',
  'intersect',
  'except',
  'minus',
  'limit',
  'window',
  'fetch',
  'offset',
};

const _notAlias = {'end', 'null', 'true', 'false', 'asc', 'desc', 'distinct', 'all'};

/// Column names and star items of the first top-level SELECT of [body].
/// Column names and `*` / `x.*` items of the first top-level SELECT of
/// [body] (a CTE, a derived table...).
(List<String>, List<String?>) sqlSelectList(String body) => _selectList(body);

(List<String>, List<String?>) _selectList(String body) {
  final words = RegExp(r'[A-Za-z_][\w$#@]*');
  var depth = 0;
  int? start;
  var end = body.length;
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    } else if (c == '"' || c == '[' || c == '`') {
      final close = body.indexOf(c == '[' ? ']' : c, i + 1);
      i = close < 0 ? body.length : close;
    } else if (words.matchAsPrefix(body, i) case final w? when depth == 0 && (i == 0 || !_isWordPart(body[i - 1]))) {
      final lw = w[0]!.toLowerCase();
      if (start == null && lw == 'select') {
        start = w.end;
      } else if (start != null && _selectEnd.contains(lw)) {
        end = i;
        break;
      }
      i = w.end - 1;
    }
  }
  if (start == null) return (const [], const []);
  var list = body.substring(start, end).trim();
  // Modifiers before the first item.
  final mod = RegExp(
    r'^(?:(?:distinct\s+on\s*\([^)]*\)|distinct|all|top\s*\(\s*[^)]*\)|top\s+\d+)(?:\s+percent)?(?:\s+with\s+ties)?\s*)+',
    caseSensitive: false,
  );
  list = list.replaceFirst(mod, '');
  final cols = <String>[];
  final stars = <String?>[];
  const id = r'(?:"[^"]*"|\[[^\]]*\]|`[^`]*`|[A-Za-z_#][\w$#@]*)';
  for (var item in _splitTopLevel(list)) {
    item = item.trim();
    if (item.isEmpty) continue;
    final star = RegExp('^(?:($id)\\s*\\.\\s*)*\\*\$').firstMatch(item);
    if (star != null) {
      stars.add(star[1] == null ? null : _unquote(star[1]!));
      continue;
    }
    // T-SQL: alias = expression
    final eq = RegExp('^($id)\\s*=(?!=)').firstMatch(item);
    if (eq != null) {
      cols.add(_unquote(eq[1]!));
      continue;
    }
    final as = RegExp('\\bas\\s+($id)\\s*\$', caseSensitive: false).firstMatch(item);
    if (as != null) {
      cols.add(_unquote(as[1]!));
      continue;
    }
    final plain = RegExp('^(?:$id\\s*\\.\\s*)*($id)\$').firstMatch(item);
    if (plain != null) {
      cols.add(_unquote(plain[1]!));
      continue;
    }
    // expression alias (without AS)
    final tail = RegExp('[\\w)\\]"`\'.]\\s+($id)\\s*\$').firstMatch(item);
    if (tail != null && !_notAlias.contains(tail[1]!.toLowerCase())) {
      cols.add(_unquote(tail[1]!));
    }
  }
  return (cols, stars);
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

List<String> _splitTopLevel(String s) {
  final out = <String>[];
  var depth = 0, from = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    } else if (c == '"' || c == '[' || c == '`') {
      final close = s.indexOf(c == '[' ? ']' : c, i + 1);
      i = close < 0 ? s.length : close;
    } else if (c == ',' && depth == 0) {
      out.add(s.substring(from, i));
      from = i + 1;
    }
  }
  out.add(s.substring(from));
  return out;
}

int _skipWs(String s, int i) {
  while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) {
    i++;
  }
  return i;
}

/// Index of the `)` matching the `(` at [open], or -1.
int _matchParen(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      if (--depth == 0) return i;
    } else if (c == '"' || c == '[' || c == '`') {
      final close = s.indexOf(c == '[' ? ']' : c, i + 1);
      if (close < 0) return -1;
      i = close;
    }
  }
  return -1;
}

/// Identifier at [i] (plain or quoted, unquoted in the result) and its end.
(String, int)? _readIdent(String s, int i) {
  if (i >= s.length) return null;
  final c = s[i];
  if (c == '"' || c == '[' || c == '`') {
    final close = s.indexOf(c == '[' ? ']' : c, i + 1);
    if (close < 0) return null;
    return (s.substring(i + 1, close), close + 1);
  }
  if (!RegExp(r'[A-Za-z_#]').hasMatch(c)) return null;
  var j = i + 1;
  while (j < s.length && _isWordPart(s[j])) {
    j++;
  }
  return (s.substring(i, j), j);
}

bool _isWordPart(String c) => RegExp(r'[\w$#@]').hasMatch(c);
