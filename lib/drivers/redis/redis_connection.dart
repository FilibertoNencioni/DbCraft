// A Redis connection: RESP over TCP/TLS with pipelining.
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../common/native_exception.dart';
import '../common/net.dart';
import 'resp.dart';

class RedisConnection {
  RedisConnection._(this.host, this.port, this._socket) {
    _sub = _socket.listen(
      _onData,
      onError: (Object e) => _failAll(e),
      onDone: () => _failAll(null),
      cancelOnError: true,
    );
  }

  final String host;
  final int port;
  final Socket _socket;
  late final StreamSubscription<List<int>> _sub;
  final RespParser _parser = RespParser();
  final Queue<Completer<Object?>> _pending = Queue();
  bool _closed = false;
  String? _abortReason;

  bool get isClosed => _closed;

  static Future<RedisConnection> connect(String host, int port, NetOptions net) async {
    final s = await connectSocket(host, port, net);
    return RedisConnection._(host, port, s);
  }

  void _onData(List<int> data) {
    try {
      _parser.feed(data);
    } catch (e) {
      _failAll(e);
      _socket.destroy();
      return;
    }
    while (_parser.replies.isNotEmpty && _pending.isNotEmpty) {
      _pending.removeFirst().complete(_parser.replies.removeFirst());
    }
    _parser.replies.clear();
  }

  void _failAll(Object? e) {
    _closed = true;
    final err = _abortReason != null
        ? NativeDbException(
            _abortReason == 'cancel' ? 'Operazione annullata' : 'Connessione interrotta ($_abortReason)',
          )
        : (e is NativeDbException
              ? e
              : NativeDbException(
                  e == null ? 'Connessione chiusa dal server Redis' : 'Connessione Redis interrotta: $e',
                ));
    while (_pending.isNotEmpty) {
      final c = _pending.removeFirst();
      if (!c.isCompleted) c.completeError(err);
    }
  }

  /// Sends a command and returns the raw reply (errors as [RedisError] values).
  Future<Object?> raw(List<Object> args) {
    if (_closed) return Future.error(NativeDbException('Connessione Redis chiusa'));
    final c = Completer<Object?>();
    _pending.add(c);
    _socket.add(encodeCommand(args));
    return c.future;
  }

  /// Sends a command; error replies are thrown.
  Future<Object?> call(List<Object> args) async {
    final r = await raw(args);
    if (r is RedisError) throw r;
    return r;
  }

  /// Sends several commands at once and returns all replies in order.
  Future<List<Object?>> pipeline(List<List<Object>> commands) {
    if (commands.isEmpty) return Future.value(const []);
    if (_closed) return Future.error(NativeDbException('Connessione Redis chiusa'));
    final futures = <Future<Object?>>[];
    final b = BytesBuilder(copy: false);
    for (final cmd in commands) {
      final c = Completer<Object?>();
      _pending.add(c);
      futures.add(c.future);
      b.add(encodeCommand(cmd));
    }
    _socket.add(b.takeBytes());
    return Future.wait(futures);
  }

  void abort(String reason) {
    if (_closed) return;
    _abortReason = reason;
    _socket.destroy();
    _failAll(null);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sub.cancel();
    } catch (_) {}
    _socket.destroy();
    _failAll(null);
  }
}
