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
}
