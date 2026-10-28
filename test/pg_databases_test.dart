// Every database of a PostgreSQL server in one connection: the connection
// string per database and the session router (one session per database).
import 'package:dbcraft/drivers/database_router_session.dart';
import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/services/metadata_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A session bound to [database], like a PostgreSQL one: catalog functions
/// see only its own tables and report its name as TABLE_CAT.
class _DbSession implements DbSession {
  _DbSession(this.database, this.tables);

  final String database;
  final List<String> tables;
  final executed = <String>[];
  final catalogCalls = <List<String?>>[];
  bool autoCommit = true;
  int commits = 0, rollbacks = 0;
  bool closed = false;
  final _open = <int, List<List<Object?>>>{};
  var _next = 1;

  static final _cols = [ColumnInfo(index: 1, name: 'v', sqlType: 4, typeName: 'int4')];

  @override
  String get completedConnectionString => 'Database=$database';
  @override
  bool get isClosed => closed;
  @override
  bool get isBusy => false;

  /// `SELECT n`: 10 rows from n; `current_database()`: the name.
  @override
  Future<ResultPage> execute(String sql, {List<Object?> params = const [], int fetchSize = 200, int queryTimeoutSec = 0}) async {
    executed.add(sql);
    if (sql.contains('current_database')) {
      return ResultPage(columns: _cols, rows: [[database]]);
    }
    final from = int.tryParse(sql.replaceFirst('SELECT ', '')) ?? 0;
    final rows = [for (var i = 0; i < 10; i++) <Object?>[from + i]];
    if (rows.length <= fetchSize) return ResultPage(columns: _cols, rows: rows);
    final id = _next++;
    _open[id] = rows.sublist(fetchSize);
    return ResultPage(columns: _cols, rows: rows.sublist(0, fetchSize), hasMore: true, cursorId: id);
  }

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) async {
    final rest = _open.remove(cursorId)!;
    return ResultPage(columns: _cols, rows: rest);
  }

  @override
  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize) async => null;
  @override
  Future<void> closeCursor(int cursorId) async => _open.remove(cursorId);

  @override
  Future<ResultPage> catalog(String function, List<String?> args) async {
    catalogCalls.add(args);
    // Like psqlODBC: a catalog other than its own matches nothing.
    if ((args.firstOrNull ?? '').isNotEmpty && args.first != database) {
      return catalogResult(CatalogColumns.tables, []);
    }
    if (function == 'tables' && args.length > 1 && args[1] == '%' && args[0] == '') {
      return catalogResult(CatalogColumns.tables, [
        [null, 'public', null, null, null],
      ]);
    }
    if (function == 'foreignKeys') {
      return catalogResult(CatalogColumns.foreignKeys, [
        [null, 'public', 'a', 'id', null, 'public', 'b', 'a_id', 1, 3, 3, 'fk', null, 7],
      ]);
    }
    return catalogResult(CatalogColumns.tables, [
      for (final t in tables) [null, 'public', t, 'TABLE', null],
    ]);
  }

  @override
  Future<Map<String, Object?>> info() async => {
    'dbmsName': 'PostgreSQL',
    'catalogUsage': 1,
    'catalogSupported': 'Y',
    'catalogTerm': 'catalog',
    'schemaUsage': 29,
    'currentCatalog': '',
    'databaseName': '',
  };

  @override
  Future<void> setAutoCommit(bool value) async => autoCommit = value;
  @override
  Future<void> commit() async => commits++;
  @override
  Future<void> rollback() async => rollbacks++;
  @override
  Future<void> setCurrentCatalog(String catalog) async {}
  @override
  Future<String?> currentCatalog() async => '';
  @override
  void cancel() {}
  @override
  Future<void> close() async => closed = true;
}

void main() {
  group('ConnectionConfig.forDatabase', () {
    test('driver mode replaces the database and drops a DATABASE parameter', () {
      final c = ConnectionConfig(
        id: 'x',
        name: 'x',
        driver: 'PostgreSQL Unicode',
        host: 'h',
        database: 'first',
        extraParams: {'database': 'other', 'SSLMode': 'require'},
      );
      final s = c.forDatabase('SOSTEGNO_CASA').buildConnectionString();
      expect(s, contains('DATABASE=SOSTEGNO_CASA'));
      expect(s, isNot(contains('first')));
      expect(s, isNot(contains('other')));
      expect(s, contains('SSLMode=require'));
      expect(c.database, 'first', reason: 'the original stays as it was');
    });

    test('DSN mode adds DATABASE=', () {
      final c = ConnectionConfig(id: 'x', name: 'x', mode: ConnectionMode.dsn, dsn: 'pg');
      expect(c.forDatabase('db2').buildConnectionString(), 'DSN=pg;DATABASE=db2');
    });

    test('connection string mode replaces the Database or DBNAME keyword', () {
      final c = ConnectionConfig(
        id: 'x',
        name: 'x',
        mode: ConnectionMode.connectionString,
        connectionString: 'Driver={PostgreSQL Unicode};Server=h;dbname=first;Uid=u;',
      );
      expect(
        c.forDatabase('a;b').buildConnectionString(),
        'Driver={PostgreSQL Unicode};Server=h;Uid=u;Database={a;b}',
      );
    });

    test('allDatabases is on by default and saved', () {
      final c = ConnectionConfig.fromJson({'id': 'x', 'name': 'x'});
      expect(c.allDatabases, isTrue);
      final off = ConnectionConfig.fromJson({...c.toJson(), 'allDatabases': false});
      expect(ConnectionConfig.fromJson(off.toJson()).allDatabases, isFalse);
    });
  });

  group('DatabaseRouterSession', () {
    late Map<String, _DbSession> sessions;
    late List<String> opened;
    late DatabaseRouterSession router;
    late List<DbSession> bootstrapped;

    setUp(() {
      sessions = {
        'sa': _DbSession('sa', ['s1']),
        'shop': _DbSession('shop', ['orders', 'customers']),
        'HR': _DbSession('HR', ['employees']),
      };
      opened = [];
      bootstrapped = [];
      router = DatabaseRouterSession(
        sessions['sa']!,
        'sa',
        open: (db) async {
          opened.add(db);
          final s = sessions[db];
          if (s == null) throw StateError('database "$db" does not exist');
          return s;
        },
        listDatabases: (s) async => ['HR', 'sa', 'shop'],
        onOpened: (s) async => bootstrapped.add(s),
      );
    });

    test('reports the databases as catalogs', () async {
      final md = MetadataService(router, await router.info());
      expect(md.supportsCatalogs, isTrue);
      expect(md.currentCatalog, 'sa');
      expect(md.catalogTerm, 'Database');
      expect(await md.catalogs(), ['HR', 'sa', 'shop']);
      expect(opened, isEmpty, reason: 'listing needs no new session');
    });

    test('reads each database on its own session, also at the same time', () async {
      final md = MetadataService(router, await router.info());
      final r = await Future.wait([md.tables('shop', 'public'), md.tables('HR', 'public'), md.tables(null, 'public')]);
      expect(r[0].map((t) => '${t.catalog}.${t.name}'), ['shop.customers', 'shop.orders']);
      expect(r[1].map((t) => '${t.catalog}.${t.name}'), ['HR.employees']);
      expect(r[2].map((t) => '${t.catalog}.${t.name}'), ['sa.s1'], reason: 'no catalog: the current database');
      // The inner session never receives a catalog it does not know.
      expect(sessions['shop']!.catalogCalls.single.first, isNull);
      expect(await Future.wait([md.schemas('shop'), md.schemas('HR')]), [
        ['public'],
        ['public'],
      ]);
    });

    test('foreign keys follow the referencing table catalog', () async {
      final r = await router.catalog('foreignKeys', [null, null, null, 'HR', 'public', 'b']);
      expect(sessions['HR']!.catalogCalls, hasLength(1));
      expect(r.rows.single[0], 'HR');
      expect(r.rows.single[4], 'HR');
    });

    test('opens a database once, even when asked twice at once', () async {
      await Future.wait([router.sessionOf('shop'), router.sessionOf('shop')]);
      expect(opened, ['shop']);
      expect(bootstrapped, [sessions['shop']]);
      expect(router.openDatabases, unorderedEquals(['sa', 'shop']));
    });

    test('execute runs on the current database; a failing switch keeps it', () async {
      await router.execute('SELECT 1');
      await router.setCurrentCatalog('shop');
      expect(await router.currentCatalog(), 'shop');
      await router.execute('SELECT 2');
      expect(sessions['sa']!.executed, ['SELECT 1']);
      expect(sessions['shop']!.executed, ['SELECT 2']);
      await expectLater(router.setCurrentCatalog('missing'), throwsStateError);
      expect(router.current, 'shop');
    });

    test('a pinned session works on its database without moving the current one', () async {
      await router.pinned('HR').execute('SELECT 3');
      expect(sessions['HR']!.executed, ['SELECT 3']);
      expect(router.current, 'sa');
    });

    test('cursors stay with the session that opened them', () async {
      final a = await router.execute('SELECT 100', fetchSize: 4);
      await router.setCurrentCatalog('shop');
      final b = await router.execute('SELECT 200', fetchSize: 4);
      expect(a.cursorId, isNot(b.cursorId));
      final restA = await router.fetchMore(a.cursorId!, 100);
      final restB = await router.fetchMore(b.cursorId!, 100);
      expect(restA.rows.first.first, 104);
      expect(restB.rows.first.first, 204);
      expect(() => router.fetchMore(a.cursorId!, 1), throwsStateError, reason: 'closed with its last page');
    });

    test('auto-commit, commit and rollback reach every database', () async {
      await router.setAutoCommit(false);
      await router.setCurrentCatalog('shop');
      expect(sessions['shop']!.autoCommit, isFalse, reason: 'opened later in the same mode');
      await router.commit();
      await router.rollback();
      expect(sessions['sa']!.commits, 1);
      expect(sessions['shop']!.commits, 1);
      expect(sessions['shop']!.rollbacks, 1);
      expect(sessions['HR']!.commits, 0, reason: 'never opened');
    });

    test('closeDatabase closes one session and moves back to the initial one', () async {
      await router.setCurrentCatalog('shop');
      await router.closeDatabase('shop');
      expect(sessions['shop']!.closed, isTrue);
      expect(router.current, 'sa');
      await router.closeDatabase('sa');
      expect(sessions['sa']!.closed, isFalse, reason: 'the initial session stays');
    });

    test('close closes every session', () async {
      await router.sessionOf('HR');
      await router.close();
      expect(sessions['sa']!.closed && sessions['HR']!.closed, isTrue);
      expect(router.isClosed, isTrue);
      await expectLater(router.sessionOf('shop'), throwsStateError);
    });
  });
}
