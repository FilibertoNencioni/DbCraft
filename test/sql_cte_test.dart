import 'package:dbcraft/services/sql_cte.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('findCtes', () {
    test('multiple CTEs, explicit columns, aliases and stars', () {
      final ctes = findCtes('''
;WITH Sales AS (
  SELECT TOP (10) o.CustomerId, SUM(o.Total) AS Total, COUNT(*) cnt, Region = o.Area, [Order Date]
  FROM dbo.Orders o -- , fake AS (select 1)
  GROUP BY o.CustomerId
), Named (A, [B c]) AS (SELECT 1, 2),
All_ AS (SELECT s.*, c.* FROM Sales s JOIN Customers c ON c.Id = s.CustomerId)
SELECT * FROM Sales s JOIN Named n ON 1 = 1''');
      expect(ctes.map((c) => c.name), ['Sales', 'Named', 'All_']);
      expect(ctes[0].columns, ['CustomerId', 'Total', 'cnt', 'Region', 'Order Date']);
      expect(ctes[1].columns, ['A', 'B c']);
      expect(ctes[2].columns, isEmpty);
      expect(ctes[2].starSources, ['s', 'c']);
    });

    test('recursive, materialized, bare star, unclosed body', () {
      final ctes = findCtes(
        'WITH RECURSIVE t(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM t), '
        'm AS MATERIALIZED (SELECT DISTINCT * FROM x)\nSELECT * FROM m;\n'
        'with "Q" as (select a, case when b then 1 end from y',
      );
      expect(ctes.map((c) => c.name), ['t', 'm', 'Q']);
      expect(ctes[0].columns, ['n']);
      expect(ctes[1].starSources, [null]);
      expect(ctes[2].columns, ['a']);
    });

    test('ignores table hints and other WITH clauses', () {
      expect(
        findCtes(
          "SELECT * FROM t WITH (NOLOCK) WHERE a = 'with x as (select 1)';\n"
          'CREATE VIEW v WITH SCHEMABINDING AS SELECT 1;\n'
          'SELECT TOP 5 WITH TIES a FROM t ORDER BY a',
        ),
        isEmpty,
      );
    });
  });
}
