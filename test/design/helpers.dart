// Shared helpers of the design tool tests: one dialect per supported SQL
// DBMS, golden SQL per dialect and a scripted fake session.

import 'dart:io';

import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/services/metadata_service.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:flutter_test/flutter_test.dart';

/// One dialect per SQL DBMS the design tools support, with a current server
/// version. Every golden test covers all of them (see [expectPerFamily]).
final sqlDialects = <String, SqlDialect>{
  'pg': SqlDialect(dbmsName: 'PostgreSQL', dbmsVersion: '16.4'),
  'mssql': SqlDialect(dbmsName: 'Microsoft SQL Server', quote: '[', dbmsVersion: '16.00.4135'),
  'mysql': SqlDialect(dbmsName: 'MySQL', quote: '`', dbmsVersion: '8.4.0'),
  'mariadb': SqlDialect(dbmsName: 'MariaDB', quote: '`', dbmsVersion: '11.4.2-MariaDB'),
  'oracle': SqlDialect(dbmsName: 'Oracle', dbmsVersion: '23.00.0000'),
  'db2': SqlDialect(dbmsName: 'DB2/LINUXX8664', dbmsVersion: '11.05.0900'),
  'sqlite': SqlDialect(dbmsName: 'SQLite', dbmsVersion: '3.45.1'),
  'firebird': SqlDialect(dbmsName: 'Firebird', dbmsVersion: 'WI-V5.0.0.1306 Firebird 5.0'),
  'snowflake': SqlDialect(dbmsName: 'Snowflake', dbmsVersion: '8.30.1'),
};

/// [sqlDialects] entry [key] with another server [version].
SqlDialect dialectAt(String key, String version) {
  final d = sqlDialects[key]!;
  return SqlDialect(dbmsName: d.dbmsName, quote: d.quote, dbmsVersion: version);
}

/// Checks [build] against the [expected] output of every dialect of
/// [sqlDialects]: a missing dialect is a failure, so adding a DBMS forces
/// writing its expectations. Values are a statement, a list of statements
/// or a [Matcher].
void expectPerFamily(Object? Function(SqlDialect d) build, Map<String, Object?> expected) {
  final missing = sqlDialects.keys.where((k) => !expected.containsKey(k)).toList();
  final unknown = expected.keys.where((k) => !sqlDialects.containsKey(k)).toList();
  expect(missing, isEmpty, reason: 'Aspettative mancanti per: ${missing.join(', ')}');
  expect(unknown, isEmpty, reason: 'Dialetti sconosciuti: ${unknown.join(', ')}');
  for (final e in sqlDialects.entries) {
    final want = expected[e.key];
    final got = build(e.value);
    expect(got, want is String && got is List ? [want] : want, reason: 'Dialetto ${e.key}');
  }
}

/// Response of a [ScriptedSession] rule: rows with column names.
class Rows {
  Rows(this.columns, this.rows);
  final List<String> columns;
  final List<List<Object?>> rows;
}

/// Fake session answering statements by regular expression. Every call
/// (statements, transaction control) is logged in [log].
class ScriptedSession implements DbSession {
  ScriptedSession({this.pageSize = 1000});

  /// Rows per page (to exercise fetchMore).
  final int pageSize;
  final log = <String>[];
  final _rules = <(RegExp, Object)>[];

  /// ODBC catalog function → rows (in the [CatalogColumns] layout).
  final catalogs = <String, List<List<Object?>>>{};
  final _cursors = <int, List<List<Object?>>>{};
  final _cursorColumns = <int, List<ColumnInfo>>{};
  var _nextCursor = 1;
  bool closed = false;

  /// Statements matching [pattern] return [response]: a [Rows], an
  /// exception (thrown) or a function of the SQL returning either.
  void on(String pattern, Object response) => _rules.add((RegExp(pattern, caseSensitive: false), response));

  void rulesClear() => _rules.clear();

  List<String> get executed => [
    for (final l in log)
      if (l.startsWith('exec: ')) l.substring(6),
  ];

  static List<ColumnInfo> _columns(List<String> names) => [
    for (var i = 0; i < names.length; i++) ColumnInfo(index: i + 1, name: names[i], sqlType: 12, typeName: 'VARCHAR'),
  ];

  ResultPage _page(int cursor, List<ColumnInfo> columns, List<List<Object?>> rest) {
    final take = rest.take(pageSize).toList();
    final more = rest.length > pageSize;
    if (more) {
      _cursors[cursor] = rest.sublist(pageSize);
      _cursorColumns[cursor] = columns;
    } else {
      _cursors.remove(cursor);
    }
    return ResultPage(columns: columns, rows: take, hasMore: more, cursorId: more ? cursor : null);
  }

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) async {
    log.add('exec: $sql');
    for (final (re, response) in _rules) {
      if (!re.hasMatch(sql)) continue;
      var r = response;
      if (r is Object Function(String)) r = r(sql);
      if (r is Exception || r is Error) throw r;
      if (r is Rows) return _page(_nextCursor++, _columns(r.columns), r.rows);
      throw StateError('Risposta non valida: $r');
    }
    return ResultPage(columns: const [], rows: const [], rowsAffected: 0);
  }

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) async {
    final rest = _cursors[cursorId] ?? const [];
    return _page(cursorId, _cursorColumns[cursorId] ?? const [], rest);
  }

  @override
  Future<void> closeCursor(int cursorId) async {
    _cursors.remove(cursorId);
    log.add('close cursor');
  }

  @override
  Future<ResultPage> catalog(String function, List<String?> args) async {
    final layout = switch (function) {
      'tables' => CatalogColumns.tables,
      'columns' => CatalogColumns.columns,
      'primaryKeys' => CatalogColumns.primaryKeys,
      'foreignKeys' => CatalogColumns.foreignKeys,
      'statistics' => CatalogColumns.statistics,
      _ => const <String>[],
    };
    var rows = catalogs[function] ?? const [];
    // Per table functions: TABLE_NAME is the third column.
    if ((function == 'columns' || function == 'primaryKeys' || function == 'statistics') &&
        args.length > 2 &&
        args[2] != null) {
      rows = [
        for (final r in rows)
          if (r[2] == args[2]) r,
      ];
    }
    // SQLForeignKeys: (pk table…) lists the references, (…, fk table) the keys.
    if (function == 'foreignKeys') {
      final pkTable = args.length > 2 ? args[2] : null, fkTable = args.length > 5 ? args[5] : null;
      rows = [
        for (final r in rows)
          if ((pkTable == null || r[2] == pkTable) && (fkTable == null || r[6] == fkTable)) r,
      ];
    }
    return catalogResult(layout, rows);
  }

  @override
  Future<void> setAutoCommit(bool value) async => log.add('autocommit $value');
  @override
  Future<void> commit() async => log.add('commit');
  @override
  Future<void> rollback() async => log.add('rollback');
  @override
  Future<void> setCurrentCatalog(String catalog) async => log.add('use $catalog');
  @override
  Future<void> close() async {
    closed = true;
    log.add('close');
  }

  @override
  bool get isClosed => closed;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Connected [DbConnection] whose sessions are [session] (main recorded to
/// [history], like the real one).
DbConnection scriptedConnection(
  ScriptedSession session, {
  String dbmsName = 'PostgreSQL',
  String dbmsVersion = '16.4',
  ConnectionType type = ConnectionType.development,
  bool autoCommit = true,
  List<String>? history,
}) {
  final dc = DbConnection(ConnectionConfig(id: 'scripted', name: 'Prova', type: type));
  dc
    ..status = ConnectionStatus.connected
    ..meta = session
    ..autoCommit = autoCommit
    ..onHistory = ((e) => history?.add(e.sql));
  dc
    ..main = dc.withHistory(session)
    ..metadata = MetadataService(session, {
      'dbmsName': dbmsName,
      'dbmsVersion': dbmsVersion,
      'identifierQuote': '"',
      'schemaUsage': 1,
    });
  return dc;
}

/// SQLColumns row.
List<Object?> catalogColumn(String table, String name, String type, int pos, {bool nullable = true, int? size}) => [
  null,
  'app',
  table,
  name,
  4,
  type,
  size ?? 10,
  null,
  0,
  10,
  nullable ? 1 : 0,
  null,
  null,
  null,
  null,
  null,
  pos,
  null, //
];

/// Scripted PostgreSQL connection with table app.orders (id pk, code, qty)
/// and app.customers (id pk) in the ODBC catalog.
ScriptedSession ordersSession() {
  final s = ScriptedSession();
  s.catalogs['tables'] = [
    [null, 'app', 'orders', 'TABLE', null],
    [null, 'app', 'customers', 'TABLE', null],
  ];
  s.catalogs['columns'] = [
    catalogColumn('orders', 'id', 'int4', 1, nullable: false),
    catalogColumn('orders', 'code', 'varchar', 2, size: 20),
    catalogColumn('orders', 'qty', 'int4', 3),
    catalogColumn('orders', 'customer_id', 'int4', 4),
    catalogColumn('customers', 'id', 'int4', 1, nullable: false),
  ];
  s.catalogs['primaryKeys'] = [
    [null, 'app', 'orders', 'id', 1, 'orders_pkey'],
    [null, 'app', 'customers', 'id', 1, 'customers_pkey'],
  ];
  return s;
}

/// Application state on an empty temporary workspace.
Future<AppState> testApp(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('dbcraft_design_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  return (await tester.runAsync(() => AppState.load(workspaceDir: dir)))!;
}
