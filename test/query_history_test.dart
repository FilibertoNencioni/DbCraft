import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/drivers/recording_session.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session implements DbSession {
  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) async {
    if (sql == 'bad') throw StateError('boom');
    return ResultPage(columns: const [], rows: const [], rowsAffected: 2);
  }

  @override
  Future<void> commit() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('RecordingSession', () {
    test('reports statements, errors and commits', () async {
      final log = <(String, List<Object?>, int?, Object?)>[];
      final s = RecordingSession(_Session(), (sql, params, page, error, ms) {
        log.add((sql, params, page?.rowsAffected, error));
      });
      await s.execute('UPDATE t SET a = ?', params: [1]);
      await expectLater(s.execute('bad'), throwsStateError);
      await s.commit();
      expect(log.map((e) => e.$1), ['UPDATE t SET a = ?', 'bad', 'COMMIT']);
      expect(log[0].$2, [1]);
      expect(log[0].$3, 2);
      expect(log[1].$4, isA<StateError>());
    });
  });

  group('SqlDialect.inlineParams', () {
    test('replaces markers outside quotes', () {
      final d = SqlDialect(dbmsName: 'Microsoft SQL Server', quote: '[');
      expect(
        d.inlineParams("UPDATE [a?] SET \"b\" = ?, c = '?' WHERE id = ? AND n IS NULL", ['x?', 5]),
        "UPDATE [a?] SET \"b\" = 'x?', c = '?' WHERE id = 5 AND n IS NULL",
      );
    });
    test('null and unicode literals', () {
      final d = SqlDialect(dbmsName: 'Microsoft SQL Server', quote: '[');
      expect(d.inlineParams('INSERT INTO t VALUES (?, ?)', [null, 'è']), "INSERT INTO t VALUES (NULL, N'è')");
    });
  });
}
