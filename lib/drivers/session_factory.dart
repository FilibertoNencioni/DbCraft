import '../model/auth_methods.dart';
import '../model/connection_config.dart';
import '../odbc/odbc_session.dart';
import 'db_session.dart';
import 'native_driver.dart';
import 'native_registry.dart';

/// Resolves access tokens for methods the ODBC driver cannot handle by itself
/// (Entra ID / AWS IAM for PostgreSQL and MySQL). Set by the cloud module.
Future<String?> Function(ConnectionConfig c)? databaseTokenProvider;

/// Opens a session for [c] with the right transport: a native driver or ODBC.
/// [password] replaces the configured one (asked at connect time).
Future<DbSession> openDbSession(
  ConnectionConfig c, {
  String? libPath,
  String? password,
  bool readOnly = false,
}) async {
  if (c.isNative) {
    final d = nativeDriverById(c.nativeDriver);
    if (d == null) throw StateError('Driver integrato "${c.nativeDriver}" non disponibile');
    return d.open(nativeParams(c, password: password, readOnly: readOnly));
  }
  String? token;
  if (needsExternalToken(c)) {
    final provider = databaseTokenProvider;
    if (provider == null) throw StateError('Autenticazione "${c.authMethod.label}" non disponibile');
    token = await provider(c);
  }
  return OdbcSession.open(
    c.buildConnectionString(overridePassword: password, token: token),
    libPath: libPath,
    loginTimeoutSec: c.loginTimeout,
    readOnly: readOnly || c.readOnly,
  );
}

NativeConnectParams nativeParams(ConnectionConfig c, {String? password, bool readOnly = false}) {
  final m = c.authMethod;
  return NativeConnectParams(
    host: c.host,
    port: c.port,
    database: c.database,
    user: m.usesUser || m == AuthMethod.password ? c.user : '',
    password: m.usesPassword || m == AuthMethod.password ? (password ?? c.password) : '',
    options: {...c.extraParams, ...c.authParams, ...c.secretParams, 'authMethod': m.name},
    connectionUri: c.connectionString,
    loginTimeoutSec: c.loginTimeout,
    readOnly: readOnly || c.readOnly,
  );
}
