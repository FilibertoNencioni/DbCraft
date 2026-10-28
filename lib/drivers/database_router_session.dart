// One session per database, behind a single DbSession, for DBMS whose
// sessions are bound to one database (PostgreSQL): switching the current
// catalog moves to the session of that database, opened on first use.
import '../odbc/odbc_types.dart';
import 'db_session.dart';

/// Opens a session on a database (the connection with another database).
typedef DatabaseOpener = Future<DbSession> Function(String database);

/// Lists the databases of the server through one of the sessions.
typedef DatabaseLister = Future<List<String>> Function(DbSession session);

/// A [DbSession] that keeps one inner session per database.
///
/// - [execute] runs on the session of the [current] database, which
///   [setCurrentCatalog] switches (opening the session if needed).
/// - [catalog] runs on the session of the catalog named in its arguments, so
///   that reading two databases at once never mixes them up; the
///   "all catalogs" call ([SQL_ALL_CATALOGS]) lists the databases instead.
/// - [setAutoCommit], [commit] and [rollback] apply to every open session;
///   sessions opened later get the same auto-commit mode.
/// - Cursor ids are the router's own: each maps to the session that opened
///   it, wherever [current] moved since.
///
/// [pinned] gives a session that always works on one database (design
/// catalog queries, metadata of a given database).
class DatabaseRouterSession implements DbSession {
  DatabaseRouterSession(
    DbSession initial,
    this.initialDatabase, {
    required DatabaseOpener open,
    required DatabaseLister listDatabases,
    Future<void> Function(DbSession session)? onOpened,
  }) : _openDatabase = open,
       _list = listDatabases,
       _afterOpen = onOpened,
       _current = initialDatabase {
    _sessions[initialDatabase] = initial;
  }

  /// The database the connection opened first.
  final String initialDatabase;
  final DatabaseOpener _openDatabase;
  final DatabaseLister _list;
  final Future<void> Function(DbSession session)? _afterOpen;

  final Map<String, DbSession> _sessions = {};
  final Map<String, Future<DbSession>> _opening = {};
  String _current;
  bool? _autoCommit;
  bool _closed = false;

  /// Router cursor id → (session, cursor id in that session).
  final Map<int, (DbSession, int)> _cursors = {};
  var _nextCursor = 1;

  /// Database [execute] runs on.
  String get current => _current;

  /// Databases with an open session.
  Iterable<String> get openDatabases => _sessions.keys;

  DbSession get _initial => _sessions[initialDatabase]!;

  /// The session of [database], opened on first use. Concurrent callers
  /// share the same opening.
  Future<DbSession> sessionOf(String database) async {
    if (_closed) throw StateError('Sessione chiusa');
    final open = _sessions[database];
    if (open != null) return open;
    return _opening[database] ??= () async {
      try {
        final s = await _openDatabase(database);
        if (_autoCommit == false) await s.setAutoCommit(false);
        await _afterOpen?.call(s);
        if (_closed) {
          await s.close();
          throw StateError('Sessione chiusa');
        }
        _sessions[database] = s;
        return s;
      } finally {
        _opening.remove(database);
      }
    }();
  }

  /// A session working on [database] only.
  DbSession pinned(String database) => _PinnedSession(this, database);

  /// Closes the session of [database] (before dropping it). The current
  /// database moves back to the initial one.
  Future<void> closeDatabase(String database) async {
    if (database == initialDatabase) return;
    final s = _sessions.remove(database);
    _cursors.removeWhere((_, v) => identical(v.$1, s));
    if (_current == database) _current = initialDatabase;
    await s?.close();
  }

  ResultPage _track(DbSession s, ResultPage page, [int? id]) {
    final inner = page.cursorId;
    if (inner == null) {
      if (id != null) _cursors.remove(id);
      return page;
    }
    final mine = id ?? _nextCursor++;
    _cursors[mine] = (s, inner);
    return _withCursor(page, mine);
  }

  (DbSession, int) _cursor(int id) {
    final c = _cursors[id];
    if (c == null) throw StateError('Cursore $id non valido');
    return c;
  }

  Future<ResultPage> _execute(
    String database,
    String sql, {
    required List<Object?> params,
    required int fetchSize,
    required int queryTimeoutSec,
  }) async {
    final s = await sessionOf(database);
    final page = await s.execute(sql, params: params, fetchSize: fetchSize, queryTimeoutSec: queryTimeoutSec);
    return _track(s, page);
  }

  Future<ResultPage> _catalog(String? database, String function, List<String?> args) async {
    if (function == 'tables' && _allCatalogs(args)) {
      final names = await _list(_initial);
      return catalogResult(CatalogColumns.tables, [
        for (final n in names) [n, null, null, null, null],
      ]);
    }
    String? named(int i) => i < args.length && (args[i] ?? '').isNotEmpty ? args[i] : null;
    // SQLForeignKeys names the referenced table first, the referencing one
    // at index 3.
    final fk = function == 'foreignKeys';
    final db = database ?? named(0) ?? (fk ? named(3) : null) ?? _current;
    final s = await sessionOf(db);
    // The session knows only its own database: drop the catalog arguments
    // and put the database back in the rows.
    final local = [
      for (var i = 0; i < args.length; i++) i == 0 || (fk && i == 3) ? (args[i] == '' ? '' : null) : args[i],
    ];
    final page = await s.catalog(function, local);
    final catColumns = [0, if (fk) 4];
    return ResultPage(
      columns: page.columns,
      rows: [
        for (final r in page.rows)
          [
            for (var i = 0; i < r.length; i++)
              catColumns.contains(i) && (r[i] == null || r[i] == '') ? db : r[i],
          ],
      ],
      hasMore: page.hasMore,
      rowsAffected: page.rowsAffected,
      elapsedMs: page.elapsedMs,
      messages: page.messages,
    );
  }

  /// SQLTables(SQL_ALL_CATALOGS, "", "", "").
  static bool _allCatalogs(List<String?> args) =>
      args.length >= 4 && args[0] == '%' && args[1] == '' && args[2] == '' && (args[3] ?? '') == '';

  // ---------------------------------------------------------------------------
  // DbSession
  // ---------------------------------------------------------------------------

  @override
  String get completedConnectionString => _initial.completedConnectionString;

  @override
  bool get isClosed => _closed;

  @override
  bool get isBusy => _sessions.values.any((s) => s.isBusy);

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) => _execute(_current, sql, params: params, fetchSize: fetchSize, queryTimeoutSec: queryTimeoutSec);

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) async {
    final (s, inner) = _cursor(cursorId);
    return _track(s, await s.fetchMore(inner, count), cursorId);
  }

  @override
  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize) async {
    final (s, inner) = _cursor(cursorId);
    final page = await s.nextResultSet(inner, fetchSize);
    if (page == null) {
      _cursors.remove(cursorId);
      return null;
    }
    return _track(s, page, cursorId);
  }

  @override
  Future<void> closeCursor(int cursorId) async {
    final c = _cursors.remove(cursorId);
    if (c != null) await c.$1.closeCursor(c.$2);
  }

  @override
  Future<ResultPage> catalog(String function, List<String?> args) => _catalog(null, function, args);

  /// The initial session's information, reporting databases as catalogs.
  @override
  Future<Map<String, Object?>> info() async => {
    ...await _initial.info(),
    'catalogSupported': 'Y',
    'catalogUsage': 1,
    'catalogTerm': 'Database',
    'currentCatalog': _current,
    'databaseName': _current,
  };

  @override
  Future<void> setAutoCommit(bool value) async {
    _autoCommit = value;
    for (final s in _sessions.values.toList()) {
      await s.setAutoCommit(value);
    }
  }

  @override
  Future<void> commit() async {
    for (final s in _sessions.values.toList()) {
      await s.commit();
    }
  }

  @override
  Future<void> rollback() async {
    for (final s in _sessions.values.toList()) {
      await s.rollback();
    }
  }

  @override
  Future<void> setCurrentCatalog(String catalog) async {
    await sessionOf(catalog);
    _current = catalog;
  }

  @override
  Future<String?> currentCatalog() async => _current;

  @override
  void cancel() {
    for (final s in _sessions.values) {
      if (s.isBusy) s.cancel();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _cursors.clear();
    final all = _sessions.values.toList();
    _sessions.clear();
    await Future.wait(all.map((s) => s.close()));
  }
}

ResultPage _withCursor(ResultPage p, int id) => ResultPage(
  columns: p.columns,
  rows: p.rows,
  hasMore: p.hasMore,
  cursorId: id,
  rowsAffected: p.rowsAffected,
  elapsedMs: p.elapsedMs,
  messages: p.messages,
  hasNextResultSet: p.hasNextResultSet,
);

/// The router working on one database: [execute] and [catalog] always go to
/// the session of [database]; cursors and transactions are the router's.
class _PinnedSession implements DbSession {
  _PinnedSession(this.router, this.database);

  final DatabaseRouterSession router;
  final String database;

  @override
  String get completedConnectionString => router.completedConnectionString;
  @override
  bool get isClosed => router.isClosed;
  @override
  bool get isBusy => router._sessions[database]?.isBusy ?? false;

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) => router._execute(database, sql, params: params, fetchSize: fetchSize, queryTimeoutSec: queryTimeoutSec);

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) => router.fetchMore(cursorId, count);
  @override
  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize) => router.nextResultSet(cursorId, fetchSize);
  @override
  Future<void> closeCursor(int cursorId) => router.closeCursor(cursorId);

  @override
  Future<ResultPage> catalog(String function, List<String?> args) => router._catalog(database, function, args);

  @override
  Future<Map<String, Object?>> info() async => {...await router.info(), 'currentCatalog': database, 'databaseName': database};

  @override
  Future<void> setAutoCommit(bool value) => router.setAutoCommit(value);
  @override
  Future<void> commit() => router.commit();
  @override
  Future<void> rollback() => router.rollback();

  /// Pinned: the database does not change.
  @override
  Future<void> setCurrentCatalog(String catalog) async {}
  @override
  Future<String?> currentCatalog() async => database;

  @override
  void cancel() => router._sessions[database]?.cancel();

  /// The router owns the sessions.
  @override
  Future<void> close() async {}
}
