// Code folding of SQL scripts: the line ranges that can be collapsed.

import 'sql_splitter.dart';

/// A collapsible region: when collapsed, line [first] stays visible and
/// lines `first + 1`..[last] (0-based, inclusive) are hidden.
class SqlFoldRange {
  const SqlFoldRange(this.first, this.last);
  final int first;
  final int last;

  @override
  bool operator ==(Object other) => other is SqlFoldRange && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);

  @override
  String toString() => '[$first, $last]';
}

/// Foldable regions of [sql]:
/// - statements spanning more lines, from their first line of code (after
///   the leading comments) to the last one;
/// - blocks in parentheses (CTE bodies, subqueries, column lists): the line
///   of `)` stays visible;
/// - `/* */` comments: the line of `*/` stays visible;
/// - runs of two or more `--` comment lines;
/// - the main query of a `WITH` statement.
///
/// The editor highlights only the visible text, so a region is dropped when
/// hiding it would change how the rest is tokenized (e.g. it would hide the
/// end of a comment or string opened on the visible line).
///
/// The result is sorted by [SqlFoldRange.first] and strictly nested: no two
/// ranges start on the same line, and a range starting inside another ends
/// before it.
List<SqlFoldRange> sqlFoldRanges(String sql, {bool blankLineDelimiter = false}) {
  if (!sql.contains('\n')) return const [];
  final lex = _Lexer(sql)..run();
  final ranges = <_Range>[];
  void add(int first, int last, {int rank = 0}) {
    if (last > first && lex.lineEnd[first] == lex.lineEnd[last]) ranges.add(_Range(first, last, rank));
  }

  for (final s in SqlSplitter(blankLineDelimiter: blankLineDelimiter).split(sql)) {
    final code = _skipComments(sql, s.start, s.end);
    if (code >= s.end) continue;
    final first = lex.lineOf(code), last = lex.lineOf(s.end - 1);
    final main = _withMainQuery(sql, code, s.end);
    // The first CTE body usually opens on the line of WITH: it gets that
    // line, the whole statement can then be folded per CTE + main query.
    add(first, last, rank: main == null ? 0 : 1);
    if (main != null) add(lex.lineOf(main), last);
  }
  for (final (open, close) in lex.parens) {
    add(lex.lineOf(open), lex.lineOf(close) - 1);
  }
  for (final (start, end, closed) in lex.blockComments) {
    final closeLine = lex.lineOf(end - 1);
    add(lex.lineOf(start), closed ? closeLine - 1 : closeLine);
  }
  for (final (first, last) in lex.lineCommentRuns) {
    add(first, last);
  }
  return _nest(ranges);
}

class _Range {
  const _Range(this.first, this.last, this.rank);
  final int first;
  final int last;

  /// Among ranges starting on the same line the lowest rank wins (then the
  /// largest).
  final int rank;
}

/// Comments, strings and parentheses of a script.
class _Lexer {
  _Lexer(this.s);
  final String s;

  final lineStarts = <int>[0];

  /// Construct open at the end of each line: '' (none), `/*` or the quote.
  final lineEnd = <String>[];

  /// Offsets of matching `(` and `)`.
  final parens = <(int, int)>[];

  /// `/* */` comments: start, end (exclusive), terminated.
  final blockComments = <(int, int, bool)>[];

  /// Runs of whole-line `--` comments: first and last line.
  final lineCommentRuns = <(int, int)>[];

  int lineOf(int offset) {
    var lo = 0, hi = lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  void run() {
    for (var i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) == 10) lineStarts.add(i + 1);
    }
    lineEnd.addAll(List.filled(lineStarts.length, ''));
    // Marks the lines ending inside [start, end) as open in [kind].
    void span(int start, int end, String kind) {
      for (var l = lineOf(start); l < lineStarts.length - 1 && lineStarts[l + 1] <= end; l++) {
        lineEnd[l] = kind;
      }
    }

    final n = s.length;
    final open = <int>[];
    int? runFirst, runLast;
    void endRun() {
      if (runFirst != null && runLast! > runFirst!) lineCommentRuns.add((runFirst!, runLast!));
      runFirst = runLast = null;
    }

    var i = 0;
    while (i < n) {
      final c = s[i];
      if (c == '-' && i + 1 < n && s[i + 1] == '-') {
        final line = lineOf(i);
        if (_onlyBlankBefore(s, i)) {
          if (runLast == line - 1) {
            runLast = line;
          } else {
            endRun();
            runFirst = runLast = line;
          }
        } else {
          endRun();
        }
        final e = s.indexOf('\n', i);
        i = e < 0 ? n : e + 1;
        continue;
      }
      if (c == '/' && i + 1 < n && s[i + 1] == '*') {
        endRun();
        final e = s.indexOf('*/', i + 2);
        final end = e < 0 ? n : e + 2;
        blockComments.add((i, end, e >= 0));
        span(i, end, '/*');
        i = end;
        continue;
      }
      if (c == "'" || c == '"' || c == '`') {
        endRun();
        final end = _skipQuoted(s, i, c);
        span(i, end, c);
        i = end;
        continue;
      }
      if (c == '[') {
        // SQL Server quoted identifier (on one line).
        final e = s.indexOf(']', i + 1);
        final nl = s.indexOf('\n', i + 1);
        if (e >= 0 && (nl < 0 || e < nl)) {
          endRun();
          i = e + 1;
          continue;
        }
      }
      if (c == r'$') {
        final m = _dollarTag.matchAsPrefix(s, i);
        if (m != null) {
          endRun();
          final tag = m[0]!;
          final e = s.indexOf(tag, i + tag.length);
          final end = e < 0 ? n : e + tag.length;
          span(i, end, tag);
          i = end;
          continue;
        }
      }
      if (c == '(') {
        open.add(i);
      } else if (c == ')' && open.isNotEmpty) {
        parens.add((open.removeLast(), i));
      }
      if (c != ' ' && c != '\t' && c != '\r' && c != '\n') endRun();
      i++;
    }
    endRun();
  }
}

final _dollarTag = RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)?\$');

/// Keywords that start the main query of a `WITH` statement.
const _mainQueryStart = {'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'MERGE'};

/// Offset of the main query of the `WITH` statement in [start]..[end], or
/// null when it is not a `WITH` statement.
int? _withMainQuery(String s, int start, int end) {
  var i = start, depth = 0;
  var first = true;
  while (i < end) {
    final c = s[i];
    if (s.startsWith('--', i)) {
      final e = s.indexOf('\n', i);
      i = e < 0 ? end : e + 1;
    } else if (s.startsWith('/*', i)) {
      final e = s.indexOf('*/', i + 2);
      i = e < 0 ? end : e + 2;
    } else if (c == "'" || c == '"' || c == '`') {
      i = _skipQuoted(s, i, c);
    } else if (c == '(') {
      depth++;
      i++;
    } else if (c == ')') {
      depth--;
      i++;
    } else if (_isWordStart(c)) {
      var j = i + 1;
      while (j < end && (_isWordStart(s[j]) || _isDigit(s[j]))) {
        j++;
      }
      final word = s.substring(i, j).toUpperCase();
      if (first) {
        if (word != 'WITH') return null;
        first = false;
      } else if (depth == 0 && _mainQueryStart.contains(word)) {
        return i;
      }
      i = j;
    } else {
      i++;
    }
  }
  return null;
}

bool _isWordStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95;
}

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 48 && u <= 57;
}

/// First offset in [start]..[end] that is not whitespace or a comment.
int _skipComments(String s, int start, int end) {
  var i = start;
  while (i < end) {
    final c = s[i];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      i++;
    } else if (s.startsWith('--', i)) {
      final e = s.indexOf('\n', i);
      i = e < 0 ? end : e + 1;
    } else if (s.startsWith('/*', i)) {
      final e = s.indexOf('*/', i + 2);
      i = e < 0 ? end : e + 2;
    } else {
      return i;
    }
  }
  return end;
}

bool _onlyBlankBefore(String s, int i) {
  for (var j = i - 1; j >= 0; j--) {
    final c = s[j];
    if (c == '\n') return true;
    if (c != ' ' && c != '\t' && c != '\r') return false;
  }
  return true;
}

int _skipQuoted(String s, int i, String q) {
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
      j += 2;
      continue;
    }
    j++;
  }
  return s.length;
}

/// Sorts [ranges] and keeps a proper tree (as the editor folding needs): one
/// range per first line ([_Range.rank]), each one strictly inside its
/// parent.
List<SqlFoldRange> _nest(List<_Range> ranges) {
  ranges.sort(
    (a, b) => a.first != b.first
        ? a.first - b.first
        : a.rank != b.rank
        ? a.rank - b.rank
        : b.last - a.last,
  );
  final result = <SqlFoldRange>[];
  final open = <_Range>[];
  for (final r in ranges) {
    while (open.isNotEmpty && open.last.last < r.first) {
      open.removeLast();
    }
    if (open.isNotEmpty && (r.first == open.last.first || r.last >= open.last.last)) continue;
    result.add(SqlFoldRange(r.first, r.last));
    open.add(r);
  }
  return result;
}
