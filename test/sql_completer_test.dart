import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/services/sql_completion/completer.dart';
import 'package:dbcraft/services/sql_completion/ranking.dart';
import 'package:dbcraft/services/sql_completion/scope.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory catalog: Customers(Id, Name), Orders(OrderId, CustomerId, Total),
/// Order_Lines(Line_Id, Order_Id, Qty) with foreign keys Orders -> Customers
/// and Order_Lines -> Orders.
class FakeCatalog extends ChangeNotifier implements SqlCompletionCatalog {
  static DbTable _t(String name) => DbTable(catalog: 'shop', schema: 'dbo', name: name, type: 'TABLE');
  static DbColumn _c(String name, [String type = 'int']) =>
      DbColumn(name: name, dataType: 4, typeName: type, size: 10, decimals: 0, nullable: true, position: 0);

  final customers = _t('Customers'), orders = _t('Orders'), lines = _t('Order_Lines');

  /// Columns not "loaded" yet (null until [finishLoading]).
  final Set<String> slow = {};

  late final Map<String, List<DbColumn>> cols = {
    'Customers': [_c('Id'), _c('Name', 'varchar')],
    'Orders': [_c('OrderId'), _c('CustomerId'), _c('Total', 'decimal')],
    'Order_Lines': [_c('Line_Id'), _c('Order_Id'), _c('Qty')],
  };

  late final List<DbForeignKey> fks = [
    _fk('FK_Orders_Customers', orders, ['CustomerId'], customers, ['Id']),
    _fk('FK_Lines_Orders', lines, ['Order_Id'], orders, ['OrderId']),
  ];

  static DbForeignKey _fk(String name, DbTable child, List<String> c, DbTable parent, List<String> p) => DbForeignKey(
    name: name,
    pkCatalog: parent.catalog,
    pkSchema: parent.schema,
    pkTable: parent.name,
    fkCatalog: child.catalog,
    fkSchema: child.schema,
    fkTable: child.name,
    columns: c,
    refColumns: p,
  );

  void finishLoading() {
    slow.clear();
    notifyListeners();
  }

  @override
  Listenable get changes => this;
  @override
  bool get loading => slow.isNotEmpty;
  @override
  List<DbTable> get tables => [customers, lines, orders];
  @override
  DbTable? table(String name, {String? schema}) {
    for (final t in tables) {
      if (t.name.toLowerCase() == name.toLowerCase()) return t;
    }
    return null;
  }

  @override
  List<DbColumn>? columns(DbTable t) => slow.contains(t.name) ? null : cols[t.name];
  @override
  List<DbForeignKey>? foreignKeys(DbTable t) => [
    for (final f in fks)
      if (f.fkTable == t.name) f,
  ];
  @override
  List<DbForeignKey>? referencedBy(DbTable t) => [
    for (final f in fks)
      if (f.pkTable == t.name) f,
  ];
  @override
  String quote(String identifier) => RegExp(r'^[A-Za-z_]\w*$').hasMatch(identifier) ? identifier : '[$identifier]';
}

void main() {
  late FakeCatalog catalog;
  setUp(() => catalog = FakeCatalog());

  /// Proposals at the `|` marker (inserted text), in order.
  List<String> complete(String sqlWithCaret) {
    final i = sqlWithCaret.indexOf('|');
    final r = SqlCompleter(catalog).complete(sqlWithCaret.replaceFirst('|', ''), i);
    return [for (final it in r?.items ?? const <SqlCompletionItem>[]) it.insert];
  }

  group('matching', () {
    int? tier(String candidate, String input) => sqlMatch(candidate, input)?.tier;
    test('tiers', () {
      expect(tier('CustomerId', 'cust'), SqlMatch.prefix);
      expect(tier('CustomerId', 'id'), SqlMatch.wordStart);
      expect(tier('customer_id', 'id'), SqlMatch.wordStart);
      expect(tier('[Order Date]', 'da'), SqlMatch.wordStart);
      expect(tier('CustomerId', 'ci'), SqlMatch.initials);
      expect(tier('order_line_id', 'oli'), SqlMatch.initials);
      expect(tier('CustomerId', 'tom'), SqlMatch.contains);
      expect(tier('CustomerId', 'cstid'), SqlMatch.fuzzy);
      expect(tier('CustomerId', 'xyz'), isNull);
      expect(tier('CustomerId', 'customerid'), isNull);
      // Single characters only match prefixes.
      expect(tier('CustomerId', 'd'), isNull);
    });
    test('tighter fuzzy spans score higher', () {
      expect(sqlMatch('order_total', 'ord')!.tier, SqlMatch.prefix);
      expect(sqlMatch('cXsXd', 'csd')!.fine, greaterThan(sqlMatch('cXXXXsXXXd', 'csd')!.fine));
    });
  });

  group('ranking', () {
    test('expected kind first, good matches before weak ones', () {
      final p = complete('SELECT id| FROM Orders o JOIN Customers c ON c.Id = o.CustomerId');
      // `Id` is already typed; word-start matches of the columns come before
      // keywords such as IDENTITY (prefix match of another kind).
      expect(p, isNot(contains('Id')));
      expect(p.take(2), ['OrderId', 'CustomerId']);
      expect(p.indexOf('IDENTITY'), greaterThan(p.indexOf('CustomerId')));
    });
    test('initials and fuzzy find columns', () {
      expect(complete('SELECT ci| FROM Orders'), contains('CustomerId'));
      expect(complete('SELECT cstid| FROM Orders').first, 'CustomerId');
    });
  });

  group('CTE visibility', () {
    test('inside a CTE body only previous CTEs (and itself) are visible', () {
      const sql = 'WITH a AS (SELECT 1 AS x), b AS (SELECT | FROM a), c AS (SELECT 2 AS y) SELECT * FROM c';
      final s = sqlCompletionScope(sql.replaceFirst('|', ''), sql.indexOf('|'));
      expect(s.ctes.keys, ['a', 'b']);
      expect(s.allCtes.keys, ['a', 'b', 'c']);
    });
    test('main query sees every CTE', () {
      const sql = 'WITH a AS (SELECT 1 AS x), b AS (SELECT 2 AS y) SELECT * FROM |';
      expect(sqlCompletionScope(sql.replaceFirst('|', ''), sql.indexOf('|')).ctes.keys, ['a', 'b']);
    });
  });

  group('loading', () {
    test('placeholder while columns load, real items afterwards', () {
      catalog.slow.add('Orders');
      final r = SqlCompleter(catalog).complete('SELECT x. FROM Orders x', 9)!;
      expect(r.items.single.kind, SqlItemKind.loading);
      expect(r.items.single.insert, r.input);
      catalog.finishLoading();
      expect(complete('SELECT x.| FROM Orders x'), ['OrderId', 'CustomerId', 'Total']);
    });
    test('no placeholder when nothing is loading', () {
      expect(complete('SELECT x.| FROM Unknown x'), isEmpty);
    });
  });

  group('joins', () {
    test('after JOIN: related tables with alias and ON from the foreign keys', () {
      final p = complete('SELECT * FROM Orders o JOIN |');
      // Input is empty: nothing is proposed until a letter is typed.
      expect(p, isEmpty);
      final c = complete('SELECT * FROM Orders o JOIN C|');
      expect(c.first, 'Customers c ON c.Id = o.CustomerId');
      final l = complete('SELECT * FROM Orders o JOIN Ord|');
      expect(l.first, 'Order_Lines ol ON ol.Order_Id = o.OrderId');
      expect(l, contains('Orders'));
    });
    test('generated alias does not clash with the ones in use', () {
      expect(complete('SELECT * FROM Orders c JOIN Cu|').first, 'Customers c2 ON c2.Id = c.CustomerId');
    });
    test('after ON: foreign key conditions, then same-name key columns', () {
      final p = complete('SELECT * FROM Orders o JOIN Customers c ON c|');
      expect(p.first, 'c.Id = o.CustomerId');
      final l = complete('SELECT * FROM Order_Lines l JOIN Orders o ON o|');
      expect(l.first, 'o.OrderId = l.Order_Id');
    });
  });

  group('star expansion', () {
    test('single table: plain column list', () {
      expect(complete('SELECT *| FROM Customers'), ['Id, Name']);
    });
    test('several tables or x.*: qualified columns', () {
      expect(
        complete('SELECT *| FROM Customers c JOIN Orders o ON o.CustomerId = c.Id').single,
        'c.Id, c.Name, o.OrderId, o.CustomerId, o.Total',
      );
      expect(
        complete('SELECT c.Name, o.*| FROM Customers c JOIN Orders o ON o.CustomerId = c.Id').single,
        'o.OrderId, o.CustomerId, o.Total',
      );
    });
    test('only in the select list', () {
      expect(complete('SELECT COUNT(*| FROM Customers'), isEmpty);
      expect(complete('SELECT a *| FROM Customers'), isEmpty);
      expect(complete('SELECT *|'), isEmpty);
    });
  });

  group('document words and usage', () {
    test('words of the script the catalog does not know', () {
      final p = complete('SELECT * INTO #tmp_sales FROM Orders;\nSELECT * FROM #tmp| ');
      expect(p, contains('#tmp_sales'));
      // Names proposed otherwise are not repeated as words.
      expect(complete('SELECT Total FROM Orders WHERE To|').where((w) => w == 'Total'), hasLength(1));
    });
    test('names used more in the history come first among equals', () {
      final items = [
        [const SqlCompletionItem('TotalA', SqlItemKind.column), const SqlCompletionItem('TotalB', SqlItemKind.column)],
      ];
      expect(rankCompletions('to', items).first.insert, 'TotalA');
      final stats = SqlUsageStats(() => ['SELECT TotalB FROM t', 'SELECT totalb, x FROM t']);
      expect(stats.count('totalb'), 2);
      expect(rankCompletions('to', items, usage: stats.count).first.insert, 'TotalB');
    });
  });
}
