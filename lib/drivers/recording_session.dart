// Session decorator that reports every statement it runs, so the query
// history collects what the SQL editors, data grids, query builder, DDL
// tools… execute on the session.
import '../odbc/odbc_types.dart';
import 'db_session.dart';

typedef StatementRecorder = void Function(
  String sql,
  List<Object?> params,
  ResultPage? page,
  Object? error,
  int durationMs,
);

class RecordingSession implements DbSession {
  RecordingSession(this.inner, this.onStatement);

  final DbSession inner;
  final StatementRecorder onStatement;

  @override
  String get completedConnectionString => inner.completedConnectionString;
  @override
  bool get isClosed => inner.isClosed;
  @override
  bool get isBusy => inner.isBusy;

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) => _record(
    sql,
    params,
    () => inner.execute(sql, params: params, fetchSize: fetchSize, queryTimeoutSec: queryTimeoutSec),
  );

  @override
  Future<void> commit() => _record('COMMIT', const [], inner.commit);

  @override
  Future<void> rollback() => _record('ROLLBACK', const [], inner.rollback);

  Future<T> _record<T>(String sql, List<Object?> params, Future<T> Function() run) async {
    final sw = Stopwatch()..start();
    try {
      final r = await run();
      onStatement(sql, params, r is ResultPage ? r : null, null, sw.elapsedMilliseconds);
      return r;
    } catch (e) {
      onStatement(sql, params, null, e, sw.elapsedMilliseconds);
      rethrow;
    }
  }

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) => inner.fetchMore(cursorId, count);
  @override
  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize) => inner.nextResultSet(cursorId, fetchSize);
  @override
  Future<void> closeCursor(int cursorId) => inner.closeCursor(cursorId);
  @override
  Future<ResultPage> catalog(String function, List<String?> args) => inner.catalog(function, args);
  @override
  Future<Map<String, Object?>> info() => inner.info();
  @override
  Future<void> setAutoCommit(bool value) => inner.setAutoCommit(value);
  @override
  Future<void> setCurrentCatalog(String catalog) => inner.setCurrentCatalog(catalog);
  @override
  Future<String?> currentCatalog() => inner.currentCatalog();
  @override
  void cancel() => inner.cancel();
  @override
  Future<void> close() => inner.close();
}
