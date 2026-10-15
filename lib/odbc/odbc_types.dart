// Plain data objects exchanged between the ODBC worker isolate and the UI.
import 'dart:typed_data';

import 'odbc_ffi.dart';

/// A single diagnostic record (SQLGetDiagRec).
class OdbcDiag {
  const OdbcDiag(this.sqlState, this.nativeError, this.message);
  final String sqlState;
  final int nativeError;
  final String message;

  @override
  String toString() => '[$sqlState] ($nativeError) $message';
}

class OdbcException implements Exception {
  OdbcException(this.operation, this.diagnostics, [this.returnCode = SQL_ERROR]);

  final String operation;
  final List<OdbcDiag> diagnostics;
  final int returnCode;

  String get sqlState => diagnostics.isEmpty ? 'HY000' : diagnostics.first.sqlState;

  String get message => diagnostics.isEmpty
      ? '$operation fallita (rc=$returnCode)'
      : [
          ...diagnostics.map((d) => d.toString()),
          if (diagnostics.any((d) => d.message.contains('OpenSSL library could not be loaded')))
            '\nIl driver non trova una versione di OpenSSL supportata (1.x o 3.x). '
                'Vedi Database › Driver ODBC installati… per la correzione.',
        ].join('\n');

  @override
  String toString() => message;
}

/// Column metadata of a result set.
class ColumnInfo {
  const ColumnInfo({
    required this.index,
    required this.name,
    required this.sqlType,
    this.typeName = '',
    this.size = 0,
    this.decimals = 0,
    this.nullable = true,
    this.baseTable,
    this.baseColumn,
    this.schema,
    this.catalog,
    this.autoIncrement = false,
  });

  final int index;
  final String name;
  final int sqlType;
  final String typeName;
  final int size;
  final int decimals;
  final bool nullable;
  final String? baseTable;
  final String? baseColumn;
  final String? schema;
  final String? catalog;
  final bool autoIncrement;

  bool get isNumeric => const {
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
  }.contains(sqlType);

  bool get isBinary => sqlType == SQL_BINARY || sqlType == SQL_VARBINARY || sqlType == SQL_LONGVARBINARY;

  bool get isLob => sqlType == SQL_LONGVARBINARY || sqlType == SQL_LONGVARCHAR || sqlType == SQL_WLONGVARCHAR;

  String get displayType {
    final t = typeName.isNotEmpty ? typeName : sqlTypeName(sqlType);
    return t;
  }

  @override
  String toString() => '$name $displayType';
}

/// A page of rows (or an update count) produced by a statement.
class ResultPage {
  ResultPage({
    required this.columns,
    required this.rows,
    this.hasMore = false,
    this.cursorId,
    this.rowsAffected = -1,
    this.elapsedMs = 0,
    this.messages = const [],
    this.hasNextResultSet = false,
  });

  /// Empty when the statement did not produce a result set.
  final List<ColumnInfo> columns;
  final List<List<Object?>> rows;

  /// More rows can be fetched with the cursor.
  final bool hasMore;

  /// Identifier of the open cursor in the worker (null when closed).
  final int? cursorId;

  /// Update count (-1 if not available).
  final int rowsAffected;
  final int elapsedMs;

  /// Informational messages (SQL_SUCCESS_WITH_INFO, PRINT, …).
  final List<String> messages;

  /// Statement produced further result sets (see OdbcSession.nextResultSet).
  final bool hasNextResultSet;

  bool get isResultSet => columns.isNotEmpty;
}

class OdbcDriverInfo {
  const OdbcDriverInfo(this.name, this.attributes);
  final String name;
  final Map<String, String> attributes;
}

class OdbcDataSource {
  const OdbcDataSource(this.name, this.driver, {this.system = false});
  final String name;
  final String driver;
  final bool system;
}

/// Value placeholder used for parameters typed explicitly.
class SqlParam {
  const SqlParam(this.value, {this.sqlType});
  final Object? value;
  final int? sqlType;
}

String sqlTypeName(int t) => switch (t) {
  SQL_CHAR => 'CHAR',
  SQL_NUMERIC => 'NUMERIC',
  SQL_DECIMAL => 'DECIMAL',
  SQL_INTEGER => 'INTEGER',
  SQL_SMALLINT => 'SMALLINT',
  SQL_FLOAT => 'FLOAT',
  SQL_REAL => 'REAL',
  SQL_DOUBLE => 'DOUBLE',
  SQL_DATETIME => 'DATETIME',
  SQL_VARCHAR => 'VARCHAR',
  SQL_TYPE_DATE => 'DATE',
  SQL_TYPE_TIME => 'TIME',
  SQL_TYPE_TIMESTAMP => 'TIMESTAMP',
  SQL_LONGVARCHAR => 'LONGVARCHAR',
  SQL_BINARY => 'BINARY',
  SQL_VARBINARY => 'VARBINARY',
  SQL_LONGVARBINARY => 'LONGVARBINARY',
  SQL_BIGINT => 'BIGINT',
  SQL_TINYINT => 'TINYINT',
  SQL_BIT => 'BIT',
  SQL_WCHAR => 'NCHAR',
  SQL_WVARCHAR => 'NVARCHAR',
  SQL_WLONGVARCHAR => 'NTEXT',
  SQL_GUID => 'GUID',
  _ => 'TYPE($t)',
};

/// Formats a value for display in grids / exports.
String formatValue(Object? v, {String nullText = '[NULL]', int maxLen = 0}) {
  if (v == null) return nullText;
  String s;
  if (v is Uint8List) {
    final n = v.length > 64 ? 64 : v.length;
    final sb = StringBuffer('0x');
    for (var i = 0; i < n; i++) {
      sb.write(v[i].toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    if (v.length > n) sb.write('… (${v.length} byte)');
    s = sb.toString();
  } else if (v is double) {
    s = v == v.truncateToDouble() && v.abs() < 1e15 ? v.toStringAsFixed(1) : v.toString();
  } else {
    s = v.toString();
  }
  if (maxLen > 0 && s.length > maxLen) s = '${s.substring(0, maxLen)}…';
  return s;
}
