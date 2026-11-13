import 'package:dbcraft/services/sql_folding.dart';
import 'package:dbcraft/ui/editors/code_folding.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

List<(int, int)> folds(String sql, {bool blank = false}) => [
  for (final r in sqlFoldRanges(sql, blankLineDelimiter: blank)) (r.first, r.last),
];

void main() {
  group('sqlFoldRanges', () {
    test('multi-line statements fold, single-line ones do not', () {
      const sql = 'SELECT 1;\n'
          'SELECT a,\n'
          '  b\n'
          'FROM t;\n'
          'UPDATE t SET a = 1;';
      expect(folds(sql), [(1, 3)]);
    });

    test('a statement folds from its first line of code, after the comments', () {
      const sql = '-- header\n'
          'SELECT a\n'
          'FROM t;';
      expect(folds(sql), [(1, 2)]);
    });

    test('block comments fold keeping the line of */ visible', () {
      const sql = '/* first\n'
          '   second\n'
          '*/\n'
          'SELECT 1; /* one line */\n'
          '/* two\n'
          '   lines */';
      // Hiding the line of */ would leave the comment open for the
      // highlighter: two-line comments cannot fold.
      expect(folds(sql), [(0, 1)]);
    });

    test('runs of -- lines fold, trailing comments do not join them', () {
      const sql = '-- a\n'
          '-- b\n'
          '  -- c\n'
          'SELECT 1; -- d\n'
          '-- e\n'
          'SELECT 2;';
      expect(folds(sql), [(0, 2)]);
    });

    test('comment markers inside strings are ignored', () {
      const sql = "SELECT '/* no',\n"
          "  '-- no'\n"
          'FROM t;';
      expect(folds(sql), [(0, 2)]);
    });

    test('comments inside a statement are nested in its fold', () {
      const sql = 'SELECT a,\n'
          '  /* x\n'
          '     y\n'
          '  */\n'
          '  b\n'
          'FROM t;';
      expect(folds(sql), [(0, 5), (1, 2)]);
    });

    test('a nested region ending on the same line as its parent is dropped', () {
      const sql = 'SELECT a\n'
          '-- x\n'
          '-- y\n'
          ';';
      expect(folds(sql), [(0, 2)]);
    });

    test('blank lines end statements only when enabled', () {
      const sql = 'SELECT a\n'
          'FROM t\n'
          '\n'
          'SELECT b\n'
          'FROM u';
      expect(folds(sql), [(0, 4)]);
      expect(folds(sql, blank: true), [(0, 1), (3, 4)]);
    });

    test('a statement whose first line opens a comment or string does not fold', () {
      const sql = "SELECT a, /* note\n"
          '  more */ b\n'
          'FROM t;\n'
          "SELECT 'multi\n"
          "line' AS x\n"
          'FROM u;';
      expect(folds(sql), isEmpty);
    });

    test('parenthesized blocks fold keeping the line of ) visible', () {
      const sql = 'CREATE TABLE t (\n'
          '  id INT,\n'
          '  name TEXT\n'
          ');\n'
          'SELECT *\n'
          'FROM a\n'
          'WHERE id IN (\n'
          '  SELECT id\n'
          '  FROM b\n'
          ')\n'
          'ORDER BY 1;';
      // CREATE TABLE: the statement wins on its first line.
      expect(folds(sql), [(0, 3), (4, 10), (6, 8)]);
    });

    test('each CTE and the main query of a WITH statement fold', () {
      const sql = 'WITH a AS (\n'
          '  SELECT 1\n'
          '),\n'
          '-- second\n'
          'b AS (\n'
          '  SELECT 2\n'
          ')\n'
          'SELECT *\n'
          'FROM a, b;';
      expect(folds(sql), [(0, 1), (4, 5), (7, 8)]);
    });

    test('a WITH statement with WITH alone on its line folds as a whole', () {
      const sql = 'WITH\n'
          'a AS (\n'
          '  SELECT 1\n'
          ')\n'
          'SELECT *\n'
          'FROM a;';
      expect(folds(sql), [(0, 5), (1, 2)]);
    });

    test('procedure bodies fold as one statement', () {
      const sql = 'CREATE PROCEDURE p AS\n'
          'BEGIN\n'
          '  SELECT 1;\n'
          '  SELECT 2;\n'
          'END;\n'
          'SELECT 3;';
      expect(folds(sql), [(0, 4)]);
    });
  });

  group('SqlChunkAnalyzer', () {
    const sql = '/* c1\n'
        '   c2\n'
        '*/\n'
        'SELECT a,\n'
        '  b\n'
        'FROM t;\n'
        'SELECT 1;';

    List<(int, int)> chunks(CodeLines lines) => [
      for (final c in const SqlChunkAnalyzer().run(lines)) (c.index, c.end),
    ];

    test('chunks hide the lines after the first one of each region', () {
      final ctrl = CodeLineEditingController.fromText(sql);
      expect(chunks(ctrl.codeLines), [(0, 2), (3, 6)]);
    });

    test('collapsed regions keep an empty chunk and shift the following ones', () {
      final ctrl = CodeLineEditingController.fromText(sql);
      ctrl.collapseChunk(0, 2);
      expect(ctrl.text, sql);
      expect(chunks(ctrl.codeLines), [(0, 1), (2, 5)]);
    });
  });

  group('visible / script lines', () {
    const sql = 'SELECT a,\n'
        '  b\n'
        'FROM t;\n'
        'SELECT x\n'
        'FROM u;';

    test('caret offset and line indexes count the collapsed lines', () {
      final ctrl = CodeLineEditingController.fromText(sql);
      ctrl.collapseChunk(0, 3);
      // Visible: 0 = "SELECT a," (collapsed), 1 = "SELECT x", 2 = "FROM u;".
      expect(ctrl.scriptOffset(1, 7), sql.indexOf('x'));
      expect(scriptLineIndex(ctrl.codeLines, 2), 4);
      expect(visibleLineIndex(ctrl.codeLines, 1), 0);
      expect(visibleLineIndex(ctrl.codeLines, 3), 1);
    });

    test('expandScriptLines shows only the regions in the range', () {
      final ctrl = CodeLineEditingController.fromText(sql);
      ctrl.collapseChunk(3, 5);
      ctrl.collapseChunk(0, 3);
      expect(ctrl.codeLines.length, 2);
      ctrl.expandScriptLines(1, 1);
      expect(ctrl.codeLines.length, 4);
      expect(ctrl.codeLines[3].chunkParent, isTrue);
      expect(ctrl.text, sql);
    });
  });
}
