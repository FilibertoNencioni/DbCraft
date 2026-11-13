import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/services/metadata_service.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/editors/sql_code_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

class _Session implements DbSession {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DbColumn _col(String name, int pos) =>
    DbColumn(name: name, dataType: 4, typeName: 'int', size: 10, decimals: 0, nullable: true, position: pos);

void main() {
  late DbConnection dc;
  late BuildContext context;

  setUp(() async {
    dc = DbConnection(ConnectionConfig(id: 'c', name: 'c'));
    final md = MetadataService(_Session(), {'dbmsName': 'Microsoft SQL Server'});
    dc.metadata = md;
    final orders = DbTable(catalog: 'shop', schema: 'dbo', name: 'Orders', type: 'TABLE');
    final customers = DbTable(catalog: 'shop', schema: 'dbo', name: 'Customers', type: 'TABLE');
    await md.cached<List<DbTable>>('tables:shop:dbo', () async => [customers, orders]);
    await md.cached<List<DbColumn>>(
      'columns:${orders.key}',
      () async => [_col('OrderId', 1), _col('CustomerId', 2), _col('Total', 3)],
    );
    await md.cached<List<DbColumn>>('columns:${customers.key}', () async => [_col('Id', 1), _col('Name', 2)]);
  });

  /// Words proposed at the `|` marker, in order.
  List<String> prompts(String sqlWithCaret) {
    final i = sqlWithCaret.indexOf('|');
    final text = sqlWithCaret.replaceFirst('|', '');
    final line = '\n'.allMatches(text.substring(0, i)).length;
    final lineStart = text.lastIndexOf('\n', i - 1) + 1;
    final lineEnd = text.indexOf('\n', i);
    final b = SqlPromptsBuilder(() => dc, () => text, enabled: () => true);
    final v = b.build(
      context,
      CodeLine(text.substring(lineStart, lineEnd < 0 ? text.length : lineEnd)),
      CodeLineSelection.collapsed(index: line, offset: i - lineStart),
    );
    return [for (final p in v?.prompts ?? const <CodePrompt>[]) p.word];
  }

  Future<void> withContext(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    context = tester.element(find.byType(SizedBox));
  }

  testWidgets('CTE columns are proposed first, even before FROM is written', (tester) async {
    await withContext(tester);
    final p = prompts('WITH c AS (SELECT Amount, CustomerName, [Order Date] FROM Orders)\nSELECT Cu|');
    expect(p.first, 'CustomerName');
    // Columns of the tables inside the CTE body are not in scope here.
    expect(p, isNot(contains('CustomerId')));
    expect(prompts('WITH c AS (SELECT Amount, [Order Date] FROM Orders)\nSELECT Ord|').first, contains('Order Date'));
  });

  testWidgets('columns of the CTE in FROM, through alias and SELECT *', (tester) async {
    await withContext(tester);
    expect(prompts('WITH c AS (SELECT * FROM Orders)\nSELECT x.| FROM c x'), ['OrderId', 'CustomerId', 'Total']);
    expect(prompts('WITH c AS (SELECT o.*, 1 AS Extra FROM Orders o)\nSELECT * FROM c WHERE c.E|'), ['Extra']);
    expect(
      prompts(';WITH c AS (SELECT CustomerId, SUM(Total) AS Total FROM Orders GROUP BY CustomerId)\nSELECT T| FROM c')
          .first,
      'Total',
    );
  });

  testWidgets('after FROM, CTEs come before tables, then keywords', (tester) async {
    await withContext(tester);
    final p = prompts('WITH OrderTotals AS (SELECT 1 AS n)\nSELECT * FROM O|');
    expect(p.take(2), ['OrderTotals', 'Orders']);
  });

  testWidgets('table columns in the select list and in WHERE', (tester) async {
    await withContext(tester);
    expect(prompts('SELECT Cu| FROM Orders').first, 'CustomerId');
    expect(prompts('SELECT * FROM Orders o JOIN Customers c ON c.Id = o.Cu|'), ['CustomerId']);
    expect(prompts('SELECT * FROM Customers WHERE N|').first, 'Name');
  });

  testWidgets('keywords first where a keyword is expected', (tester) async {
    await withContext(tester);
    expect(prompts('SELECT Name F|').first, 'FROM');
  });
}
