import 'package:dbcraft/services/sql_dialect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schemaQualified omits only the implicit schema', () {
    final ms = SqlDialect(dbmsName: 'Microsoft SQL Server', quote: '[');
    expect(ms.schemaQualified('dbo', 'Orders'), 'Orders');
    expect(ms.schemaQualified('DBO', 'Orders'), 'Orders');
    expect(ms.schemaQualified('sales', 'Orders'), 'sales.Orders');
    expect(ms.schemaQualified('sales', 'Order Lines'), 'sales.[Order Lines]');
    expect(ms.schemaQualified(null, 'Orders'), 'Orders');

    final pg = SqlDialect(dbmsName: 'PostgreSQL');
    expect(pg.schemaQualified('public', 'orders'), 'orders');
    expect(pg.schemaQualified('sales', 'orders'), 'sales.orders');

    final ora = SqlDialect(dbmsName: 'Oracle');
    expect(ora.schemaQualified('HR', 'EMPLOYEES'), 'HR.EMPLOYEES');
  });
}
