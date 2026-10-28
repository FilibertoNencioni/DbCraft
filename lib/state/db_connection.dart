import 'package:flutter/foundation.dart';

import '../model/connection_config.dart';
import '../drivers/db_session.dart';
import '../drivers/recording_session.dart';
import '../drivers/session_factory.dart';
import '../odbc/odbc_types.dart';
import '../services/metadata_service.dart';
import '../services/sql_dialect.dart';
import '../services/sql_splitter.dart';
import '../services/storage.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

/// Part of a database whose structure changed (see
/// [DbConnection.schemaChanged]). A null [catalog] or [schema] matches any.
class SchemaScope {
  const SchemaScope._(this.level, {this.catalog, this.schema, this.object});

  /// The list of databases (catalogs) or everything may have changed.
  static const connection = SchemaScope._(SchemaLevel.connection);

  /// The schemas of [catalog] changed.
  const SchemaScope.catalog(String? catalog) : this._(SchemaLevel.catalog, catalog: catalog);

  /// The objects of a schema changed (created, dropped, renamed).
  const SchemaScope.schema(String? catalog, String? schema)
    : this._(SchemaLevel.schema, catalog: catalog, schema: schema);

  /// The structure of the object [object] changed.
  const SchemaScope.object(String? catalog, String? schema, String object)
    : this._(SchemaLevel.object, catalog: catalog, schema: schema, object: object);

  /// Users, roles or privileges changed (of [catalog] for SQL Server
  /// database users): no schema object is affected.
  const SchemaScope.security([String? catalog]) : this._(SchemaLevel.security, catalog: catalog);

  final SchemaLevel level;
  final String? catalog;
  final String? schema;
  final String? object;

  /// Whether a location (catalog, schema) is inside this scope.
  bool covers(String? catalog, String? schema) {
    if (level == SchemaLevel.security) return false;
    return level == SchemaLevel.connection ||
        ((this.catalog == null || catalog == null || _same(this.catalog, catalog)) &&
            (level == SchemaLevel.catalog || this.schema == null || schema == null || _same(this.schema, schema)));
  }

  /// Whether the object [name] at (catalog, schema) is inside this scope.
  bool coversObject(String? catalog, String? schema, String name) =>
      covers(catalog, schema) && (object == null || _same(object, name));

  static bool _same(String? a, String? b) => (a ?? '').toLowerCase() == (b ?? '').toLowerCase();

  @override
  String toString() => 'SchemaScope(${level.name} ${[catalog, schema, object].whereType<String>().join('.')})';
}

enum SchemaLevel { connection, catalog, schema, object, security }

/// Runtime state of a configured connection (DBeaver "data source").
///
/// Two ODBC sessions are opened: one for metadata reading (navigator,
/// autocompletion) and one for SQL editors / data editors, so that browsing
/// the navigator never waits for a running query.
class DbConnection extends ChangeNotifier {
  DbConnection(this.config);

  ConnectionConfig config;
  ConnectionStatus status = ConnectionStatus.disconnected;
  String? error;
  DbSession? main;
  DbSession? meta;
  MetadataService? metadata;
  Map<String, Object?> info = const {};
  DateTime? connectedAt;

  bool autoCommit = true;

  /// Database (catalog) used by SQL editors that did not choose one.
  String? defaultCatalog;

  /// Database the [main] session is currently set to: SQL editors share it,
  /// so each one switches it to its own before running (see [useCatalog]).
  String? mainCatalog;

  /// Statements executed in manual commit mode since the last commit.
  int pendingStatements = 0;

  /// Receives every statement run on the [main] session (query history).
  void Function(HistoryEntry e)? onHistory;

  /// Incremented by [schemaChanged]; the navigator and the object editors
  /// compare it with the last value they saw.
  int schemaGeneration = 0;

  /// Scopes of the latest [schemaChanged] calls (oldest first).
  final List<SchemaScope> _schemaChanges = [];
  static const _keptSchemaChanges = 32;

  /// What changed after [generation]: the whole connection when [generation]
  /// is too old to know.
  List<SchemaScope> schemaChangesSince(int generation) {
    final n = schemaGeneration - generation;
    if (n <= 0) return const [];
    if (n > _schemaChanges.length) return const [SchemaScope.connection];
    return _schemaChanges.sublist(_schemaChanges.length - n);
  }

  String? _sessionPassword;
  String? _libPath;

  /// Connection string including the password typed at connect time.
  String get effectiveConnectionString =>
      config.buildConnectionString(overridePassword: config.savePassword ? null : _sessionPassword);

  String? get _password => config.savePassword ? null : _sessionPassword;

  /// Opens an additional independent session (exports, imports, …).
  Future<DbSession> openSession({bool readOnly = false}) =>
      sessionOpener?.call(readOnly) ??
      openDbSession(config, libPath: _libPath, password: _password, readOnly: readOnly);

  /// Replaces the driver in [openSession] (tests).
  @visibleForTesting
  Future<DbSession> Function(bool readOnly)? sessionOpener;

  /// [session] reporting its statements to the query history, like [main].
  DbSession withHistory(DbSession session) => RecordingSession(session, _recordStatement);

  /// The [main] session without the query history recorder: for statements
  /// that carry secrets (CREATE USER … PASSWORD). Same transaction and
  /// current catalog as [main].
  DbSession? get unrecordedMain {
    final m = main;
    return m is RecordingSession ? m.inner : m;
  }

  bool get isConnected => status == ConnectionStatus.connected;
  SqlDialect get dialect => metadata?.dialect ?? SqlDialect(dbmsName: '');

  String get serverLabel {
    final n = info['dbmsName'] as String? ?? '';
    final v = info['dbmsVersion'] as String? ?? '';
    return [n, v].where((e) => e.isNotEmpty).join(' ');
  }

  Future<void> connect({String? libPath, String? password}) async {
    if (status == ConnectionStatus.connecting || isConnected) return;
    status = ConnectionStatus.connecting;
    error = null;
    notifyListeners();
    if (password != null) _sessionPassword = password;
    _libPath = libPath;
    DbSession? m, md;
    try {
      // Open the metadata session first: it validates the parameters
      // without opening two failing logins.
      md = await openDbSession(config, libPath: libPath, password: _password);
      m = RecordingSession(
        await openDbSession(config, libPath: libPath, password: _password, readOnly: config.readOnly),
        _recordStatement,
      );
      final inf = normalizeServerInfo(await md.info());
      if (config.defaultCatalog.isNotEmpty) {
        await m.setCurrentCatalog(config.defaultCatalog);
        inf['currentCatalog'] = config.defaultCatalog;
      }
      if (!config.autoCommit) await m.setAutoCommit(false);
      if (config.bootstrapQueries.trim().isNotEmpty) {
        for (final s in SqlSplitter().split(config.bootstrapQueries)) {
          final r = await m.execute(s.text);
          if (r.cursorId != null) await m.closeCursor(r.cursorId!);
        }
      }
      main = m;
      meta = md;
      info = inf;
      metadata = MetadataService(md, inf);
      defaultCatalog = mainCatalog = inf['currentCatalog'] as String?;
      autoCommit = config.autoCommit;
      pendingStatements = 0;
      status = ConnectionStatus.connected;
      connectedAt = DateTime.now();
    } catch (e) {
      await m?.close();
      await md?.close();
      status = ConnectionStatus.error;
      error = e.toString();
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    final m = main, md = meta;
    main = null;
    meta = null;
    metadata = null;
    defaultCatalog = mainCatalog = null;
    status = ConnectionStatus.disconnected;
    pendingStatements = 0;
    connectedAt = null;
    notifyListeners();
    await Future.wait([if (m != null) m.close(), if (md != null) md.close()]);
  }

  Future<void> reconnect({String? libPath}) async {
    await disconnect();
    await connect(libPath: libPath);
  }

  /// Switches the main session to [catalog] if it is not already there.
  Future<void> useCatalog(String? catalog) async {
    final m = main;
    if (m == null || catalog == null || catalog.isEmpty || catalog == mainCatalog) return;
    await m.setCurrentCatalog(catalog);
    mainCatalog = catalog;
  }

  /// Re-reads the main session catalog (after a `USE xxx` in a script).
  Future<String?> syncMainCatalog() async {
    final m = main;
    if (m == null) return mainCatalog;
    try {
      final cur = await m.currentCatalog();
      if (cur != null && cur.isNotEmpty) mainCatalog = cur;
    } catch (_) {
      // Not supported by the driver: keep the last known value.
    }
    return mainCatalog;
  }

  Future<void> setAutoCommit(bool value) async {
    final m = main;
    if (m == null) return;
    await m.setAutoCommit(value);
    autoCommit = value;
    pendingStatements = 0;
    notifyListeners();
  }

  Future<void> commit() async {
    await main?.commit();
    pendingStatements = 0;
    notifyListeners();
  }

  Future<void> rollback() async {
    await main?.rollback();
    pendingStatements = 0;
    notifyListeners();
  }

  /// Called after each statement run on the main session.
  void statementExecuted({bool modifying = true}) {
    if (!autoCommit && modifying) {
      pendingStatements++;
      notifyListeners();
    }
  }

  void _recordStatement(String sql, List<Object?> params, ResultPage? page, Object? error, int durationMs) {
    onHistory?.call(
      HistoryEntry(
        sql: dialect.inlineParams(sql, params),
        connectionId: config.id,
        connectionName: config.name,
        time: DateTime.now(),
        durationMs: durationMs,
        rows: page == null ? -1 : (page.isResultSet ? page.rows.length : page.rowsAffected),
        error: error == null ? null : (error is OdbcException ? error.message : error.toString()),
      ),
    );
  }

  void refreshMetadata() {
    metadata?.clearCache();
    notifyListeners();
  }

  /// Called after DDL: drops the cached metadata and tells the navigator and
  /// the open editors which part of the database to reload.
  void schemaChanged([SchemaScope scope = SchemaScope.connection]) {
    metadata?.clearCache();
    schemaGeneration++;
    _schemaChanges.add(scope);
    if (_schemaChanges.length > _keptSchemaChanges) _schemaChanges.removeAt(0);
    notifyListeners();
  }

  void touch() => notifyListeners();
}

final _modifying = RegExp(
  r'^\s*(insert|update|delete|merge|drop|truncate|alter|create|replace|grant|revoke|rename|upsert|exec|execute|call|copy|load|comment|refresh|do)\b',
  caseSensitive: false,
);

/// Rough check used for the "production" confirmation and transaction count.
bool isModifyingSql(String sql) {
  final stripped = sql
      .replaceAll(RegExp(r'--[^\n]*'), '')
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .trimLeft();
  if (_modifying.hasMatch(stripped)) return true;
  // WITH … DELETE/UPDATE/INSERT
  return RegExp(
    r'^\s*with\b[\s\S]*\b(insert|update|delete|merge)\b',
    caseSensitive: false,
  ).hasMatch(stripped);
}

bool isDangerousSql(String sql) {
  final s = sql.trim().toLowerCase();
  if (RegExp(r'^(drop|truncate)\b').hasMatch(s)) return true;
  // DELETE / UPDATE without WHERE
  if (RegExp(r'^(delete|update)\b').hasMatch(s) && !RegExp(r'\bwhere\b').hasMatch(s)) {
    return true;
  }
  return false;
}

/// The MySQL and MariaDB ODBC drivers report the version in the ODBC format
/// (`08.04.000003`): shown as the server does (`8.4.3`).
Map<String, Object?> normalizeServerInfo(Map<String, Object?> info) {
  final name = (info['dbmsName'] as String? ?? '').toLowerCase();
  final v = info['dbmsVersion'] as String? ?? '';
  final m = RegExp(r'^0*(\d+)\.0*(\d+)\.0*(\d+)$').firstMatch(v.trim());
  if (m != null && (name.contains('mysql') || name.contains('mariadb'))) {
    info['dbmsVersion'] = '${m[1]}.${m[2]}.${m[3]}';
  }
  return info;
}
