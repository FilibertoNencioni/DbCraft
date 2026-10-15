// Type aware SQL literals and parameter values shared by the data compare
// synchronization script and the mock data generator.
//
// ODBC returns dates, times and decimals as strings: when those values are
// written back (possibly to a different DBMS) they need a literal or a bound
// parameter that the target understands independently of its session
// language / NLS settings.
import 'dart:typed_data';

import '../../odbc/odbc_ffi.dart';
import '../../odbc/odbc_types.dart';
import '../../services/sql_dialect.dart';

/// Kind of temporal value of an ODBC SQL type (null when not temporal).
enum TemporalKind { date, time, timestamp }

TemporalKind? temporalKindOf(int? sqlType) => switch (sqlType) {
  SQL_TYPE_DATE || 9 => TemporalKind.date,
  SQL_TYPE_TIME || 10 => TemporalKind.time,
  SQL_TYPE_TIMESTAMP || 11 => TemporalKind.timestamp,
  _ => null,
};

bool isNumericSqlType(int? t) => const {
  SQL_NUMERIC,
  SQL_DECIMAL,
  SQL_INTEGER,
  SQL_SMALLINT,
  SQL_FLOAT,
  SQL_REAL,
  SQL_DOUBLE,
  SQL_BIGINT,
  SQL_TINYINT,
}.contains(t);

bool isIntegerSqlType(int? t) => const {SQL_INTEGER, SQL_SMALLINT, SQL_BIGINT, SQL_TINYINT}.contains(t);

bool isFloatSqlType(int? t) => const {SQL_FLOAT, SQL_REAL, SQL_DOUBLE}.contains(t);

bool isTextSqlType(int? t) =>
    const {SQL_CHAR, SQL_VARCHAR, SQL_LONGVARCHAR, SQL_WCHAR, SQL_WVARCHAR, SQL_WLONGVARCHAR}.contains(t);

bool isBinarySqlType(int? t) => const {SQL_BINARY, SQL_VARBINARY, SQL_LONGVARBINARY}.contains(t);

/// Standard ODBC types that can be used to type a NULL parameter.
const _bindableNullTypes = {
  SQL_CHAR,
  SQL_VARCHAR,
  SQL_LONGVARCHAR,
  SQL_WCHAR,
  SQL_WVARCHAR,
  SQL_WLONGVARCHAR,
  SQL_NUMERIC,
  SQL_DECIMAL,
  SQL_INTEGER,
  SQL_SMALLINT,
  SQL_FLOAT,
  SQL_REAL,
  SQL_DOUBLE,
  SQL_BIGINT,
  SQL_TINYINT,
  SQL_BIT,
  SQL_BINARY,
  SQL_VARBINARY,
  SQL_LONGVARBINARY,
  SQL_TYPE_DATE,
  SQL_TYPE_TIME,
  SQL_TYPE_TIMESTAMP,
  SQL_GUID,
};

final _isoDateTime = RegExp(r'^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}(?::\d{2})?)(\.\d+)?)?$');
final _isoTime = RegExp(r'^\d{2}:\d{2}(?::\d{2})?(\.\d+)?$');
final _plainNumber = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

/// Normalizes a date/time string to `YYYY-MM-DD[ HH:MM:SS[.fff]]` (or
/// `HH:MM:SS[.fff]` for times). Returns null when [s] is not ISO-like.
({String date, String? time, String? fraction})? parseIsoDateTime(String s) {
  final m = _isoDateTime.firstMatch(s.trim());
  if (m == null) return null;
  var time = m.group(2);
  if (time != null && time.length == 5) time = '$time:00';
  return (date: m.group(1)!, time: time, fraction: m.group(3));
}

/// SQL literal of [v] for a column of ODBC type [sqlType] in dialect [d].
String typedLiteral(SqlDialect d, int? sqlType, Object? v) {
  if (v == null) return 'NULL';
  if (v is bool) return d.family == DbFamily.postgres ? (v ? 'TRUE' : 'FALSE') : (v ? '1' : '0');
  if (sqlType == SQL_BIT && d.family == DbFamily.postgres) {
    if (v is num) return v != 0 ? 'TRUE' : 'FALSE';
    final s = v.toString().trim().toLowerCase();
    if (s == '1' || s == 'true' || s == 't') return 'TRUE';
    if (s == '0' || s == 'false' || s == 'f') return 'FALSE';
  }
  if (v is num) {
    if (v is double && (v.isNaN || v.isInfinite)) return d.stringLiteral(v.toString());
    return v.toString();
  }
  if (v is Uint8List) return d.literal(v);
  final s = v.toString();
  if (isNumericSqlType(sqlType) && _plainNumber.hasMatch(s.trim())) return s.trim();
  final tk = temporalKindOf(sqlType);
  if (tk != null) {
    final lit = _temporalLiteral(d, tk, s);
    if (lit != null) return lit;
  }
  return d.literal(s);
}

String? _temporalLiteral(SqlDialect d, TemporalKind tk, String s) {
  if (tk == TemporalKind.time) {
    if (!_isoTime.hasMatch(s.trim())) return null;
    return d.family == DbFamily.oracle ? "TIMESTAMP '1970-01-01 ${s.trim()}'" : d.stringLiteral(s.trim());
  }
  final p = parseIsoDateTime(s);
  if (p == null) return null;
  final time = p.time == null ? null : '${p.time}${p.fraction ?? ''}';
  switch (d.family) {
    case DbFamily.oracle:
      if (tk == TemporalKind.date && time == null) return "DATE '${p.date}'";
      return "TIMESTAMP '${p.date} ${time ?? '00:00:00'}'";
    case DbFamily.sqlServer:
      // ISO 8601 with "T" is interpreted the same way whatever the
      // session language (DATEFORMAT) is.
      if (tk == TemporalKind.date) return "'${p.date}'";
      return "'${p.date}T${time ?? '00:00:00'}'";
    default:
      if (tk == TemporalKind.date && time == null) return "'${p.date}'";
      return "'${p.date} ${time ?? '00:00:00'}'";
  }
}

/// Parameter value for [v] written to a column of ODBC type [sqlType].
///
/// Date/time strings are bound with their SQL type when the ODBC canonical
/// format applies (so the conversion does not depend on the server NLS
/// settings); NULLs are typed so drivers do not have to guess.
Object? bindValue(SqlDialect d, int? sqlType, Object? v) {
  if (v == null) {
    return sqlType != null && _bindableNullTypes.contains(sqlType) ? SqlParam(null, sqlType: sqlType) : null;
  }
  if (v is! String) return v;
  final tk = temporalKindOf(sqlType);
  if (tk == null || tk == TemporalKind.time) return v;
  final p = parseIsoDateTime(v);
  if (p == null) return v;
  if (d.family == DbFamily.sqlServer) {
    if (tk == TemporalKind.date) return p.date;
    return '${p.date}T${p.time ?? '00:00:00'}${p.fraction ?? ''}';
  }
  // Fractional seconds would need the decimal digits of the parameter:
  // leave them to the server conversion.
  if (p.fraction != null && p.fraction!.replaceAll(RegExp(r'[.0]'), '').isNotEmpty) return v;
  if (tk == TemporalKind.date) {
    return SqlParam(p.date, sqlType: SQL_TYPE_DATE);
  }
  return SqlParam('${p.date} ${p.time ?? '00:00:00'}', sqlType: SQL_TYPE_TIMESTAMP);
}
