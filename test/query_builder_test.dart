import 'package:dbcraft/features/query_builder/query_model.dart';
import 'package:dbcraft/features/query_builder/visual_filter.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DbTable _t(String name, {String? schema}) => DbTable(catalog: null, schema: schema, name: name, type: 'TABLE');

QbColumn _c(String name, {int type = 12, bool key = false}) => QbColumn(name: name, sqlType: type, isKey: key);

DbForeignKey _fk(String fkTable, String col, String pkTable, String ref) => DbForeignKey(
  name: 'fk_${fkTable}_$pkTable',
  pkCatalog: null,
  pkSchema: null,
  pkTable: pkTable,
  fkCatalog: null,
  fkSchema: null,
  fkTable: fkTable,
  columns: [col],
  refColumns: [ref],
);

/// dipendenti(id, nome, stipendio, reparto_id → reparti.id), reparti(id, nome)
QueryModel _employees() {
  final m = QueryModel();
  m.addTable(
    _t('dipendenti'),
    [
      _c('id', type: 4, key: true),
      _c('nome'),
      _c('stipendio', type: 3),
      _c('assunto', type: 91),
      _c('reparto_id', type: 4),
    ],
    foreignKeys: [_fk('dipendenti', 'reparto_id', 'reparti', 'id')],
  );
  m.addTable(_t('reparti'), [_c('id', type: 4, key: true), _c('nome')]);
  return m;
}

void main() {
  final pg = SqlDialect(dbmsName: 'PostgreSQL');
  final sqlite = SqlDialect(dbmsName: 'SQLite');
  final mssql = SqlDialect(dbmsName: 'Microsoft SQL Server');
  final oracle = SqlDialect(dbmsName: 'Oracle');
  final db2 = SqlDialect(dbmsName: 'DB2/LINUXX8664');
  final firebird = SqlDialect(dbmsName: 'Firebird');

  group('QueryModel', () {
    test('auto aliases and FK joins', () {
      final m = _employees();
      expect(m.tables.map((t) => t.alias), ['t1', 't2']);
      expect(m.joins, hasLength(1));
      final j = m.joins.single;
      expect(m.byId(j.leftId)!.table.name, 'reparti');
      expect(j.leftColumn, 'id');
      expect(m.byId(j.rightId)!.table.name, 'dipendenti');
      expect(j.rightColumn, 'reparto_id');
    });

    test('FK join is found when the referencing table is added second', () {
      final m = QueryModel();
      m.addTable(_t('reparti'), [_c('id', type: 4)]);
      m.addTable(
        _t('dipendenti'),
        [_c('id', type: 4), _c('reparto_id', type: 4)],
        foreignKeys: [_fk('dipendenti', 'reparto_id', 'reparti', 'id')],
      );
      expect(m.joins, hasLength(1));
    });

    test('same table twice gets distinct aliases and no automatic self join', () {
      final m = QueryModel();
      m.addTable(_t('a'), [_c('id')]);
      m.addTable(_t('a'), [_c('id')]);
      expect(m.tables.map((t) => t.alias), ['t1', 't2']);
      expect(m.joins, isEmpty);
    });

    test('removeTable drops joins and fields', () {
      final m = _employees();
      m.toggleColumn(m.tables[1].id, 'nome');
      m.removeTable(m.tables[1].id);
      expect(m.joins, isEmpty);
      expect(m.fields, isEmpty);
    });

    test('toggleColumn keeps conditions', () {
      final m = _employees();
      final id = m.tables[0].id;
      m.toggleColumn(id, 'nome');
      m.fields.single.filterOp = FilterOp.eq;
      m.toggleColumn(id, 'nome');
      expect(m.fields.single.output, isFalse);
      expect(m.isSelected(id, 'nome'), isFalse);
    });
  });

  group('QuerySqlGenerator', () {
    test('empty model', () {
      expect(QuerySqlGenerator(pg).generate(QueryModel()), '');
    });

    test('select star with join', () {
      final m = _employees();
      expect(
        QuerySqlGenerator(pg).generate(m),
        'SELECT * FROM dipendenti t1 INNER JOIN reparti t2 ON t2.id = t1.reparto_id',
      );
    });

    test('columns, aliases, join types flip when needed', () {
      final m = _employees();
      final d = m.tables[0], r = m.tables[1];
      m.toggleColumn(d.id, 'nome');
      m.toggleColumn(r.id, 'nome');
      m.fields[1].alias = 'reparto';
      // Stored as reparti LEFT JOIN dipendenti: dipendenti comes first, so
      // the generator must emit RIGHT JOIN reparti.
      m.joins.single.type = JoinType.left;
      expect(
        QuerySqlGenerator(pg).generate(m),
        'SELECT t1.nome, t2.nome AS reparto FROM dipendenti t1 RIGHT JOIN reparti t2 ON t2.id = t1.reparto_id',
      );
    });

    test('aggregates produce GROUP BY and HAVING', () {
      final m = _employees();
      final d = m.tables[0], r = m.tables[1];
      m.fields.addAll([
        QbField(tableId: r.id, column: 'nome', alias: 'reparto'),
        QbField(tableId: d.id, column: 'id', aggregate: Aggregate.count, alias: 'n'),
        QbField(
          tableId: d.id,
          column: 'stipendio',
          aggregate: Aggregate.avg,
          alias: 'media',
          filterOp: FilterOp.gt,
          value: '1500,5',
          sort: SortDir.desc,
        ),
      ]);
      expect(
        QuerySqlGenerator(pg).generate(m),
        'SELECT t2.nome AS reparto, COUNT(t1.id) AS n, AVG(t1.stipendio) AS media '
        'FROM dipendenti t1 INNER JOIN reparti t2 ON t2.id = t1.reparto_id '
        'GROUP BY t2.nome HAVING AVG(t1.stipendio) > 1500.5 ORDER BY AVG(t1.stipendio) DESC',
      );
    });

    test('count distinct and COUNT(*) expression', () {
      final m = QueryModel();
      final t = m.addTable(_t('t'), [_c('a')]);
      m.fields.addAll([
        QbField(tableId: t.id, column: 'a', aggregate: Aggregate.countDistinct),
        QbField(expression: '*', aggregate: Aggregate.count, alias: 'tot'),
      ]);
      expect(QuerySqlGenerator(pg).generate(m), 'SELECT COUNT(DISTINCT t1.a), COUNT(*) AS tot FROM t t1');
    });

    test('filters and literals', () {
      final m = _employees();
      final d = m.tables[0];
      m.fields.addAll([
        QbField(tableId: d.id, column: 'nome', filterOp: FilterOp.like, value: "D'Ar", output: false),
        QbField(tableId: d.id, column: 'id', filterOp: FilterOp.inList, value: '1, 2,3', output: false),
        QbField(tableId: d.id, column: 'nome', filterOp: FilterOp.inList, value: "'a,b', c", output: false),
        QbField(
          tableId: d.id,
          column: 'stipendio',
          filterOp: FilterOp.between,
          value: '10',
          value2: '20',
          output: false,
        ),
        QbField(tableId: d.id, column: 'reparto_id', filterOp: FilterOp.isNull, output: false),
        QbField(tableId: d.id, column: 'assunto', filterOp: FilterOp.ge, value: '2024-01-01', output: false),
        QbField(tableId: d.id, column: 'assunto', filterOp: FilterOp.lt, value: '=CURRENT_DATE', output: false),
        // Incomplete conditions are ignored.
        QbField(tableId: d.id, column: 'id', filterOp: FilterOp.eq, value: '', output: false),
      ]);
      final sql = QuerySqlGenerator(sqlite).generate(m);
      expect(
        sql,
        'SELECT * FROM dipendenti t1 INNER JOIN reparti t2 ON t2.id = t1.reparto_id WHERE '
        "t1.nome LIKE '%D''Ar%' AND t1.id IN (1, 2, 3) AND t1.nome IN ('a,b', 'c') "
        'AND t1.stipendio BETWEEN 10 AND 20 AND t1.reparto_id IS NULL '
        "AND t1.assunto >= '2024-01-01' AND t1.assunto < CURRENT_DATE",
      );
      final ora = QuerySqlGenerator(oracle).generate(m);
      expect(ora, contains('"t1"."assunto" >= DATE \'2024-01-01\''));
    });

    test('quoting of identifiers', () {
      final m = QueryModel();
      final t = m.addTable(_t('order details', schema: 'Sales'), [_c('Unit Price'), _c('select')]);
      m.toggleColumn(t.id, 'Unit Price');
      m.toggleColumn(t.id, 'select');
      m.fields.first.alias = 'prezzo unitario';
      expect(
        QuerySqlGenerator(sqlite).generate(m),
        'SELECT t1."Unit Price" AS "prezzo unitario", t1."select" FROM Sales."order details" t1',
      );
      expect(
        QuerySqlGenerator(SqlDialect(dbmsName: 'Microsoft SQL Server', quote: '[')).generate(m),
        'SELECT t1.[Unit Price] AS [prezzo unitario], t1.[select] FROM Sales.[order details] t1',
      );
    });

    test('limit per dialect', () {
      QueryModel model({bool distinct = false}) {
        final m = QueryModel();
        final t = m.addTable(_t('t'), [_c('a')]);
        m.toggleColumn(t.id, 'a');
        m.limit = 10;
        m.distinct = distinct;
        return m;
      }

      expect(QuerySqlGenerator(pg).generate(model()), 'SELECT t1.a FROM t t1 LIMIT 10');
      expect(QuerySqlGenerator(mssql).generate(model(distinct: true)), 'SELECT DISTINCT TOP 10 t1.a FROM t t1');
      expect(QuerySqlGenerator(oracle).generate(model()), 'SELECT "t1"."a" FROM "t" "t1" FETCH FIRST 10 ROWS ONLY');
      expect(QuerySqlGenerator(db2).generate(model()), endsWith('FETCH FIRST 10 ROWS ONLY'));
      expect(QuerySqlGenerator(firebird).generate(model(distinct: true)), startsWith('SELECT FIRST 10 DISTINCT '));
    });

    test('pretty layout', () {
      final m = _employees();
      m.toggleColumn(m.tables[0].id, 'nome');
      m.toggleColumn(m.tables[1].id, 'nome');
      m.fields[0].filterOp = FilterOp.isNotNull;
      m.fields[1].filterOp = FilterOp.eq;
      m.fields[1].value = 'IT';
      m.limit = 5;
      expect(
        QuerySqlGenerator(pg).generate(m, pretty: true),
        'SELECT\n    t1.nome,\n    t2.nome\n'
        'FROM dipendenti t1\nINNER JOIN reparti t2 ON t2.id = t1.reparto_id\n'
        "WHERE t1.nome IS NOT NULL\n    AND t2.nome = 'IT'\n"
        'LIMIT 5',
      );
    });

    test('disconnected tables use CROSS JOIN and sort order is honoured', () {
      final m = QueryModel();
      final a = m.addTable(_t('a'), [_c('x')]);
      final b = m.addTable(_t('b'), [_c('y')]);
      m.fields.addAll([
        QbField(tableId: a.id, column: 'x', sort: SortDir.asc, sortOrder: 2),
        QbField(tableId: b.id, column: 'y', sort: SortDir.desc, sortOrder: 1),
      ]);
      expect(QuerySqlGenerator(pg).generate(m), 'SELECT t1.x, t2.y FROM a t1 CROSS JOIN b t2 ORDER BY t2.y DESC, t1.x');
    });

    test('three tables are ordered so that every join references placed tables', () {
      final m = QueryModel();
      final a = m.addTable(_t('a'), [_c('id')], autoJoin: false);
      final b = m.addTable(_t('b'), [_c('id')], autoJoin: false);
      final c = m.addTable(_t('c'), [_c('a_id'), _c('b_id')], autoJoin: false);
      m.joins.addAll([
        QbJoin(leftId: c.id, leftColumn: 'a_id', rightId: a.id, rightColumn: 'id'),
        QbJoin(leftId: c.id, leftColumn: 'b_id', rightId: b.id, rightColumn: 'id', type: JoinType.left),
      ]);
      expect(
        QuerySqlGenerator(pg).generate(m),
        'SELECT * FROM a t1 INNER JOIN c t3 ON t3.a_id = t1.id LEFT JOIN b t2 ON t3.b_id = t2.id',
      );
    });
  });

  group('Visual filter', () {
    test('where and order by', () {
      final f = VisualFilter()
        ..conditions.addAll([
          FilterCondition(column: 'nome', kind: ValueKind.text, op: FilterOp.like, value: 'ros'),
          FilterCondition(column: 'stipendio', kind: ValueKind.number, op: FilterOp.ge, value: '1000'),
          FilterCondition(column: 'email', kind: ValueKind.text, op: FilterOp.isNotNull),
        ])
        ..sort.add(const SortKey('Cognome', descending: true));
      expect(f.whereSql(sqlite), "nome LIKE '%ros%' AND stipendio >= 1000 AND email IS NOT NULL");
      expect(f.orderSql(sqlite), 'Cognome DESC');
      expect(f.orderSql(pg), '"Cognome" DESC');
    });

    test('operators per kind', () {
      expect(FilterOp.forKind(ValueKind.number), isNot(contains(FilterOp.like)));
      expect(FilterOp.forKind(ValueKind.text), contains(FilterOp.like));
      expect(valueKindOf(12, 'DATE'), ValueKind.date);
      expect(valueKindOf(12, 'VARCHAR'), ValueKind.text);
      expect(valueKindOf(93, 'TIMESTAMP'), ValueKind.timestamp);
      expect(valueKindOf(4, 'INTEGER'), ValueKind.number);
    });

    test('typed literals', () {
      expect(typedLiteral(oracle, '2024-03-01 10:00', ValueKind.timestamp), "TIMESTAMP '2024-03-01 10:00'");
      expect(typedLiteral(pg, 'sì', ValueKind.boolean), 'TRUE');
      expect(typedLiteral(mssql, 'sì', ValueKind.boolean), '1');
      expect(typedLiteral(pg, 'abc', ValueKind.number), "'abc'");
    });
  });

  testWidgets('visual filter bar adds a chip through the popover', (tester) async {
    final f = VisualFilter();
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (ctx, set) => VisualFilterBar(
              filter: f,
              columns: const [
                FilterColumn('nome', ValueKind.text, 'VARCHAR'),
                FilterColumn('assunto', ValueKind.date, 'DATE'),
              ],
              onChanged: () => set(() => changes++),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Aggiungi filtro'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'ros');
    await tester.pump();
    await tester.tap(find.text('Aggiungi').last);
    await tester.pumpAndSettle();
    expect(f.conditions.single.label, 'nome contiene "ros"');
    expect(find.text('nome contiene "ros"'), findsOneWidget);
    expect(changes, 1);
  });
}
