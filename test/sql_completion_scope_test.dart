import 'package:dbcraft/services/sql_completion/scope.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scope at the `|` marker.
SqlCompletionScope at(String sqlWithCaret) {
  final i = sqlWithCaret.indexOf('|');
  return sqlCompletionScope(sqlWithCaret.replaceFirst('|', ''), i);
}

void main() {
  group('clause at the caret', () {
    final cases = {
      'SELECT |': SqlClause.column,
      'SELECT a, |': SqlClause.column,
      'SELECT a |': SqlClause.other,
      'SELECT DISTINCT na|': SqlClause.column,
      'SELECT a FROM |': SqlClause.table,
      'SELECT a FROM t, |': SqlClause.table,
      'SELECT a FROM t |': SqlClause.other,
      'SELECT a FROM t JOIN |': SqlClause.table,
      'SELECT a FROM t JOIN u ON |': SqlClause.column,
      'SELECT a FROM t WHERE x = 1 AND |': SqlClause.column,
      'SELECT a FROM t WHERE x = |': SqlClause.column,
      'SELECT a FROM t WHERE x IN (|': SqlClause.column,
      'SELECT COUNT(|': SqlClause.column,
      'SELECT a FROM t ORDER BY a, |': SqlClause.column,
      'UPDATE |': SqlClause.table,
      'UPDATE t SET |': SqlClause.column,
      'INSERT INTO |': SqlClause.table,
      'INSERT INTO t (a, |': SqlClause.column,
      'SELECT a AS |': SqlClause.other,
      "SELECT 'from ' || |": SqlClause.column,
    };
    cases.forEach((sql, clause) {
      test(sql, () => expect(at(sql).clause, clause));
    });
  });

  group('tables and CTEs in scope', () {
    test('main query of a WITH statement sees its FROM, not the CTE bodies', () {
      final s = at(
        ';WITH Sales AS (SELECT o.CustomerId, SUM(o.Total) AS Total FROM dbo.Orders o GROUP BY o.CustomerId)\n'
        'SELECT s.| FROM Sales s',
      );
      expect(s.ctes.keys, ['sales']);
      expect(s.ctes['sales']!.columns, ['CustomerId', 'Total']);
      expect(s.resolve('s'), 'Sales');
      expect(s.tables, ['Sales']);
      expect(s.hasFrom, isTrue);
    });

    test('before FROM is written there is no source yet', () {
      final s = at('WITH c AS (SELECT a, b FROM t)\nSELECT |');
      expect(s.hasFrom, isFalse);
      expect(s.tables, isEmpty);
      expect(s.ctes['c']!.columns, ['a', 'b']);
    });

    test('inside a CTE body the body tables are in scope', () {
      final s = at('WITH c AS (SELECT o.| FROM Orders o), d AS (SELECT * FROM Lines l) SELECT * FROM c');
      expect(s.resolve('o'), 'Orders');
      expect(s.aliases.containsKey('l'), isFalse);
    });

    test('correlated subquery sees the outer aliases, inner first', () {
      final s = at('SELECT * FROM Customers c WHERE EXISTS (SELECT 1 FROM Orders o WHERE o.CustomerId = |)');
      expect(s.tables, ['Orders', 'Customers']);
      expect(s.resolve('c'), 'Customers');
    });

    test('only the statement under the caret', () {
      final s = at('WITH x AS (SELECT 1 AS n) SELECT n FROM x;\nSELECT | FROM y');
      expect(s.ctes, isEmpty);
      expect(s.tables, ['y']);
    });

    test('quoted and qualified names, comma joins', () {
      final s = at('SELECT | FROM [dbo].[Order Lines] ol, "public"."users" AS u, `db`.`t`');
      expect(s.resolve('ol'), 'Order Lines');
      expect(s.resolve('u'), 'users');
      expect(s.tables.toSet(), {'Order Lines', 'users', 't'});
    });

    test('PostgreSQL / MySQL / Oracle style statements', () {
      expect(at('WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT | FROM r').ctes['r']!.columns, [
        'n',
      ]);
      expect(at('SELECT | FROM emp e JOIN dept d USING (deptno)').tables.toSet(), {'emp', 'dept'});
      expect(at('MERGE INTO tgt t USING src s ON (t.id = s.id) WHEN MATCHED THEN UPDATE SET t.|').resolve('s'), 'src');
    });
  });
}
