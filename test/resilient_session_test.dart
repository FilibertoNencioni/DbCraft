import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/drivers/resilient_session.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:flutter_test/flutter_test.dart';

OdbcException _gone() => OdbcException('SQLExecDirect', const [
  OdbcDiag('HY000', 4031, '[ma-3.2.10][8.4.3]The client was disconnected by the server because of inactivity.'),
]);

/// Fake session: [dead] makes every call fail as a dropped connection.
class _Session implements DbSession {
  _Session(this.n);

  final int n;
  bool dead = false;
  bool closed = false;
  bool? autoCommit;
  String? currentDb;
  final executed = <String>[];
  var commits = 0, rollbacks = 0;

  static final _cols = [ColumnInfo(index: 1, name: 'v', sqlType: 4, typeName: 'int')];

  void _check() {
    if (dead) throw _gone();
  }

  @override
  String get completedConnectionString => 'session $n';
  @override
  bool get isClosed => closed;
  @override
  bool get isBusy => false;

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) async {
    _check();
    executed.add(sql);
    if (sql.startsWith('SELECT big')) {
      return ResultPage(
        columns: _cols,
        rows: [
          [n],
        ],
        hasMore: true,
        cursorId: 1,
      );
    }
    return ResultPage(
      columns: sql.startsWith('SELECT') ? _cols : const [],
      rows: [
        if (sql.startsWith('SELECT')) [n],
      ],
    );
  }

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) async {
    _check();
    return ResultPage(
      columns: _cols,
      rows: [
        [cursorId],
      ],
    );
  }

  @override
  Future<void> closeCursor(int cursorId) async => _check();
  @override
  Future<ResultPage> catalog(String function, List<String?> args) async {
    _check();
    return ResultPage(
      columns: _cols,
      rows: [
        [n],
      ],
    );
  }

  @override
  Future<void> setAutoCommit(bool value) async {
    _check();
    autoCommit = value;
  }

  @override
  Future<void> commit() async {
    _check();
    commits++;
  }

  @override
  Future<void> rollback() async {
    _check();
    rollbacks++;
  }

  @override
  Future<void> setCurrentCatalog(String catalog) async {
    _check();
    currentDb = catalog;
  }

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<_Session> opened;
  late List<bool> lost;
  late List<_Session> bootstrapped;

  ResilientSession make({String? Function()? hint}) {
    opened = [_Session(0)];
    lost = [];
    bootstrapped = [];
    return ResilientSession(
      opened.first,
      reopen: () async => (opened..add(_Session(opened.length))).last,
      isReadOnly: isReadOnlySql,
      pingSql: 'SELECT 1',
      onReopened: (s) async => bootstrapped.add(s as _Session),
      catalogHint: hint,
      onTransactionLost: lost.add,
    );
  }

  group('isConnectionLost', () {
    OdbcException e(String state, int native, String msg) => OdbcException('x', [OdbcDiag(state, native, msg)]);
    test('recognizes the errors of the drivers', () {
      expect(isConnectionLost(_gone()), isTrue);
      expect(isConnectionLost(e('08S01', 2013, 'Lost connection to server during query')), isTrue);
      expect(isConnectionLost(e('08003', 0, 'Connection not open')), isTrue);
      expect(isConnectionLost(e('HY000', 2006, '[MySQL][ODBC 8.0(w) Driver]MySQL server has gone away')), isTrue);
      expect(isConnectionLost(e('57P05', 35, 'FATAL: terminating connection due to idle-session timeout')), isTrue);
      expect(
        isConnectionLost(e('25P03', 108, 'FATAL: terminating connection due to idle-in-transaction timeout')),
        isTrue,
      );
      expect(
        isConnectionLost(e('HY000', 3113, '[Oracle][ODBC][Ora]ORA-03113: end-of-file on communication channel')),
        isTrue,
      );
    });
    test('ignores ordinary errors', () {
      expect(isConnectionLost(e('42S02', 1146, "Table 'x' doesn't exist")), isFalse);
      expect(isConnectionLost(e('23000', 1062, 'Duplicate entry')), isFalse);
      expect(isConnectionLost(e('HY000', 2013, 'Some other driver message')), isFalse);
      expect(isConnectionLost(StateError('x')), isFalse);
    });
  });

  group('isReadOnlySql', () {
    test('only plain reads run again', () {
      expect(isReadOnlySql('SELECT * FROM t'), isTrue);
      expect(isReadOnlySql('-- c\nWITH x AS (SELECT 1) SELECT * FROM x'), isTrue);
      expect(isReadOnlySql('SHOW TABLES'), isTrue);
      expect(isReadOnlySql('UPDATE t SET a = 1'), isFalse);
      expect(isReadOnlySql('WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x'), isFalse);
      expect(isReadOnlySql('SELECT * INTO t2 FROM t'), isFalse);
      expect(isReadOnlySql('SELECT * FROM t FOR UPDATE'), isFalse);
      expect(isReadOnlySql('EXPLAIN ANALYZE DELETE FROM t'), isFalse);
      expect(isReadOnlySql('SET wait_timeout = 3'), isFalse);
    });
  });

  group('ResilientSession', () {
    test('reopens and runs a read again with the same settings', () async {
      final s = make();
      await s.setCurrentCatalog('shop');
      opened.first.dead = true;
      final r = await s.execute('SELECT 1');
      expect(r.rows, [
        [1],
      ]);
      expect(opened, hasLength(2));
      expect(opened.first.closed, isTrue);
      expect(opened[1].currentDb, 'shop');
      expect(bootstrapped, [opened[1]]);
      expect(s.reconnections, 1);
      expect(lost, isEmpty);
    });

    test('the catalog hint wins over the last catalog set', () async {
      var current = 'a';
      final s = make(hint: () => current);
      await s.setCurrentCatalog('a');
      current = 'b'; // USE b in a script
      opened.first.dead = true;
      await s.execute('SELECT 1');
      expect(opened[1].currentDb, 'b');
    });

    test('does not run a modifying statement again', () async {
      final s = make();
      opened.first.dead = true;
      await expectLater(
        s.execute('UPDATE t SET a = 1'),
        throwsA(isA<ConnectionLostException>().having((e) => e.transactionLost, 'transactionLost', isFalse)),
      );
      expect(opened, hasLength(2));
      expect(opened[1].executed, isEmpty);
      // The session works again.
      await s.execute('UPDATE t SET a = 1');
      expect(opened[1].executed, ['UPDATE t SET a = 1']);
    });

    test('reports a lost manual transaction and keeps manual commit', () async {
      final s = make();
      await s.setAutoCommit(false);
      await s.execute('INSERT INTO t VALUES (1)');
      opened.first.dead = true;
      await expectLater(
        s.commit(),
        throwsA(isA<ConnectionLostException>().having((e) => e.transactionLost, 'transactionLost', isTrue)),
      );
      expect(lost, [true]);
      expect(opened[1].autoCommit, isFalse);
      expect(opened[1].commits, 0);
      // A new transaction commits normally.
      await s.execute('INSERT INTO t VALUES (2)');
      await s.commit();
      expect(opened[1].commits, 1);
    });

    test('a read in a dirty transaction is not run on a new one', () async {
      final s = make();
      await s.setAutoCommit(false);
      await s.execute('DELETE FROM t');
      opened.first.dead = true;
      await expectLater(s.execute('SELECT 1'), throwsA(isA<ConnectionLostException>()));
      expect(opened[1].executed, isEmpty);
      expect(lost, [true]);
    });

    test('manual commit without changes reconnects transparently', () async {
      final s = make();
      await s.setAutoCommit(false);
      await s.execute('SELECT 1');
      opened.first.dead = true;
      expect((await s.execute('SELECT 2')).rows, [
        [1],
      ]);
      await s.commit();
      expect(lost, isEmpty);
    });

    test('rollback of a lost transaction succeeds', () async {
      final s = make();
      await s.setAutoCommit(false);
      await s.execute('UPDATE t SET a = 1');
      opened.first.dead = true;
      await s.rollback();
      expect(lost, [true]);
    });

    test('cursors of a lost session are not confused with new ones', () async {
      final s = make();
      final old = await s.execute('SELECT big');
      opened.first.dead = true;
      final fresh = await s.execute('SELECT big');
      expect(fresh.cursorId, isNot(old.cursorId));
      await expectLater(s.fetchMore(old.cursorId!, 10), throwsA(isA<ConnectionLostException>()));
      await s.closeCursor(old.cursorId!); // no-op
      expect((await s.fetchMore(fresh.cursorId!, 10)).rows, [
        [1],
      ]);
    });

    test('ping keeps the session alive and reopens a lost one', () async {
      final s = make();
      await s.ping();
      expect(opened.first.executed, ['SELECT 1']);
      opened.first.dead = true;
      await s.ping();
      expect(opened, hasLength(2));
      expect(lost, isEmpty);
    });

    test('ping in manual commit: only with pending changes, loss noticed', () async {
      final s = make();
      await s.setAutoCommit(false);
      expect(s.wantsPing, isFalse);
      await s.execute('UPDATE t SET a = 1');
      expect(s.wantsPing, isTrue);
      opened.first.dead = true;
      await s.ping();
      expect(lost, [false]);
      expect(s.wantsPing, isFalse);
    });

    test('a failing reopen leaves the session usable later', () async {
      var fail = true;
      final first = _Session(0);
      final s = ResilientSession(
        first,
        reopen: () async {
          if (fail) throw StateError('server down');
          return _Session(1);
        },
        isReadOnly: isReadOnlySql,
      );
      first.dead = true;
      await expectLater(s.execute('SELECT 1'), throwsA(isA<ConnectionLostException>()));
      fail = false;
      expect((await s.execute('SELECT 1')).rows, [
        [1],
      ]);
    });
  });
}
