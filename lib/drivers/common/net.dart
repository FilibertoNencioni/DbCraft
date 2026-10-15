// Networking helpers shared by the native drivers: TCP / TLS connection with
// timeout and a buffered reader that returns exact byte counts.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'native_exception.dart';

/// Transport options (TLS, certificates, timeout).
class NetOptions {
  const NetOptions({
    this.tls = false,
    this.caFile = '',
    this.allowInvalidCertificates = false,
    this.certFile = '',
    this.keyFile = '',
    this.keyPassword = '',
    this.timeout = const Duration(seconds: 15),
  });

  final bool tls;

  /// PEM file with the trusted certification authorities (empty: system roots).
  final String caFile;
  final bool allowInvalidCertificates;

  /// Client certificate (PEM) and private key (may be the same file).
  final String certFile;
  final String keyFile;
  final String keyPassword;
  final Duration timeout;

  NetOptions copyWith({bool? tls, Duration? timeout}) => NetOptions(
    tls: tls ?? this.tls,
    caFile: caFile,
    allowInvalidCertificates: allowInvalidCertificates,
    certFile: certFile,
    keyFile: keyFile,
    keyPassword: keyPassword,
    timeout: timeout ?? this.timeout,
  );

  SecurityContext securityContext() {
    final ctx = SecurityContext(withTrustedRoots: true);
    if (caFile.isNotEmpty) {
      try {
        ctx.setTrustedCertificates(caFile);
      } catch (e) {
        throw NativeDbException('Impossibile leggere il file CA "$caFile": $e');
      }
    }
    if (certFile.isNotEmpty) {
      try {
        ctx.useCertificateChain(certFile);
        ctx.usePrivateKey(keyFile.isEmpty ? certFile : keyFile, password: keyPassword.isEmpty ? null : keyPassword);
      } catch (e) {
        throw NativeDbException('Impossibile leggere il certificato client "$certFile": $e');
      }
    }
    return ctx;
  }
}

/// Opens a TCP (or TLS) connection to [host]:[port].
Future<Socket> connectSocket(String host, int port, NetOptions o) async {
  try {
    final Socket s;
    if (o.tls) {
      s = await SecureSocket.connect(
        host,
        port,
        context: o.securityContext(),
        onBadCertificate: o.allowInvalidCertificates ? (_) => true : null,
        timeout: o.timeout,
      );
    } else {
      s = await Socket.connect(host, port, timeout: o.timeout);
    }
    s.setOption(SocketOption.tcpNoDelay, true);
    return s;
  } on NativeDbException {
    rethrow;
  } on HandshakeException catch (e) {
    throw NativeDbException('Errore TLS verso $host:$port: ${e.message}${e.osError == null ? '' : ' (${e.osError})'}');
  } on SocketException catch (e) {
    final why = e.osError?.message ?? e.message;
    throw NativeDbException('Impossibile connettersi a $host:$port: $why');
  } on TimeoutException {
    throw NativeDbException('Timeout di connessione verso $host:$port (${o.timeout.inSeconds} s)');
  }
}

/// Buffers the bytes of a stream and returns them in exact-sized chunks.
class ByteReader {
  ByteReader(Stream<List<int>> stream) {
    _sub = stream.listen(_onData, onError: _onError, onDone: _onDone, cancelOnError: true);
  }

  late final StreamSubscription<List<int>> _sub;
  Uint8List _buf = Uint8List(8192);
  int _start = 0;
  int _end = 0;
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;

  int get available => _end - _start;
  bool get isDone => _done || _error != null;

  void _onData(List<int> data) {
    final need = _end + data.length;
    if (need > _buf.length) {
      final live = _end - _start;
      if (live + data.length <= _buf.length ~/ 2) {
        _buf.setRange(0, live, _buf, _start);
      } else {
        var size = _buf.length * 2;
        while (size < live + data.length) {
          size *= 2;
        }
        final nb = Uint8List(size)..setRange(0, live, _buf, _start);
        _buf = nb;
      }
      _start = 0;
      _end = live;
    }
    _buf.setRange(_end, _end + data.length, data);
    _end += data.length;
    _wake();
  }

  void _onError(Object e) {
    _error = e;
    _wake();
  }

  void _onDone() {
    _done = true;
    _wake();
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _more() {
    if (_error != null) {
      final e = _error!;
      return Future.error(e is NativeDbException ? e : NativeDbException('Connessione interrotta: $e'));
    }
    if (_done) return Future.error(NativeDbException('Connessione chiusa dal server'));
    return (_waiter ??= Completer<void>()).future;
  }

  /// Reads exactly [n] bytes.
  Future<Uint8List> read(int n) async {
    while (available < n) {
      await _more();
    }
    final out = Uint8List.fromList(Uint8List.sublistView(_buf, _start, _start + n));
    _start += n;
    if (_start == _end) _start = _end = 0;
    return out;
  }

  /// Fails the pending and future reads (used when the socket is closed
  /// locally, e.g. on cancel).
  void fail(Object error) {
    _error ??= error;
    _wake();
  }

  Future<void> cancel() => _sub.cancel();
}

/// Reads a little-endian int32 from [b] at [o].
int readInt32LE(Uint8List b, int o) => ByteData.sublistView(b).getInt32(o, Endian.little);
