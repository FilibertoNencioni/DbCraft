// Common interface of a database session.
//
// The UI, the metadata service and the data editors only talk to a
// [DbSession]. ODBC sessions (odbc/odbc_session.dart) and the native drivers
// (MongoDB, Redis, Cassandra, BigQuery, …) implement it.
//
// Native drivers emulate the ODBC catalog functions: [catalog] must return a
// [ResultPage] whose rows follow the ODBC column order of the function
// (SQLTables, SQLColumns, SQLPrimaryKeys, SQLForeignKeys, SQLStatistics,
// SQLProcedures, SQLProcedureColumns) because MetadataService reads them by
// position.
import '../odbc/odbc_types.dart';

abstract class DbSession {
  /// Connection string actually used (for ODBC the one completed by the
  /// driver manager, for native drivers a masked URI).
  String get completedConnectionString;

  bool get isClosed;
  bool get isBusy;

  /// Executes a statement (SQL, CQL, Redis command, MongoDB shell command…).
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  });

  Future<ResultPage> fetchMore(int cursorId, int count);

  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize);

  Future<void> closeCursor(int cursorId);

  /// ODBC catalog function emulation: `tables`, `columns`, `primaryKeys`,
  /// `foreignKeys`, `statistics`, `procedures`, `procedureColumns`, `typeInfo`.
  Future<ResultPage> catalog(String function, List<String?> args);

  /// Connection information. Keys used by the app: dbmsName, dbmsVersion,
  /// driverName, driverVersion, serverName, databaseName, userName,
  /// identifierQuote, catalogTerm, schemaTerm, catalogSupported ('Y'/'N'),
  /// proceduresSupported ('Y'/'N'), schemaUsage (int), catalogUsage (int),
  /// currentCatalog, keywords and – for native drivers – `nativeDriver`
  /// (driver id) and `queryLanguage` ('sql', 'cql', 'mongo', 'redis').
  Future<Map<String, Object?>> info();

  Future<void> setAutoCommit(bool value);
  Future<void> commit();
  Future<void> rollback();
  Future<void> setCurrentCatalog(String catalog);
  Future<String?> currentCatalog();

  /// Best effort cancellation of the running statement.
  void cancel();

  Future<void> close();
}

/// Builds an empty catalog result with the given column names (helper for
/// native drivers).
ResultPage catalogResult(List<String> columns, List<List<Object?>> rows) => ResultPage(
  columns: [
    for (var i = 0; i < columns.length; i++) ColumnInfo(index: i + 1, name: columns[i], sqlType: 12, typeName: 'VARCHAR'),
  ],
  rows: rows,
);

/// ODBC column layouts of the catalog functions (used by native drivers).
abstract final class CatalogColumns {
  static const tables = ['TABLE_CAT', 'TABLE_SCHEM', 'TABLE_NAME', 'TABLE_TYPE', 'REMARKS'];
  static const columns = [
    'TABLE_CAT', 'TABLE_SCHEM', 'TABLE_NAME', 'COLUMN_NAME', 'DATA_TYPE', 'TYPE_NAME', //
    'COLUMN_SIZE', 'BUFFER_LENGTH', 'DECIMAL_DIGITS', 'NUM_PREC_RADIX', 'NULLABLE', 'REMARKS',
    'COLUMN_DEF', 'SQL_DATA_TYPE', 'SQL_DATETIME_SUB', 'CHAR_OCTET_LENGTH', 'ORDINAL_POSITION', 'IS_NULLABLE',
  ];
  static const primaryKeys = ['TABLE_CAT', 'TABLE_SCHEM', 'TABLE_NAME', 'COLUMN_NAME', 'KEY_SEQ', 'PK_NAME'];
  static const foreignKeys = [
    'PKTABLE_CAT', 'PKTABLE_SCHEM', 'PKTABLE_NAME', 'PKCOLUMN_NAME', 'FKTABLE_CAT', 'FKTABLE_SCHEM', //
    'FKTABLE_NAME', 'FKCOLUMN_NAME', 'KEY_SEQ', 'UPDATE_RULE', 'DELETE_RULE', 'FK_NAME', 'PK_NAME', 'DEFERRABILITY',
  ];
  static const statistics = [
    'TABLE_CAT', 'TABLE_SCHEM', 'TABLE_NAME', 'NON_UNIQUE', 'INDEX_QUALIFIER', 'INDEX_NAME', //
    'TYPE', 'ORDINAL_POSITION', 'COLUMN_NAME', 'ASC_OR_DESC', 'CARDINALITY', 'PAGES', 'FILTER_CONDITION',
  ];
  static const procedures = [
    'PROCEDURE_CAT', 'PROCEDURE_SCHEM', 'PROCEDURE_NAME', 'NUM_INPUT_PARAMS', 'NUM_OUTPUT_PARAMS', //
    'NUM_RESULT_SETS', 'REMARKS', 'PROCEDURE_TYPE',
  ];
}
