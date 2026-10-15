// MongoDB wire protocol: OP_MSG (opcode 2013) framing.
import 'dart:convert';
import 'dart:typed_data';

import '../common/native_exception.dart';
import 'bson.dart';

const int opMsg = 2013;
const int opReply = 1;
const int opCompressed = 2012;

/// flagBits of OP_MSG.
const int msgChecksumPresent = 1;
const int msgMoreToCome = 2;

class OpMsg {
  OpMsg({
    required this.requestId,
    required this.responseTo,
    required this.body,
    this.flags = 0,
    this.sequences = const {},
  });

  final int requestId;
  final int responseTo;
  final int flags;
  final Map<String, Object?> body;

  /// Kind 1 sections: identifier → documents.
  final Map<String, List<Map<String, Object?>>> sequences;
}

/// Encodes an OP_MSG with a body section and optional document sequences.
Uint8List encodeOpMsg(
  int requestId,
  Map<String, Object?> body, {
  Map<String, List<Map<String, Object?>>> sequences = const {},
  int flags = 0,
  int responseTo = 0,
}) {
  final b = BytesBuilder(copy: false);
  final header = ByteData(20);
  b.add(header.buffer.asUint8List()); // patched below (16 header + 4 flags)
  b.addByte(0);
  b.add(encodeBson(body));
  sequences.forEach((id, docs) {
    final payload = BytesBuilder(copy: false);
    payload.add(utf8.encode(id));
    payload.addByte(0);
    for (final d in docs) {
      payload.add(encodeBson(d));
    }
    final p = payload.toBytes();
    b.addByte(1);
    final size = ByteData(4)..setInt32(0, p.length + 4, Endian.little);
    b.add(size.buffer.asUint8List());
    b.add(p);
  });
  final out = b.toBytes();
  final bd = ByteData.sublistView(out);
  bd.setInt32(0, out.length, Endian.little);
  bd.setInt32(4, requestId, Endian.little);
  bd.setInt32(8, responseTo, Endian.little);
  bd.setInt32(12, opMsg, Endian.little);
  bd.setUint32(16, flags, Endian.little);
  return out;
}

/// Decodes a full message (header included).
OpMsg decodeOpMsg(Uint8List msg) {
  final bd = ByteData.sublistView(msg);
  final length = bd.getInt32(0, Endian.little);
  final requestId = bd.getInt32(4, Endian.little);
  final responseTo = bd.getInt32(8, Endian.little);
  final opCode = bd.getInt32(12, Endian.little);
  if (opCode == opReply) {
    // Legacy OP_REPLY: flags, cursorId, startingFrom, numberReturned, docs.
    final docOffset = 16 + 20;
    final body = docOffset < length ? decodeBson(msg, docOffset) : <String, Object?>{};
    return OpMsg(requestId: requestId, responseTo: responseTo, body: body);
  }
  if (opCode == opCompressed) {
    throw NativeDbException('Messaggio compresso non supportato (compressione non negoziata)');
  }
  if (opCode != opMsg) throw NativeDbException('Opcode MongoDB inatteso: $opCode');
  final flags = bd.getUint32(16, Endian.little);
  final end = flags & msgChecksumPresent != 0 ? length - 4 : length;
  var pos = 20;
  Map<String, Object?>? body;
  final seqs = <String, List<Map<String, Object?>>>{};
  while (pos < end) {
    final kind = msg[pos++];
    if (kind == 0) {
      final len = bsonLength(msg, pos);
      body = decodeBson(msg, pos);
      pos += len;
    } else if (kind == 1) {
      final size = bd.getInt32(pos, Endian.little);
      final secEnd = pos + size;
      var p = pos + 4;
      final z = msg.indexOf(0, p);
      final id = utf8.decode(msg.sublist(p, z));
      p = z + 1;
      final docs = <Map<String, Object?>>[];
      while (p < secEnd) {
        final l = bsonLength(msg, p);
        docs.add(decodeBson(msg, p));
        p += l;
      }
      seqs[id] = docs;
      pos = secEnd;
    } else {
      throw NativeDbException('Sezione OP_MSG sconosciuta: $kind');
    }
  }
  if (body == null) throw NativeDbException('OP_MSG senza documento body');
  return OpMsg(requestId: requestId, responseTo: responseTo, body: body, flags: flags, sequences: seqs);
}
