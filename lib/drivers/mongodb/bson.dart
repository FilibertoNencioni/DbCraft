// BSON (https://bsonspec.org) encoder / decoder and the special value types,
// plus the conversions used by the MongoDB driver: shell-style rendering,
// grid values, relaxed JSON hooks (ObjectId("…"), ISODate("…"), Extended
// JSON) and type names.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../odbc/odbc_ffi.dart';
import '../common/native_exception.dart';
import '../common/relaxed_json.dart';

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

class ObjectId {
  ObjectId(this.bytes) : assert(bytes.length == 12);

  factory ObjectId.parse(String hex) {
    final h = hex.trim();
    if (!isValidHex(h)) throw NativeDbException('ObjectId non valido: "$hex" (servono 24 cifre esadecimali)');
    final b = Uint8List(12);
    for (var i = 0; i < 12; i++) {
      b[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return ObjectId(b);
  }

  factory ObjectId.generate() {
    final b = Uint8List(12);
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    b[0] = ts >> 24 & 0xff;
    b[1] = ts >> 16 & 0xff;
    b[2] = ts >> 8 & 0xff;
    b[3] = ts & 0xff;
    b.setRange(4, 9, _processUnique);
    final c = _counter = (_counter + 1) & 0xffffff;
    b[9] = c >> 16 & 0xff;
    b[10] = c >> 8 & 0xff;
    b[11] = c & 0xff;
    return ObjectId(b);
  }

  static final _rnd = Random.secure();
  static final List<int> _processUnique = List.generate(5, (_) => _rnd.nextInt(256));
  static int _counter = _rnd.nextInt(0xffffff);

  static bool isValidHex(String s) => s.length == 24 && RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(s);

  final Uint8List bytes;

  String get hex => bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  DateTime get timestamp =>
      DateTime.fromMillisecondsSinceEpoch(ByteData.sublistView(bytes).getUint32(0) * 1000, isUtc: true);

  @override
  bool operator ==(Object other) => other is ObjectId && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;

  @override
  String toString() => 'ObjectId("$hex")';
}

/// 64-bit integer explicitly typed as BSON int64 (NumberLong).
class BsonInt64 {
  const BsonInt64(this.value);
  final int value;

  @override
  bool operator ==(Object other) => other is BsonInt64 && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '$value';
}

class BsonBinary {
  BsonBinary(this.data, [this.subtype = 0]);
  final Uint8List data;
  final int subtype;

  bool get isUuid => (subtype == 4 || subtype == 3) && data.length == 16;

  String get uuid {
    final h = data.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static BsonBinary fromUuid(String s) {
    final h = s.replaceAll('-', '').replaceAll('{', '').replaceAll('}', '');
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(h)) throw NativeDbException('UUID non valido: "$s"');
    return BsonBinary(
      Uint8List.fromList([for (var i = 0; i < 16; i++) int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)]),
      4,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BsonBinary && other.subtype == subtype && base64.encode(other.data) == base64.encode(data);
  @override
  int get hashCode => Object.hash(subtype, base64.encode(data));
}

class BsonRegex {
  const BsonRegex(this.pattern, [this.options = '']);
  final String pattern;
  final String options;

  @override
  bool operator ==(Object other) => other is BsonRegex && other.pattern == pattern && other.options == options;
  @override
  int get hashCode => Object.hash(pattern, options);
  @override
  String toString() => '/$pattern/$options';
}

class BsonTimestamp {
  const BsonTimestamp(this.seconds, this.increment);
  final int seconds;
  final int increment;

  @override
  bool operator ==(Object other) => other is BsonTimestamp && other.seconds == seconds && other.increment == increment;
  @override
  int get hashCode => Object.hash(seconds, increment);
  @override
  String toString() => 'Timestamp({ t: $seconds, i: $increment })';
}

class BsonJavaScript {
  const BsonJavaScript(this.code, [this.scope]);
  final String code;
  final Map<String, Object?>? scope;
}

class BsonMinKey {
  const BsonMinKey();
  @override
  String toString() => 'MinKey()';
}

class BsonMaxKey {
  const BsonMaxKey();
  @override
  String toString() => 'MaxKey()';
}

/// IEEE 754-2008 decimal128 (BID encoding), kept as raw bytes.
class BsonDecimal128 {
  BsonDecimal128(this.bytes) : assert(bytes.length == 16);
  final Uint8List bytes;

  static final _mask64 = (BigInt.one << 64) - BigInt.one;

  factory BsonDecimal128.parse(String input) {
    var s = input.trim();
    var neg = false;
    if (s.startsWith('-') || s.startsWith('+')) {
      neg = s.startsWith('-');
      s = s.substring(1);
    }
    BigInt high;
    var low = BigInt.zero;
    final sign = neg ? BigInt.one << 63 : BigInt.zero;
    final lower = s.toLowerCase();
    if (lower == 'inf' || lower == 'infinity') {
      high = sign | (BigInt.from(0x78) << 56);
    } else if (lower == 'nan') {
      high = BigInt.from(0x7c) << 56;
    } else {
      final m = RegExp(r'^(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$').firstMatch(s);
      if (m == null || ((m.group(1) ?? '').isEmpty && (m.group(2) ?? '').isEmpty)) {
        throw NativeDbException('Decimal128 non valido: "$input"');
      }
      final intPart = m.group(1) ?? '';
      final frac = m.group(2) ?? '';
      var exp = int.parse(m.group(3) ?? '0') - frac.length;
      var digits = (intPart + frac).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (digits.isEmpty) digits = '0';
      // Drop trailing zeros when there are too many digits.
      while (digits.length > 34 && digits.endsWith('0')) {
        digits = digits.substring(0, digits.length - 1);
        exp++;
      }
      if (digits.length > 34) throw NativeDbException('Decimal128: troppe cifre significative in "$input"');
      while (exp > 6111 && digits.length < 34) {
        digits = '${digits}0';
        exp--;
      }
      if (exp < -6176 || exp > 6111) throw NativeDbException('Decimal128: esponente fuori intervallo in "$input"');
      final coeff = BigInt.parse(digits);
      high = sign | (BigInt.from(exp + 6176) << 49) | (coeff >> 64);
      low = coeff & _mask64;
    }
    final b = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      b[i] = ((low >> (8 * i)) & BigInt.from(0xff)).toInt();
      b[8 + i] = ((high >> (8 * i)) & BigInt.from(0xff)).toInt();
    }
    return BsonDecimal128(b);
  }

  @override
  String toString() {
    var low = BigInt.zero, high = BigInt.zero;
    for (var i = 7; i >= 0; i--) {
      low = (low << 8) | BigInt.from(bytes[i]);
      high = (high << 8) | BigInt.from(bytes[8 + i]);
    }
    final neg = (high >> 63) & BigInt.one == BigInt.one;
    final comb = ((high >> 58) & BigInt.from(0x1f)).toInt();
    if (comb == 0x1e) return neg ? '-Infinity' : 'Infinity';
    if (comb == 0x1f) return 'NaN';
    int exp;
    BigInt coeff;
    if ((high >> 61) & BigInt.from(3) == BigInt.from(3)) {
      exp = ((high >> 47) & BigInt.from(0x3fff)).toInt() - 6176;
      coeff = BigInt.zero; // non-canonical
    } else {
      exp = ((high >> 49) & BigInt.from(0x3fff)).toInt() - 6176;
      coeff = ((high & ((BigInt.one << 49) - BigInt.one)) << 64) | low;
      if (coeff.bitLength > 113 || coeff > BigInt.parse('9999999999999999999999999999999999')) coeff = BigInt.zero;
    }
    final digits = coeff.toString();
    final adjusted = exp + digits.length - 1;
    String out;
    if (exp <= 0 && adjusted >= -6) {
      if (exp == 0) {
        out = digits;
      } else {
        final point = digits.length + exp;
        out = point > 0 ? '${digits.substring(0, point)}.${digits.substring(point)}' : '0.${'0' * -point}$digits';
      }
    } else {
      final mant = digits.length > 1 ? '${digits[0]}.${digits.substring(1)}' : digits;
      out = '${mant}E${adjusted >= 0 ? '+' : ''}$adjusted';
    }
    return neg ? '-$out' : out;
  }

  @override
  bool operator ==(Object other) => other is BsonDecimal128 && other.toString() == toString();
  @override
  int get hashCode => toString().hashCode;
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

class _Writer {
  Uint8List _b = Uint8List(256);
  int len = 0;

  void _ensure(int n) {
    if (len + n <= _b.length) return;
    var size = _b.length * 2;
    while (size < len + n) {
      size *= 2;
    }
    _b = Uint8List(size)..setRange(0, len, _b);
  }

  void byte(int v) {
    _ensure(1);
    _b[len++] = v & 0xff;
  }

  void bytes(List<int> v) {
    _ensure(v.length);
    _b.setRange(len, len + v.length, v);
    len += v.length;
  }

  void int32(int v) {
    _ensure(4);
    ByteData.sublistView(_b).setInt32(len, v, Endian.little);
    len += 4;
  }

  void int64(int v) {
    _ensure(8);
    ByteData.sublistView(_b).setInt64(len, v, Endian.little);
    len += 8;
  }

  void uint32(int v) {
    _ensure(4);
    ByteData.sublistView(_b).setUint32(len, v, Endian.little);
    len += 4;
  }

  void double64(double v) {
    _ensure(8);
    ByteData.sublistView(_b).setFloat64(len, v, Endian.little);
    len += 8;
  }

  void patchInt32(int at, int v) => ByteData.sublistView(_b).setInt32(at, v, Endian.little);

  void cstring(String s) {
    final e = utf8.encode(s);
    if (e.contains(0)) throw NativeDbException('Nome di campo con carattere NUL non ammesso');
    bytes(e);
    byte(0);
  }

  void string(String s) {
    final e = utf8.encode(s);
    int32(e.length + 1);
    bytes(e);
    byte(0);
  }

  Uint8List take() => Uint8List.sublistView(_b, 0, len);
}

/// Encodes [doc] as a BSON document.
Uint8List encodeBson(Map<String, Object?> doc) {
  final w = _Writer();
  _writeDoc(w, doc);
  return Uint8List.fromList(w.take());
}

void _writeDoc(_Writer w, Map<Object?, Object?> doc) {
  final start = w.len;
  w.int32(0);
  doc.forEach((k, v) => _writeElement(w, k.toString(), v));
  w.byte(0);
  w.patchInt32(start, w.len - start);
}

void _writeElement(_Writer w, String name, Object? v) {
  void head(int type) {
    w.byte(type);
    w.cstring(name);
  }

  switch (v) {
    case null:
      head(0x0A);
    case double():
      head(0x01);
      w.double64(v);
    case String():
      head(0x02);
      w.string(v);
    case bool():
      head(0x08);
      w.byte(v ? 1 : 0);
    case int():
      if (v >= -0x80000000 && v <= 0x7fffffff) {
        head(0x10);
        w.int32(v);
      } else {
        head(0x12);
        w.int64(v);
      }
    case BsonInt64():
      head(0x12);
      w.int64(v.value);
    case Map():
      head(0x03);
      _writeDoc(w, v);
    case Uint8List():
      head(0x05);
      w.int32(v.length);
      w.byte(0);
      w.bytes(v);
    case List():
      head(0x04);
      _writeDoc(w, {for (var i = 0; i < v.length; i++) '$i': v[i]});
    case ObjectId():
      head(0x07);
      w.bytes(v.bytes);
    case DateTime():
      head(0x09);
      w.int64(v.millisecondsSinceEpoch);
    case BsonBinary():
      head(0x05);
      if (v.subtype == 2) {
        w.int32(v.data.length + 4);
        w.byte(2);
        w.int32(v.data.length);
      } else {
        w.int32(v.data.length);
        w.byte(v.subtype);
      }
      w.bytes(v.data);
    case BsonRegex():
      head(0x0B);
      w.cstring(v.pattern);
      w.cstring((v.options.split('')..sort()).join());
    case BsonTimestamp():
      head(0x11);
      w.uint32(v.increment);
      w.uint32(v.seconds);
    case BsonDecimal128():
      head(0x13);
      w.bytes(v.bytes);
    case BsonJavaScript():
      if (v.scope == null) {
        head(0x0D);
        w.string(v.code);
      } else {
        head(0x0F);
        final start = w.len;
        w.int32(0);
        w.string(v.code);
        _writeDoc(w, v.scope!);
        w.patchInt32(start, w.len - start);
      }
    case BsonMinKey():
      head(0xFF);
    case BsonMaxKey():
      head(0x7F);
    case Set():
      head(0x04);
      final l = v.toList();
      _writeDoc(w, {for (var i = 0; i < l.length; i++) '$i': l[i]});
    default:
      throw NativeDbException('Tipo non serializzabile in BSON: ${v.runtimeType}');
  }
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

class _Reader {
  _Reader(this.b, this.pos) : bd = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData bd;
  int pos;

  int int32() {
    final v = bd.getInt32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int uint32() {
    final v = bd.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int int64() {
    final v = bd.getInt64(pos, Endian.little);
    pos += 8;
    return v;
  }

  double float64() {
    final v = bd.getFloat64(pos, Endian.little);
    pos += 8;
    return v;
  }

  String cstring() {
    final end = b.indexOf(0, pos);
    if (end < 0) throw NativeDbException('BSON non valido: stringa non terminata');
    final s = utf8.decode(Uint8List.sublistView(b, pos, end), allowMalformed: true);
    pos = end + 1;
    return s;
  }

  String string() {
    final n = int32();
    if (n < 1 || pos + n > b.length) throw NativeDbException('BSON non valido: lunghezza stringa $n');
    final s = utf8.decode(Uint8List.sublistView(b, pos, pos + n - 1), allowMalformed: true);
    pos += n;
    return s;
  }

  Uint8List take(int n) {
    final v = Uint8List.fromList(Uint8List.sublistView(b, pos, pos + n));
    pos += n;
    return v;
  }
}

/// Decodes the BSON document starting at [offset].
Map<String, Object?> decodeBson(Uint8List bytes, [int offset = 0]) => _readDoc(_Reader(bytes, offset));

/// Length of the BSON document starting at [offset].
int bsonLength(Uint8List bytes, [int offset = 0]) => ByteData.sublistView(bytes).getInt32(offset, Endian.little);

Map<String, Object?> _readDoc(_Reader r) {
  final start = r.pos;
  final len = r.int32();
  if (len < 5 || start + len > r.b.length) throw NativeDbException('BSON non valido: lunghezza documento $len');
  final end = start + len - 1;
  final out = <String, Object?>{};
  while (r.pos < end) {
    final type = r.b[r.pos++];
    final name = r.cstring();
    out[name] = _readValue(r, type);
  }
  r.pos = start + len;
  return out;
}

Object? _readValue(_Reader r, int type) {
  switch (type) {
    case 0x01:
      return r.float64();
    case 0x02:
      return r.string();
    case 0x03:
      return _readDoc(r);
    case 0x04:
      return _readDoc(r).values.toList();
    case 0x05:
      var n = r.int32();
      final sub = r.b[r.pos++];
      if (sub == 2 && n >= 4) {
        r.int32();
        n -= 4;
      }
      final data = r.take(n);
      return sub == 0 ? data : BsonBinary(data, sub);
    case 0x06:
      return null;
    case 0x07:
      return ObjectId(r.take(12));
    case 0x08:
      return r.b[r.pos++] != 0;
    case 0x09:
      final ms = r.int64();
      if (ms.abs() > 8640000000000000) return BsonInt64(ms);
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    case 0x0A:
      return null;
    case 0x0B:
      return BsonRegex(r.cstring(), r.cstring());
    case 0x0C:
      final ns = r.string();
      final id = ObjectId(r.take(12));
      return {r'$ref': ns, r'$id': id};
    case 0x0D:
      return BsonJavaScript(r.string());
    case 0x0E:
      return r.string();
    case 0x0F:
      r.int32();
      final code = r.string();
      return BsonJavaScript(code, _readDoc(r));
    case 0x10:
      return r.int32();
    case 0x11:
      final inc = r.uint32();
      final sec = r.uint32();
      return BsonTimestamp(sec, inc);
    case 0x12:
      return BsonInt64(r.int64());
    case 0x13:
      return BsonDecimal128(r.take(16));
    case 0xFF:
      return const BsonMinKey();
    case 0x7F:
      return const BsonMaxKey();
    default:
      throw NativeDbException('BSON: tipo 0x${type.toRadixString(16)} non supportato');
  }
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

/// Integer value of a numeric BSON field.
int? bsonInt(Object? v) => switch (v) {
  int() => v,
  BsonInt64() => v.value,
  double() => v.toInt(),
  String() => int.tryParse(v),
  _ => null,
};

/// MongoDB $type alias of a value.
String bsonTypeName(Object? v) => switch (v) {
  null => 'null',
  double() => 'double',
  String() => 'string',
  Map() => 'object',
  Uint8List() || BsonBinary() => (v is BsonBinary && v.isUuid) ? 'uuid' : 'binData',
  List() => 'array',
  ObjectId() => 'objectId',
  bool() => 'bool',
  DateTime() => 'date',
  BsonRegex() => 'regex',
  BsonJavaScript() => 'javascript',
  int() => 'int',
  BsonTimestamp() => 'timestamp',
  BsonInt64() => 'long',
  BsonDecimal128() => 'decimal',
  BsonMinKey() => 'minKey',
  BsonMaxKey() => 'maxKey',
  _ => 'unknown',
};

/// ODBC SQL type used for a MongoDB type name.
int sqlTypeForBson(String typeName) => switch (typeName) {
  'double' => SQL_DOUBLE,
  'int' => SQL_INTEGER,
  'long' => SQL_BIGINT,
  'decimal' => SQL_DECIMAL,
  'date' => SQL_TYPE_TIMESTAMP,
  'binData' => SQL_VARBINARY,
  'uuid' => SQL_GUID,
  'object' || 'array' => SQL_LONGVARCHAR,
  _ => SQL_VARCHAR,
};

String _iso(DateTime d) => d.toUtc().toIso8601String();

/// Shell-style rendering of special values (used inside compact JSON).
String? shellSpecial(Object? v) => switch (v) {
  ObjectId() => 'ObjectId("${v.hex}")',
  DateTime() => 'ISODate("${_iso(v)}")',
  BsonInt64() => 'NumberLong(${v.value})',
  BsonDecimal128() => 'NumberDecimal("$v")',
  BsonTimestamp() => 'Timestamp(${v.seconds}, ${v.increment})',
  BsonBinary() =>
    v.isUuid && v.subtype == 4 ? 'UUID("${v.uuid}")' : 'BinData(${v.subtype}, "${base64.encode(v.data)}")',
  Uint8List() => 'BinData(0, "${base64.encode(v)}")',
  BsonRegex() => '/${v.pattern}/${v.options}',
  BsonJavaScript() => 'Code(${jsonEncode(v.code)})',
  BsonMinKey() => 'MinKey()',
  BsonMaxKey() => 'MaxKey()',
  _ => null,
};

/// Compact shell-style JSON of a value (nested documents in the grid).
String shellJson(Object? v) => compactJson(v, special: shellSpecial);

/// Value shown in a grid cell (int / double / String / Uint8List / null).
Object? gridValue(Object? v) => switch (v) {
  null => null,
  int() || double() || String() => v,
  bool() => v ? 'true' : 'false',
  ObjectId() => v.hex,
  DateTime() => _iso(v),
  BsonInt64() => v.value,
  BsonDecimal128() => v.toString(),
  BsonBinary() => v.isUuid ? v.uuid : v.data,
  Uint8List() => v,
  BsonRegex() => v.toString(),
  BsonTimestamp() => 'Timestamp(${v.seconds}, ${v.increment})',
  BsonJavaScript() => v.code,
  Map() || List() => shellJson(v),
  _ => v.toString(),
};

DateTime parseShellDate(String s) {
  var t = s.trim();
  // ISODate without zone means UTC (as in mongosh).
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t)) t = '${t}T00:00:00';
  if (RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$').hasMatch(t)) t = '${t.replaceFirst(' ', 'T')}Z';
  final d = DateTime.tryParse(t);
  if (d == null) throw NativeDbException('Data non valida: "$s"');
  return d.toUtc();
}

/// Hook for [JsScanner.onCall]: shell constructors.
Object? mongoCallHook(String name, List<Object?> rawArgs) {
  final noParens = jsNoArgs(rawArgs);
  final args = noParens ? const <Object?>[] : rawArgs;
  Object? a(int i) => i < args.length ? args[i] : null;
  switch (name) {
    case 'ObjectId':
    case 'ObjectID':
      return args.isEmpty ? ObjectId.generate() : ObjectId.parse(a(0).toString());
    case 'ISODate':
    case 'Date':
      if (args.isEmpty) return DateTime.now().toUtc();
      if (args.length == 1) {
        final v = a(0);
        if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
        if (v is DateTime) return v;
        return parseShellDate(v.toString());
      }
      final n = [for (final x in args) (x as num).toInt()];
      return DateTime(
        n[0],
        n[1] + 1,
        n.length > 2 ? n[2] : 1,
        n.length > 3 ? n[3] : 0,
        n.length > 4 ? n[4] : 0,
        n.length > 5 ? n[5] : 0,
        n.length > 6 ? n[6] : 0,
      ).toUtc();
    case 'NumberLong':
    case 'Long':
    case 'Int64':
      final v = a(0);
      return BsonInt64(v is num ? v.toInt() : int.parse(v.toString()));
    case 'NumberInt':
    case 'Int32':
      final v = a(0);
      return v is num ? v.toInt() : int.parse(v.toString());
    case 'Double':
    case 'Number':
      final v = a(0);
      return v is num ? (name == 'Double' ? v.toDouble() : v) : num.parse(v.toString());
    case 'NumberDecimal':
    case 'Decimal128':
      return BsonDecimal128.parse(a(0).toString());
    case 'Timestamp':
      final v = a(0);
      if (v is Map) return BsonTimestamp(bsonInt(v['t']) ?? 0, bsonInt(v['i']) ?? 0);
      return BsonTimestamp(bsonInt(v) ?? 0, bsonInt(a(1)) ?? 0);
    case 'BinData':
      return BsonBinary(base64.decode(a(1).toString()), bsonInt(a(0)) ?? 0);
    case 'HexData':
    case 'MD5':
      final hex = (name == 'MD5' ? a(0) : a(1)).toString();
      final data = Uint8List.fromList([
        for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
      return BsonBinary(data, name == 'MD5' ? 5 : bsonInt(a(0)) ?? 0);
    case 'UUID':
      if (args.isEmpty) {
        final r = Random.secure();
        final b = Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
        b[6] = (b[6] & 0x0f) | 0x40;
        b[8] = (b[8] & 0x3f) | 0x80;
        return BsonBinary(b, 4);
      }
      return BsonBinary.fromUuid(a(0).toString());
    case 'MinKey':
      return const BsonMinKey();
    case 'MaxKey':
      return const BsonMaxKey();
    case 'RegExp':
      return BsonRegex(a(0).toString(), (a(1) ?? '').toString());
    case 'Code':
      return BsonJavaScript(a(0).toString(), a(1) is Map ? (a(1) as Map).cast<String, Object?>() : null);
    case 'DBRef':
      return {r'$ref': a(0), r'$id': a(1), if (a(2) != null) r'$db': a(2)};
    case 'Number.MAX_SAFE_INTEGER':
      return 9007199254740991;
    case 'Number.MIN_SAFE_INTEGER':
      return -9007199254740991;
  }
  throw NativeDbException('Funzione non supportata: $name');
}

/// Hook for [JsScanner.onObject]: canonical / relaxed Extended JSON.
Object? mongoObjectHook(Map<String, Object?> m) {
  if (m.isEmpty || !m.keys.first.startsWith(r'$')) return m;
  final k = m.keys.first;
  final v = m[k];
  try {
    if (m.length == 1) {
      switch (k) {
        case r'$oid':
          return ObjectId.parse(v.toString());
        case r'$date':
          if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
          if (v is BsonInt64) return DateTime.fromMillisecondsSinceEpoch(v.value, isUtc: true);
          if (v is String) return parseShellDate(v);
          return m;
        case r'$numberLong':
          return BsonInt64(int.parse(v.toString()));
        case r'$numberInt':
          return int.parse(v.toString());
        case r'$numberDouble':
          return double.parse(v.toString());
        case r'$numberDecimal':
          return BsonDecimal128.parse(v.toString());
        case r'$binary':
          if (v is Map) {
            return BsonBinary(base64.decode(v['base64'].toString()), int.parse(v['subType'].toString(), radix: 16));
          }
          return m;
        case r'$uuid':
          return BsonBinary.fromUuid(v.toString());
        case r'$timestamp':
          if (v is Map) return BsonTimestamp(bsonInt(v['t']) ?? 0, bsonInt(v['i']) ?? 0);
          return m;
        case r'$regularExpression':
          if (v is Map) return BsonRegex(v['pattern'].toString(), (v['options'] ?? '').toString());
          return m;
        case r'$minKey':
          return const BsonMinKey();
        case r'$maxKey':
          return const BsonMaxKey();
        case r'$undefined':
          return null;
        case r'$symbol':
          return v.toString();
        case r'$code':
          return BsonJavaScript(v.toString());
      }
    } else if (m.length == 2 && k == r'$binary' && m.containsKey(r'$type')) {
      return BsonBinary(base64.decode(v.toString()), int.parse(m[r'$type'].toString(), radix: 16));
    } else if (m.length == 2 && k == r'$code' && m[r'$scope'] is Map) {
      return BsonJavaScript(v.toString(), (m[r'$scope'] as Map).cast<String, Object?>());
    }
  } on FormatException catch (e) {
    throw NativeDbException('Extended JSON non valido per $k: ${e.message}');
  }
  return m;
}

Object? mongoRegexHook(String pattern, String flags) => BsonRegex(pattern, flags);

/// Parses a MongoDB shell value (relaxed JSON with shell constructors).
Object? parseMongoValue(String text) =>
    parseRelaxedJson(text, onCall: mongoCallHook, onObject: mongoObjectHook, onRegex: mongoRegexHook);

/// Converts a grid value back to the BSON type [typeName] (UPDATE / INSERT
/// generated by the result grid).
Object? coerceToBsonType(Object? v, String? typeName) {
  if (v == null || typeName == null) return v;
  if ((typeName == 'object' || typeName == 'array') && v is String && v.trim().isNotEmpty) {
    // Invalid JSON must not silently turn a document into a string.
    return parseMongoValue(v);
  }
  try {
    switch (typeName) {
      case 'objectId':
        if (v is String && ObjectId.isValidHex(v)) return ObjectId.parse(v);
      case 'date':
        if (v is String && v.trim().isNotEmpty) return parseShellDate(v);
        if (v is int) return DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
      case 'int':
        if (v is String) return int.tryParse(v.trim()) ?? v;
        if (v is double && v == v.truncateToDouble()) return v.toInt();
      case 'long':
        if (v is String) {
          final i = int.tryParse(v.trim());
          return i == null ? v : BsonInt64(i);
        }
        if (v is int) return BsonInt64(v);
      case 'double':
        if (v is String) return double.tryParse(v.trim().replaceAll(',', '.')) ?? v;
        if (v is int) return v.toDouble();
      case 'decimal':
        return BsonDecimal128.parse(v.toString());
      case 'bool':
        final s = v.toString().trim().toLowerCase();
        if (const {'true', '1', 'yes', 'sì', 'si'}.contains(s)) return true;
        if (const {'false', '0', 'no'}.contains(s)) return false;
      case 'uuid':
        if (v is String) return BsonBinary.fromUuid(v);
    }
  } on NativeDbException {
    return v;
  } on FormatException {
    return v;
  }
  return v;
}
