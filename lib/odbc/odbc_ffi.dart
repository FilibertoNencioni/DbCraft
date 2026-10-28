// ignore_for_file: constant_identifier_names, non_constant_identifier_names, library_private_types_in_public_api
// Low level ODBC bindings (dart:ffi) for the ODBC Driver Manager.
//
// Supported driver managers:
//  * Windows: odbc32.dll
//  * macOS / Linux: unixODBC (libodbc) – SQLWCHAR is UTF-16
//  * macOS / Linux: iODBC (libiodbc) – SQLWCHAR is UTF-32 (wchar_t)
//
// Only the wide ("W") variants of the string based functions are used, so all
// text is exchanged as Unicode independently of the driver code page.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Constants (from sql.h / sqlext.h / sqlucode.h)
// ---------------------------------------------------------------------------

const int SQL_SUCCESS = 0;
const int SQL_SUCCESS_WITH_INFO = 1;
const int SQL_STILL_EXECUTING = 2;
const int SQL_NEED_DATA = 99;
const int SQL_NO_DATA = 100;
const int SQL_ERROR = -1;
const int SQL_INVALID_HANDLE = -2;

const int SQL_HANDLE_ENV = 1;
const int SQL_HANDLE_DBC = 2;
const int SQL_HANDLE_STMT = 3;

const int SQL_ATTR_ODBC_VERSION = 200;
const int SQL_OV_ODBC3 = 3;

const int SQL_ATTR_ACCESS_MODE = 101;
const int SQL_ATTR_AUTOCOMMIT = 102;
const int SQL_ATTR_LOGIN_TIMEOUT = 103;
const int SQL_ATTR_TXN_ISOLATION = 108;
const int SQL_ATTR_CURRENT_CATALOG = 109;
const int SQL_ATTR_CONNECTION_TIMEOUT = 113;
const int SQL_MODE_READ_WRITE = 0;
const int SQL_MODE_READ_ONLY = 1;
const int SQL_AUTOCOMMIT_OFF = 0;
const int SQL_AUTOCOMMIT_ON = 1;

const int SQL_ATTR_QUERY_TIMEOUT = 0;
const int SQL_ATTR_MAX_ROWS = 1;

const int SQL_DRIVER_NOPROMPT = 0;
const int SQL_COMMIT = 0;
const int SQL_ROLLBACK = 1;

const int SQL_NTS = -3;
const int SQL_NULL_DATA = -1;
const int SQL_NO_TOTAL = -4;
const int SQL_IS_INTEGER = -6;
const int SQL_IS_UINTEGER = -5;

const int SQL_CLOSE = 0;
const int SQL_UNBIND = 2;
const int SQL_RESET_PARAMS = 3;

const int SQL_FETCH_NEXT = 1;
const int SQL_FETCH_FIRST = 2;

const int SQL_PARAM_INPUT = 1;

// C data types
const int SQL_C_CHAR = 1;
const int SQL_C_WCHAR = -8;
const int SQL_C_SBIGINT = -25;
const int SQL_C_DOUBLE = 8;
const int SQL_C_BINARY = -2;
const int SQL_C_BIT = -7;

// SQL data types
const int SQL_UNKNOWN_TYPE = 0;
const int SQL_CHAR = 1;
const int SQL_NUMERIC = 2;
const int SQL_DECIMAL = 3;
const int SQL_INTEGER = 4;
const int SQL_SMALLINT = 5;
const int SQL_FLOAT = 6;
const int SQL_REAL = 7;
const int SQL_DOUBLE = 8;
const int SQL_DATETIME = 9;
const int SQL_VARCHAR = 12;
const int SQL_TYPE_DATE = 91;
const int SQL_TYPE_TIME = 92;
const int SQL_TYPE_TIMESTAMP = 93;
const int SQL_LONGVARCHAR = -1;
const int SQL_BINARY = -2;
const int SQL_VARBINARY = -3;
const int SQL_LONGVARBINARY = -4;
const int SQL_BIGINT = -5;
const int SQL_TINYINT = -6;
const int SQL_BIT = -7;
const int SQL_WCHAR = -8;
const int SQL_WVARCHAR = -9;
const int SQL_WLONGVARCHAR = -10;
const int SQL_GUID = -11;
const int SQL_ALL_TYPES = 0;

// SQLGetInfo
const int SQL_DATA_SOURCE_NAME = 2;
const int SQL_DRIVER_NAME = 6;
const int SQL_DRIVER_VER = 7;
const int SQL_ODBC_VER = 10;
const int SQL_SERVER_NAME = 13;
const int SQL_SEARCH_PATTERN_ESCAPE = 14;
const int SQL_DATABASE_NAME = 16;
const int SQL_DBMS_NAME = 17;
const int SQL_DBMS_VER = 18;
const int SQL_IDENTIFIER_QUOTE_CHAR = 29;
const int SQL_SCHEMA_TERM = 39;
const int SQL_PROCEDURE_TERM = 40;
const int SQL_CATALOG_NAME_SEPARATOR = 41;
const int SQL_CATALOG_TERM = 42;
const int SQL_TABLE_TERM = 45;
const int SQL_TXN_CAPABLE = 46;
const int SQL_USER_NAME = 47;
const int SQL_DRIVER_ODBC_VER = 77;
const int SQL_KEYWORDS = 89;
const int SQL_SCHEMA_USAGE = 91;
const int SQL_CATALOG_USAGE = 92;
const int SQL_PROCEDURES = 21;
const int SQL_CATALOG_NAME = 10003;
const int SQL_MAX_IDENTIFIER_LEN = 10005;
const int SQL_MAX_CONCURRENT_ACTIVITIES = 1;

// SQLColAttribute
const int SQL_DESC_AUTO_UNIQUE_VALUE = 11;
const int SQL_DESC_TYPE_NAME = 14;
const int SQL_DESC_TABLE_NAME = 15;
const int SQL_DESC_SCHEMA_NAME = 16;
const int SQL_DESC_CATALOG_NAME = 17;
const int SQL_DESC_LABEL = 18;
const int SQL_DESC_BASE_COLUMN_NAME = 22;
const int SQL_DESC_BASE_TABLE_NAME = 23;

// SQLStatistics
const int SQL_INDEX_UNIQUE = 0;
const int SQL_INDEX_ALL = 1;
const int SQL_QUICK = 0;
const int SQL_TABLE_STAT = 0;

// SQLDrivers / SQLDataSources
const int SQL_FETCH_FIRST_USER = 31;
const int SQL_FETCH_FIRST_SYSTEM = 32;

// ---------------------------------------------------------------------------
// Native signatures
// ---------------------------------------------------------------------------

typedef SQLHANDLE = Pointer<Void>;

typedef _AllocHandleN = Int16 Function(Int16, SQLHANDLE, Pointer<SQLHANDLE>);
typedef _AllocHandleD = int Function(int, SQLHANDLE, Pointer<SQLHANDLE>);
typedef _FreeHandleN = Int16 Function(Int16, SQLHANDLE);
typedef _FreeHandleD = int Function(int, SQLHANDLE);
typedef _SetEnvAttrN = Int16 Function(SQLHANDLE, Int32, Pointer<Void>, Int32);
typedef _SetEnvAttrD = int Function(SQLHANDLE, int, Pointer<Void>, int);
typedef _SetAttrN = Int16 Function(SQLHANDLE, Int32, Pointer<Void>, Int32);
typedef _SetAttrD = int Function(SQLHANDLE, int, Pointer<Void>, int);
typedef _GetConnectAttrN = Int16 Function(SQLHANDLE, Int32, Pointer<Void>, Int32, Pointer<Int32>);
typedef _GetConnectAttrD = int Function(SQLHANDLE, int, Pointer<Void>, int, Pointer<Int32>);
typedef _DriverConnectN = Int16 Function(
  SQLHANDLE,
  Pointer<Void>,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Pointer<Int16>,
  Uint16,
);
typedef _DriverConnectD = int Function(
  SQLHANDLE,
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Int16>,
  int,
);
typedef _HandleOnlyN = Int16 Function(SQLHANDLE);
typedef _HandleOnlyD = int Function(SQLHANDLE);
typedef _EndTranN = Int16 Function(Int16, SQLHANDLE, Int16);
typedef _EndTranD = int Function(int, SQLHANDLE, int);
typedef _ExecDirectN = Int16 Function(SQLHANDLE, Pointer<Uint8>, Int32);
typedef _ExecDirectD = int Function(SQLHANDLE, Pointer<Uint8>, int);
typedef _NumResultColsN = Int16 Function(SQLHANDLE, Pointer<Int16>);
typedef _NumResultColsD = int Function(SQLHANDLE, Pointer<Int16>);
typedef _RowCountN = Int16 Function(SQLHANDLE, Pointer<IntPtr>);
typedef _RowCountD = int Function(SQLHANDLE, Pointer<IntPtr>);
typedef _DescribeColN = Int16 Function(
  SQLHANDLE,
  Uint16,
  Pointer<Uint8>,
  Int16,
  Pointer<Int16>,
  Pointer<Int16>,
  Pointer<UintPtr>,
  Pointer<Int16>,
  Pointer<Int16>,
);
typedef _DescribeColD = int Function(
  SQLHANDLE,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Int16>,
  Pointer<Int16>,
  Pointer<UintPtr>,
  Pointer<Int16>,
  Pointer<Int16>,
);
typedef _ColAttributeN = Int16 Function(
  SQLHANDLE,
  Uint16,
  Uint16,
  Pointer<Void>,
  Int16,
  Pointer<Int16>,
  Pointer<IntPtr>,
);
typedef _ColAttributeD = int Function(
  SQLHANDLE,
  int,
  int,
  Pointer<Void>,
  int,
  Pointer<Int16>,
  Pointer<IntPtr>,
);
typedef _GetDataN = Int16 Function(SQLHANDLE, Uint16, Int16, Pointer<Void>, IntPtr, Pointer<IntPtr>);
typedef _GetDataD = int Function(SQLHANDLE, int, int, Pointer<Void>, int, Pointer<IntPtr>);
typedef _FreeStmtN = Int16 Function(SQLHANDLE, Uint16);
typedef _FreeStmtD = int Function(SQLHANDLE, int);
typedef _BindParameterN = Int16 Function(
  SQLHANDLE,
  Uint16,
  Int16,
  Int16,
  Int16,
  UintPtr,
  Int16,
  Pointer<Void>,
  IntPtr,
  Pointer<IntPtr>,
);
typedef _BindParameterD = int Function(
  SQLHANDLE,
  int,
  int,
  int,
  int,
  int,
  int,
  Pointer<Void>,
  int,
  Pointer<IntPtr>,
);
typedef _GetDiagRecN = Int16 Function(
  Int16,
  SQLHANDLE,
  Int16,
  Pointer<Uint8>,
  Pointer<Int32>,
  Pointer<Uint8>,
  Int16,
  Pointer<Int16>,
);
typedef _GetDiagRecD = int Function(
  int,
  SQLHANDLE,
  int,
  Pointer<Uint8>,
  Pointer<Int32>,
  Pointer<Uint8>,
  int,
  Pointer<Int16>,
);
typedef _GetInfoN = Int16 Function(SQLHANDLE, Uint16, Pointer<Void>, Int16, Pointer<Int16>);
typedef _GetInfoD = int Function(SQLHANDLE, int, Pointer<Void>, int, Pointer<Int16>);
typedef _Cat3N = Int16 Function(
  SQLHANDLE,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
);
typedef _Cat3D = int Function(SQLHANDLE, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _Cat4N = Int16 Function(
  SQLHANDLE,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
);
typedef _Cat4D = int Function(
  SQLHANDLE,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);
typedef _Cat6N = Int16 Function(
  SQLHANDLE,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
);
typedef _Cat6D = int Function(
  SQLHANDLE,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);
typedef _StatisticsN = Int16 Function(
  SQLHANDLE,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Pointer<Uint8>,
  Int16,
  Uint16,
  Uint16,
);
typedef _StatisticsD = int Function(
  SQLHANDLE,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
  int,
);
typedef _GetTypeInfoN = Int16 Function(SQLHANDLE, Int16);
typedef _GetTypeInfoD = int Function(SQLHANDLE, int);
typedef _EnumN = Int16 Function(
  SQLHANDLE,
  Uint16,
  Pointer<Uint8>,
  Int16,
  Pointer<Int16>,
  Pointer<Uint8>,
  Int16,
  Pointer<Int16>,
);
typedef _EnumD = int Function(
  SQLHANDLE,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Int16>,
  Pointer<Uint8>,
  int,
  Pointer<Int16>,
);

/// Resolved ODBC driver manager entry points.
class OdbcApi {
  OdbcApi._(this.library, this.path, this.wcharSize) {
    final l = library;
    SQLAllocHandle = l.lookupFunction<_AllocHandleN, _AllocHandleD>('SQLAllocHandle');
    SQLFreeHandle = l.lookupFunction<_FreeHandleN, _FreeHandleD>('SQLFreeHandle');
    SQLSetEnvAttr = l.lookupFunction<_SetEnvAttrN, _SetEnvAttrD>('SQLSetEnvAttr');
    SQLSetConnectAttr = l.lookupFunction<_SetAttrN, _SetAttrD>('SQLSetConnectAttrW');
    SQLGetConnectAttr = l.lookupFunction<_GetConnectAttrN, _GetConnectAttrD>('SQLGetConnectAttrW');
    SQLSetStmtAttr = l.lookupFunction<_SetAttrN, _SetAttrD>('SQLSetStmtAttrW');
    SQLDriverConnect = l.lookupFunction<_DriverConnectN, _DriverConnectD>('SQLDriverConnectW');
    SQLDisconnect = l.lookupFunction<_HandleOnlyN, _HandleOnlyD>('SQLDisconnect');
    SQLEndTran = l.lookupFunction<_EndTranN, _EndTranD>('SQLEndTran');
    SQLExecDirect = l.lookupFunction<_ExecDirectN, _ExecDirectD>('SQLExecDirectW');
    SQLPrepare = l.lookupFunction<_ExecDirectN, _ExecDirectD>('SQLPrepareW');
    SQLExecute = l.lookupFunction<_HandleOnlyN, _HandleOnlyD>('SQLExecute');
    SQLNumResultCols = l.lookupFunction<_NumResultColsN, _NumResultColsD>('SQLNumResultCols');
    SQLRowCount = l.lookupFunction<_RowCountN, _RowCountD>('SQLRowCount');
    SQLDescribeCol = l.lookupFunction<_DescribeColN, _DescribeColD>('SQLDescribeColW');
    SQLColAttribute = l.lookupFunction<_ColAttributeN, _ColAttributeD>('SQLColAttributeW');
    SQLFetch = l.lookupFunction<_HandleOnlyN, _HandleOnlyD>('SQLFetch');
    SQLGetData = l.lookupFunction<_GetDataN, _GetDataD>('SQLGetData');
    SQLMoreResults = l.lookupFunction<_HandleOnlyN, _HandleOnlyD>('SQLMoreResults');
    SQLCancel = l.lookupFunction<_HandleOnlyN, _HandleOnlyD>('SQLCancel');
    SQLFreeStmt = l.lookupFunction<_FreeStmtN, _FreeStmtD>('SQLFreeStmt');
    SQLBindParameter = l.lookupFunction<_BindParameterN, _BindParameterD>('SQLBindParameter');
    SQLGetDiagRec = l.lookupFunction<_GetDiagRecN, _GetDiagRecD>('SQLGetDiagRecW');
    SQLGetInfo = l.lookupFunction<_GetInfoN, _GetInfoD>('SQLGetInfoW');
    SQLTables = l.lookupFunction<_Cat4N, _Cat4D>('SQLTablesW');
    SQLColumns = l.lookupFunction<_Cat4N, _Cat4D>('SQLColumnsW');
    SQLPrimaryKeys = l.lookupFunction<_Cat3N, _Cat3D>('SQLPrimaryKeysW');
    SQLForeignKeys = l.lookupFunction<_Cat6N, _Cat6D>('SQLForeignKeysW');
    SQLStatistics = l.lookupFunction<_StatisticsN, _StatisticsD>('SQLStatisticsW');
    SQLProcedures = l.lookupFunction<_Cat3N, _Cat3D>('SQLProceduresW');
    SQLProcedureColumns = l.lookupFunction<_Cat4N, _Cat4D>('SQLProcedureColumnsW');
    SQLGetTypeInfo = l.lookupFunction<_GetTypeInfoN, _GetTypeInfoD>('SQLGetTypeInfoW');
    SQLDrivers = l.lookupFunction<_EnumN, _EnumD>('SQLDriversW');
    SQLDataSources = l.lookupFunction<_EnumN, _EnumD>('SQLDataSourcesW');
  }

  final DynamicLibrary library;
  final String path;

  /// Size in bytes of SQLWCHAR (2 = UTF-16, 4 = UTF-32).
  final int wcharSize;

  late final _AllocHandleD SQLAllocHandle;
  late final _FreeHandleD SQLFreeHandle;
  late final _SetEnvAttrD SQLSetEnvAttr;
  late final _SetAttrD SQLSetConnectAttr;
  late final _GetConnectAttrD SQLGetConnectAttr;
  late final _SetAttrD SQLSetStmtAttr;
  late final _DriverConnectD SQLDriverConnect;
  late final _HandleOnlyD SQLDisconnect;
  late final _EndTranD SQLEndTran;
  late final _ExecDirectD SQLExecDirect;
  late final _ExecDirectD SQLPrepare;
  late final _HandleOnlyD SQLExecute;
  late final _NumResultColsD SQLNumResultCols;
  late final _RowCountD SQLRowCount;
  late final _DescribeColD SQLDescribeCol;
  late final _ColAttributeD SQLColAttribute;
  late final _HandleOnlyD SQLFetch;
  late final _GetDataD SQLGetData;
  late final _HandleOnlyD SQLMoreResults;
  late final _HandleOnlyD SQLCancel;
  late final _FreeStmtD SQLFreeStmt;
  late final _BindParameterD SQLBindParameter;
  late final _GetDiagRecD SQLGetDiagRec;
  late final _GetInfoD SQLGetInfo;
  late final _Cat4D SQLTables;
  late final _Cat4D SQLColumns;
  late final _Cat3D SQLPrimaryKeys;
  late final _Cat6D SQLForeignKeys;
  late final _StatisticsD SQLStatistics;
  late final _Cat3D SQLProcedures;
  late final _Cat4D SQLProcedureColumns;
  late final _GetTypeInfoD SQLGetTypeInfo;
  late final _EnumD SQLDrivers;
  late final _EnumD SQLDataSources;

  static final Map<String, OdbcApi> _cache = {};

  /// Default locations probed for the driver manager.
  static List<String> defaultCandidates() {
    if (Platform.isWindows) return ['odbc32.dll'];
    if (Platform.isMacOS) {
      return [
        '/opt/homebrew/lib/libodbc.2.dylib',
        '/usr/local/lib/libodbc.2.dylib',
        '/opt/local/lib/libodbc.2.dylib',
        'libodbc.2.dylib',
        '/usr/local/iODBC/lib/libiodbc.2.dylib',
        '/usr/lib/libiodbc.2.dylib',
        'libiodbc.2.dylib',
      ];
    }
    return [
      'libodbc.so.2',
      'libodbc.so',
      'libodbc.so.1',
      '/usr/lib/x86_64-linux-gnu/libodbc.so.2',
      '/usr/lib64/libodbc.so.2',
      'libiodbc.so.2',
    ];
  }

  /// Loads the driver manager. [customPath] (from preferences) or the
  /// `DBCRAFT_ODBC_LIB` environment variable take precedence over defaults.
  static OdbcApi load([String? customPath]) {
    _ensureUtf8CharType();
    final candidates = <String>[
      if (customPath != null && customPath.trim().isNotEmpty) customPath.trim(),
      if (Platform.environment['DBCRAFT_ODBC_LIB'] case final String env when env.isNotEmpty) env,
      ...defaultCandidates(),
    ];
    final errors = <String>[];
    for (final c in candidates) {
      final cached = _cache[c];
      if (cached != null) return cached;
      try {
        final lib = DynamicLibrary.open(c);
        final isIodbc = !Platform.isWindows && c.toLowerCase().contains('iodbc');
        final api = OdbcApi._(lib, c, isIodbc ? 4 : 2);
        _cache[c] = api;
        return api;
      } catch (e) {
        errors.add('$c: $e');
      }
    }
    throw OdbcLoadException(
      'Impossibile caricare il Driver Manager ODBC.\n'
      'Installa unixODBC (macOS: "brew install unixodbc", Linux: '
      '"apt install unixodbc") oppure indica il percorso della libreria '
      'nelle Preferenze.\n\n${errors.join('\n')}',
    );
  }

  static bool _localeChecked = false;

  /// unixODBC and iODBC convert the Unicode calls for drivers exporting only
  /// the ANSI functions (e.g. sqliteodbc) with the character set of the
  /// process locale. A GUI app starts with the "C" locale, so the text sent
  /// to those drivers was converted to Latin-1: switch LC_CTYPE to UTF-8.
  static void _ensureUtf8CharType() {
    if (_localeChecked || Platform.isWindows) return;
    _localeChecked = true;
    try {
      final setlocale = DynamicLibrary.process()
          .lookupFunction<Pointer<Utf8> Function(Int32, Pointer<Utf8>), Pointer<Utf8> Function(int, Pointer<Utf8>)>(
            'setlocale',
          );
      final lcCType = Platform.isMacOS ? 2 : 0;
      final current = setlocale(lcCType, nullptr);
      final name = current == nullptr ? 'C' : current.toDartString();
      if (name != 'C' && name != 'POSIX') return;
      for (final candidate in ['UTF-8', 'C.UTF-8', 'C.utf8', 'en_US.UTF-8']) {
        final arg = candidate.toNativeUtf8();
        try {
          if (setlocale(lcCType, arg) != nullptr) return;
        } finally {
          malloc.free(arg);
        }
      }
    } catch (_) {
      // Keep the default locale: only non ASCII text for ANSI drivers suffers.
    }
  }

  // -------------------------------------------------------------------------
  // Wide string helpers
  // -------------------------------------------------------------------------

  /// Encodes [s] as a NUL terminated SQLWCHAR string allocated with [alloc].
  Pointer<Uint8> toWide(String s, Allocator alloc) {
    if (wcharSize == 2) {
      final units = s.codeUnits;
      final p = alloc<Uint16>(units.length + 1);
      final list = p.asTypedList(units.length + 1);
      list.setAll(0, units);
      list[units.length] = 0;
      return p.cast();
    } else {
      final runes = s.runes.toList();
      final p = alloc<Uint32>(runes.length + 1);
      final list = p.asTypedList(runes.length + 1);
      list.setAll(0, runes);
      list[runes.length] = 0;
      return p.cast();
    }
  }

  /// Number of SQLWCHAR characters needed to encode [s] (without NUL).
  int wideLength(String s) => wcharSize == 2 ? s.length : s.runes.length;

  /// Decodes [chars] SQLWCHAR characters (or until NUL when [chars] < 0).
  String fromWide(Pointer<Uint8> p, [int chars = -1]) {
    if (p == nullptr) return '';
    if (wcharSize == 2) {
      final u = p.cast<Uint16>();
      if (chars < 0) {
        chars = 0;
        while (u[chars] != 0) {
          chars++;
        }
      }
      return String.fromCharCodes(u.asTypedList(chars));
    } else {
      final u = p.cast<Uint32>();
      if (chars < 0) {
        chars = 0;
        while (u[chars] != 0) {
          chars++;
        }
      }
      return String.fromCharCodes(u.asTypedList(chars));
    }
  }

  /// Decodes a byte buffer holding SQLWCHAR data.
  String wideBytesToString(Uint8List bytes) {
    if (wcharSize == 2) {
      final n = bytes.length ~/ 2;
      return String.fromCharCodes(Uint16List.view(bytes.buffer, bytes.offsetInBytes, n));
    }
    final n = bytes.length ~/ 4;
    return String.fromCharCodes(Uint32List.view(bytes.buffer, bytes.offsetInBytes, n));
  }
}

class OdbcLoadException implements Exception {
  OdbcLoadException(this.message);
  final String message;
  @override
  String toString() => message;
}

bool sqlSucceeded(int rc) => rc == SQL_SUCCESS || rc == SQL_SUCCESS_WITH_INFO;
