// CQL native protocol (v3 / v4): frames, primitive notation, type options
// and value codecs.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../common/native_exception.dart';

const opError = 0x00;
const opStartup = 0x01;
const opReady = 0x02;
const opAuthenticate = 0x03;
const opOptions = 0x05;
const opSupported = 0x06;
const opQuery = 0x07;
const opResult = 0x08;
const opPrepare = 0x09;
const opExecute = 0x0A;
const opRegister = 0x0B;
const opEvent = 0x0C;
const opBatch = 0x0D;
const opAuthChallenge = 0x0E;
const opAuthResponse = 0x0F;
const opAuthSuccess = 0x10;

const resultVoid = 1;
const resultRows = 2;
const resultSetKeyspace = 3;
const resultPrepared = 4;
const resultSchemaChange = 5;

/// Consistency levels by name.
const cqlConsistency = {
  'ANY': 0,
  'ONE': 1,
  'TWO': 2,
  'THREE': 3,
  'QUORUM': 4,
  'ALL': 5,
  'LOCAL_QUORUM': 6,
  'EACH_QUORUM': 7,
  'SERIAL': 8,
  'LOCAL_SERIAL': 9,
  'LOCAL_ONE': 10,
};

const _errorNames = {
  0x0000: 'Server error',
  0x000A: 'Protocol error',
  0x0100: 'Bad credentials',
  0x1000: 'Unavailable',
  0x1001: 'Overloaded',
  0x1002: 'Bootstrapping',
  0x1003: 'Truncate error',
  0x1100: 'Write timeout',
  0x1200: 'Read timeout',
  0x1300: 'Read failure',
  0x1400: 'Function failure',
  0x1500: 'Write failure',
  0x2000: 'Syntax error',
  0x2100: 'Unauthorized',
  0x2200: 'Invalid',
  0x2300: 'Config error',
  0x2400: 'Already exists',
  0x2500: 'Unprepared',
};

class CqlException extends NativeDbException {
  CqlException(this.errorCode, String message)
    : super(message, code: _errorNames[errorCode] ?? '0x${errorCode.toRadixString(16)}', source: 'Cassandra');
  final int errorCode;
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// Encodes a request frame (protocol v3+ header: 9 bytes).
Uint8List encodeFrame(int version, int stream, int opcode, Uint8List body, {int flags = 0}) {
  final out = Uint8List(9 + body.length);
  final bd = ByteData.sublistView(out);
  out[0] = version & 0x7f;
  out[1] = flags;
  bd.setInt16(2, stream);
  out[4] = opcode;
  bd.setInt32(5, body.length);
  out.setRange(9, out.length, body);
  return out;
}

class CqlFrameHeader {
  CqlFrameHeader(this.version, this.isResponse, this.flags, this.stream, this.opcode, this.length);
  final int version;
  final bool isResponse;
  final int flags;
  final int stream;
  final int opcode;
  final int length;

  static CqlFrameHeader parse(Uint8List h) {
    final bd = ByteData.sublistView(h);
    return CqlFrameHeader(h[0] & 0x7f, h[0] & 0x80 != 0, h[1], bd.getInt16(2), h[4], bd.getInt32(5));
  }
}

// ---------------------------------------------------------------------------
// Primitive notation
// ---------------------------------------------------------------------------

class CqlWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void byte(int v) => _b.addByte(v & 0xff);

  void short(int v) => _b.add([v >> 8 & 0xff, v & 0xff]);

  void int32(int v) => _b.add((ByteData(4)..setInt32(0, v)).buffer.asUint8List());

  void int64(int v) => _b.add((ByteData(8)..setInt64(0, v)).buffer.asUint8List());

  void raw(List<int> v) => _b.add(v);

  void string(String s) {
    final e = utf8.encode(s);
    short(e.length);
    _b.add(e);
  }

  void longString(String s) {
    final e = utf8.encode(s);
    int32(e.length);
    _b.add(e);
  }

  /// [bytes]: int length (-1 = null) + data.
  void bytes(List<int>? v) {
    if (v == null) {
      int32(-1);
    } else {
      int32(v.length);
      _b.add(v);
    }
  }

  void shortBytes(List<int> v) {
    short(v.length);
    _b.add(v);
  }

  void stringMap(Map<String, String> m) {
    short(m.length);
    m.forEach((k, v) {
      string(k);
      string(v);
    });
  }

  Uint8List take() => _b.takeBytes();
}

class CqlReader {
  CqlReader(this.b, [this.pos = 0]) : bd = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData bd;
  int pos;

  bool get atEnd => pos >= b.length;

  int byte() => b[pos++];

  int short() {
    final v = bd.getUint16(pos);
    pos += 2;
    return v;
  }

  int int32() {
    final v = bd.getInt32(pos);
    pos += 4;
    return v;
  }

  int int64() {
    final v = bd.getInt64(pos);
    pos += 8;
    return v;
  }

  String string() {
    final n = short();
    final s = utf8.decode(Uint8List.sublistView(b, pos, pos + n), allowMalformed: true);
    pos += n;
    return s;
  }

  String longString() {
    final n = int32();
    final s = utf8.decode(Uint8List.sublistView(b, pos, pos + n), allowMalformed: true);
    pos += n;
    return s;
  }

  Uint8List? bytes() {
    final n = int32();
    if (n < 0) return null;
    final v = Uint8List.sublistView(b, pos, pos + n);
    pos += n;
    return v;
  }

  Uint8List shortBytes() {
    final n = short();
    final v = Uint8List.sublistView(b, pos, pos + n);
    pos += n;
    return v;
  }

  List<String> stringList() => [for (var i = short(); i > 0; i--) string()];

  Map<String, List<String>> stringMultimap() => {for (var i = short(); i > 0; i--) string(): stringList()};

  Map<String, Uint8List?> bytesMap() => {for (var i = short(); i > 0; i--) string(): bytes()};
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

class CqlType {
  CqlType(this.id, {this.custom, this.params = const [], this.keyspace, this.name, this.fields = const []});

  static const custom0 = 0x0000;
  static const ascii = 0x0001;
  static const bigint = 0x0002;
  static const blob = 0x0003;
  static const boolean = 0x0004;
  static const counter = 0x0005;
  static const decimal = 0x0006;
  static const double_ = 0x0007;
  static const float = 0x0008;
  static const int_ = 0x0009;
  static const timestamp = 0x000B;
  static const uuid = 0x000C;
  static const varchar = 0x000D;
  static const varint = 0x000E;
  static const timeuuid = 0x000F;
  static const inet = 0x0010;
  static const date = 0x0011;
  static const time = 0x0012;
  static const smallint = 0x0013;
  static const tinyint = 0x0014;
  static const duration = 0x0015;
  static const list = 0x0020;
  static const map = 0x0021;
  static const set = 0x0022;
  static const udt = 0x0030;
  static const tuple = 0x0031;

  final int id;
  final String? custom;
  final List<CqlType> params;
  final String? keyspace;
  final String? name;
  final List<(String, CqlType)> fields;

  bool get isDuration => id == duration || (id == custom0 && (custom ?? '').endsWith('DurationType'));

  bool get isCollection => id == list || id == set || id == map || id == tuple || id == udt;

  static CqlType read(CqlReader r) {
    final id = r.short();
    switch (id) {
      case custom0:
        return CqlType(id, custom: r.string());
      case list:
      case set:
        return CqlType(id, params: [read(r)]);
      case map:
        return CqlType(id, params: [read(r), read(r)]);
      case udt:
        final ks = r.string();
        final n = r.string();
        final count = r.short();
        return CqlType(id, keyspace: ks, name: n, fields: [for (var i = 0; i < count; i++) (r.string(), read(r))]);
      case tuple:
        final count = r.short();
        return CqlType(id, params: [for (var i = 0; i < count; i++) read(r)]);
      default:
        return CqlType(id);
    }
  }

  @override
  String toString() => switch (id) {
    custom0 => isDuration ? 'duration' : "'${custom ?? ''}'",
    ascii => 'ascii',
    bigint => 'bigint',
    blob => 'blob',
    boolean => 'boolean',
    counter => 'counter',
    decimal => 'decimal',
    double_ => 'double',
    float => 'float',
    int_ => 'int',
    timestamp => 'timestamp',
    uuid => 'uuid',
    varchar => 'text',
    varint => 'varint',
    timeuuid => 'timeuuid',
    inet => 'inet',
    date => 'date',
    time => 'time',
    smallint => 'smallint',
    tinyint => 'tinyint',
    duration => 'duration',
    list => 'list<${params.first}>',
    set => 'set<${params.first}>',
    map => 'map<${params[0]}, ${params[1]}>',
    udt => 'frozen<${name ?? ''}>',
    tuple => 'tuple<${params.join(', ')}>',
    _ => 'type(0x${id.toRadixString(16)})',
  };
}

// ---------------------------------------------------------------------------
// Value decoding
// ---------------------------------------------------------------------------

BigInt _bigFromBytes(Uint8List b) {
  if (b.isEmpty) return BigInt.zero;
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  if (b[0] & 0x80 != 0) v -= BigInt.one << (8 * b.length);
  return v;
}

Uint8List _bigToBytes(BigInt v) {
  final out = <int>[];
  var x = v;
  while (true) {
    out.insert(0, (x & BigInt.from(0xff)).toInt());
    x = x >> 8;
    final top = out.first & 0x80;
    if ((x == BigInt.zero && top == 0) || (x == BigInt.from(-1) && top != 0)) break;
  }
  return Uint8List.fromList(out);
}

String _two(int v, [int w = 2]) => v.toString().padLeft(w, '0');

String formatUuid(Uint8List b) {
  final h = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String formatCqlDate(int unsignedDays) {
  final d = DateTime.utc(1970).add(Duration(days: unsignedDays - 0x80000000));
  return '${_two(d.year, 4)}-${_two(d.month)}-${_two(d.day)}';
}

String formatCqlTime(int nanos) {
  final h = nanos ~/ 3600000000000;
  final m = nanos ~/ 60000000000 % 60;
  final s = nanos ~/ 1000000000 % 60;
  final frac = nanos % 1000000000;
  final base = '${_two(h)}:${_two(m)}:${_two(s)}';
  if (frac == 0) return base;
  return '$base.${frac.toString().padLeft(9, '0').replaceFirst(RegExp(r'0+$'), '')}';
}

(int, int) _readVint(Uint8List b, int pos) {
  final first = b[pos];
  if (first & 0x80 == 0) return (first, pos + 1);
  var extra = 0;
  while (extra < 8 && (first << extra) & 0x80 != 0) {
    extra++;
  }
  var v = extra >= 8 ? 0 : first & (0xff >> extra);
  for (var i = 1; i <= extra; i++) {
    v = (v << 8) | b[pos + i];
  }
  return (v, pos + 1 + extra);
}

int _zigzag(int v) => (v >>> 1) ^ -(v & 1);

String formatDuration(int months, int days, int nanos) {
  if (months == 0 && days == 0 && nanos == 0) return '0s';
  final neg = months < 0 || days < 0 || nanos < 0;
  months = months.abs();
  days = days.abs();
  nanos = nanos.abs();
  final sb = StringBuffer(neg ? '-' : '');
  void part(int v, String u) {
    if (v != 0) sb.write('$v$u');
  }

  part(months ~/ 12, 'y');
  part(months % 12, 'mo');
  part(days, 'd');
  part(nanos ~/ 3600000000000, 'h');
  part(nanos ~/ 60000000000 % 60, 'm');
  part(nanos ~/ 1000000000 % 60, 's');
  part(nanos ~/ 1000000 % 1000, 'ms');
  part(nanos ~/ 1000 % 1000, 'us');
  part(nanos % 1000, 'ns');
  return sb.toString();
}

/// Decodes a value to a Dart value (collections as List / Map).
Object? decodeCqlValue(CqlType t, Uint8List? b) {
  if (b == null) return null;
  final bd = ByteData.sublistView(b);
  switch (t.id) {
    case CqlType.ascii:
    case CqlType.varchar:
      return utf8.decode(b, allowMalformed: true);
    case CqlType.bigint:
    case CqlType.counter:
      return b.length == 8 ? bd.getInt64(0) : _bigFromBytes(b).toInt();
    case CqlType.int_:
      return b.length == 4 ? bd.getInt32(0) : null;
    case CqlType.smallint:
      return b.length == 2 ? bd.getInt16(0) : null;
    case CqlType.tinyint:
      return b.length == 1 ? bd.getInt8(0) : null;
    case CqlType.blob:
      return Uint8List.fromList(b);
    case CqlType.boolean:
      return b.isEmpty ? null : b[0] != 0;
    case CqlType.double_:
      return b.length == 8 ? bd.getFloat64(0) : null;
    case CqlType.float:
      return b.length == 4 ? bd.getFloat32(0) : null;
    case CqlType.decimal:
      if (b.length < 4) return null;
      final scale = bd.getInt32(0);
      final unscaled = _bigFromBytes(Uint8List.sublistView(b, 4));
      return formatDecimal(unscaled, scale);
    case CqlType.varint:
      final v = _bigFromBytes(b);
      return v.isValidInt ? v.toInt() : v.toString();
    case CqlType.timestamp:
      if (b.length != 8) return null;
      final ms = bd.getInt64(0);
      try {
        return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();
      } catch (_) {
        return '$ms';
      }
    case CqlType.uuid:
    case CqlType.timeuuid:
      return b.length == 16 ? formatUuid(b) : null;
    case CqlType.inet:
      try {
        return InternetAddress.fromRawAddress(Uint8List.fromList(b)).address;
      } catch (_) {
        return null;
      }
    case CqlType.date:
      return b.length == 4 ? formatCqlDate(bd.getUint32(0)) : null;
    case CqlType.time:
      return b.length == 8 ? formatCqlTime(bd.getInt64(0)) : null;
    case CqlType.list:
    case CqlType.set:
      final r = CqlReader(b);
      final n = r.int32();
      return [for (var i = 0; i < n; i++) decodeCqlValue(t.params.first, r.bytes())];
    case CqlType.map:
      final r = CqlReader(b);
      final n = r.int32();
      final m = <Object?, Object?>{};
      for (var i = 0; i < n; i++) {
        final k = decodeCqlValue(t.params[0], r.bytes());
        m[k] = decodeCqlValue(t.params[1], r.bytes());
      }
      return m;
    case CqlType.tuple:
      final r = CqlReader(b);
      return [for (final p in t.params) r.atEnd ? null : decodeCqlValue(p, r.bytes())];
    case CqlType.udt:
      final r = CqlReader(b);
      final m = <String, Object?>{};
      for (final (name, type) in t.fields) {
        if (r.atEnd) break;
        m[name] = decodeCqlValue(type, r.bytes());
      }
      return m;
    default:
      if (t.isDuration) {
        final (mo, p1) = _readVint(b, 0);
        final (d, p2) = _readVint(b, p1);
        final (ns, _) = _readVint(b, p2);
        return formatDuration(_zigzag(mo), _zigzag(d), _zigzag(ns));
      }
      return Uint8List.fromList(b);
  }
}

String formatDecimal(BigInt unscaled, int scale) {
  final neg = unscaled.isNegative;
  var digits = unscaled.abs().toString();
  String out;
  if (scale <= 0) {
    out = digits + '0' * -scale;
  } else {
    if (digits.length <= scale) digits = digits.padLeft(scale + 1, '0');
    out = '${digits.substring(0, digits.length - scale)}.${digits.substring(digits.length - scale)}';
  }
  return neg ? '-$out' : out;
}

String _jsonOf(Object? v) => jsonEncode(_jsonable(v));

Object? _jsonable(Object? v) => switch (v) {
  Map() => {
    for (final e in v.entries) e.key is String ? e.key as String : jsonEncode(_jsonable(e.key)): _jsonable(e.value),
  },
  Uint8List() => '0x${v.map((e) => e.toRadixString(16).padLeft(2, '0')).join()}',
  List() => [for (final x in v) _jsonable(x)],
  double() when v.isNaN || v.isInfinite => v.toString(),
  _ => v,
};

/// Value shown in the grid: numbers, strings, blobs, 'true'/'false', JSON for
/// collections, tuples and UDTs.
Object? cqlGridValue(CqlType t, Uint8List? b) {
  final v = decodeCqlValue(t, b);
  return switch (v) {
    bool() => v ? 'true' : 'false',
    Uint8List() => v,
    Map() || List() => _jsonOf(v),
    _ => v,
  };
}

// ---------------------------------------------------------------------------
// Value encoding (bound parameters of prepared statements)
// ---------------------------------------------------------------------------

DateTime _parseUtc(String s) {
  var t = s.trim().replaceFirst(' ', 'T');
  if (!RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(t)) t = '${t}Z';
  final d = DateTime.tryParse(t);
  if (d == null) throw NativeDbException('Data/ora non valida: "$s"');
  return d;
}

Uint8List _hexBytes(String s) {
  final h = s.startsWith('0x') || s.startsWith('0X') ? s.substring(2) : s;
  if (h.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(h)) throw NativeDbException('Valore blob non valido: "$s"');
  return Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
}

Object? _fromJsonText(Object? v) {
  if (v is String) {
    try {
      return jsonDecode(v);
    } on FormatException {
      throw NativeDbException('Valore JSON non valido per una collezione: "$v"');
    }
  }
  return v;
}

int _int(Object? v) => switch (v) {
  int() => v,
  double() => v.toInt(),
  bool() => v ? 1 : 0,
  _ => int.tryParse(v.toString().trim()) ?? (throw NativeDbException('Numero intero non valido: "$v"')),
};

double _double(Object? v) => switch (v) {
  num() => v.toDouble(),
  _ =>
    double.tryParse(v.toString().trim().replaceAll(',', '.')) ?? (throw NativeDbException('Numero non valido: "$v"')),
};

/// Encodes [v] (grid value: String / num / bool / Uint8List / collections)
/// for the CQL type [t].
Uint8List? encodeCqlValue(CqlType t, Object? v) {
  if (v == null) return null;
  ByteData bd(int n) => ByteData(n);
  switch (t.id) {
    case CqlType.ascii:
    case CqlType.varchar:
      return Uint8List.fromList(utf8.encode(v is Uint8List ? latin1.decode(v) : v.toString()));
    case CqlType.bigint:
    case CqlType.counter:
      return (bd(8)..setInt64(0, _int(v))).buffer.asUint8List();
    case CqlType.int_:
      return (bd(4)..setInt32(0, _int(v))).buffer.asUint8List();
    case CqlType.smallint:
      return (bd(2)..setInt16(0, _int(v))).buffer.asUint8List();
    case CqlType.tinyint:
      return (bd(1)..setInt8(0, _int(v))).buffer.asUint8List();
    case CqlType.boolean:
      final s = v.toString().trim().toLowerCase();
      return Uint8List.fromList([v == true || s == 'true' || s == '1' || s == 'yes' || s == 'sì' ? 1 : 0]);
    case CqlType.double_:
      return (bd(8)..setFloat64(0, _double(v))).buffer.asUint8List();
    case CqlType.float:
      return (bd(4)..setFloat32(0, _double(v))).buffer.asUint8List();
    case CqlType.decimal:
      final s = v.toString().trim();
      final m = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$').firstMatch(s);
      if (m == null) throw NativeDbException('Decimale non valido: "$s"');
      final frac = m.group(3) ?? '';
      final unscaled = BigInt.parse('${m.group(1)}${m.group(2)}$frac'.replaceAll('+', '').padLeft(1, '0'));
      final scale = frac.length - int.parse(m.group(4) ?? '0');
      final w = CqlWriter()
        ..int32(scale)
        ..raw(_bigToBytes(unscaled));
      return w.take();
    case CqlType.varint:
      return _bigToBytes(v is int ? BigInt.from(v) : BigInt.parse(v.toString().trim()));
    case CqlType.timestamp:
      final ms = v is int ? v : _parseUtc(v.toString()).millisecondsSinceEpoch;
      return (bd(8)..setInt64(0, ms)).buffer.asUint8List();
    case CqlType.uuid:
    case CqlType.timeuuid:
      final h = v.toString().replaceAll('-', '').trim();
      if (h.length != 32) throw NativeDbException('UUID non valido: "$v"');
      return _hexBytes(h);
    case CqlType.inet:
      return InternetAddress(v.toString().trim()).rawAddress;
    case CqlType.date:
      final s = v.toString().trim();
      final d = _parseUtc(s.contains('T') ? s : '${s}T00:00:00Z');
      final days = DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(1970)).inDays;
      return (bd(4)..setUint32(0, days + 0x80000000)).buffer.asUint8List();
    case CqlType.time:
      final s = v.toString().trim();
      final m = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?$').firstMatch(s);
      if (m == null) throw NativeDbException('Ora non valida: "$s"');
      final nanos =
          int.parse(m.group(1)!) * 3600000000000 +
          int.parse(m.group(2)!) * 60000000000 +
          int.parse(m.group(3) ?? '0') * 1000000000 +
          int.parse((m.group(4) ?? '0').padRight(9, '0'));
      return (bd(8)..setInt64(0, nanos)).buffer.asUint8List();
    case CqlType.blob:
      return v is Uint8List ? v : _hexBytes(v.toString().trim());
    case CqlType.list:
    case CqlType.set:
      final l = _fromJsonText(v);
      if (l is! List) throw NativeDbException('Array JSON atteso per ${t.toString()}');
      final w = CqlWriter()..int32(l.length);
      for (final e in l) {
        w.bytes(encodeCqlValue(t.params.first, e));
      }
      return w.take();
    case CqlType.map:
      final m = _fromJsonText(v);
      if (m is! Map) throw NativeDbException('Oggetto JSON atteso per ${t.toString()}');
      final w = CqlWriter()..int32(m.length);
      m.forEach((k, val) {
        w.bytes(encodeCqlValue(t.params[0], k));
        w.bytes(encodeCqlValue(t.params[1], val));
      });
      return w.take();
    case CqlType.tuple:
      final l = _fromJsonText(v);
      if (l is! List) throw NativeDbException('Array JSON atteso per ${t.toString()}');
      final w = CqlWriter();
      for (var i = 0; i < t.params.length; i++) {
        w.bytes(encodeCqlValue(t.params[i], i < l.length ? l[i] : null));
      }
      return w.take();
    case CqlType.udt:
      final m = _fromJsonText(v);
      if (m is! Map) throw NativeDbException('Oggetto JSON atteso per ${t.toString()}');
      final w = CqlWriter();
      for (final (name, type) in t.fields) {
        w.bytes(encodeCqlValue(type, m[name]));
      }
      return w.take();
    default:
      if (v is Uint8List) return v;
      throw NativeDbException('Tipo ${t.toString()} non supportato come parametro');
  }
}
