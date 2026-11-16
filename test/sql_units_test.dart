import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/services/sql_splitter.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> units(String sql, DbFamily? f, {bool blank = true}) =>
    SqlSplitter(family: f, blankLineDelimiter: blank).units(sql).map((u) => u.text).toList();

void main() {
  group('SQL Server batches', () {
    test('DECLARE and the statements using it run in one batch', () {
      const sql = 'DECLARE @x INT = 1;\nSELECT @x;\n\nSELECT @x + 1';
      expect(units(sql, DbFamily.sqlServer), [sql]);
      final u = SqlSplitter(family: DbFamily.sqlServer).units(sql).single;
      expect(u.statements.map((s) => s.text), ['DECLARE @x INT = 1', 'SELECT @x', 'SELECT @x + 1']);
      expect(u.isBatch, isTrue);
    });

    test('GO separates batches, GO n repeats', () {
      final u = SqlSplitter(family: DbFamily.sqlServer).units('SELECT 1; SELECT 2\nGO\nINSERT t VALUES (1)\nGO 3\nSELECT 3');
      expect(u.map((e) => e.text), ['SELECT 1; SELECT 2', 'INSERT t VALUES (1)', 'SELECT 3']);
      expect(u.map((e) => e.repeat), [1, 3, 1]);
    });

    test('statements that must be alone in a batch get their own unit', () {
      const sql = 'CREATE TABLE t (a INT);\nCREATE VIEW v AS SELECT a FROM t;\nSELECT * FROM v;';
      expect(units(sql, DbFamily.sqlServer), ['CREATE TABLE t (a INT)', 'CREATE VIEW v AS SELECT a FROM t', 'SELECT * FROM v']);
      const proc = 'CREATE PROCEDURE p AS\nBEGIN\n  DECLARE @a INT = 1;\n  SELECT @a;\nEND;\nEXEC p;';
      expect(units(proc, DbFamily.sqlServer), ['CREATE PROCEDURE p AS\nBEGIN\n  DECLARE @a INT = 1;\n  SELECT @a;\nEND', 'EXEC p']);
      expect(units('CREATE PROCEDURE p AS SELECT 1', DbFamily.sqlServer), ['CREATE PROCEDURE p AS SELECT 1']);
    });

    test('other dialects keep one unit per statement', () {
      expect(units('SELECT 1; SELECT 2', DbFamily.postgres), ['SELECT 1', 'SELECT 2']);
      expect(units('SELECT 1; SELECT 2', null), ['SELECT 1', 'SELECT 2']);
    });
  });

  group('DECLARE blocks', () {
    test('Oracle / generic: DECLARE … BEGIN … END is one statement', () {
      const block = 'DECLARE\n  x NUMBER := 1;\n  y VARCHAR2(10);\nBEGIN\n  x := x + 1;\n  IF x > 1 THEN NULL; END IF;\nEND';
      for (final f in [DbFamily.oracle, DbFamily.snowflake, null]) {
        expect(units('$block;\nSELECT 1 FROM dual;', f), [block, 'SELECT 1 FROM dual'], reason: '$f');
      }
      // A blank line in the declarations does not end the block either.
      const spaced = 'DECLARE\n  x NUMBER;\n\n  y NUMBER;\nBEGIN\n  NULL;\nEND';
      expect(units(spaced, DbFamily.oracle), [spaced]);
    });

    test('T-SQL, cursors and Db2 temporary tables are plain statements', () {
      expect(units('DECLARE @x INT;\nSELECT @x', DbFamily.postgres), ['DECLARE @x INT', 'SELECT @x']);
      expect(units('DECLARE c CURSOR FOR SELECT 1;\nFETCH c', DbFamily.postgres), ['DECLARE c CURSOR FOR SELECT 1', 'FETCH c']);
      expect(units('DECLARE c NO SCROLL CURSOR WITH HOLD FOR SELECT 1;\nFETCH c', null),
          ['DECLARE c NO SCROLL CURSOR WITH HOLD FOR SELECT 1', 'FETCH c']);
      expect(units('DECLARE GLOBAL TEMPORARY TABLE t (a INT);\nSELECT 1', DbFamily.db2),
          ['DECLARE GLOBAL TEMPORARY TABLE t (a INT)', 'SELECT 1']);
    });

    test('Firebird EXECUTE BLOCK', () {
      const block = 'EXECUTE BLOCK RETURNS (n INT) AS\n  DECLARE VARIABLE i INT = 0;\nBEGIN\n  n = i;\n  SUSPEND;\nEND';
      expect(units('$block;\nSELECT 1 FROM rdb\$database;', DbFamily.firebird), [block, r'SELECT 1 FROM rdb$database']);
    });

    test('BigQuery: a script with DECLARE runs as one job', () {
      const script = 'DECLARE x INT64 DEFAULT 1;\nSET x = x + 1;\nSELECT x';
      expect(units(script, DbFamily.bigquery), [script]);
      expect(units('SELECT 1;\nSELECT 2', DbFamily.bigquery), ['SELECT 1', 'SELECT 2']);
      // On BigQuery DECLARE is a statement, not a block.
      expect(SqlSplitter(family: DbFamily.bigquery).split(script).length, 3);
    });
  });
}
