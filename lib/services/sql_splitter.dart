// SQL script parsing: statement splitting, statement at cursor, parameters.

class SqlStatement {
  const SqlStatement(this.text, this.start, this.end);
  final String text;

  /// Offsets in the original script.
  final int start;
  final int end;

  @override
  String toString() => 'SqlStatement($start-$end: $text)';
}

class SqlSplitter {
  SqlSplitter({this.blankLineDelimiter = false});

  /// Treat empty lines as statement delimiters (DBeaver "smart" mode).
  final bool blankLineDelimiter;

  static final _blockStart = RegExp(
    r'^\s*(create\s+(or\s+(replace|alter)\s+)?((no)?editionable\s+)?(definer\s*=\s*\S+\s+)?'
    r'(proc|procedure|function|trigger|package|type\s+body)\b|declare|'
    r'begin(?!\s*(tran|transaction|work)\b|\s*;)|do\s)',
    caseSensitive: false,
  );

  List<SqlStatement> split(String sql) {
    final result = <SqlStatement>[];
    final n = sql.length;
    var stmtStart = 0;
    var i = 0;
    var depth = 0;
    var blockMode = false;
    var checkedBlock = false;
    String? lastWord;
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
      lastWord = null;
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
          final tag = m[0]!;
          final e = sql.indexOf(tag, i + tag.length);
          i = e < 0 ? n : e + tag.length;
          continue;
        }
      }
      if (!checkedBlock && !_isSpace(c)) {
        checkedBlock = true;
        blockMode = _blockStart.hasMatch(sql.substring(i, i + 64 > n ? n : i + 64));
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
        if (word == 'GO' && atLineStart(i) && _restOfLineBlank(sql, j)) {
          emit(i, _skipTo(sql, j, '\n'));
          i = stmtStart;
          continue;
        }
        if (blockMode) {
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
        i = j;
        continue;
      }
      if (delimiter != ';') {
        i++;
        continue;
      }
      if (c == ';' && (!blockMode || depth <= 0)) {
        emit(i, i + 1);
        i++;
        continue;
      }
      if (c == '/' && atLineStart(i) && _restOfLineBlank(sql, i + 1)) {
        emit(i, _skipTo(sql, i + 1, '\n'));
        i = stmtStart;
        continue;
      }
      if (c == '\n' && blankLineDelimiter && (!blockMode || depth <= 0)) {
        // Blank line?
        var j = i + 1;
        while (j < n && (sql[j] == ' ' || sql[j] == '\t' || sql[j] == '\r')) {
          j++;
        }
        if (j < n && sql[j] == '\n') {
          emit(i, j);
          i = j;
          continue;
        }
      }
      i++;
    }
    emit(n, n);
    return result;
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
