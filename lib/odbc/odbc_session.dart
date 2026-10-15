// Asynchronous ODBC session: every connection lives in its own isolate so
// that long running queries never block the UI thread.
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../drivers/db_session.dart';
import 'odbc_core.dart';
import 'odbc_ffi.dart';
import 'odbc_types.dart';

class _Request {
  _Request(this.id, this.op, this.args);
  final int id;
  final String op;
  final List<Object?> args;
}

class _Response {
  _Response(this.id, this.result, this.error);
  final int id;
  final Object? result;
  final Object? error;
}

class _Boot {
  _Boot(this.port, this.libPath, this.connectionString, this.loginTimeout, this.readOnly, this.cancelSlot);
  final SendPort port;
  final String libPath;
  final String connectionString;
  final int loginTimeout;
  final bool readOnly;
  final int cancelSlot;
}

class OdbcSession implements DbSession {
  OdbcSession._(
    this._api,
    this._isolate,
    this._send,
    this._receive,
    this._cancelSlot,
    this.completedConnectionString,
  );

  final OdbcApi _api;
  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _receive;
  final Pointer<IntPtr> _cancelSlot;
  @override
  final String completedConnectionString;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 1;
  bool _closed = false;
  int _busy = 0;

  @override
  bool get isClosed => _closed;
  @override
  bool get isBusy => _busy > 0;

  /// Opens a new session. [libPath] overrides the driver manager location.
  static Future<OdbcSession> open(
    String connectionString, {
    String? libPath,
    int loginTimeoutSec = 15,
    bool readOnly = false,
  }) async {
    final api = OdbcApi.load(libPath);
    final slot = calloc<IntPtr>()..value = 0;
    final receive = ReceivePort();
    final boot = Completer<Object?>();
    late SendPort send;
    final pending = <int, Completer<Object?>>{};
    OdbcSession? session;

    void failAll(Object error) {
      if (!boot.isCompleted) boot.completeError(error);
      final waiting = session?._pending ?? pending;
      for (final c in waiting.values) {
        if (!c.isCompleted) c.completeError(error);
      }
      waiting.clear();
      session?._closed = true;
    }

    receive.listen((msg) {
      if (msg is SendPort) {
        send = msg;
      } else if (msg is _Response) {
        if (msg.id == 0) {
          if (boot.isCompleted) return;
          msg.error != null ? boot.completeError(msg.error!) : boot.complete(msg.result);
          return;
        }
        final c = (session?._pending ?? pending).remove(msg.id);
        if (c == null) return;
        if (msg.error != null) {
          c.completeError(msg.error!);
        } else {
          c.complete(msg.result);
        }
      } else if (msg is List && msg.length == 2) {
        // Uncaught error in the worker isolate: [message, stack].
        failAll(StateError('Errore nel worker ODBC: ${msg[0]}'));
      } else if (msg == null) {
        failAll(StateError('Il worker ODBC è terminato'));
      }
    });

    final isolate = await Isolate.spawn(
      _workerMain,
      _Boot(receive.sendPort, api.path, connectionString, loginTimeoutSec, readOnly, slot.address),
      debugName: 'odbc-session',
      onError: receive.sendPort,
      onExit: receive.sendPort,
      errorsAreFatal: true,
    );
    // Safety net in case the driver never returns from the login.
    final bootTimeout = Duration(seconds: (loginTimeoutSec <= 0 ? 60 : loginTimeoutSec) + 30);
    try {
      final completed = await boot.future.timeout(bootTimeout) as String;
      session = OdbcSession._(api, isolate, send, receive, slot, completed);
      return session;
    } catch (e) {
      receive.close();
      isolate.kill(priority: Isolate.immediate);
      calloc.free(slot);
      if (e is TimeoutException) {
        throw StateError('Timeout di connessione: il driver ODBC non ha risposto');
      }
      rethrow;
    }
  }

  Future<T> _call<T>(String op, [List<Object?> args = const []]) {
    if (_closed) {
      return Future.error(StateError('Sessione ODBC chiusa'));
    }
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _busy++;
    _send.send(_Request(id, op, args));
    return c.future.then((v) => v as T).whenComplete(() => _busy--);
  }

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) => _call<ResultPage>('execute', [sql, params, fetchSize, queryTimeoutSec]);

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) => _call<ResultPage>('fetchMore', [cursorId, count]);

  @override
  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize) =>
      _call<ResultPage?>('nextResultSet', [cursorId, fetchSize]);

  @override
  Future<void> closeCursor(int cursorId) => _call<void>('closeCursor', [cursorId]);

  @override
  Future<ResultPage> catalog(String function, List<String?> args) =>
      _call<ResultPage>('catalog', [function, args]);

  @override
  Future<Map<String, Object?>> info() => _call<Map<String, Object?>>('info');

  @override
  Future<void> setAutoCommit(bool value) => _call<void>('autoCommit', [value]);

  @override
  Future<void> commit() => _call<void>('endTran', [true]);

  @override
  Future<void> rollback() => _call<void>('endTran', [false]);

  @override
  Future<void> setCurrentCatalog(String catalog) => _call<void>('setCatalog', [catalog]);

  @override
  Future<String?> currentCatalog() => _call<String?>('getCatalog');

  /// Asks the driver to cancel the running statement (SQLCancel is allowed
  /// from a different thread than the one executing the statement).
  @override
  void cancel() {
    if (_closed) return;
    final addr = _cancelSlot.value;
    if (addr != 0) {
      _api.SQLCancel(Pointer.fromAddress(addr));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await _call<void>('close').timeout(const Duration(seconds: 10));
    } catch (_) {
      // ignore – the isolate is killed anyway.
    }
    _closed = true;
    for (final c in _pending.values.where((c) => !c.isCompleted)) {
      c.completeError(StateError('Sessione ODBC chiusa'));
    }
    _pending.clear();
    _receive.close();
    _isolate.kill(priority: Isolate.immediate);
    calloc.free(_cancelSlot);
  }
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

void _workerMain(_Boot boot) {
  final port = ReceivePort();
  boot.port.send(port.sendPort);
  final api = OdbcApi.load(boot.libPath);
  final core = OdbcConnectionCore(api, cancelSlot: Pointer<IntPtr>.fromAddress(boot.cancelSlot));
  try {
    final completed = core.connect(
      boot.connectionString,
      loginTimeoutSec: boot.loginTimeout,
      readOnly: boot.readOnly,
    );
    boot.port.send(_Response(0, completed, null));
  } catch (e) {
    core.disconnect();
    boot.port.send(_Response(0, null, _sendableError(e)));
    port.close();
    return;
  }

  port.listen((msg) {
    if (msg is! _Request) return;
    Object? result;
    Object? error;
    try {
      final a = msg.args;
      switch (msg.op) {
        case 'execute':
          result = core.execute(
            a[0] as String,
            params: (a[1] as List).cast<Object?>(),
            fetchSize: a[2] as int,
            queryTimeoutSec: a[3] as int,
          );
        case 'fetchMore':
          result = core.fetchMore(a[0] as int, a[1] as int);
        case 'nextResultSet':
          result = core.nextResultSet(a[0] as int, a[1] as int);
        case 'closeCursor':
          core.closeCursor(a[0] as int);
        case 'catalog':
          result = core.catalog(a[0] as String, (a[1] as List).cast<Object?>());
        case 'info':
          result = core.getInfo();
        case 'autoCommit':
          core.setAutoCommit(a[0] as bool);
        case 'endTran':
          core.endTransaction(a[0] as bool);
        case 'setCatalog':
          core.setCurrentCatalog(a[0] as String);
        case 'getCatalog':
          result = core.getCurrentCatalog();
        case 'close':
          core.disconnect();
          boot.port.send(_Response(msg.id, null, null));
          port.close();
          return;
        default:
          throw ArgumentError('Operazione sconosciuta ${msg.op}');
      }
    } catch (e) {
      error = _sendableError(e);
    }
    boot.port.send(_Response(msg.id, result, error));
  });
}

Object _sendableError(Object e) {
  if (e is OdbcException || e is OdbcLoadException) return e;
  return Exception(e.toString());
}

/// Runs [fn] with a short-lived driver manager instance in a helper isolate.
Future<T> withOdbcApi<T>(String? libPath, T Function(OdbcApi api) fn) {
  return Isolate.run(() => fn(OdbcApi.load(libPath)));
}

Future<List<OdbcDriverInfo>> odbcDrivers([String? libPath]) => withOdbcApi(libPath, listDrivers);

Future<List<OdbcDataSource>> odbcDataSources([String? libPath]) => withOdbcApi(libPath, listDataSources);
