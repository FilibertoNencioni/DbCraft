// Shared plumbing of the native driver sessions: serialized access to the
// connection, busy tracking, timeouts, cursors and multiple result sets.
import 'dart:async';

import '../../odbc/odbc_ffi.dart';
import '../../odbc/odbc_types.dart';
import '../db_session.dart';
import 'native_exception.dart';

/// Source of rows for a result set. [fetch] is always called while the
/// session lock is held.
abstract class NativeCursor {
  List<ColumnInfo> get columns;
  bool get hasMore;

  /// Returns up to [count] rows (all remaining rows when [count] <= 0).
  Future<List<List<Object?>>> fetch(int count);
  Future<void> close();
}

/// Cursor over rows already in memory.
class ListCursor implements NativeCursor {
  ListCursor(this.columns, this.rows);

  @override
  final List<ColumnInfo> columns;
  final List<List<Object?>> rows;
  int _pos = 0;

  @override
  bool get hasMore => _pos < rows.length;

  @override
  Future<List<List<Object?>>> fetch(int count) async {
    final end = count <= 0 ? rows.length : (_pos + count).clamp(0, rows.length);
    final out = rows.sublist(_pos, end);
    _pos = end;
    return out;
  }

  @override
  Future<void> close() async => _pos = rows.length;
}

/// Outcome of one statement of a script.
class StatementOutcome {
  StatementOutcome.cursor(NativeCursor this.cursor, {this.messages = const []}) : rowsAffected = -1;
  StatementOutcome.rows(List<ColumnInfo> columns, List<List<Object?>> rows, {this.messages = const []})
    : cursor = ListCursor(columns, rows),
      rowsAffected = -1;
  StatementOutcome.update(this.rowsAffected, {this.messages = const []}) : cursor = null;

  final NativeCursor? cursor;
  final int rowsAffected;
  final List<String> messages;
}

class _CursorEntry {
  _CursorEntry(this.cursor, this.pending);
  NativeCursor cursor;
  final List<StatementOutcome> pending;
}

/// Builds a column description.
ColumnInfo nativeColumn(
  int index,
  String name, {
  int sqlType = SQL_VARCHAR,
  String typeName = '',
  String? table,
  String? catalog,
  String? schema,
}) => ColumnInfo(
  index: index,
  name: name,
  sqlType: sqlType,
  typeName: typeName.isEmpty ? sqlTypeName(sqlType) : typeName,
  baseTable: table,
  baseColumn: table == null ? null : name,
  catalog: catalog,
  schema: schema,
);

/// Column list helper: `cols([('key', SQL_VARCHAR), …])`.
List<ColumnInfo> nativeColumns(List<(String, int)> spec, {String? table, String? catalog}) => [
  for (var i = 0; i < spec.length; i++)
    nativeColumn(i + 1, spec[i].$1, sqlType: spec[i].$2, table: table, catalog: catalog),
];

abstract class NativeSessionBase implements DbSession {
  bool _closed = false;
  int _busy = 0;
  Future<void> _tail = Future.value();
  final Map<int, _CursorEntry> _cursors = {};
  int _nextCursor = 1;

  /// Name used in error messages ('MongoDB', 'Redis', …).
  String get engineName;

  @override
  bool get isClosed => _closed;
  @override
  bool get isBusy => _busy > 0;

  /// Runs the statements of [sql] and returns their outcomes. Called with
  /// the lock held.
  Future<List<StatementOutcome>> runScript(String sql, List<Object?> params, int fetchSize, int queryTimeoutSec);

  /// Closes the network connection abruptly (cancel / timeout). The next
  /// operation must reconnect.
  void abortConnection(String reason);

  /// Closes the network connection gracefully.
  Future<void> closeConnection();

  /// Runs [fn] exclusively: the native protocols handle one request at a time
  /// per connection.
  Future<T> exclusive<T>(Future<T> Function() fn, {int timeoutSec = 0}) {
    if (_closed) return Future.error(NativeDbException('Sessione $engineName chiusa'));
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    _busy++;
    Future<T> run() async {
      try {
        await prev;
      } catch (_) {}
      try {
        if (_closed) throw NativeDbException('Sessione $engineName chiusa');
        if (timeoutSec <= 0) return await fn();
        return await fn().timeout(
          Duration(seconds: timeoutSec),
          onTimeout: () {
            abortConnection('timeout');
            throw NativeDbException('Timeout della query ($timeoutSec s): operazione interrotta');
          },
        );
      } finally {
        _busy--;
        done.complete();
      }
    }

    return run();
  }

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) {
    return exclusive(() async {
      final sw = Stopwatch()..start();
      final outcomes = await runScript(sql, params, fetchSize, queryTimeoutSec);
      final page = await _firstPage(outcomes, fetchSize);
      return _withElapsed(page, sw.elapsedMilliseconds);
    }, timeoutSec: queryTimeoutSec);
  }

  ResultPage _withElapsed(ResultPage p, int ms) => ResultPage(
    columns: p.columns,
    rows: p.rows,
    hasMore: p.hasMore,
    cursorId: p.cursorId,
    rowsAffected: p.rowsAffected,
    messages: p.messages,
    hasNextResultSet: p.hasNextResultSet,
    elapsedMs: ms,
  );

  Future<ResultPage> _firstPage(List<StatementOutcome> outcomes, int fetchSize) async {
    final messages = <String>[];
    var affected = -1;
    final results = <StatementOutcome>[];
    for (final o in outcomes) {
      messages.addAll(o.messages);
      if (o.cursor != null) {
        results.add(o);
      } else if (o.rowsAffected >= 0) {
        affected = (affected < 0 ? 0 : affected) + o.rowsAffected;
      }
    }
    if (results.isEmpty) {
      return ResultPage(columns: const [], rows: const [], rowsAffected: affected, messages: messages);
    }
    return _pageOf(results.first.cursor!, results.sublist(1), fetchSize, messages);
  }

  Future<ResultPage> _pageOf(
    NativeCursor c,
    List<StatementOutcome> pending,
    int fetchSize,
    List<String> messages,
  ) async {
    List<List<Object?>> rows;
    try {
      rows = await c.fetch(fetchSize);
    } catch (_) {
      await _safeClose(c);
      for (final p in pending) {
        await _safeClose(p.cursor);
      }
      rethrow;
    }
    final more = c.hasMore;
    int? id;
    if (more || pending.isNotEmpty) {
      id = _nextCursor++;
      _cursors[id] = _CursorEntry(c, pending);
    } else {
      await _safeClose(c);
    }
    return ResultPage(
      columns: c.columns,
      rows: rows,
      hasMore: more,
      cursorId: id,
      messages: messages,
      hasNextResultSet: pending.isNotEmpty,
    );
  }

  Future<void> _safeClose(NativeCursor? c) async {
    if (c == null) return;
    try {
      await c.close();
    } catch (_) {}
  }

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) => exclusive(() async {
    final e = _cursors[cursorId];
    if (e == null) return ResultPage(columns: const [], rows: const []);
    final rows = await e.cursor.fetch(count);
    final more = e.cursor.hasMore;
    final keep = more || e.pending.isNotEmpty;
    if (!keep) {
      _cursors.remove(cursorId);
      await _safeClose(e.cursor);
    }
    return ResultPage(
      columns: e.cursor.columns,
      rows: rows,
      hasMore: more,
      cursorId: keep ? cursorId : null,
      hasNextResultSet: e.pending.isNotEmpty,
    );
  });

  @override
  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize) => exclusive(() async {
    final e = _cursors.remove(cursorId);
    if (e == null) return null;
    await _safeClose(e.cursor);
    if (e.pending.isEmpty) return null;
    final next = e.pending.first;
    return _pageOf(next.cursor!, e.pending.sublist(1), fetchSize, const []);
  });

  @override
  Future<void> closeCursor(int cursorId) async {
    final e = _cursors.remove(cursorId);
    if (e == null) return;
    await exclusive(() async {
      await _safeClose(e.cursor);
      for (final p in e.pending) {
        await _safeClose(p.cursor);
      }
    });
  }

  /// Forgets every cursor (after the connection was lost).
  void dropCursors() => _cursors.clear();

  @override
  Future<void> setAutoCommit(bool value) async {
    // No multi-statement transactions: every statement is applied at once.
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}

  @override
  void cancel() {
    if (_closed || _busy == 0) return;
    abortConnection('cancel');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cursors.clear();
    try {
      await closeConnection().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}

/// Error raised when a write is attempted on a read-only connection.
NativeDbException readOnlyError(String what) =>
    NativeDbException('Connessione in sola lettura: "$what" non è consentito');
