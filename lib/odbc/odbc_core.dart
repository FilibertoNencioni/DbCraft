// Synchronous ODBC connection wrapper. It is meant to be used from a worker
// isolate (see odbc_session.dart) so that blocking driver calls never freeze
// the UI.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'cancel_slot.dart';
import 'odbc_ffi.dart';
import 'odbc_types.dart';

/// Maximum number of bytes read for a single LOB value.
const int kMaxLobBytes = 8 * 1024 * 1024;

/// Allocates an ODBC 3 environment handle.
SQLHANDLE allocEnvironment(OdbcApi api) {
  final out = calloc<SQLHANDLE>();
  try {
    final rc = api.SQLAllocHandle(SQL_HANDLE_ENV, nullptr, out);
    if (!sqlSucceeded(rc)) {
      throw OdbcException('SQLAllocHandle(ENV)', const [], rc);
    }
    final env = out.value;
    api.SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, Pointer.fromAddress(SQL_OV_ODBC3), 0);
    return env;
  } finally {
    calloc.free(out);
  }
}

List<OdbcDiag> readDiagnostics(OdbcApi api, int handleType, SQLHANDLE h) {
  final result = <OdbcDiag>[];
  if (h == nullptr) return result;
  using((arena) {
    final state = arena<Uint8>(6 * api.wcharSize + 8);
    final native = arena<Int32>();
    const msgChars = 2048;
    final msg = arena<Uint8>((msgChars + 1) * api.wcharSize);
    final len = arena<Int16>();
    for (var rec = 1; rec < 50; rec++) {
      final rc = api.SQLGetDiagRec(handleType, h, rec, state, native, msg, msgChars, len);
      if (!sqlSucceeded(rc)) break;
      final l = len.value > msgChars ? msgChars : len.value;
      result.add(OdbcDiag(api.fromWide(state, 5), native.value, api.fromWide(msg, l).trim()));
    }
  });
  return result;
}

/// Lists the installed ODBC drivers.
List<OdbcDriverInfo> listDrivers(OdbcApi api) {
  final env = allocEnvironment(api);
  final drivers = <OdbcDriverInfo>[];
  try {
    using((arena) {
      const max = 1024;
      final desc = arena<Uint8>((max + 1) * api.wcharSize);
      final attr = arena<Uint8>((max * 4 + 1) * api.wcharSize);
      final dl = arena<Int16>();
      final al = arena<Int16>();
      var dir = SQL_FETCH_FIRST;
      while (true) {
        final rc = api.SQLDrivers(env, dir, desc, max, dl, attr, max * 4, al);
        if (!sqlSucceeded(rc)) break;
        dir = SQL_FETCH_NEXT;
        final name = api.fromWide(desc, dl.value.clamp(0, max));
        // Attributes are "key=value\0key=value\0\0".
        final attrs = <String, String>{};
        final raw = api.fromWide(attr, al.value.clamp(0, max * 4));
        for (final part in raw.split('\u0000')) {
          final i = part.indexOf('=');
          if (i > 0) attrs[part.substring(0, i)] = part.substring(i + 1);
        }
        drivers.add(OdbcDriverInfo(name, attrs));
      }
    });
  } finally {
    api.SQLFreeHandle(SQL_HANDLE_ENV, env);
  }
  return drivers;
}

/// Lists the configured DSNs (user and system).
List<OdbcDataSource> listDataSources(OdbcApi api) {
  final env = allocEnvironment(api);
  final result = <OdbcDataSource>[];
  try {
    using((arena) {
      const max = 512;
      final name = arena<Uint8>((max + 1) * api.wcharSize);
      final desc = arena<Uint8>((max + 1) * api.wcharSize);
      final nl = arena<Int16>();
      final dl = arena<Int16>();
      for (final first in [SQL_FETCH_FIRST_USER, SQL_FETCH_FIRST_SYSTEM]) {
        var dir = first;
        while (true) {
          final rc = api.SQLDataSources(env, dir, name, max, nl, desc, max, dl);
          if (!sqlSucceeded(rc)) break;
          dir = SQL_FETCH_NEXT;
          result.add(
            OdbcDataSource(
              api.fromWide(name, nl.value.clamp(0, max)),
              api.fromWide(desc, dl.value.clamp(0, max)),
              system: first == SQL_FETCH_FIRST_SYSTEM,
            ),
          );
        }
      }
    });
  } finally {
    api.SQLFreeHandle(SQL_HANDLE_ENV, env);
  }
  return result;
}

/// Kind of value extraction used for a column.
enum _Fetch { integer, real, decimal, binary, text }

class _Cursor {
  _Cursor(this.stmt, this.columns, this.fetchModes);
  final SQLHANDLE stmt;
  List<ColumnInfo> columns;
  List<_Fetch> fetchModes;
  bool exhausted = false;
  bool positionedOnNextResult = false;

  /// Diagnostics of the look-ahead SQLMoreResults, handed to the next
  /// result.
  final List<String> pendingMessages = [];
  final List<OdbcDiag> pendingErrors = [];

  /// Error that ended the rows of this result (a statement of a batch that
  /// failed while sending them, e.g. a division by zero).
  List<OdbcDiag>? fetchError;
}

/// SQL Server returns decimals without the leading zero (`.5`, `-.5`).
String normalizeDecimalText(String v) {
  if (v.startsWith('.')) return '0$v';
  if (v.startsWith('-.')) return '-0${v.substring(1)}';
  return v;
}

class OdbcConnectionCore {
  OdbcConnectionCore(this.api, {this.cancelSlot});

  final OdbcApi api;

  /// Native slot where the handle of the running statement is published so
  /// that the UI isolate can call SQLCancel on it.
  final CancelSlot? cancelSlot;

  SQLHANDLE _env = nullptr;
  SQLHANDLE _dbc = nullptr;
  bool _connected = false;
  bool autoCommit = true;
  final Map<int, _Cursor> _cursors = {};
  int _nextCursorId = 1;

  /// SQL_MAX_CONCURRENT_ACTIVITIES: 1 = a single active statement per
  /// connection (SQL Server without MARS, Sybase, FreeTDS…), 0 = no limit.
  int? _maxActive;

  bool get isConnected => _connected;

  // -------------------------------------------------------------------------
  // Connection management
  // -------------------------------------------------------------------------

  /// Connects using a full ODBC connection string. Returns the completed
  /// connection string reported by the driver.
  String connect(String connectionString, {int loginTimeoutSec = 15, bool readOnly = false}) {
    _env = allocEnvironment(api);
    final out = calloc<SQLHANDLE>();
    try {
      final rc = api.SQLAllocHandle(SQL_HANDLE_DBC, _env, out);
      _check(rc, 'SQLAllocHandle(DBC)', SQL_HANDLE_ENV, _env);
      _dbc = out.value;
    } finally {
      calloc.free(out);
    }
    if (loginTimeoutSec > 0) {
      api.SQLSetConnectAttr(
        _dbc,
        SQL_ATTR_LOGIN_TIMEOUT,
        Pointer.fromAddress(loginTimeoutSec),
        SQL_IS_UINTEGER,
      );
    }
    return using((arena) {
      final inStr = api.toWide(connectionString, arena);
      const outMax = 2048;
      final outStr = arena<Uint8>((outMax + 1) * api.wcharSize);
      final outLen = arena<Int16>();
      final rc = api.SQLDriverConnect(
        _dbc,
        nullptr,
        inStr,
        api.wideLength(connectionString),
        outStr,
        outMax,
        outLen,
        SQL_DRIVER_NOPROMPT,
      );
      _check(rc, 'SQLDriverConnect', SQL_HANDLE_DBC, _dbc);
      _connected = true;
      if (readOnly) {
        api.SQLSetConnectAttr(
          _dbc,
          SQL_ATTR_ACCESS_MODE,
          Pointer.fromAddress(SQL_MODE_READ_ONLY),
          SQL_IS_UINTEGER,
        );
      }
      return api.fromWide(outStr, outLen.value.clamp(0, outMax));
    });
  }

  void disconnect() {
    for (final c in _cursors.values) {
      api.SQLFreeHandle(SQL_HANDLE_STMT, c.stmt);
    }
    _cursors.clear();
    if (_dbc != nullptr) {
      if (_connected) {
        if (!autoCommit) {
          api.SQLEndTran(SQL_HANDLE_DBC, _dbc, SQL_ROLLBACK);
        }
        api.SQLDisconnect(_dbc);
      }
      api.SQLFreeHandle(SQL_HANDLE_DBC, _dbc);
      _dbc = nullptr;
    }
    if (_env != nullptr) {
      api.SQLFreeHandle(SQL_HANDLE_ENV, _env);
      _env = nullptr;
    }
    _connected = false;
  }

  void setAutoCommit(bool value) {
    _closeCursorsForTransaction();
    final rc = api.SQLSetConnectAttr(
      _dbc,
      SQL_ATTR_AUTOCOMMIT,
      Pointer.fromAddress(value ? SQL_AUTOCOMMIT_ON : SQL_AUTOCOMMIT_OFF),
      SQL_IS_UINTEGER,
    );
    _check(rc, 'SQLSetConnectAttr(AUTOCOMMIT)', SQL_HANDLE_DBC, _dbc);
    autoCommit = value;
  }

  void endTransaction(bool commit) {
    _closeCursorsForTransaction();
    final rc = api.SQLEndTran(SQL_HANDLE_DBC, _dbc, commit ? SQL_COMMIT : SQL_ROLLBACK);
    _check(rc, commit ? 'COMMIT' : 'ROLLBACK', SQL_HANDLE_DBC, _dbc);
  }

  void setCurrentCatalog(String catalog) => _whenFree(() => _setCurrentCatalog(catalog));

  void _setCurrentCatalog(String catalog) {
    using((arena) {
      final p = api.toWide(catalog, arena);
      final rc = api.SQLSetConnectAttr(
        _dbc,
        SQL_ATTR_CURRENT_CATALOG,
        p.cast(),
        api.wideLength(catalog) * api.wcharSize,
      );
      _check(rc, 'SQLSetConnectAttr(CURRENT_CATALOG)', SQL_HANDLE_DBC, _dbc);
    });
  }

  String? getCurrentCatalog() {
    return using((arena) {
      const max = 512;
      final buf = arena<Uint8>((max + 1) * api.wcharSize);
      final len = arena<Int32>();
      final rc = api.SQLGetConnectAttr(_dbc, SQL_ATTR_CURRENT_CATALOG, buf.cast(), max * api.wcharSize, len);
      if (!sqlSucceeded(rc)) return null;
      final chars = (len.value ~/ api.wcharSize).clamp(0, max);
      return api.fromWide(buf, chars);
    });
  }

  /// Reads the main SQLGetInfo values.
  Map<String, Object?> getInfo() {
    final info = <String, Object?>{};
    String? str(int type) => using((arena) {
      const max = 4096;
      final buf = arena<Uint8>((max + 1) * api.wcharSize);
      final len = arena<Int16>();
      final rc = api.SQLGetInfo(_dbc, type, buf.cast(), (max * api.wcharSize), len);
      if (!sqlSucceeded(rc)) return null;
      return api.fromWide(buf, (len.value ~/ api.wcharSize).clamp(0, max));
    });
    int? u32(int type) => using((arena) {
      final buf = arena<Uint32>();
      final rc = api.SQLGetInfo(_dbc, type, buf.cast(), 4, nullptr);
      return sqlSucceeded(rc) ? buf.value : null;
    });
    int? u16(int type) => using((arena) {
      final buf = arena<Uint16>();
      final rc = api.SQLGetInfo(_dbc, type, buf.cast(), 2, nullptr);
      return sqlSucceeded(rc) ? buf.value : null;
    });
    info['dataSourceName'] = str(SQL_DATA_SOURCE_NAME);
    info['driverName'] = str(SQL_DRIVER_NAME);
    info['driverVersion'] = str(SQL_DRIVER_VER);
    info['odbcVersion'] = str(SQL_ODBC_VER);
    info['driverOdbcVersion'] = str(SQL_DRIVER_ODBC_VER);
    info['serverName'] = str(SQL_SERVER_NAME);
    info['databaseName'] = str(SQL_DATABASE_NAME);
    info['dbmsName'] = str(SQL_DBMS_NAME);
    info['dbmsVersion'] = str(SQL_DBMS_VER);
    info['userName'] = str(SQL_USER_NAME);
    info['identifierQuote'] = str(SQL_IDENTIFIER_QUOTE_CHAR);
    info['catalogSeparator'] = str(SQL_CATALOG_NAME_SEPARATOR);
    info['catalogTerm'] = str(SQL_CATALOG_TERM);
    info['schemaTerm'] = str(SQL_SCHEMA_TERM);
    info['procedureTerm'] = str(SQL_PROCEDURE_TERM);
    info['tableTerm'] = str(SQL_TABLE_TERM);
    info['keywords'] = str(SQL_KEYWORDS);
    info['searchEscape'] = str(SQL_SEARCH_PATTERN_ESCAPE);
    info['catalogSupported'] = str(SQL_CATALOG_NAME);
    info['proceduresSupported'] = str(SQL_PROCEDURES);
    info['schemaUsage'] = u32(SQL_SCHEMA_USAGE);
    info['catalogUsage'] = u32(SQL_CATALOG_USAGE);
    info['txnCapable'] = u16(SQL_TXN_CAPABLE);
    info['maxIdentifierLength'] = u16(SQL_MAX_IDENTIFIER_LEN);
    info['currentCatalog'] = getCurrentCatalog();
    return info;
  }

  // -------------------------------------------------------------------------
  // Statements
  // -------------------------------------------------------------------------

  SQLHANDLE _allocStmt() {
    final out = calloc<SQLHANDLE>();
    try {
      final rc = api.SQLAllocHandle(SQL_HANDLE_STMT, _dbc, out);
      _check(rc, 'SQLAllocHandle(STMT)', SQL_HANDLE_DBC, _dbc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void _publish(SQLHANDLE stmt) {
    cancelSlot?.publish(stmt.address);
  }

  void _freeStmt(SQLHANDLE stmt) {
    cancelSlot?.unpublish(stmt.address);
    api.SQLFreeHandle(SQL_HANDLE_STMT, stmt);
  }

  /// Drivers allowing a single active statement refuse any command while a
  /// result set is still open ("Connection is busy with results for another
  /// command"). The open cursors are closed first — the grids keep the rows
  /// already fetched — and the command is retried once if the driver still
  /// reports the connection busy.
  T _whenFree<T>(T Function() run) {
    if (_cursors.isNotEmpty) {
      _maxActive ??= using((arena) {
        final buf = arena<Uint16>();
        final rc = api.SQLGetInfo(_dbc, SQL_MAX_CONCURRENT_ACTIVITIES, buf.cast(), 2, nullptr);
        return sqlSucceeded(rc) ? buf.value : 0;
      });
      if (_maxActive == 1) _closeAllCursors();
    }
    try {
      return run();
    } on OdbcException catch (e) {
      if (_cursors.isEmpty || !e.message.toLowerCase().contains('busy')) rethrow;
      _closeAllCursors();
      return run();
    }
  }

  /// Transaction boundaries are refused while a result set is still pending
  /// (SQL Server with MARS: "New transaction is not allowed because there are
  /// other threads running in the session"), and most drivers close cursors
  /// on commit anyway. The grids keep the rows already fetched.
  void _closeCursorsForTransaction() {
    if (_cursors.isNotEmpty) _closeAllCursors();
  }

  void _closeAllCursors() {
    for (final c in _cursors.values) {
      _freeStmt(c.stmt);
    }
    _cursors.clear();
  }

  /// Executes [sql]. When [params] is not empty the statement is prepared and
  /// the values are bound positionally (`?`).
  ResultPage execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) => _whenFree(
    () => _execute(sql, params: params, fetchSize: fetchSize, queryTimeoutSec: queryTimeoutSec),
  );

  ResultPage _execute(
    String sql, {
    required List<Object?> params,
    required int fetchSize,
    required int queryTimeoutSec,
  }) {
    final sw = Stopwatch()..start();
    final stmt = _allocStmt();
    final messages = <String>[];
    final errors = <OdbcDiag>[];
    try {
      _publish(stmt);
      if (queryTimeoutSec > 0) {
        api.SQLSetStmtAttr(
          stmt,
          SQL_ATTR_QUERY_TIMEOUT,
          Pointer.fromAddress(queryTimeoutSec),
          SQL_IS_UINTEGER,
        );
      }
      final rc = using((arena) {
        final text = api.toWide(sql, arena);
        if (params.isEmpty) {
          return api.SQLExecDirect(stmt, text, api.wideLength(sql));
        }
        var r = api.SQLPrepare(stmt, text, api.wideLength(sql));
        _check(r, 'SQLPrepare', SQL_HANDLE_STMT, stmt);
        _bindParams(stmt, params, arena);
        return api.SQLExecute(stmt);
      });
      if (rc == SQL_SUCCESS_WITH_INFO) _readInfo(stmt, messages, errors);
      // A failure of the execution itself ends everything: the Driver
      // Manager refuses SQLMoreResults afterwards (function sequence error),
      // even when the server went on with the rest of the batch.
      if (rc != SQL_NO_DATA) _check(rc, 'SQLExecute', SQL_HANDLE_STMT, stmt);
      return _processResults(stmt, fetchSize, sw, messages, errors, throwErrors: true);
    } catch (_) {
      _freeStmt(stmt);
      rethrow;
    }
  }

  void _bindParams(SQLHANDLE stmt, List<Object?> params, Arena arena) {
    for (var i = 0; i < params.length; i++) {
      var v = params[i];
      int? forcedType;
      if (v is SqlParam) {
        forcedType = v.sqlType;
        v = v.value;
      }
      final ind = arena<IntPtr>();
      int cType, sqlType, colSize = 0, bufLen = 0;
      Pointer<Void> buf;
      if (v == null) {
        cType = SQL_C_WCHAR;
        sqlType = forcedType ?? SQL_VARCHAR;
        colSize = 1;
        buf = arena<Uint8>(api.wcharSize).cast();
        ind.value = SQL_NULL_DATA;
      } else if (v is bool) {
        final p = arena<Int64>()..value = v ? 1 : 0;
        cType = SQL_C_SBIGINT;
        sqlType = forcedType ?? SQL_BIT;
        buf = p.cast();
        bufLen = 8;
        ind.value = 8;
      } else if (v is int) {
        final p = arena<Int64>()..value = v;
        cType = SQL_C_SBIGINT;
        sqlType = forcedType ?? SQL_BIGINT;
        colSize = 19;
        buf = p.cast();
        bufLen = 8;
        ind.value = 8;
      } else if (v is double) {
        final p = arena<Double>()..value = v;
        cType = SQL_C_DOUBLE;
        sqlType = forcedType ?? SQL_DOUBLE;
        colSize = 15;
        buf = p.cast();
        bufLen = 8;
        ind.value = 8;
      } else if (v is Uint8List) {
        final p = arena<Uint8>(v.isEmpty ? 1 : v.length);
        p.asTypedList(v.length).setAll(0, v);
        cType = SQL_C_BINARY;
        sqlType = forcedType ?? SQL_VARBINARY;
        colSize = v.isEmpty ? 1 : v.length;
        buf = p.cast();
        bufLen = v.length;
        ind.value = v.length;
      } else {
        final s = v.toString();
        final chars = api.wideLength(s);
        buf = api.toWide(s, arena).cast();
        cType = SQL_C_WCHAR;
        sqlType = forcedType ?? (chars > 4000 ? SQL_WLONGVARCHAR : SQL_WVARCHAR);
        colSize = chars == 0 ? 1 : chars;
        bufLen = (chars + 1) * api.wcharSize;
        ind.value = chars * api.wcharSize;
      }
      final rc = api.SQLBindParameter(
        stmt,
        i + 1,
        SQL_PARAM_INPUT,
        cType,
        sqlType,
        colSize,
        0,
        buf,
        bufLen,
        ind,
      );
      _check(rc, 'SQLBindParameter(${i + 1})', SQL_HANDLE_STMT, stmt);
    }
  }

  /// Diagnostics of a SQL_SUCCESS_WITH_INFO: informational messages (PRINT,
  /// warnings) and the errors of batch statements that did not stop the
  /// batch (ODBC reports them as "with info" when the batch goes on).
  void _readInfo(SQLHANDLE stmt, List<String> messages, List<OdbcDiag> errors) {
    for (final d in readDiagnostics(api, SQL_HANDLE_STMT, stmt)) {
      if (d.isError) {
        errors.add(d);
      } else {
        messages.add(d.message);
      }
    }
  }

  /// Errors after which reading the following results makes no sense: the
  /// driver's own (function sequence, cancel, timeout, connection).
  static bool _batchCanGoOn(List<OdbcDiag> diag) =>
      diag.isNotEmpty &&
      !diag.any((d) => d.sqlState == 'HY010' || d.sqlState == 'HY008' || d.sqlState.startsWith('HYT') ||
          d.sqlState.startsWith('08') || d.sqlState.startsWith('IM'));

  /// Moves to the next result of a batch. A statement of the batch that
  /// failed gives SQL_ERROR while the batch goes on (SQL Server): its errors
  /// are collected and the move is tried again. Returns SQL_SUCCESS(_WITH_
  /// INFO) when positioned on a result, SQL_NO_DATA (or the last code) when
  /// nothing follows.
  int _moreResults(SQLHANDLE stmt, List<String> messages, List<OdbcDiag> errors) {
    String? last;
    for (var guard = 0; guard < 10000; guard++) {
      final more = api.SQLMoreResults(stmt);
      if (more == SQL_SUCCESS_WITH_INFO) _readInfo(stmt, messages, errors);
      if (more != SQL_ERROR) return more;
      final diag = readDiagnostics(api, SQL_HANDLE_STMT, stmt);
      final text = diag.join('\n');
      if (!_batchCanGoOn(diag) || text == last) {
        // The driver is stuck (or done): report what it said, once.
        if (text != last) errors.addAll(diag.where((d) => d.sqlState != 'HY010'));
        return more;
      }
      errors.addAll(diag);
      last = text;
    }
    return SQL_NO_DATA;
  }

  /// Walks the results of [stmt] until a result set is found (kept open as a
  /// cursor) or there are no more results (statement freed). Errors of the
  /// batch statements go in the page; with [throwErrors] they are thrown
  /// when no result set came (callers that only expect success).
  ResultPage _processResults(
    SQLHANDLE stmt,
    int fetchSize,
    Stopwatch sw,
    List<String> messages,
    List<OdbcDiag> errors, {
    bool throwErrors = false,
  }) {
    var affected = -1;
    while (true) {
      final cols = _numResultCols(stmt);
      if (cols > 0) {
        final columns = _describe(stmt, cols);
        final cursor = _Cursor(stmt, columns, columns.map(_fetchMode).toList());
        final id = _nextCursorId++;
        _cursors[id] = cursor;
        try {
          final rows = _fetchRows(cursor, fetchSize);
          if (cursor.fetchError != null && rows.isEmpty) {
            // The statement failed before its first row: not a result, an
            // error; the batch goes on with the next result.
            errors.addAll(cursor.fetchError!);
            _cursors.remove(id);
            if (sqlSucceeded(_moreResults(stmt, messages, errors))) continue;
            if (throwErrors) throw OdbcException('SQLFetch', errors, SQL_ERROR);
            _freeStmt(stmt);
            return ResultPage(
              columns: const [],
              rows: const [],
              elapsedMs: sw.elapsedMilliseconds,
              messages: messages,
              errors: [for (final e in errors) e.toString()],
            );
          }
          return _pageFor(id, cursor, rows, sw, messages, errors);
        } catch (_) {
          // The caller frees the statement.
          _cursors.remove(id);
          rethrow;
        }
      }
      final rc = using((arena) {
        final cnt = arena<IntPtr>();
        final r = api.SQLRowCount(stmt, cnt);
        return sqlSucceeded(r) ? cnt.value : -1;
      });
      if (rc >= 0) affected = (affected < 0 ? 0 : affected) + rc;
      final more = _moreResults(stmt, messages, errors);
      if (!sqlSucceeded(more)) {
        if (throwErrors && errors.isNotEmpty) {
          // The caller frees the statement.
          throw OdbcException('SQLMoreResults', errors, SQL_ERROR);
        }
        _freeStmt(stmt);
        return ResultPage(
          columns: const [],
          rows: const [],
          rowsAffected: affected,
          elapsedMs: sw.elapsedMilliseconds,
          messages: messages,
          errors: [for (final e in errors) e.toString()],
        );
      }
    }
  }

  ResultPage _pageFor(
    int id,
    _Cursor cursor,
    List<List<Object?>> rows,
    Stopwatch sw,
    List<String> messages,
    List<OdbcDiag> errors,
  ) {
    var hasNext = false;
    final pageErrors = [for (final e in errors) e.toString()];
    if (cursor.fetchError != null) {
      pageErrors.addAll(cursor.fetchError!.map((e) => e.toString()));
      cursor.fetchError = null;
    }
    if (cursor.exhausted) {
      // Look ahead for further result sets so the UI can offer them.
      final more = _moreResults(cursor.stmt, cursor.pendingMessages, cursor.pendingErrors);
      if (sqlSucceeded(more)) {
        cursor.positionedOnNextResult = true;
        hasNext = true;
      } else {
        // Nothing follows: the errors met on the way belong to this page.
        pageErrors.addAll(cursor.pendingErrors.map((e) => e.toString()));
        messages = [...messages, ...cursor.pendingMessages];
        _cursors.remove(id);
        _freeStmt(cursor.stmt);
      }
    }
    final open = _cursors.containsKey(id);
    return ResultPage(
      columns: cursor.columns,
      rows: rows,
      hasMore: !cursor.exhausted,
      cursorId: open ? id : null,
      elapsedMs: sw.elapsedMilliseconds,
      messages: messages,
      errors: pageErrors,
      hasNextResultSet: hasNext,
    );
  }

  ResultPage fetchMore(int cursorId, int count) {
    final sw = Stopwatch()..start();
    final cursor = _cursors[cursorId];
    if (cursor == null || cursor.exhausted) {
      return ResultPage(columns: const [], rows: const []);
    }
    _publish(cursor.stmt);
    try {
      final rows = _fetchRows(cursor, count);
      return _pageFor(cursorId, cursor, rows, sw, const [], const []);
    } catch (_) {
      closeCursor(cursorId);
      rethrow;
    }
  }

  ResultPage? nextResultSet(int cursorId, int fetchSize) {
    final cursor = _cursors.remove(cursorId);
    if (cursor == null) return null;
    final sw = Stopwatch()..start();
    final messages = [...cursor.pendingMessages];
    final errors = [...cursor.pendingErrors];
    if (!cursor.positionedOnNextResult) {
      final more = _moreResults(cursor.stmt, messages, errors);
      if (!sqlSucceeded(more)) {
        _freeStmt(cursor.stmt);
        // Failed statements after the last result: reported, not lost.
        if (errors.isEmpty && messages.isEmpty) return null;
        return ResultPage(
          columns: const [],
          rows: const [],
          elapsedMs: sw.elapsedMilliseconds,
          messages: messages,
          errors: [for (final e in errors) e.toString()],
        );
      }
    }
    try {
      return _processResults(cursor.stmt, fetchSize, sw, messages, errors);
    } catch (_) {
      _freeStmt(cursor.stmt);
      rethrow;
    }
  }

  void closeCursor(int cursorId) {
    final c = _cursors.remove(cursorId);
    if (c != null) _freeStmt(c.stmt);
  }

  int _numResultCols(SQLHANDLE stmt) => using((arena) {
    final n = arena<Int16>();
    final rc = api.SQLNumResultCols(stmt, n);
    _check(rc, 'SQLNumResultCols', SQL_HANDLE_STMT, stmt);
    return n.value;
  });

  List<ColumnInfo> _describe(SQLHANDLE stmt, int count) {
    return using((arena) {
      const max = 256;
      final name = arena<Uint8>((max + 1) * api.wcharSize);
      final nameLen = arena<Int16>();
      final type = arena<Int16>();
      final size = arena<UintPtr>();
      final dec = arena<Int16>();
      final nullable = arena<Int16>();
      final strBuf = arena<Uint8>((max + 1) * api.wcharSize);
      final strLen = arena<Int16>();
      final num = arena<IntPtr>();

      String? attrStr(int col, int field) {
        strLen.value = 0;
        final rc = api.SQLColAttribute(stmt, col, field, strBuf.cast(), max * api.wcharSize, strLen, num);
        if (!sqlSucceeded(rc)) return null;
        final s = api.fromWide(strBuf, (strLen.value ~/ api.wcharSize).clamp(0, max));
        return s.isEmpty ? null : s;
      }

      int attrNum(int col, int field) {
        num.value = 0;
        final rc = api.SQLColAttribute(stmt, col, field, nullptr, 0, nullptr, num);
        return sqlSucceeded(rc) ? num.value : 0;
      }

      final result = <ColumnInfo>[];
      for (var i = 1; i <= count; i++) {
        final rc = api.SQLDescribeCol(stmt, i, name, max, nameLen, type, size, dec, nullable);
        _check(rc, 'SQLDescribeCol', SQL_HANDLE_STMT, stmt);
        var colName = api.fromWide(name, nameLen.value.clamp(0, max));
        if (colName.isEmpty) colName = 'col$i';
        result.add(
          ColumnInfo(
            index: i - 1,
            name: colName,
            sqlType: type.value,
            typeName: attrStr(i, SQL_DESC_TYPE_NAME) ?? '',
            size: size.value,
            decimals: dec.value,
            nullable: nullable.value != 0,
            baseTable: attrStr(i, SQL_DESC_BASE_TABLE_NAME) ?? attrStr(i, SQL_DESC_TABLE_NAME),
            baseColumn: attrStr(i, SQL_DESC_BASE_COLUMN_NAME),
            schema: attrStr(i, SQL_DESC_SCHEMA_NAME),
            catalog: attrStr(i, SQL_DESC_CATALOG_NAME),
            autoIncrement: attrNum(i, SQL_DESC_AUTO_UNIQUE_VALUE) != 0,
          ),
        );
      }
      return result;
    });
  }

  static _Fetch _fetchMode(ColumnInfo c) {
    switch (c.sqlType) {
      case SQL_INTEGER:
      case SQL_SMALLINT:
      case SQL_TINYINT:
      case SQL_BIGINT:
      case SQL_BIT:
        return _Fetch.integer;
      case SQL_REAL:
      case SQL_FLOAT:
      case SQL_DOUBLE:
        return _Fetch.real;
      case SQL_DECIMAL:
      case SQL_NUMERIC:
        return _Fetch.decimal;
      case SQL_BINARY:
      case SQL_VARBINARY:
      case SQL_LONGVARBINARY:
        return _Fetch.binary;
      default:
        return _Fetch.text;
    }
  }

  List<List<Object?>> _fetchRows(_Cursor cursor, int max) {
    final rows = <List<Object?>>[];
    final stmt = cursor.stmt;
    using((arena) {
      const chunk = 16 * 1024;
      final buf = arena<Uint8>(chunk + 8);
      final ind = arena<IntPtr>();
      while (max <= 0 || rows.length < max) {
        final rc = api.SQLFetch(stmt);
        if (rc == SQL_NO_DATA) {
          cursor.exhausted = true;
          break;
        }
        if (rc == SQL_ERROR) {
          // A failed statement of a batch ends its rows; the results after
          // it are still read (see _pageFor).
          final diag = readDiagnostics(api, SQL_HANDLE_STMT, stmt);
          if (!_batchCanGoOn(diag)) throw OdbcException('SQLFetch', diag, rc);
          cursor
            ..fetchError = diag
            ..exhausted = true;
          break;
        }
        _check(rc, 'SQLFetch', SQL_HANDLE_STMT, stmt);
        final row = List<Object?>.filled(cursor.columns.length, null);
        for (var c = 0; c < cursor.columns.length; c++) {
          row[c] = _getValue(stmt, c + 1, cursor.fetchModes[c], buf, chunk, ind);
        }
        rows.add(row);
      }
    });
    return rows;
  }

  Object? _getValue(
    SQLHANDLE stmt,
    int col,
    _Fetch mode,
    Pointer<Uint8> buf,
    int chunk,
    Pointer<IntPtr> ind,
  ) {
    switch (mode) {
      case _Fetch.integer:
        final rc = api.SQLGetData(stmt, col, SQL_C_SBIGINT, buf.cast(), 8, ind);
        if (rc == SQL_ERROR) {
          // Some drivers refuse the conversion: fall back to text.
          return _getValue(stmt, col, _Fetch.text, buf, chunk, ind);
        }
        _check(rc, 'SQLGetData', SQL_HANDLE_STMT, stmt);
        if (ind.value == SQL_NULL_DATA) return null;
        return buf.cast<Int64>().value;
      case _Fetch.real:
        final rc = api.SQLGetData(stmt, col, SQL_C_DOUBLE, buf.cast(), 8, ind);
        if (rc == SQL_ERROR) {
          return _getValue(stmt, col, _Fetch.text, buf, chunk, ind);
        }
        _check(rc, 'SQLGetData', SQL_HANDLE_STMT, stmt);
        if (ind.value == SQL_NULL_DATA) return null;
        return buf.cast<Double>().value;
      case _Fetch.decimal:
        final v = _getValue(stmt, col, _Fetch.text, buf, chunk, ind);
        return v is String ? normalizeDecimalText(v) : v;
      case _Fetch.binary:
      case _Fetch.text:
        final isText = mode == _Fetch.text;
        final cType = isText ? SQL_C_WCHAR : SQL_C_BINARY;
        // Text buffers must leave room for the NUL terminator.
        final usable = isText ? chunk - api.wcharSize : chunk;
        final builder = BytesBuilder(copy: true);
        while (true) {
          final rc = api.SQLGetData(stmt, col, cType, buf.cast(), chunk, ind);
          if (rc == SQL_NO_DATA) break;
          _check(rc, 'SQLGetData', SQL_HANDLE_STMT, stmt);
          final len = ind.value;
          if (len == SQL_NULL_DATA) return null;
          if (rc == SQL_SUCCESS_WITH_INFO && (len == SQL_NO_TOTAL || len > usable)) {
            builder.add(buf.asTypedList(usable));
            if (builder.length >= kMaxLobBytes) break;
            continue;
          }
          builder.add(buf.asTypedList(len < 0 ? 0 : (len > usable ? usable : len)));
          break;
        }
        final bytes = builder.takeBytes();
        if (!isText) return bytes;
        return api.wideBytesToString(bytes);
    }
  }

  // -------------------------------------------------------------------------
  // Catalog functions
  // -------------------------------------------------------------------------

  /// Runs an ODBC catalog function and returns the full result.
  ResultPage catalog(String function, List<Object?> args) => _whenFree(() => _catalog(function, args));

  ResultPage _catalog(String function, List<Object?> args) {
    final sw = Stopwatch()..start();
    final stmt = _allocStmt();
    try {
      _publish(stmt);
      final rc = using((arena) {
        Pointer<Uint8> s(int i) {
          final v = i < args.length ? args[i] : null;
          return v == null ? nullptr : api.toWide(v as String, arena);
        }

        int l(int i) {
          final v = i < args.length ? args[i] : null;
          return v == null ? 0 : api.wideLength(v as String);
        }

        switch (function) {
          case 'tables':
            return api.SQLTables(stmt, s(0), l(0), s(1), l(1), s(2), l(2), s(3), l(3));
          case 'columns':
            return api.SQLColumns(stmt, s(0), l(0), s(1), l(1), s(2), l(2), s(3), l(3));
          case 'primaryKeys':
            return api.SQLPrimaryKeys(stmt, s(0), l(0), s(1), l(1), s(2), l(2));
          case 'foreignKeys':
            return api.SQLForeignKeys(
              stmt,
              s(0),
              l(0),
              s(1),
              l(1),
              s(2),
              l(2),
              s(3),
              l(3),
              s(4),
              l(4),
              s(5),
              l(5),
            );
          case 'statistics':
            return api.SQLStatistics(stmt, s(0), l(0), s(1), l(1), s(2), l(2), SQL_INDEX_ALL, SQL_QUICK);
          case 'procedures':
            return api.SQLProcedures(stmt, s(0), l(0), s(1), l(1), s(2), l(2));
          case 'procedureColumns':
            return api.SQLProcedureColumns(stmt, s(0), l(0), s(1), l(1), s(2), l(2), s(3), l(3));
          case 'typeInfo':
            return api.SQLGetTypeInfo(stmt, SQL_ALL_TYPES);
          default:
            throw ArgumentError('Funzione catalogo sconosciuta: $function');
        }
      });
      _check(rc, 'SQL$function', SQL_HANDLE_STMT, stmt);
      final cols = _numResultCols(stmt);
      final columns = _describe(stmt, cols);
      final cursor = _Cursor(stmt, columns, columns.map(_fetchMode).toList());
      final rows = _fetchRows(cursor, 0);
      return ResultPage(columns: columns, rows: rows, elapsedMs: sw.elapsedMilliseconds);
    } finally {
      _freeStmt(stmt);
    }
  }

  // -------------------------------------------------------------------------

  void _check(int rc, String op, int handleType, SQLHANDLE h) {
    if (rc == SQL_SUCCESS || rc == SQL_SUCCESS_WITH_INFO) return;
    throw OdbcException(op, readDiagnostics(api, handleType, h), rc);
  }
}
