// Session decorator that survives the loss of the connection: servers drop
// idle sessions (MySQL wait_timeout, PostgreSQL idle_session_timeout, Oracle
// IDLE_TIME…) and so do firewalls, NATs and load balancers.
//
// When an operation fails because the connection is gone, the session is
// reopened with the same auto-commit mode, current catalog and bootstrap
// queries. Read-only statements and metadata calls are then run again;
// statements that may modify data are not, and a manual transaction with
// pending changes is reported as lost instead of silently continuing on a
// new (empty) transaction.
//
// [ping] keeps an idle session (and its open transaction) alive.
import 'dart:async';

import '../odbc/odbc_types.dart';
import 'db_session.dart';

/// The connection to the server was lost. [transactionLost]: the server
/// rolled back the manual transaction that had pending changes.
class ConnectionLostException implements Exception {
  ConnectionLostException(this.message, {this.transactionLost = false, this.cause});

  final String message;
  final bool transactionLost;
  final Object? cause;

  @override
  String toString() => message;
}

/// Message shown when a manual transaction is lost with the connection.
const transactionLostMessage =
    'Connessione al server persa: la transazione in corso è stata annullata dal server e le modifiche '
    'non confermate sono andate perse. La connessione è stata ristabilita.';

const _sqlStates = {
  '57P01', '57P02', '57P03', // PostgreSQL: admin / crash shutdown, cannot connect now
  '57P05', // PostgreSQL: idle_session_timeout
  '25P03', // PostgreSQL: idle_in_transaction_session_timeout
};

/// MySQL / MariaDB: server has gone away, lost connection during query,
/// lost connection (SSL), disconnected because of inactivity (8.0.24+).
const _mysqlErrors = {2006, 2013, 2055, 4031};

final _oracleErrors = RegExp(r'ORA-(00028|01012|02396|03113|03114|03135|12152|12537|12547|12570|12571)\b');

final _lostMessages = RegExp(
  r'gone away|lost connection|connection lost|connection not open|communication link failure|'
  r'server closed the connection unexpectedly|terminating connection|connection is dead',
  caseSensitive: false,
);

/// Whether [e] means the connection to the server is gone.
bool isConnectionLost(Object e) {
  if (e is ConnectionLostException) return true;
  if (e is! OdbcException) return false;
  for (final d in e.diagnostics) {
    final state = d.sqlState.toUpperCase();
    if (state.startsWith('08') || _sqlStates.contains(state)) return true;
    final msg = d.message.toLowerCase();
    if (_mysqlErrors.contains(d.nativeError) &&
        (msg.contains('mysql') || msg.contains('mariadb') || msg.contains('[ma-'))) {
      return true;
    }
    if (_oracleErrors.hasMatch(d.message) || _lostMessages.hasMatch(d.message)) return true;
  }
  return false;
}

class ResilientSession implements DbSession {
  ResilientSession(
    DbSession inner, {
    required this.reopen,
    required this.isReadOnly,
    this.onReopened,
    this.catalogHint,
    this.onTransactionLost,
    this.pingSql,
  }) : _inner = inner;

  /// Opens a new session like the lost one.
  final Future<DbSession> Function() reopen;

  /// Whether a statement only reads (it may run again after a reconnection
  /// and does not make the manual transaction dirty).
  final bool Function(String sql) isReadOnly;

  /// Runs on a reopened session before it replaces the lost one (bootstrap
  /// queries).
  final Future<void> Function(DbSession session)? onReopened;

  /// Catalog to restore on a reopened session when the owner knows better
  /// than the last [setCurrentCatalog] (`USE xxx` in a script).
  final String? Function()? catalogHint;

  /// The manual transaction with pending changes was lost. [reported]: the
  /// caller got a [ConnectionLostException] saying so.
  final void Function(bool reported)? onTransactionLost;

  /// Statement run by [ping]; null disables it.
  final String? pingSql;

  DbSession _inner;
  int _generation = 0;
  Future<void>? _reopening;
  bool _closed = false;
  bool _pinging = false;
  bool? _autoCommit;
  String? _catalog;

  /// A manual transaction has statements that may have changed data.
  bool _dirty = false;
  DateTime _lastActivity = DateTime.now();

  /// The current underlying session.
  DbSession get inner => _inner;

  /// Number of times the session was reopened.
  int get reconnections => _generation;

  /// Time since the last operation (including pings).
  Duration get idleFor => DateTime.now().difference(_lastActivity);

  /// Whether [ping] has something to keep alive: in manual commit mode only
  /// a transaction with pending changes (a ping would otherwise open a
  /// transaction for nothing; an idle session lost meanwhile is reopened
  /// without consequences).
  bool get wantsPing => pingSql != null && (_autoCommit != false || _dirty);

  @override
  String get completedConnectionString => _inner.completedConnectionString;
  @override
  bool get isClosed => _closed;
  @override
  bool get isBusy => _pinging ? false : (_inner.isBusy || _reopening != null);

  // ---------------------------------------------------------------------------
  // Recovery
  // ---------------------------------------------------------------------------

  /// Runs [op] on the current session. When the connection is lost the
  /// session is reopened, then [op] runs again if [retry] allows it.
  /// [lossOk]: with no pending changes, a lost connection already gives the
  /// outcome of [op] (commit / rollback of nothing). [txLossOk]: losing the
  /// pending changes is what the caller asked for (rollback).
  Future<T> _run<T>(
    Future<T> Function(DbSession s, int generation) op, {
    bool retry = false,
    bool lossOk = false,
    bool txLossOk = false,
    String? notRetried,
  }) async {
    if (_closed) throw StateError('Sessione chiusa');
    await _waitReopening();
    _lastActivity = DateTime.now();
    final gen = _generation;
    final s = _inner;
    try {
      return await op(s, gen);
    } catch (e) {
      if (_closed || !(isConnectionLost(e) || s.isClosed)) rethrow;
      final txLost = _autoCommit == false && _dirty;
      await _recover(gen, e);
      if (txLost) {
        _dirty = false;
        onTransactionLost?.call(true);
        if (txLossOk) return null as T;
        throw ConnectionLostException('$transactionLostMessage\n\nDettaglio: $e', transactionLost: true, cause: e);
      }
      if (lossOk) return null as T;
      if (retry) return await op(_inner, _generation);
      throw ConnectionLostException(
        notRetried ??
            'Connessione al server persa e ristabilita: l\'istruzione potrebbe non essere stata eseguita. '
                'Verifica e rieseguila.\n\nDettaglio: $e',
        cause: e,
      );
    } finally {
      _lastActivity = DateTime.now();
    }
  }

  Future<void> _waitReopening() async {
    final r = _reopening;
    if (r == null) return;
    try {
      await r;
    } catch (_) {
      // The caller tries again on its own.
    }
  }

  /// Reopens the session lost at [generation] (once, whoever notices first).
  Future<void> _recover(int generation, Object cause) {
    if (generation != _generation) return _reopening ?? Future.value();
    return _reopening ??= () async {
      await Future<void>.value();
      try {
        final fresh = await reopen();
        try {
          if (_autoCommit == false) await fresh.setAutoCommit(false);
          final catalog = catalogHint?.call() ?? _catalog;
          if (catalog != null && catalog.isNotEmpty) await fresh.setCurrentCatalog(catalog);
          await onReopened?.call(fresh);
        } catch (_) {
          await fresh.close();
          rethrow;
        }
        final old = _inner;
        _inner = fresh;
        _generation++;
        _dirty = false;
        unawaited(old.close().catchError((_) {}));
        if (_closed) await fresh.close();
      } catch (e) {
        throw ConnectionLostException(
          'Connessione al server persa e impossibile ristabilirla: $e\n\nDettaglio: $cause',
          cause: cause,
        );
      } finally {
        _reopening = null;
      }
    }();
  }

  /// Keeps the session alive with a light statement; a lost connection is
  /// reopened right away.
  Future<void> ping() async {
    final sql = pingSql;
    if (sql == null || _closed || _pinging || _inner.isBusy || _reopening != null) return;
    _pinging = true;
    final gen = _generation;
    final s = _inner;
    try {
      final r = await s.execute(sql);
      if (r.cursorId != null) await s.closeCursor(r.cursorId!);
    } catch (e) {
      if (!_closed && (isConnectionLost(e) || s.isClosed)) {
        final txLost = _autoCommit == false && _dirty;
        try {
          await _recover(gen, e);
          if (txLost) {
            _dirty = false;
            onTransactionLost?.call(false);
          }
        } catch (_) {
          // Server unreachable: the next operation tries again.
        }
      }
    } finally {
      _pinging = false;
      _lastActivity = DateTime.now();
    }
  }

  // ---------------------------------------------------------------------------
  // Cursors: ids carry the generation, so that a cursor of a lost session is
  // never confused with one of the reopened session.
  // ---------------------------------------------------------------------------

  static int _wrap(int generation, int id) => generation == 0 ? id : (generation << 32) | id;

  ResultPage _page(ResultPage p, int generation) {
    final id = p.cursorId;
    if (id == null || generation == 0) return p;
    return ResultPage(
      columns: p.columns,
      rows: p.rows,
      hasMore: p.hasMore,
      cursorId: _wrap(generation, id),
      rowsAffected: p.rowsAffected,
      elapsedMs: p.elapsedMs,
      messages: p.messages,
      hasNextResultSet: p.hasNextResultSet,
    );
  }

  /// The id in the current session, null for a cursor of a lost session.
  int? _innerCursor(int id) => id >> 32 == _generation ? id & 0xFFFFFFFF : null;

  static const _staleCursor =
      'La connessione al server è stata ristabilita: il risultato non è più disponibile, riesegui la query.';

  // ---------------------------------------------------------------------------
  // DbSession
  // ---------------------------------------------------------------------------

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) {
    final readOnly = isReadOnly(sql);
    return _run((s, gen) async {
      final page = await s.execute(sql, params: params, fetchSize: fetchSize, queryTimeoutSec: queryTimeoutSec);
      if (!readOnly && _autoCommit == false) _dirty = true;
      return _page(page, gen);
    }, retry: readOnly);
  }

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) {
    final id = _innerCursor(cursorId);
    if (id == null) return Future.error(ConnectionLostException(_staleCursor));
    return _run((s, gen) async => _page(await s.fetchMore(id, count), gen), notRetried: _staleCursor);
  }

  @override
  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize) {
    final id = _innerCursor(cursorId);
    if (id == null) return Future.error(ConnectionLostException(_staleCursor));
    return _run((s, gen) async {
      final page = await s.nextResultSet(id, fetchSize);
      return page == null ? null : _page(page, gen);
    }, notRetried: _staleCursor);
  }

  @override
  Future<void> closeCursor(int cursorId) async {
    final id = _innerCursor(cursorId);
    if (id == null || _closed) return;
    try {
      await _run((s, _) => s.closeCursor(id));
    } on ConnectionLostException catch (e) {
      // The cursor is gone with the connection; only a lost transaction
      // matters.
      if (e.transactionLost) rethrow;
    }
  }

  @override
  Future<ResultPage> catalog(String function, List<String?> args) =>
      _run((s, _) => s.catalog(function, args), retry: true);

  @override
  Future<Map<String, Object?>> info() => _run((s, _) => s.info(), retry: true);

  @override
  Future<void> setAutoCommit(bool value) async {
    await _run((s, _) => s.setAutoCommit(value), retry: true);
    _autoCommit = value;
    _dirty = false;
  }

  @override
  Future<void> commit() async {
    await _run((s, _) => s.commit(), lossOk: true);
    _dirty = false;
  }

  @override
  Future<void> rollback() async {
    await _run((s, _) => s.rollback(), lossOk: true, txLossOk: true);
    _dirty = false;
  }

  @override
  Future<void> setCurrentCatalog(String catalog) async {
    await _run((s, _) => s.setCurrentCatalog(catalog), retry: true);
    _catalog = catalog;
  }

  @override
  Future<String?> currentCatalog() => _run((s, _) => s.currentCatalog(), retry: true);

  @override
  void cancel() => _inner.cancel();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _waitReopening();
    await _inner.close();
  }
}
