import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/drivers/recording_session.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/services/metadata_service.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/services/storage.dart';
import 'package:dbcraft/state/db_connection.dart';
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
  Future<void> rollback() async {}

  @override
  Future<void> setAutoCommit(bool value) async {}

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

  group('history of rolled back transactions', () {
    late List<HistoryEntry> history;
    late DbConnection dc;

    setUp(() {
      history = [];
      dc = DbConnection(ConnectionConfig(id: 'c', name: 'c'))
        ..onHistory = history.add
        ..onHistoryRolledBack = (entries, reason) {
          for (final e in entries) {
            final i = history.indexWhere((h) => identical(h, e));
            history[i] = HistoryEntry(
              sql: e.sql,
              connectionId: e.connectionId,
              connectionName: e.connectionName,
              time: e.time,
              durationMs: e.durationMs,
              rows: e.rows,
              error: reason,
            );
          }
        };
    });

    Map<String, String?> status() => {for (final h in history) h.sql: h.error};

    test('ROLLBACK marks the changes of the transaction, not the reads', () async {
      final s = dc.withHistory(_Session());
      await s.execute('INSERT INTO t VALUES (0)'); // auto-commit: confirmed
      await s.setAutoCommit(false);
      await s.execute('INSERT INTO t VALUES (1)');
      await s.execute('SELECT * FROM t');
      await s.rollback();
      expect(status(), {
        'INSERT INTO t VALUES (0)': null,
        'INSERT INTO t VALUES (1)': 'Annullata (rollback)',
        'SELECT * FROM t': null,
        'ROLLBACK': null,
      });
    });

    test('committed changes stay confirmed', () async {
      final s = dc.withHistory(_Session());
      await s.setAutoCommit(false);
      await s.execute('UPDATE t SET a = 1');
      await s.commit();
      await s.execute('UPDATE t SET a = 2');
      await s.rollback();
      expect(status()['UPDATE t SET a = 1'], isNull);
      expect(status()['UPDATE t SET a = 2'], 'Annullata (rollback)');
    });

    test('back to auto-commit confirms the pending changes', () async {
      final s = dc.withHistory(_Session());
      await s.setAutoCommit(false);
      await s.execute('DELETE FROM t');
      await s.setAutoCommit(true);
      await s.rollback();
      expect(status()['DELETE FROM t'], isNull);
    });

    test('session settings are not changes', () async {
      final s = dc.withHistory(_Session());
      await s.setAutoCommit(false);
      await s.execute('SET search_path TO x');
      await s.rollback();
      expect(status()['SET search_path TO x'], isNull);
    });

    test('DDL commits the transaction on MySQL', () async {
      dc.info = {'dbmsName': 'MySQL'};
      dc.metadata = MetadataService(_Session(), {'dbmsName': 'MySQL'});
      final s = dc.withHistory(_Session());
      await s.setAutoCommit(false);
      await s.execute('INSERT INTO t VALUES (1)');
      await s.execute('CREATE TABLE u (a INT)');
      await s.execute('INSERT INTO u VALUES (1)');
      await s.rollback();
      expect(status()['INSERT INTO t VALUES (1)'], isNull);
      expect(status()['CREATE TABLE u (a INT)'], isNull);
      expect(status()['INSERT INTO u VALUES (1)'], 'Annullata (rollback)');
    });

    test('each recorded session has its own transaction', () async {
      final a = dc.withHistory(_Session()), b = dc.withHistory(_Session());
      await a.setAutoCommit(false);
      await b.setAutoCommit(false);
      await a.execute('INSERT INTO a VALUES (1)');
      await b.execute('INSERT INTO b VALUES (1)');
      await b.rollback();
      expect(status()['INSERT INTO a VALUES (1)'], isNull);
      expect(status()['INSERT INTO b VALUES (1)'], 'Annullata (rollback)');
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
