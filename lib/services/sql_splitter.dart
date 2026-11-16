// SQL script parsing: statement splitting, execution units (batches),
// statement at cursor, parameters.

import 'sql_dialect.dart';

class SqlStatement {
  const SqlStatement(this.text, this.start, this.end);
  final String text;

  /// Offsets in the original script.
  final int start;
  final int end;

  @override
  String toString() => 'SqlStatement($start-$end: $text)';
}

/// What the app sends to the server in one call: a statement or, on SQL
/// Server, a batch (the statements between two `GO`), where `DECLARE`d
/// variables and `#temp` tables live.
class SqlUnit {
  const SqlUnit(this.text, this.start, this.end, this.statements, {this.repeat = 1});

  factory SqlUnit.of(String script, List<SqlStatement> statements, {int repeat = 1}) {
    final start = statements.first.start, end = statements.last.end;
    return SqlUnit(
      statements.length == 1 ? statements.first.text : script.substring(start, end),
      start,
      end,
      statements,
      repeat: repeat,
    );
  }

  /// A unit made of a single text (generated statements, explain, refresh).
  factory SqlUnit.single(String sql) => SqlUnit(sql, 0, sql.length, [SqlStatement(sql, 0, sql.length)]);

  final String text;

  /// Offsets in the original script.
  final int start;
  final int end;

  /// The statements of the unit (offsets in the original script).
  final List<SqlStatement> statements;

  /// `GO n`: times the batch runs.
  final int repeat;

  bool get isBatch => statements.length > 1;

  @override
  String toString() => 'SqlUnit($start-$end, ${statements.length} statements: $text)';
}

class SqlSplitter {
  SqlSplitter({this.blankLineDelimiter = false, this.family});

  /// Treat empty lines as statement delimiters (DBeaver "smart" mode).
  final bool blankLineDelimiter;

  /// Dialect of the target database (null: unknown, generic rules). It
  /// decides which `DECLARE` opens a block and how statements group into
  /// [units].
  final DbFamily? family;

  static final _blockStart = RegExp(
    r'^\s*(create\s+(or\s+(replace|alter)\s+)?((no)?editionable\s+)?(definer\s*=\s*\S+\s+)?'
    r'(proc|procedure|function|trigger|package|type\s+body)\b|declare|execute\s+block\b|'
    r'begin(?!\s*(tran|transaction|work)\b|\s*;)|do\s)',
    caseSensitive: false,
  );

  /// `DECLARE` statements that are not the declaration section of a block:
  /// T-SQL variables, cursors, Db2 temporary tables.
  static final _declareStatement = RegExp(
    r'^\s*declare\s+(@|global\b|\S+\s+(?:[a-z_]+\s+){0,4}cursor\b)',
    caseSensitive: false,
  );
  static final _declareOrBlock = RegExp(r'^\s*(declare|execute\s+block)\b', caseSensitive: false);

  /// Whether the statement starting with [head] opens a block whose
  /// declarations end with `;` before its BEGIN … END (PL/SQL, Snowflake
  /// Scripting, Firebird EXECUTE BLOCK).
  bool _isDeclareBlock(String head) {
    if (!_declareOrBlock.hasMatch(head) || _declareStatement.hasMatch(head)) return false;
    if (RegExp(r'^\s*execute', caseSensitive: false).hasMatch(head)) return true;
    // SQL Server: DECLARE @x; BigQuery: DECLARE x INT64; MySQL: only inside
    // routines. All are plain statements.
    return family != DbFamily.sqlServer && family != DbFamily.bigquery && family != DbFamily.mysql;
  }

  List<SqlStatement> split(String sql) => _scan(sql).$1;

  /// Execution units of [sql]: on SQL Server the batches between `GO`
  /// (statements that must be alone in a batch, such as CREATE PROCEDURE or
  /// CREATE VIEW, get their own); on BigQuery the whole script when it uses
  /// scripting (DECLARE, SET, BEGIN…); elsewhere one unit per statement.
  List<SqlUnit> units(String sql) {
    final (stmts, breaks) = _scan(sql);
    if (stmts.isEmpty) return const [];
    switch (family) {
      case DbFamily.sqlServer:
        final out = <SqlUnit>[];
        var from = 0;
        void group(int to, int repeat) {
          if (to > from) out.addAll(_batchUnits(sql, stmts.sublist(from, to), repeat));
          from = to;
        }

        for (final (at, repeat) in breaks) {
          group(at, repeat);
        }
        group(stmts.length, 1);
        return out;
      case DbFamily.bigquery when stmts.length > 1 && stmts.any((s) => _bigQueryScripting.hasMatch(s.text)):
        return [SqlUnit.of(sql, stmts)];
      default:
        return [for (final s in stmts) SqlUnit.of(sql, [s])];
    }
  }

  static final _bigQueryScripting = RegExp(
    r'^(?:\s|--[^\n]*\n|/\*[\s\S]*?\*/)*(declare|set|begin|if|while|loop|repeat|for)\b',
    caseSensitive: false,
  );

  /// Statements SQL Server accepts only as the first (or only) of a batch.
  static final _aloneInBatch = RegExp(
    r'^(?:\s|--[^\n]*\n|/\*[\s\S]*?\*/)*(create|alter|create\s+or\s+alter)\s+'
    r'(proc|procedure|function|trigger|view|schema|default|rule)\b',
    caseSensitive: false,
  );

  /// A batch, split around the statements that must be alone in it: a
  /// script without `GO` between them runs as before batches existed.
  static List<SqlUnit> _batchUnits(String sql, List<SqlStatement> stmts, int repeat) {
    final out = <SqlUnit>[];
    var run = <SqlStatement>[];
    void flush() {
      if (run.isNotEmpty) out.add(SqlUnit.of(sql, run, repeat: repeat));
      run = [];
    }

    for (final s in stmts) {
      if (stmts.length > 1 && _aloneInBatch.hasMatch(s.text)) {
        flush();
        out.add(SqlUnit.of(sql, [s], repeat: repeat));
      } else {
        run.add(s);
      }
    }
    flush();
    return out;
  }

  /// Statements of [sql] and the `GO` batch breaks: (number of statements
  /// before the break, repeat count of the batch).
  (List<SqlStatement>, List<(int, int)>) _scan(String sql) {
    final result = <SqlStatement>[];
    final breaks = <(int, int)>[];
    final n = sql.length;
    var stmtStart = 0;
    var i = 0;
    var depth = 0;
    var blockMode = false;
    var checkedBlock = false;
    // DECLARE … BEGIN … END: the `;` of the declarations do not end it.
    var declareBlock = false;
    var sawBegin = false;
    String? lastWord;
    // State for the blank-line delimiter: a blank line does not end a
    // statement that is obviously incomplete.
    var parens = 0;
    String? lastTok;
    var sawWord = false;
    var cteHead = false;
    // MySQL client directive "DELIMITER $$": until "DELIMITER ;" statements
    // end only at the custom delimiter.
    var delimiter = ';';

    void emit(int end, int next) {
      final raw = sql.substring(stmtStart, end);
      final trimmed = raw.trim();
      if (trimmed.isNotEmpty && !_onlyComments(trimmed)) {
        final lead = raw.length - raw.trimLeft().length;
        result.add(SqlStatement(trimmed, stmtStart + lead, stmtStart + lead + trimmed.length));
      }
      stmtStart = next;
      depth = 0;
      blockMode = false;
      checkedBlock = false;
      declareBlock = false;
      sawBegin = false;
      lastWord = null;
      parens = 0;
      lastTok = null;
      sawWord = false;
      cteHead = false;
    }

    bool atLineStart(int pos) {
      var j = pos - 1;
      while (j >= 0 && (sql[j] == ' ' || sql[j] == '\t')) {
        j--;
      }
      return j < 0 || sql[j] == '\n';
    }

    while (i < n) {
      final c = sql[i];
      // Comments
      if (c == '-' && i + 1 < n && sql[i + 1] == '-') {
        i = _skipTo(sql, i, '\n');
        continue;
      }
      if (c == '/' && i + 1 < n && sql[i + 1] == '*') {
        final e = sql.indexOf('*/', i + 2);
        i = e < 0 ? n : e + 2;
        continue;
      }
      if (delimiter != ';' && sql.startsWith(delimiter, i)) {
        emit(i, i + delimiter.length);
        i = stmtStart;
        continue;
      }
      // Quoted text
      if (c == "'" || c == '"' || c == '`') {
        i = _skipQuoted(sql, i, c);
        lastTok = c;
        continue;
      }
      if (c == '[') {
        final e = sql.indexOf(']', i + 1);
        i = e < 0 ? n : e + 1;
        lastTok = ']';
        continue;
      }
      if (c == r'$') {
        final m = RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)?\$').matchAsPrefix(sql, i);
        if (m != null) {
          final tag = m[0]!;
          final e = sql.indexOf(tag, i + tag.length);
          i = e < 0 ? n : e + tag.length;
          lastTok = r'$';
          continue;
        }
      }
      if (!checkedBlock && !_isSpace(c)) {
        checkedBlock = true;
        final head = sql.substring(i, i + 200 > n ? n : i + 200);
        blockMode = _blockStart.hasMatch(head);
        declareBlock = blockMode && _isDeclareBlock(head);
        // DECLARE @x / DECLARE c CURSOR … are plain statements.
        if (blockMode && !declareBlock && _declareOrBlock.hasMatch(head)) blockMode = false;
      }
      // Words (for BEGIN/END tracking and GO)
      if (_isWordStart(c)) {
        var j = i + 1;
        while (j < n && _isWordPart(sql[j])) {
          j++;
        }
        final word = sql.substring(i, j).toUpperCase();
        if (word == 'DELIMITER' && atLineStart(i)) {
          final eol = _skipTo(sql, j, '\n');
          final token = sql.substring(j, eol).trim().split(RegExp(r'\s+')).first;
          if (token.isNotEmpty) {
            emit(i, eol);
            delimiter = token;
            i = stmtStart;
            continue;
          }
        }
        if (delimiter != ';') {
          i = j;
          continue;
        }
        if (word == 'GO' && atLineStart(i)) {
          final count = _goCount(sql, j);
          if (count != null) {
            emit(i, _skipTo(sql, j, '\n'));
            breaks.add((result.length, count));
            i = stmtStart;
            continue;
          }
        }
        if (blockMode) {
          if (word == 'BEGIN' && depth <= 0) sawBegin = true;
          if (word == 'BEGIN' || word == 'CASE') {
            depth++;
          } else if (word == 'END') {
            depth--;
          } else if (lastWord == 'END' &&
              (word == 'IF' || word == 'LOOP' || word == 'WHILE' || word == 'REPEAT')) {
            depth++; // "END IF" does not close a BEGIN.
          }
        }
        lastWord = word;
        lastTok = word;
        if (!sawWord) {
          sawWord = true;
          cteHead = word == 'WITH';
        } else if (cteHead && parens == 0 && _cteBodyStart.contains(word)) {
          cteHead = false;
        }
        i = j;
        continue;
      }
      if (delimiter != ';') {
        i++;
        continue;
      }
      final inDeclarations = declareBlock && !sawBegin;
      if (c == ';' && (!blockMode || depth <= 0) && !inDeclarations) {
        emit(i, i + 1);
        i++;
        continue;
      }
      if (c == '/' && atLineStart(i) && _restOfLineBlank(sql, i + 1)) {
        emit(i, _skipTo(sql, i + 1, '\n'));
        i = stmtStart;
        continue;
      }
      if (c == '\n' && blankLineDelimiter && (!blockMode || depth <= 0) && !inDeclarations && parens == 0 && !cteHead) {
        // Blank line?
        var j = i + 1;
        while (j < n && (sql[j] == ' ' || sql[j] == '\t' || sql[j] == '\r')) {
          j++;
        }
        if (j < n && sql[j] == '\n' && !_continuesAfter(lastTok) && !_continuesBefore(_nextToken(sql, j))) {
          emit(i, j);
          i = j;
          continue;
        }
      }
      if (c == '(') {
        parens++;
      } else if (c == ')' && parens > 0) {
        parens--;
      }
      if (!_isSpace(c)) lastTok = c;
      i++;
    }
    emit(n, n);
    return (result, breaks);
  }

  /// `GO` alone on its line (1) or `GO n` (n): the batch runs n times; null
  /// when the line holds something else.
  static int? _goCount(String s, int from) {
    final e = s.indexOf('\n', from);
    final rest = s.substring(from, e < 0 ? s.length : e).trim();
    if (rest.isEmpty) return 1;
    final n = int.tryParse(rest);
    return n != null && n > 0 ? n : null;
  }

  /// Statement under the caret (or the closest one before it).
  SqlStatement? statementAt(String sql, int offset) {
    final all = split(sql);
    if (all.isEmpty) return null;
    SqlStatement? best;
    for (final s in all) {
      if (offset >= s.start && offset <= s.end) return s;
      if (s.end <= offset) best = s;
    }
    // Caret after the last delimiter on the same line: take the previous one.
    return best ?? all.first;
  }

  /// Keywords that start the main query of a `WITH` statement.
  static const _cteBodyStart = {'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'MERGE'};

  /// Tokens that cannot end a statement: a blank line after them is not a
  /// delimiter.
  static const _openEnded = {
    ',', '(', '=', '<', '>', '+', '|', '.', //
    'SELECT', 'FROM', 'WHERE', 'AND', 'OR', 'NOT', 'JOIN', 'INNER', 'LEFT', 'RIGHT', 'FULL', 'OUTER',
    'CROSS', 'ON', 'BY', 'AS', 'WITH', 'UNION', 'ALL', 'EXCEPT', 'INTERSECT', 'MINUS', 'SET', 'VALUES',
    'INTO', 'IN', 'IS', 'LIKE', 'BETWEEN', 'CASE', 'WHEN', 'THEN', 'ELSE', 'HAVING', 'DISTINCT', 'ORDER',
    'GROUP', 'PARTITION', 'OVER', 'USING',
  };

  /// Tokens that cannot start a statement: a blank line before them is not a
  /// delimiter.
  static const _continuation = {
    ',', ')', '.', '=', '<', '>', '+', '|', //
    'FROM', 'WHERE', 'AND', 'OR', 'JOIN', 'INNER', 'LEFT', 'RIGHT', 'FULL', 'OUTER', 'CROSS', 'ON',
    'GROUP', 'ORDER', 'HAVING', 'UNION', 'EXCEPT', 'INTERSECT', 'MINUS', 'LIMIT', 'OFFSET',
    'WINDOW', 'RETURNING', 'OUTPUT', 'WHEN', 'THEN', 'ELSE', 'OVER', 'PARTITION', 'USING', 'AS', 'INTO',
    'NOT', 'IN', 'IS', 'LIKE', 'BETWEEN',
  };

  static bool _continuesAfter(String? tok) => tok != null && _openEnded.contains(tok);
  static bool _continuesBefore(String? tok) => tok != null && _continuation.contains(tok);

  /// First token (upper-case word or single character) at or after [from],
  /// skipping whitespace and comments.
  static String? _nextToken(String s, int from) {
    var i = from;
    final n = s.length;
    while (i < n) {
      final c = s[i];
      if (_isSpace(c)) {
        i++;
      } else if (c == '-' && i + 1 < n && s[i + 1] == '-') {
        i = _skipTo(s, i, '\n');
      } else if (c == '/' && i + 1 < n && s[i + 1] == '*') {
        final e = s.indexOf('*/', i + 2);
        i = e < 0 ? n : e + 2;
      } else if (_isWordStart(c)) {
        var j = i + 1;
        while (j < n && _isWordPart(s[j])) {
          j++;
        }
        return s.substring(i, j).toUpperCase();
      } else {
        return c;
      }
    }
    return null;
  }

  static bool _onlyComments(String s) {
    final stripped = s.replaceAll(RegExp(r'--[^\n]*'), '').replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '').trim();
    return stripped.isEmpty || stripped == ';';
  }

  static int _skipTo(String s, int from, String ch) {
    final e = s.indexOf(ch, from);
    return e < 0 ? s.length : e + 1;
  }

  static int _skipQuoted(String s, int i, String q) {
    var j = i + 1;
    while (j < s.length) {
      if (s[j] == q) {
        if (j + 1 < s.length && s[j + 1] == q) {
          j += 2;
          continue;
        }
        return j + 1;
      }
      if (s[j] == r'\' && q != '"' && j + 1 < s.length) {
        // MySQL style escapes – harmless for other databases.
        j += 2;
        continue;
      }
      j++;
    }
    return s.length;
  }

  static bool _restOfLineBlank(String s, int from) {
    for (var j = from; j < s.length; j++) {
      final c = s[j];
      if (c == '\n') return true;
      if (c != ' ' && c != '\t' && c != '\r') return false;
    }
    return true;
  }

  static bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
  static bool _isWordStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95;
  }

  static bool _isWordPart(String c) {
    final u = c.codeUnitAt(0);
    return _isWordStart(c) || (u >= 48 && u <= 57) || u == 36 || u == 35;
  }
}

/// A parameter placeholder found in a statement.
class SqlParameterRef {
  const SqlParameterRef(this.name, this.start, this.end);

  /// Parameter name (`:name`) or its 1-based position for `?`.
  final String name;
  final int start;
  final int end;
  bool get positional => name.startsWith('?');
}

/// Finds `?` and `:name` placeholders outside literals/comments.
List<SqlParameterRef> findParameters(String sql) {
  final out = <SqlParameterRef>[];
  var i = 0;
  var pos = 0;
  final n = sql.length;
  while (i < n) {
    final c = sql[i];
    if (c == '-' && i + 1 < n && sql[i + 1] == '-') {
      final e = sql.indexOf('\n', i);
      i = e < 0 ? n : e;
      continue;
    }
    if (c == '/' && i + 1 < n && sql[i + 1] == '*') {
      final e = sql.indexOf('*/', i + 2);
      i = e < 0 ? n : e + 2;
      continue;
    }
    if (c == "'" || c == '"' || c == '`') {
      i = SqlSplitter._skipQuoted(sql, i, c);
      continue;
    }
    if (c == '[') {
      final e = sql.indexOf(']', i + 1);
      i = e < 0 ? n : e + 1;
      continue;
    }
    if (c == r'$') {
      final m = RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)?\$').matchAsPrefix(sql, i);
      if (m != null) {
        final e = sql.indexOf(m[0]!, i + m[0]!.length);
        i = e < 0 ? n : e + m[0]!.length;
        continue;
      }
    }
    if (c == '?') {
      // Skip ODBC escapes like {? = CALL …} – still a parameter.
      pos++;
      out.add(SqlParameterRef('?$pos', i, i + 1));
      i++;
      continue;
    }
    if (c == ':' && i + 1 < n) {
      final prev = i > 0 ? sql[i - 1] : ' ';
      if (prev == ':' || sql[i + 1] == ':' || prev == '=') {
        i += 2;
        continue;
      }
      final m = RegExp(r':([A-Za-z_][A-Za-z0-9_]*)').matchAsPrefix(sql, i);
      if (m != null && !RegExp(r'[A-Za-z0-9_]').hasMatch(prev)) {
        out.add(SqlParameterRef(m[1]!, i, m.end));
        i = m.end;
        continue;
      }
    }
    i++;
  }
  return out;
}

/// Replaces named parameters with `?` and returns the ordered names.
(String, List<String>) toPositional(String sql, List<SqlParameterRef> params) {
  final sb = StringBuffer();
  var last = 0;
  final order = <String>[];
  for (final p in params) {
    sb.write(sql.substring(last, p.start));
    sb.write('?');
    order.add(p.name);
    last = p.end;
  }
  sb.write(sql.substring(last));
  return (sb.toString(), order);
}

/// Removes comments preceding the statement (some ODBC drivers, e.g. the
/// SQLite one, mis-handle them).
String stripLeadingComments(String sql) {
  var s = sql.trimLeft();
  while (true) {
    if (s.startsWith('--')) {
      final e = s.indexOf('\n');
      s = e < 0 ? '' : s.substring(e + 1).trimLeft();
    } else if (s.startsWith('/*')) {
      final e = s.indexOf('*/');
      s = e < 0 ? '' : s.substring(e + 2).trimLeft();
    } else {
      return s;
    }
  }
}
