import 'package:flutter/foundation.dart';

import '../model/connection_config.dart';
import '../drivers/db_session.dart';
import '../drivers/session_factory.dart';
import '../services/metadata_service.dart';
import '../services/sql_dialect.dart';
import '../services/sql_splitter.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

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

  /// Statements executed in manual commit mode since the last commit.
  int pendingStatements = 0;

  String? _sessionPassword;
  String? _libPath;

  /// Connection string including the password typed at connect time.
  String get effectiveConnectionString =>
      config.buildConnectionString(overridePassword: config.savePassword ? null : _sessionPassword);

  String? get _password => config.savePassword ? null : _sessionPassword;

  /// Opens an additional independent session (exports, imports, …).
  Future<DbSession> openSession({bool readOnly = false}) =>
      openDbSession(config, libPath: _libPath, password: _password, readOnly: readOnly);

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
      m = await openDbSession(config, libPath: libPath, password: _password, readOnly: config.readOnly);
      final inf = await md.info();
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

  void refreshMetadata() {
    metadata?.clearCache();
    notifyListeners();
  }

  void touch() => notifyListeners();
}

final _modifying = RegExp(
  r'^\s*(insert|update|delete|merge|drop|truncate|alter|create|replace|grant|revoke|rename|upsert|exec|execute|call)\b',
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
