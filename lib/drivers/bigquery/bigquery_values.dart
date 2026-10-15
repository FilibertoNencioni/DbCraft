// BigQuery schema and value conversion (REST JSON → Dart values shown by the
// grid). Pure functions, unit tested in test/cloud_test.dart.
import 'dart:convert';
import 'dart:typed_data';

import '../../odbc/odbc_ffi.dart';

/// A field of a BigQuery table / result schema.
class BqField {
  const BqField(this.name, this.type, {this.mode = 'NULLABLE', this.fields = const [], this.description});
  final String name;

  /// Legacy or standard type name (INTEGER/INT64, RECORD/STRUCT, …).
  final String type;

  /// NULLABLE, REQUIRED or REPEATED.
  final String mode;
  final List<BqField> fields;
  final String? description;

  bool get repeated => mode == 'REPEATED';
  bool get isRecord => type == 'RECORD' || type == 'STRUCT';

  /// Type as shown to the user (standard SQL names).
  String get displayType {
    final base = isRecord ? 'STRUCT' : standardType(type);
    return repeated ? 'ARRAY<$base>' : base;
  }
}

/// Normalizes legacy type names to standard SQL names.
String standardType(String t) => switch (t.toUpperCase()) {
  'INTEGER' => 'INT64',
  'FLOAT' => 'FLOAT64',
  'BOOLEAN' => 'BOOL',
  'RECORD' => 'STRUCT',
  final x => x,
};

List<BqField> parseBqSchema(Map? schema) => [
  for (final f in (schema?['fields'] as List?) ?? const []) _field(f as Map),
];

BqField _field(Map f) => BqField(
  f['name'] as String? ?? '',
  (f['type'] as String? ?? 'STRING').toUpperCase(),
  mode: (f['mode'] as String? ?? 'NULLABLE').toUpperCase(),
  fields: [for (final c in (f['fields'] as List?) ?? const []) _field(c as Map)],
  description: f['description'] as String?,
);

/// ODBC SQL type of a BigQuery type (drives alignment and editors).
int bqSqlType(String type, {bool repeated = false}) {
  if (repeated) return SQL_WLONGVARCHAR;
  return switch (standardType(type)) {
    'INT64' => SQL_BIGINT,
    'FLOAT64' => SQL_DOUBLE,
    'NUMERIC' || 'BIGNUMERIC' || 'DECIMAL' || 'BIGDECIMAL' => SQL_DECIMAL,
    'BOOL' => SQL_BIT,
    'TIMESTAMP' || 'DATETIME' => SQL_TYPE_TIMESTAMP,
    'DATE' => SQL_TYPE_DATE,
    'TIME' => SQL_TYPE_TIME,
    'BYTES' => SQL_VARBINARY,
    'STRING' => SQL_WVARCHAR,
    _ => SQL_WLONGVARCHAR, // STRUCT, JSON, GEOGRAPHY, INTERVAL, RANGE
  };
}

/// Column of the flattened schema (nested fields as `a.b`).
class BqColumn {
  const BqColumn(this.name, this.typeName, this.sqlType, {this.nullable = true, this.remarks, this.decimals = 0});
  final String name;
  final String typeName;
  final int sqlType;
  final bool nullable;
  final String? remarks;
  final int decimals;
}

/// Flattens RECORD fields (`addr`, `addr.city`, …) for the column catalog.
List<BqColumn> flattenBqFields(List<BqField> fields, [String prefix = '']) {
  final out = <BqColumn>[];
  for (final f in fields) {
    final name = '$prefix${f.name}';
    final notes = [if (f.description != null && f.description!.isNotEmpty) f.description!, if (f.repeated) 'REPEATED'];
    out.add(
      BqColumn(
        name,
        f.displayType,
        bqSqlType(f.type, repeated: f.repeated),
        nullable: f.mode != 'REQUIRED',
        remarks: notes.isEmpty ? null : notes.join(' · '),
        decimals: standardType(f.type) == 'NUMERIC' ? 9 : (standardType(f.type) == 'BIGNUMERIC' ? 38 : 0),
      ),
    );
    if (f.isRecord) out.addAll(flattenBqFields(f.fields, '$name.'));
  }
  return out;
}

/// TIMESTAMP value (seconds as float/scientific string, or microseconds as
/// int64 string with `formatOptions.useInt64Timestamp`) → ISO-8601 UTC.
String bqTimestamp(String v) {
  int micros;
  if (v.contains('.') || v.contains('E') || v.contains('e')) {
    // Seconds: parse the decimal part exactly when possible.
    final s = v.toUpperCase();
    if (!s.contains('E')) {
      final parts = s.split('.');
      final secs = int.parse(parts[0]);
      final frac = '${parts[1]}000000'.substring(0, 6);
      micros = secs * 1000000 + (secs < 0 ? -int.parse(frac) : int.parse(frac));
    } else {
      micros = (double.parse(s) * 1000000).round();
    }
  } else {
    final n = int.parse(v);
    micros = n.abs() >= 100000000000000 ? n : n * 1000000;
  }
  final t = DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  String two(int x) => x.toString().padLeft(2, '0');
  final frac = micros % 1000000;
  final base =
      '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}T'
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  return frac == 0 ? '${base}Z' : '$base.${frac.toString().padLeft(6, '0')}Z';
}

/// Converts a cell for the grid: scalars to int/double/bool/String/bytes,
/// STRUCT and ARRAY to compact JSON.
Object? convertBqValue(BqField f, Object? v) {
  if (v == null) return null;
  if (f.repeated || f.isRecord) return jsonEncode(_jsonValue(f, v));
  return _scalar(f, v);
}

Object? _scalar(BqField f, Object? v) {
  if (v == null) return null;
  final s = v is String ? v : '$v';
  switch (standardType(f.type)) {
    case 'INT64':
      return int.tryParse(s) ?? s;
    case 'FLOAT64':
      return switch (s) {
        'NaN' => double.nan,
        'Infinity' => double.infinity,
        '-Infinity' => double.negativeInfinity,
        _ => double.tryParse(s) ?? s,
      };
    case 'BOOL':
      return s.toLowerCase() == 'true';
    case 'TIMESTAMP':
      try {
        return bqTimestamp(s);
      } catch (_) {
        return s;
      }
    case 'BYTES':
      try {
        return Uint8List.fromList(base64Decode(s));
      } catch (_) {
        return s;
      }
    default:
      return s;
  }
}

/// JSON-friendly value of nested data (records become objects).
Object? _jsonValue(BqField f, Object? v) {
  if (v == null) return null;
  if (f.repeated) {
    final item = BqField(f.name, f.type, fields: f.fields);
    return [for (final e in (v as List)) _jsonValue(item, (e as Map)['v'])];
  }
  if (f.isRecord) {
    final cells = ((v as Map)['f'] as List?) ?? const [];
    return {
      for (var i = 0; i < f.fields.length && i < cells.length; i++)
        f.fields[i].name: _jsonValue(f.fields[i], (cells[i] as Map)['v']),
    };
  }
  final x = _scalar(f, v);
  if (x is Uint8List) return base64Encode(x);
  if (x is double && !x.isFinite) return x.toString();
  if (standardType(f.type) == 'JSON' && x is String) {
    try {
      return jsonDecode(x);
    } catch (_) {
      return x;
    }
  }
  return x;
}

/// Converts a REST row (`{"f": [{"v": …}, …]}`) using [schema].
List<Object?> convertBqRow(List<BqField> schema, Map row) {
  final cells = (row['f'] as List?) ?? const [];
  return [
    for (var i = 0; i < schema.length; i++) i < cells.length ? convertBqValue(schema[i], (cells[i] as Map)['v']) : null,
  ];
}

/// Query parameter for a Dart value (positional `?` parameters).
Map<String, Object?> bqParameter(Object? v) {
  String type;
  Object? value;
  switch (v) {
    case null:
      return {
        'parameterType': {'type': 'STRING'},
        'parameterValue': <String, Object?>{},
      };
    case bool b:
      type = 'BOOL';
      value = b ? 'true' : 'false';
    case int i:
      type = 'INT64';
      value = '$i';
    case double d:
      type = 'FLOAT64';
      value = '$d';
    case Uint8List bytes:
      type = 'BYTES';
      value = base64Encode(bytes);
    case DateTime t:
      type = 'TIMESTAMP';
      value = t.toUtc().toIso8601String();
    default:
      type = 'STRING';
      value = '$v';
  }
  return {
    'parameterType': {'type': type},
    'parameterValue': {'value': value},
  };
}
