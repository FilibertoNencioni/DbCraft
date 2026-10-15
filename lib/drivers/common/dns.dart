// Minimal DNS client (SRV and TXT records) used by mongodb+srv:// URIs.
// Queries the resolvers of /etc/resolv.conf over UDP (falling back to TCP on
// truncation) and public resolvers when none is configured.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'native_exception.dart';

class SrvRecord {
  const SrvRecord(this.priority, this.weight, this.port, this.target);
  final int priority;
  final int weight;
  final int port;
  final String target;

  @override
  String toString() => '$target:$port';
}

const dnsTypeTxt = 16;
const dnsTypeSrv = 33;

/// Nameservers from /etc/resolv.conf plus public fallbacks.
Future<List<String>> systemNameservers() async {
  final out = <String>[];
  try {
    final f = File('/etc/resolv.conf');
    if (await f.exists()) {
      for (final l in await f.readAsLines()) {
        final m = RegExp(r'^\s*nameserver\s+(\S+)').firstMatch(l);
        if (m != null) out.add(m.group(1)!.split('%').first);
      }
    }
  } catch (_) {}
  for (final f in const ['1.1.1.1', '8.8.8.8']) {
    if (!out.contains(f)) out.add(f);
  }
  return out;
}

/// Encodes a DNS query for [name] / [type].
Uint8List buildDnsQuery(int id, String name, int type) {
  final b = BytesBuilder();
  b.add([id >> 8 & 0xff, id & 0xff, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final label in name.split('.').where((e) => e.isNotEmpty)) {
    final l = utf8.encode(label);
    b.addByte(l.length);
    b.add(l);
  }
  b.add([0, type >> 8, type & 0xff, 0, 1]);
  return b.toBytes();
}

/// Parsed answer: list of (type, rdata offset, rdata length) plus the raw
/// message (needed for name decompression).
class DnsMessage {
  DnsMessage(this.data);
  final Uint8List data;

  int get id => data[0] << 8 | data[1];
  bool get truncated => data[2] & 0x02 != 0;
  int get rcode => data[3] & 0x0f;

  int _u16(int o) => data[o] << 8 | data[o + 1];

  (String, int) readName(int o) {
    final labels = <String>[];
    var jumped = false;
    var end = o;
    var guard = 0;
    while (true) {
      if (o >= data.length || guard++ > 128) throw NativeDbException('Risposta DNS non valida');
      final len = data[o];
      if (len == 0) {
        if (!jumped) end = o + 1;
        break;
      }
      if (len & 0xc0 == 0xc0) {
        if (!jumped) end = o + 2;
        o = ((len & 0x3f) << 8) | data[o + 1];
        jumped = true;
        continue;
      }
      labels.add(utf8.decode(data.sublist(o + 1, o + 1 + len), allowMalformed: true));
      o += len + 1;
    }
    return (labels.join('.'), end);
  }

  /// Answer records of [type].
  List<(int, int)> answers(int type) {
    final qd = _u16(4), an = _u16(6);
    var o = 12;
    for (var i = 0; i < qd; i++) {
      o = readName(o).$2 + 4;
    }
    final out = <(int, int)>[];
    for (var i = 0; i < an; i++) {
      o = readName(o).$2;
      final t = _u16(o);
      final len = _u16(o + 8);
      final rd = o + 10;
      if (t == type) out.add((rd, len));
      o = rd + len;
    }
    return out;
  }

  List<SrvRecord> srv() => [
    for (final (o, _) in answers(dnsTypeSrv)) SrvRecord(_u16(o), _u16(o + 2), _u16(o + 4), readName(o + 6).$1),
  ];

  /// TXT records (the character strings of each record are concatenated).
  List<String> txt() {
    final out = <String>[];
    for (final (o, len) in answers(dnsTypeTxt)) {
      final sb = StringBuffer();
      var p = o;
      while (p < o + len) {
        final l = data[p];
        sb.write(utf8.decode(data.sublist(p + 1, p + 1 + l), allowMalformed: true));
        p += l + 1;
      }
      out.add(sb.toString());
    }
    return out;
  }
}

Future<DnsMessage> _udp(String server, Uint8List q, int id, Duration timeout) async {
  final addr = InternetAddress(server);
  final sock = await RawDatagramSocket.bind(
    addr.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
    0,
  );
  final c = Completer<DnsMessage>();
  final sub = sock.listen((ev) {
    if (ev != RawSocketEvent.read) return;
    final d = sock.receive();
    if (d == null || d.data.length < 12) return;
    final m = DnsMessage(d.data);
    if (m.id == id && !c.isCompleted) c.complete(m);
  });
  try {
    sock.send(q, addr, 53);
    return await c.future.timeout(timeout);
  } finally {
    await sub.cancel();
    sock.close();
  }
}

Future<DnsMessage> _tcp(String server, Uint8List q, Duration timeout) async {
  final s = await Socket.connect(server, 53, timeout: timeout);
  try {
    s.add([q.length >> 8, q.length & 0xff, ...q]);
    final buf = BytesBuilder();
    await for (final chunk in s.timeout(timeout)) {
      buf.add(chunk);
      final b = buf.toBytes();
      if (b.length >= 2 && b.length >= 2 + (b[0] << 8 | b[1])) {
        return DnsMessage(Uint8List.sublistView(b, 2, 2 + (b[0] << 8 | b[1])));
      }
    }
    throw NativeDbException('Risposta DNS incompleta da $server');
  } finally {
    s.destroy();
  }
}

/// Queries [name] for records of [type].
Future<DnsMessage> dnsQuery(
  String name,
  int type, {
  List<String>? servers,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final list = servers ?? await systemNameservers();
  Object? last;
  for (final server in list) {
    final id = Random().nextInt(0xffff);
    final q = buildDnsQuery(id, name, type);
    try {
      var m = await _udp(server, q, id, timeout);
      if (m.truncated) m = await _tcp(server, q, timeout);
      if (m.rcode == 3) throw NativeDbException('Nome DNS inesistente: $name');
      if (m.rcode != 0) throw NativeDbException('Errore DNS ${m.rcode} per $name');
      return m;
    } on NativeDbException catch (e) {
      if (e.message.startsWith('Nome DNS inesistente')) rethrow;
      last = e;
    } catch (e) {
      last = e;
    }
  }
  throw NativeDbException('Risoluzione DNS di $name non riuscita: $last');
}

Future<List<SrvRecord>> resolveSrv(String name) async {
  final r = (await dnsQuery(name, dnsTypeSrv)).srv();
  r.sort((a, b) => a.priority != b.priority ? a.priority.compareTo(b.priority) : b.weight.compareTo(a.weight));
  return r;
}

Future<List<String>> resolveTxt(String name) async {
  try {
    return (await dnsQuery(name, dnsTypeTxt)).txt();
  } on NativeDbException catch (e) {
    if (e.message.startsWith('Nome DNS inesistente')) return const [];
    rethrow;
  }
}
