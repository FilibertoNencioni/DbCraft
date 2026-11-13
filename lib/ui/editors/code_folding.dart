// Code folding in the SQL editors (re_editor chunks).
//
// re_editor indexes lines by what is visible: a collapsed line holds the
// hidden ones as `chunks`, while `controller.text` is the whole script. The
// helpers below convert between the two.

import 'package:re_editor/re_editor.dart';

import '../../services/sql_folding.dart';

/// Folds statements and multi-line comments ([sqlFoldRanges]).
class SqlChunkAnalyzer implements CodeChunkAnalyzer {
  const SqlChunkAnalyzer({this.blankLineDelimiter = false});

  /// Empty lines end statements (as in the execution).
  final bool blankLineDelimiter;

  @override
  List<CodeChunk> run(CodeLines codeLines) {
    final text = codeLines.asString(TextLineBreak.lf);
    final starts = _lineStarts(codeLines);
    final chunks = <CodeChunk>[];
    for (final r in sqlFoldRanges(text, blankLineDelimiter: blankLineDelimiter)) {
      final a = _visibleLine(starts, r.first), b = _visibleLine(starts, r.last);
      // A collapsed region maps to a single visible line: the chunk is kept
      // (empty) so that re_editor does not expand it.
      // Ranges inside a collapsed one map to its line: keep the outermost.
      if (chunks.isEmpty || chunks.last.index != a) chunks.add(CodeChunk(a, b + 1));
    }
    return chunks;
  }

  @override
  bool operator ==(Object other) => other is SqlChunkAnalyzer && other.blankLineDelimiter == blankLineDelimiter;

  @override
  int get hashCode => blankLineDelimiter.hashCode;
}

/// Script line of each visible line of [lines].
List<int> _lineStarts(CodeLines lines) {
  final starts = List<int>.filled(lines.length, 0);
  var line = 0;
  for (var i = 0; i < lines.length; i++) {
    starts[i] = line;
    line += lines[i].lineCount;
  }
  return starts;
}

/// Visible line showing script line [line] (the collapsed line when hidden).
int _visibleLine(List<int> starts, int line) {
  var lo = 0, hi = starts.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= line) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// Visible line of [lines] showing script line [line] (the collapsed line
/// when it is hidden).
int visibleLineIndex(CodeLines lines, int line) => _visibleLine(_lineStarts(lines), line);

/// Script line of visible line [index] of [lines].
int scriptLineIndex(CodeLines lines, int index) {
  var line = 0;
  for (var i = 0; i < index && i < lines.length; i++) {
    line += lines[i].lineCount;
  }
  return line;
}

extension SqlCodeFolding on CodeLineEditingController {
  /// Offset in [text] (a `\n` line break) of [column] of visible line
  /// [index].
  int scriptOffset(int index, int column) {
    final lines = codeLines;
    var off = 0;
    for (var i = 0; i < index && i < lines.length; i++) {
      off += lines[i].charCount + lines[i].lineCount;
    }
    return off + column;
  }

  /// Expands the collapsed regions containing script lines [first]..[last],
  /// so they can be selected.
  void expandScriptLines(int first, int last) {
    var line = 0;
    for (var i = 0; i < codeLines.length && line <= last;) {
      final l = codeLines[i];
      if (l.chunkParent && line + l.lineCount - 1 >= first) {
        expandChunk(i); // Line i is now a single line: check it again.
        continue;
      }
      line += l.lineCount;
      i++;
    }
  }
}
