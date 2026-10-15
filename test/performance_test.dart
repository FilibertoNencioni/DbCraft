import 'package:dbcraft/features/performance/perf_metrics.dart';
import 'package:dbcraft/features/performance/perf_providers.dart';
import 'package:dbcraft/features/performance/plan_model.dart';
import 'package:dbcraft/features/performance/plan_runner.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:flutter_test/flutter_test.dart';

const _pgPlan = '''
[
  {
    "Plan": {
      "Node Type": "Hash Join", "Join Type": "Inner", "Startup Cost": 10.0, "Total Cost": 120.0,
      "Plan Rows": 100, "Plan Width": 8, "Actual Startup Time": 0.5, "Actual Total Time": 30.0,
      "Actual Rows": 5000, "Actual Loops": 1, "Hash Cond": "(o.customer_id = c.id)",
      "Plans": [
        {
          "Node Type": "Seq Scan", "Parent Relationship": "Outer", "Relation Name": "orders", "Schema": "public",
          "Alias": "o", "Startup Cost": 0.0, "Total Cost": 80.0, "Plan Rows": 50000, "Actual Startup Time": 0.01,
          "Actual Total Time": 20.0, "Actual Rows": 50000, "Actual Loops": 1, "Filter": "(total > 10)",
          "Shared Hit Blocks": 10, "Shared Read Blocks": 90
        },
        {
          "Node Type": "Hash", "Parent Relationship": "Inner", "Startup Cost": 5.0, "Total Cost": 5.0,
          "Plan Rows": 10, "Actual Startup Time": 1.0, "Actual Total Time": 1.0, "Actual Rows": 10, "Actual Loops": 1,
          "Hash Batches": 4,
          "Plans": [
            {
              "Node Type": "Sort", "Startup Cost": 1.0, "Total Cost": 4.0, "Plan Rows": 10,
              "Actual Startup Time": 0.5, "Actual Total Time": 0.8, "Actual Rows": 10, "Actual Loops": 1,
              "Sort Key": ["c.id"], "Sort Method": "external merge", "Sort Space Used": 2048, "Sort Space Type": "Disk"
            }
          ]
        }
      ]
    },
    "Planning Time": 0.2,
    "Execution Time": 31.5
  }
]
''';

const _myPlan = '''
{
  "query_block": {
    "select_id": 1,
    "cost_info": {"query_cost": "1210.50"},
    "ordering_operation": {
      "using_filesort": true,
      "nested_loop": [
        {"table": {"table_name": "o", "access_type": "ALL", "rows_examined_per_scan": 20000,
                   "rows_produced_per_join": 20000, "filtered": "100.00",
                   "cost_info": {"read_cost": "100.00", "eval_cost": "1000.00", "prefix_cost": "1100.00"},
                   "attached_condition": "(o.total > 10)"}},
        {"table": {"table_name": "c", "access_type": "eq_ref", "possible_keys": ["PRIMARY"], "key": "PRIMARY",
                   "rows_examined_per_scan": 1, "cost_info": {"read_cost": "100.00", "eval_cost": "10.50",
                   "prefix_cost": "1210.50"}}}
      ]
    }
  }
}
''';

const _ssPlan = '''
<?xml version="1.0" encoding="utf-16"?>
<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.5" Build="16.0.1000.6">
  <BatchSequence><Batch><Statements>
    <StmtSimple StatementText="SELECT * FROM dbo.Orders WHERE CustomerId = 5" StatementId="1" StatementType="SELECT"
                StatementSubTreeCost="12.5" StatementEstRows="40">
      <QueryPlan DegreeOfParallelism="1" CachedPlanSize="16">
        <MissingIndexes>
          <MissingIndexGroup Impact="93.5">
            <MissingIndex Database="[Shop]" Schema="[dbo]" Table="[Orders]">
              <ColumnGroup Usage="EQUALITY"><Column Name="[CustomerId]" ColumnId="2"/></ColumnGroup>
              <ColumnGroup Usage="INCLUDE"><Column Name="[Total]" ColumnId="3"/></ColumnGroup>
            </MissingIndex>
          </MissingIndexGroup>
        </MissingIndexes>
        <RelOp NodeId="0" PhysicalOp="Parallelism" LogicalOp="Gather Streams" EstimateRows="40"
               EstimatedTotalSubtreeCost="12.5">
          <Parallelism>
            <RelOp NodeId="1" PhysicalOp="Clustered Index Scan" LogicalOp="Clustered Index Scan" EstimateRows="40"
                   EstimatedTotalSubtreeCost="12.0" TableCardinality="250000">
              <Warnings><ColumnsWithNoStatistics><ColumnReference Column="[Total]"/></ColumnsWithNoStatistics></Warnings>
              <RunTimeInformation>
                <RunTimeCountersPerThread Thread="0" ActualRows="3000" ActualExecutions="1" ActualElapsedms="80"/>
              </RunTimeInformation>
              <IndexScan Ordered="0">
                <Object Database="[Shop]" Schema="[dbo]" Table="[Orders]" Index="[PK_Orders]"/>
                <Predicate><ScalarOperator ScalarString="[Shop].[dbo].[Orders].[CustomerId]=(5)"/></Predicate>
              </IndexScan>
            </RelOp>
          </Parallelism>
        </RelOp>
      </QueryPlan>
    </StmtSimple>
  </Statements></Batch></BatchSequence>
</ShowPlanXML>
''';

void main() {
  group('PostgreSQL JSON plan', () {
    final t = parsePostgresJsonPlan(_pgPlan);

    test('tree, objects and summary', () {
      expect(t.root.operation, 'Hash Join');
      expect(t.root.children, hasLength(2));
      final scan = t.root.children.first;
      expect(scan.operation, 'Seq Scan');
      expect(scan.object, 'public.orders o');
      expect(scan.detail, 'Filter: (total > 10)');
      expect(scan.buffers, 100);
      expect(t.summary['Execution Time'], '31.5');
      expect(t.analyzed, isTrue);
      expect(t.nodes.map((n) => n.id), [0, 1, 2, 3]);
    });

    test('exclusive time drives the share', () {
      final scan = t.root.children.first;
      expect(scan.selfTimeMs, closeTo(20, 1e-9));
      // root: 30 - 20 - 1 = 9 ms self.
      expect(t.root.selfTimeMs, closeTo(9, 1e-9));
      final total = t.nodes.fold<double>(0, (a, n) => a + n.share);
      expect(total, closeTo(1, 1e-9));
      expect(scan.share, greaterThan(0.6));
    });

    test('warnings: mismatch, big seq scan, disk sort, hash batches', () {
      final all = t.allWarnings.map((e) => e.$2.message).join('\n');
      expect(all, contains('Stima delle righe errata'));
      expect(all, contains('Scansione completa su una tabella grande'));
      expect(all, contains('Ordinamento su disco'));
      expect(all, contains('4 batch'));
    });

    test('estimated plan without actuals uses cost shares', () {
      final p = parsePostgresJsonPlan(
        '[{"Plan": {"Node Type": "Aggregate", "Strategy": "Hashed", "Total Cost": 10, "Plan Rows": 1, '
        '"Plans": [{"Node Type": "Index Scan", "Relation Name": "t", "Index Name": "t_pk", "Total Cost": 8, '
        '"Plan Rows": 5, "Join Type": "Left"}]}}]',
      );
      expect(p.root.operation, 'HashAggregate');
      expect(p.root.selfCost, 2);
      expect(p.root.children.first.share, closeTo(0.8, 1e-9));
      expect(p.root.children.first.object, 't (indice t_pk)');
      expect(p.analyzed, isFalse);
    });
  });

  group('MySQL JSON plan', () {
    test('nested loop, sort and tables', () {
      final t = parseMySqlJsonPlan(_myPlan);
      expect(t.root.operation, 'Query block #1');
      final sort = t.root.children.single;
      expect(sort.operation, 'Sort (filesort)');
      final loop = sort.children.single;
      expect(loop.operation, 'Nested loop');
      expect(loop.children.map((e) => e.operation), ['Full table scan', 'Unique key lookup']);
      final scan = loop.children.first;
      expect(scan.selfCost, 1100);
      expect(scan.rowsEstimated, 20000);
      expect(scan.warnings.map((w) => w.message).join(), contains('Nessun indice'));
      expect(scan.warnings.map((w) => w.message).join(), contains('Scansione completa'));
      expect(loop.children.last.object, 'c (indice PRIMARY)');
      expect(t.root.cost, closeTo(1210.5, 1e-9));
    });

    test('format version 2', () {
      final t = parseMySqlJsonPlan(
        '{"query": "select 1", "operation": "Filter: (t.a > 1)", "estimated_rows": 3, "estimated_total_cost": 5,'
        ' "inputs": [{"operation": "Table scan on t", "table_name": "t", "access_type": "table",'
        ' "estimated_rows": 30, "estimated_total_cost": 4}]}',
      );
      expect(t.root.children.single.object, 't');
      expect(t.root.selfCost, 1);
    });
  });

  group('SQL Server showplan XML', () {
    final t = parseSqlServerShowplan(_ssPlan);

    test('statement, operators and object', () {
      expect(t.root.operation, 'SELECT');
      final par = t.root.children.single;
      expect(par.operation, 'Parallelism (Gather Streams)');
      final scan = par.children.single;
      expect(scan.operation, 'Clustered Index Scan');
      expect(scan.object, 'dbo.Orders (indice PK_Orders)');
      expect(scan.detail, '[Shop].[dbo].[Orders].[CustomerId]=(5)');
      expect(scan.rowsActual, 3000);
      expect(scan.timeMs, 80);
      expect(t.summary['Versione'], '16.0.1000.6');
    });

    test('missing index and warnings', () {
      expect(t.warnings, hasLength(1));
      expect(t.warnings.first.message, contains('93.5'));
      expect(t.warnings.first.suggestion, contains('ON [dbo].[Orders] ([CustomerId])'));
      expect(t.warnings.first.suggestion, contains('INCLUDE ([Total])'));
      final scan = t.root.children.single.children.single;
      final msgs = scan.warnings.map((w) => w.message).join('\n');
      expect(msgs, contains('Colonne senza statistiche: [Total]'));
      expect(msgs, contains('Stima delle righe errata'));
      expect(msgs, contains('tabella grande'));
    });
  });

  group('row based plans', () {
    test('SQLite EXPLAIN QUERY PLAN tree', () {
      final t = parseSqlitePlan(
        ['id', 'parent', 'notused', 'detail'],
        [
          [2, 0, 0, 'SCAN orders'],
          [5, 0, 0, 'SEARCH customers USING INTEGER PRIMARY KEY (rowid=?)'],
          [9, 0, 0, 'USE TEMP B-TREE FOR ORDER BY'],
          [12, 5, 0, 'CORRELATED SCALAR SUBQUERY 1'],
        ],
      );
      expect(t.root.operation, 'Query');
      expect(t.root.children, hasLength(3));
      expect(t.root.children[1].children.single.operation, 'CORRELATED SCALAR SUBQUERY 1');
      expect(t.root.children.first.fullScan, isTrue);
      expect(t.root.children.first.warnings, isNotEmpty);
      expect(t.root.children[1].warnings, isEmpty);
      expect(t.root.children[2].warnings.single.level, PlanWarningLevel.info);
    });

    test('Oracle plan table', () {
      final t = parseOraclePlan(
        ['ID', 'PARENT_ID', 'OPERATION', 'OPTIONS', 'OBJECT_OWNER', 'OBJECT_NAME', 'COST', 'CARDINALITY'],
        [
          [0, null, 'SELECT STATEMENT', null, null, null, '30', '100'],
          [1, 0, 'HASH JOIN', null, null, null, '30', '100'],
          [2, 1, 'TABLE ACCESS', 'FULL', 'HR', 'EMPLOYEES', '20', '50000'],
          [3, 1, 'INDEX', 'RANGE SCAN', 'HR', 'DEPT_IX', '5', '10'],
        ],
      );
      expect(t.root.operation, 'SELECT STATEMENT');
      final join = t.root.children.single;
      expect(join.children.map((e) => e.operation), ['TABLE ACCESS FULL', 'INDEX RANGE SCAN']);
      expect(join.children.first.object, 'HR.EMPLOYEES');
      expect(join.selfCost, 5);
      expect(join.children.first.warnings.single.message, contains('Scansione completa'));
    });

    test('treeFromRows with several roots adds a synthetic root', () {
      final root = treeFromRows([(1, null, PlanNode(operation: 'a')), (2, null, PlanNode(operation: 'b'))]);
      expect(root.operation, 'Query');
      expect(root.children, hasLength(2));
    });
  });

  test('layout places children below and inside the canvas', () {
    final t = parsePostgresJsonPlan(_pgPlan);
    final l = layoutPlan(t.root, width: (_) => 100, height: 50, hGap: 10, vGap: 20, margin: 10);
    final root = l.rects[t.root]!;
    final a = l.rects[t.root.children[0]]!, b = l.rects[t.root.children[1]]!;
    expect(a.top, root.bottom + 20);
    expect(b.left, greaterThanOrEqualTo(a.right + 10));
    expect(root.center.dx, closeTo((a.center.dx + b.center.dx) / 2, 1e-9));
    for (final r in l.rects.values) {
      expect(r.right, lessThanOrEqualTo(l.size.width));
      expect(r.bottom, lessThanOrEqualTo(l.size.height));
    }
    expect(planToText(t), contains('-> Seq Scan · public.orders o'));
  });

  test('plan helpers', () {
    expect(cleanPlanSql('select 1;  '), 'select 1');
    expect(postgresExplainSql('select 1;', analyze: true), 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) select 1');
    expect(visualPlanSupported(DbFamily.sqlite), isTrue);
    expect(visualPlanSupported(DbFamily.mongodb), isFalse);
    expect(planAnalyzeSupported(DbFamily.mysql), isFalse);
    expect(estimateRatio(10, 1000), closeTo(1001 / 11, 1e-9));
  });

  group('metrics', () {
    test('sample buffer keeps the last samples', () {
      final b = SampleBuffer(3);
      for (final v in [1.0, 2.0, null, 4.0, double.nan]) {
        b.add(v);
      }
      expect(b.values, [null, 4.0, null]);
      expect(b.last, 4);
      expect(b.length, 3);
      b.add(9);
      expect(b.values, [4.0, null, 9.0]);
      expect(b.min, 4);
      expect(b.max, 9);
    });

    test('rate per second from counters', () {
      final t0 = DateTime(2026, 1, 1, 10);
      final a = CounterSnapshot(t0, {'commit': 100, 'rollback': 10});
      final b = CounterSnapshot(t0.add(const Duration(seconds: 5)), {'commit': 150, 'rollback': 20});
      expect(ratePerSec(null, b, ['commit']), isNull);
      expect(ratePerSec(a, b, ['commit', 'rollback']), 12);
      expect(ratePerSec(a, b, ['missing']), isNull);
      // Counter reset.
      final c = CounterSnapshot(t0.add(const Duration(seconds: 10)), {'commit': 5, 'rollback': 0});
      expect(ratePerSec(b, c, ['commit']), isNull);
      expect(ratePerSec(b, b, ['commit']), isNull);
    });

    test('hit ratio over the interval and cumulative fallback', () {
      final t0 = DateTime(2026);
      final a = CounterSnapshot(t0, {'hit': 900, 'read': 100});
      final b = CounterSnapshot(t0.add(const Duration(seconds: 1)), {'hit': 990, 'read': 110});
      expect(hitRatio(a, b, 'hit', 'read'), 90);
      expect(hitRatio(b, b, 'hit', 'read'), closeTo(990 * 100 / 1100, 1e-9));
      expect(hitRatio(null, a, 'hit', 'read'), 90);
    });

    test('provider KPIs compute from snapshots', () {
      final p = PerfProvider.forFamily(DbFamily.postgres)!;
      final t0 = DateTime(2026);
      final a = CounterSnapshot(t0, {'xact_commit': 10, 'xact_rollback': 0, 'active': 2});
      final b = CounterSnapshot(t0.add(const Duration(seconds: 2)), {
        'xact_commit': 30,
        'xact_rollback': 2,
        'active': 3,
      });
      final tps = p.kpis.firstWhere((k) => k.id == 'tps');
      expect(tps.compute(b, a), 11);
      expect(p.kpis.firstWhere((k) => k.id == 'active').compute(b, a), 3);
      expect(PerfProvider.forFamily(DbFamily.sqlite), isNull);
      for (final f in [DbFamily.sqlServer, DbFamily.mysql, DbFamily.oracle]) {
        final pp = PerfProvider.forFamily(f)!;
        expect(pp.tables.first.id, 'sessions');
        expect(pp.tables.first.actions, isNotNull);
      }
    });

    test('counter query mapping', () {
      const pairs = CounterQuery.pairs(['x']);
      expect(
        pairs.map(
          ['Variable_name', 'Value'],
          [
            ['Questions', '120'],
            ['Threads_running', 3],
          ],
        ),
        {'questions': 120, 'threads_running': 3},
      );
      const row = CounterQuery.row(['x']);
      expect(
        row.map(
          ['TOTAL', 'active', 'name'],
          [
            [5, '2', 'x'],
          ],
        ),
        {'total': 5, 'active': 2},
      );
    });

    test('kill statements', () {
      final pg = PerfProvider.forFamily(DbFamily.postgres)!.tables.first.actions!;
      expect(pg.terminate({'pid': 42}), 'SELECT pg_terminate_backend(42)');
      expect(pg.cancel!({'pid': '42'}), 'SELECT pg_cancel_backend(42)');
      final my = PerfProvider.forFamily(DbFamily.mysql)!.tables.first.actions!;
      expect(my.cancel!({'id': 7}), 'KILL QUERY 7');
      final ora = PerfProvider.forFamily(DbFamily.oracle)!.tables.first.actions!;
      expect(ora.terminate({'sid': 12, 'serial': '345'}), "ALTER SYSTEM KILL SESSION '12,345' IMMEDIATE");
      final ss = PerfProvider.forFamily(DbFamily.sqlServer)!.tables.first.actions!;
      expect(ss.terminate({'sessione': 55}), 'KILL 55');
      expect(ss.cancel, isNull);
    });

    test('blocking tree', () {
      final tree = buildBlockingTree([
        BlockingEntry('3', parseBlockers('{1}'), const []),
        BlockingEntry('4', parseBlockers('3'), const []),
        BlockingEntry('5', parseBlockers('1, 3'), const []),
        BlockingEntry('1', parseBlockers('0'), const []),
        BlockingEntry('9', parseBlockers('8'), const []),
      ]);
      expect(tree.map((n) => '${n.entry.id}@${n.depth}'), ['1@0', '3@1', '4@2', '5@2', '8@0', '9@1']);
      expect(tree.first.blockedCount, 3);
      expect(tree.firstWhere((n) => n.entry.id == '8').entry.row, isNull);
      // Cycle (deadlock): both emitted once.
      final cyc = buildBlockingTree([
        BlockingEntry('a', ['b'], null),
        BlockingEntry('b', ['a'], null),
      ]);
      expect(cyc.map((n) => n.entry.id).toSet(), {'a', 'b'});
      expect(parseBlockers(null), isEmpty);
      expect(parseBlockers(12.0), ['12']);
    });

    test('formatting', () {
      expect(formatBytes(1536), '1,5 KB');
      expect(formatBytes(10 * 1024 * 1024 * 1024), '10,0 GB');
      expect(formatSeconds(75), '1m 15s');
      expect(formatSeconds(3 * 3600 + 120), '3h 02m');
      expect(formatNumber(1234567.891, decimals: 2), '1.234.567,89');
      expect(formatCompact(15300), '15,3k');
      expect(columnKind('durata_s'), ColKind.seconds);
      expect(columnKind('totale_ms'), ColKind.millis);
      expect(columnKind('dati_b'), ColKind.bytes);
      expect(columnKind('query'), ColKind.query);
      expect(columnLabel('righe_stimate'), 'righe stimate');
      expect(columnLabel('medio_ms'), 'medio (ms)');
      expect(formatCell(90, ColKind.seconds), '1m 30s');
      expect(formatCell('select  1\n from t', ColKind.query), 'select 1 from t');
    });
  });
}
