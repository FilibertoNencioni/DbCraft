import 'sql_keywords.dart';

enum _T { word, quoted, comment, symbol, space, number }

class _Tok {
  _Tok(this.type, this.text);
  final _T type;
  String text;
}

/// Lightweight SQL formatter (keyword case + clause line breaks).
class SqlFormatter {
  SqlFormatter({this.upperCaseKeywords = true, this.indent = '    '});

  final bool upperCaseKeywords;
  final String indent;

  static const _newLineBefore = {
    'SELECT',
    'FROM',
    'WHERE',
    'GROUP',
    'ORDER',
    'HAVING',
    'LIMIT',
    'OFFSET',
    'UNION',
    'INTERSECT',
    'EXCEPT',
    'VALUES',
    'SET',
    'RETURNING',
    'WINDOW',
    'JOIN',
    'INNER',
    'LEFT',
    'RIGHT',
    'FULL',
    'CROSS',
    'INSERT',
    'UPDATE',
    'DELETE',
    'WITH',
    'FETCH',
  };
  static const _joinModifiers = {'INNER', 'LEFT', 'RIGHT', 'FULL', 'CROSS', 'OUTER', 'NATURAL'};

  List<_Tok> _tokenize(String s) {
    final out = <_Tok>[];
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == '-' && i + 1 < s.length && s[i + 1] == '-') {
        var e = s.indexOf('\n', i);
        e = e < 0 ? s.length : e;
        out.add(_Tok(_T.comment, s.substring(i, e)));
        i = e;
      } else if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
        var e = s.indexOf('*/', i + 2);
        e = e < 0 ? s.length : e + 2;
        out.add(_Tok(_T.comment, s.substring(i, e)));
        i = e;
      } else if (c == "'" || c == '"' || c == '`' || c == '[') {
        final close = c == '[' ? ']' : c;
        var j = i + 1;
        while (j < s.length) {
          if (s[j] == close) {
            if (j + 1 < s.length && s[j + 1] == close && close != ']') {
              j += 2;
              continue;
            }
            break;
          }
          j++;
        }
        j = j >= s.length ? s.length : j + 1;
        out.add(_Tok(_T.quoted, s.substring(i, j)));
        i = j;
      } else if (RegExp(r'\s').hasMatch(c)) {
        var j = i;
        while (j < s.length && RegExp(r'\s').hasMatch(s[j])) {
          j++;
        }
        out.add(_Tok(_T.space, ' '));
        i = j;
      } else if (RegExp(r'[A-Za-z_@#$]').hasMatch(c)) {
        var j = i + 1;
        while (j < s.length && RegExp(r'[A-Za-z0-9_@#$]').hasMatch(s[j])) {
          j++;
        }
        out.add(_Tok(_T.word, s.substring(i, j)));
        i = j;
      } else if (RegExp(r'[0-9]').hasMatch(c)) {
        var j = i + 1;
        while (j < s.length && RegExp(r'[0-9.eE]').hasMatch(s[j])) {
          j++;
        }
        out.add(_Tok(_T.number, s.substring(i, j)));
        i = j;
      } else {
        // Multi char operators
        final two = i + 1 < s.length ? s.substring(i, i + 2) : c;
        if (const {'<=', '>=', '<>', '!=', '||', '::', ':='}.contains(two)) {
          out.add(_Tok(_T.symbol, two));
          i += 2;
        } else {
          out.add(_Tok(_T.symbol, c));
          i++;
        }
      }
    }
    return out;
  }

  String format(String sql) {
    final toks = _tokenize(sql.trim());
    final sb = StringBuffer();
    var depth = 0;
    var clause = '';
    final parenClause = <String>[];
    var lineStart = true;

    void newline([int extra = 0]) {
      final str = sb.toString().trimRight();
      sb
        ..clear()
        ..write(str)
        ..write('\n')
        ..write(indent * (depth + extra));
      lineStart = true;
    }

    void write(String s) {
      if (!lineStart && sb.isNotEmpty) {
        final last = sb.toString();
        final lc = last[last.length - 1];
        // Function calls keep the parenthesis attached: COUNT(x), not COUNT (x)
        // (MySQL rejects the space by default).
        final call = s == '(' && _isCallee(last);
        if (!call &&
            lc != ' ' &&
            lc != '(' &&
            lc != '\n' &&
            s != ',' &&
            s != ')' &&
            s != ';' &&
            s != '.' &&
            !last.endsWith('.') &&
            s != '::' &&
            !last.endsWith('::')) {
          sb.write(' ');
        }
      }
      sb.write(s);
      lineStart = false;
    }

    String? prevWord;
    for (var k = 0; k < toks.length; k++) {
      final t = toks[k];
      switch (t.type) {
        case _T.space:
          continue;
        case _T.comment:
          write(t.text);
          if (t.text.startsWith('--')) newline();
        case _T.word:
          final up = t.text.toUpperCase();
          final isKw = isSqlKeyword(up) || kSqlFunctions.contains(up);
          final text = isKw && upperCaseKeywords ? up : t.text;
          final joinContinuation = up == 'JOIN' && _joinModifiers.contains(prevWord);
          final outerContinuation = up == 'OUTER' && _joinModifiers.contains(prevWord);
          if (_newLineBefore.contains(up) &&
              !joinContinuation &&
              !outerContinuation &&
              !(up == 'SET' && prevWord == 'UPDATE') &&
              sb.isNotEmpty) {
            newline();
          }
          write(text);
          if (const {'SELECT', 'FROM', 'WHERE', 'SET', 'BY', 'VALUES', 'HAVING'}.contains(up)) {
            clause = up;
          }
          // Select list on its own indented lines (DBeaver style).
          if (up == 'SELECT' || ((up == 'DISTINCT' || up == 'ALL') && prevWord == 'SELECT')) {
            final next = toks
                .skip(k + 1)
                .firstWhere((x) => x.type != _T.space, orElse: () => _Tok(_T.space, ''));
            final nu = next.text.toUpperCase();
            if (!(up == 'SELECT' && (nu == 'DISTINCT' || nu == 'ALL' || nu == 'TOP'))) newline(1);
          }
          if (up == 'AND' || up == 'OR') {
            // keep inline
          }
          prevWord = up;
        case _T.symbol:
          if (t.text == '(') {
            write('(');
            parenClause.add(clause);
            depth++;
            lineStart = true; // no space after (
          } else if (t.text == ')') {
            depth = depth > 0 ? depth - 1 : 0;
            clause = parenClause.isNotEmpty ? parenClause.removeLast() : '';
            lineStart = false;
            sb.write(')');
          } else if (t.text == ',') {
            sb.write(',');
            if (clause == 'SELECT' || clause == 'BY' || clause == 'SET') {
              newline(1);
            } else {
              lineStart = false;
            }
          } else if (t.text == ';') {
            sb.write(';');
            depth = 0;
            sb.write('\n');
            newline();
          } else if (t.text == '.') {
            sb.write('.');
            lineStart = true;
          } else {
            write(t.text);
          }
          prevWord = null;
        case _T.quoted:
        case _T.number:
          write(t.text);
          prevWord = null;
      }
    }
    return sb
        .toString()
        .split('\n')
        .map((l) => l.trimRight())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}

/// Words after which "(" starts a sub-expression, not a function call.
const _spacedBeforeParen = {
  'IN', 'VALUES', 'AS', 'EXISTS', 'FROM', 'JOIN', 'ON', 'AND', 'OR', 'NOT', 'WHERE', 'SELECT', 'INTO', //
  'TABLE', 'USING', 'OVER', 'ANY', 'ALL', 'SOME', 'WITH', 'UNION', 'INTERSECT', 'EXCEPT', 'MINUS', 'THEN',
  'ELSE', 'WHEN', 'CASE', 'RETURNS', 'BY', 'SET', 'IS', 'LIKE', 'BETWEEN', 'HAVING', 'RETURN', 'DISTINCT',
  'PRIMARY', 'KEY', 'UNIQUE', 'CHECK', 'REFERENCES', 'INDEX', 'VIEW', 'PROCEDURE', 'FUNCTION', 'BEGIN',
};

/// The text before "(" ends with an identifier that is called as a function.
bool _isCallee(String before) {
  final m = RegExp(r'([A-Za-z_][A-Za-z0-9_$#@]*)$').firstMatch(before);
  if (m == null) return false;
  return !_spacedBeforeParen.contains(m.group(1)!.toUpperCase());
}
