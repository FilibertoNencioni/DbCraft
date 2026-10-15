import 'package:dbcraft/services/sql_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('function calls keep the parenthesis attached', () {
    final out = SqlFormatter().format('select count(x), max( y ) from t where a in (1,2) and exists (select 1)');
    expect(out, contains('COUNT(x)'));
    expect(out, contains('MAX(y'));
    expect(out, contains('IN (1'));
    expect(out, contains('EXISTS ('));
  });
}
