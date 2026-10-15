// A connection to a Cassandra node over the CQL native protocol (v4 with
// fallback to v3): STARTUP, SASL PLAIN authentication, QUERY / PREPARE /
// EXECUTE with paging.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../common/native_exception.dart';
import '../common/net.dart';
import 'cql_protocol.dart';

const cassandraDriverVersion = '1.0.0';

class CqlColumn {
  const CqlColumn(this.keyspace, this.table, this.name, this.type);
  final String keyspace;
  final String table;
  final String name;
  final CqlType type;
}

class CqlRows {
  CqlRows(this.columns, this.rows, this.pagingState);
  final List<CqlColumn> columns;
  final List<List<Uint8List?>> rows;
  final Uint8List? pagingState;
}

class CqlResult {
  CqlResult(
    this.kind, {
    this.rows,
    this.keyspace,
    this.schemaChange,
    this.preparedId,
    this.boundVariables = const [],
    this.resultColumns = const [],
  });
  final int kind;
  final CqlRows? rows;
  final String? keyspace;
  final String? schemaChange;
  final Uint8List? preparedId;
  final List<CqlColumn> boundVariables;
  final List<CqlColumn> resultColumns;
}

/// Reads the column specification of a rows / prepared metadata block.
/// Returns (flags, columns, pagingState).
(int, List<CqlColumn>, Uint8List?) _readMetadata(CqlReader r, {bool prepared = false, int version = 4}) {
  final flags = r.int32();
  final count = r.int32();
  if (prepared && version >= 4) {
    final pk = r.int32();
    for (var i = 0; i < pk; i++) {
      r.short();
    }
  }
  Uint8List? paging;
  if (!prepared && flags & 0x0002 != 0) paging = r.bytes();
  if (flags & 0x0004 != 0) return (flags, const [], paging);
  String? gks, gt;
  if (flags & 0x0001 != 0) {
    gks = r.string();
    gt = r.string();
  }
  final cols = <CqlColumn>[];
  for (var i = 0; i < count; i++) {
    final ks = gks ?? r.string();
    final t = gt ?? r.string();
    cols.add(CqlColumn(ks, t, r.string(), CqlType.read(r)));
  }
  return (flags, cols, paging);
}

/// Parses a RESULT body.
CqlResult parseCqlResult(CqlReader r, {int version = 4}) {
  final kind = r.int32();
  switch (kind) {
    case resultRows:
      final (_, cols, paging) = _readMetadata(r);
      final n = r.int32();
      final rows = <List<Uint8List?>>[];
      for (var i = 0; i < n; i++) {
        rows.add([for (var j = 0; j < cols.length; j++) r.bytes()]);
      }
      return CqlResult(kind, rows: CqlRows(cols, rows, paging));
    case resultSetKeyspace:
      return CqlResult(kind, keyspace: r.string());
    case resultPrepared:
      final id = Uint8List.fromList(r.shortBytes());
      final (_, bound, _) = _readMetadata(r, prepared: true, version: version);
      final (_, resultCols, _) = _readMetadata(r);
      return CqlResult(kind, preparedId: id, boundVariables: bound, resultColumns: resultCols);
    case resultSchemaChange:
      final change = r.string();
      final target = r.string();
      final ks = r.string();
      var what = '$target $ks';
      if (target != 'KEYSPACE') {
        what = '$target $ks.${r.string()}';
      }
      return CqlResult(kind, schemaChange: '$change $what');
    default:
      return CqlResult(kind);
  }
}

/// Encodes the query parameters of QUERY / EXECUTE.
Uint8List encodeQueryParameters({
  required int consistency,
  List<Uint8List?>? values,
  int pageSize = 0,
  Uint8List? pagingState,
  bool skipMetadata = false,
}) {
  var flags = 0;
  if (values != null && values.isNotEmpty) flags |= 0x01;
  if (skipMetadata) flags |= 0x02;
  if (pageSize > 0) flags |= 0x04;
  if (pagingState != null) flags |= 0x08;
  final w = CqlWriter()
    ..short(consistency)
    ..byte(flags);
  if (flags & 0x01 != 0) {
    w.short(values!.length);
    for (final v in values) {
      w.bytes(v);
    }
  }
  if (pageSize > 0) w.int32(pageSize);
  if (pagingState != null) w.bytes(pagingState);
  return w.take();
}

class CqlConnection {
  CqlConnection._(this.host, this.port, this._socket, this.version) : _reader = ByteReader(_socket);

  final String host;
  final int port;
  final Socket _socket;
  final ByteReader _reader;
  final int version;
  int _stream = 0;
  bool _closed = false;
  List<String> lastWarnings = const [];

  bool get isClosed => _closed || _reader.isDone;

  /// Opens and authenticates a connection (protocol v4, then v3).
  static Future<CqlConnection> connect(
    String host,
    int port,
    NetOptions net, {
    String user = '',
    String password = '',
  }) async {
    CqlException? protocolError;
    for (final v in const [4, 3]) {
      final s = await connectSocket(host, port, net);
      final c = CqlConnection._(host, port, s, v);
      try {
        await c._startup(user, password);
        return c;
      } on CqlException catch (e) {
        await c.close();
        if (e.errorCode == 0x000A) {
          protocolError = e;
          continue;
        }
        rethrow;
      } on NativeDbException catch (e) {
        await c.close();
        // Some old servers just drop the connection on an unknown version.
        if (v == 4 && e.message.startsWith('Connessione chiusa')) continue;
        rethrow;
      } catch (_) {
        await c.close();
        rethrow;
      }
    }
    throw NativeDbException('Protocollo CQL non supportato dal server: ${protocolError?.message}');
  }

  Future<void> _startup(String user, String password) async {
    var (op, r) = await request(
      opStartup,
      (CqlWriter()
            ..stringMap({'CQL_VERSION': '3.0.0', 'DRIVER_NAME': 'DbCraft', 'DRIVER_VERSION': cassandraDriverVersion}))
          .take(),
    );
    if (op == opReady) return;
    if (op != opAuthenticate) throw NativeDbException('Risposta CQL inattesa a STARTUP (opcode $op)');
    final authenticator = r.string();
    if (user.isEmpty) {
      throw NativeDbException('Il server richiede l\'autenticazione ($authenticator): indica utente e password');
    }
    final plain = Uint8List.fromList(utf8.encode('\u0000$user\u0000$password'));
    final dse = authenticator.contains('DseAuthenticator');
    var token = dse ? Uint8List.fromList(utf8.encode('PLAIN')) : plain;
    for (var step = 0; step < 4; step++) {
      try {
        (op, r) = await request(opAuthResponse, (CqlWriter()..bytes(token)).take());
      } on CqlException catch (e) {
        if (e.errorCode == 0x0100) {
          throw NativeDbException(
            'Autenticazione Cassandra fallita: ${e.message}',
            code: 'Bad credentials',
            source: 'Cassandra',
          );
        }
        rethrow;
      }
      if (op == opAuthSuccess) return;
      if (op != opAuthChallenge) {
        throw NativeDbException('Risposta CQL inattesa durante l\'autenticazione (opcode $op)');
      }
      r.bytes(); // DSE sends "PLAIN-START": answer with the PLAIN token.
      token = plain;
    }
    throw NativeDbException('Autenticazione Cassandra non completata');
  }

  /// Sends a request frame and returns (opcode, body) of the response.
  Future<(int, CqlReader)> request(int opcode, Uint8List body) async {
    if (isClosed) throw NativeDbException('Connessione Cassandra chiusa');
    final stream = _stream = (_stream + 1) & 0x7fff;
    _socket.add(encodeFrame(version, stream, opcode, body));
    while (true) {
      final h = CqlFrameHeader.parse(await _reader.read(9));
      final data = h.length == 0 ? Uint8List(0) : await _reader.read(h.length);
      if (h.stream != stream) continue; // events or stale responses
      final r = CqlReader(data);
      final warnings = <String>[];
      if (h.flags & 0x02 != 0) r.pos += 16; // tracing id
      if (h.flags & 0x08 != 0) warnings.addAll(r.stringList());
      if (h.flags & 0x04 != 0) r.bytesMap();
      lastWarnings = warnings;
      if (h.opcode == opError) {
        final code = r.int32();
        final msg = r.string();
        throw CqlException(code, msg);
      }
      return (h.opcode, r);
    }
  }

  Future<CqlResult> query(String cql, {required int consistency, int pageSize = 0, Uint8List? pagingState}) async {
    final w = CqlWriter()
      ..longString(cql)
      ..raw(encodeQueryParameters(consistency: consistency, pageSize: pageSize, pagingState: pagingState));
    final (op, r) = await request(opQuery, w.take());
    if (op != opResult) throw NativeDbException('Risposta CQL inattesa (opcode $op)');
    return parseCqlResult(r, version: version);
  }

  Future<CqlResult> prepare(String cql) async {
    final (op, r) = await request(opPrepare, (CqlWriter()..longString(cql)).take());
    if (op != opResult) throw NativeDbException('Risposta CQL inattesa a PREPARE (opcode $op)');
    return parseCqlResult(r, version: version);
  }

  Future<CqlResult> execute(
    Uint8List id,
    List<Uint8List?> values, {
    required int consistency,
    int pageSize = 0,
    Uint8List? pagingState,
  }) async {
    final w = CqlWriter()
      ..shortBytes(id)
      ..raw(
        encodeQueryParameters(consistency: consistency, values: values, pageSize: pageSize, pagingState: pagingState),
      );
    final (op, r) = await request(opExecute, w.take());
    if (op != opResult) throw NativeDbException('Risposta CQL inattesa a EXECUTE (opcode $op)');
    return parseCqlResult(r, version: version);
  }

  void abort(String reason) {
    if (_closed) return;
    _closed = true;
    _reader.fail(NativeDbException(reason == 'cancel' ? 'Operazione annullata' : 'Connessione interrotta ($reason)'));
    _socket.destroy();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reader.fail(NativeDbException('Connessione Cassandra chiusa'));
    _socket.destroy();
  }
}
