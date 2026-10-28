import 'package:flutter/material.dart';

import '../drivers/native_registry.dart';
import 'auth_methods.dart';
import '../ui/theme/app_icons.dart';

/// How the connection is opened: through ODBC (driver, DSN or connection
/// string) or with a built-in native driver (MongoDB, Redis, Cassandra,
/// BigQuery…).
enum ConnectionMode { dsn, driver, connectionString, native }

/// Connection "type" like in DBeaver: drives colors and safety checks. The
/// UI color comes from the theme (`ConnectionTypeColor.colorOf`).
enum ConnectionType {
  development('Sviluppo', false),
  test('Test', false),
  production('Produzione', true);

  const ConnectionType(this.label, this.confirmExecute);
  final String label;

  /// Ask for confirmation before running data modifying statements.
  final bool confirmExecute;
}

class ConnectionConfig {
  ConnectionConfig({
    required this.id,
    required this.name,
    this.mode = ConnectionMode.driver,
    this.dsn = '',
    this.driver = '',
    this.host = '',
    this.port = '',
    this.database = '',
    this.user = '',
    this.password = '',
    this.savePassword = true,
    this.connectionString = '',
    Map<String, String>? extraParams,
    this.type = ConnectionType.development,
    this.folder = '',
    this.readOnly = false,
    this.autoCommit = true,
    this.defaultCatalog = '',
    this.allDatabases = true,
    this.loginTimeout = 15,
    this.queryTimeout = 0,
    this.bootstrapQueries = '',
    this.description = '',
    this.nativeDriver = '',
    this.authMethod = AuthMethod.password,
    Map<String, String>? authParams,
    Map<String, String>? secretParams,
  }) : extraParams = extraParams ?? {},
       authParams = authParams ?? {},
       secretParams = secretParams ?? {};

  final String id;
  String name;
  ConnectionMode mode;
  String dsn;
  String driver;
  String host;
  String port;
  String database;
  String user;
  String password;
  bool savePassword;
  String connectionString;
  Map<String, String> extraParams;
  ConnectionType type;
  String folder;
  bool readOnly;
  bool autoCommit;
  String defaultCatalog;

  /// PostgreSQL: list every database of the server, each opened on its own
  /// sessions, instead of only [database].
  bool allDatabases;
  int loginTimeout;
  int queryTimeout;

  /// Statements executed right after connecting (one per line / `;`).
  String bootstrapQueries;
  String description;

  /// Native driver id (mode == native): mongodb, redis, cassandra, bigquery.
  String nativeDriver;

  AuthMethod authMethod;

  /// Non secret parameters of the authentication method (tenant, profile…).
  Map<String, String> authParams;

  /// Secret values (client secrets, tokens, secret native options). Never
  /// written to connections.json: they live in the encrypted vault.
  Map<String, String> secretParams;

  bool get isNative => mode == ConnectionMode.native;

  static final _databaseKeyword = RegExp(r'^\s*(DATABASE|DBNAME)\s*=', caseSensitive: false);

  /// A copy opening [db] instead of [database]: the database field, a
  /// `DATABASE=` added to a DSN, or the keyword of a connection string.
  ConnectionConfig forDatabase(String db) {
    final c = copy()..extraParams = {
      for (final e in extraParams.entries)
        if (!_databaseKeyword.hasMatch('${e.key}=')) e.key: e.value,
    };
    switch (mode) {
      case ConnectionMode.driver || ConnectionMode.native:
        c.database = db;
      case ConnectionMode.dsn:
        c.extraParams['DATABASE'] = db;
      case ConnectionMode.connectionString:
        final segments = [
          for (final e in splitOdbcSegments(connectionString))
            if (e.trim().isNotEmpty && !_databaseKeyword.hasMatch(e)) e,
        ];
        c.connectionString = [...segments, 'Database=${odbcEscape(db)}'].join(';');
    }
    return c;
  }

  ConnectionConfig copy({String? id, String? name}) => ConnectionConfig.fromJson({
    ...toJson(includePassword: true),
    'id': id ?? this.id,
    'name': name ?? this.name,
  });

  /// Display information of the native driver / ODBC template.
  IconData get icon => isNative ? (nativeDriverById(nativeDriver)?.icon ?? AppIcons.database) : template.icon;
  Color get color => isNative ? (nativeDriverById(nativeDriver)?.color ?? const Color(0xFF607D8B)) : template.color;

  DriverTemplate get template => DriverTemplate.forDriver(driver);

  /// Builds the ODBC connection string. [overridePassword] is used when the
  /// password is not saved and has been asked to the user.
  String buildConnectionString({String? overridePassword, String? token}) {
    final pwd = authMethod.usesPassword || authMethod == AuthMethod.password ? (overridePassword ?? password) : '';
    final useUser = authMethod.usesUser;
    final auth = mode == ConnectionMode.driver || mode == ConnectionMode.dsn ? authAttributes(this, token: token) : const <String, String>{};
    bool overridden(String? key) => key != null && auth.keys.any((k) => k.toLowerCase() == key.toLowerCase());
    switch (mode) {
      case ConnectionMode.native:
        final d = nativeDriverById(nativeDriver);
        if (connectionString.trim().isNotEmpty) return connectionString.trim();
        final hp = [host, if (port.isNotEmpty) port].join(':');
        return '${d?.id ?? nativeDriver}://${user.isNotEmpty && useUser ? '$user@' : ''}$hp${database.isEmpty ? '' : '/$database'}';
      case ConnectionMode.connectionString:
        var s = connectionString.trim();
        if (pwd.isEmpty) return s;
        // An empty PWD= / PASSWORD= left by [movePasswordToVault] is filled
        // in place, so that the keyword chosen by the user is kept.
        final segments = splitOdbcSegments(s);
        final i = segments.indexWhere((e) => _passwordKeyword.hasMatch(e));
        if (i < 0) return '${s.endsWith(';') || s.isEmpty ? s : '$s;'}PWD=${odbcEscape(pwd)}';
        final m = _passwordKeyword.firstMatch(segments[i])!;
        if (segments[i].substring(m.end).trim().isNotEmpty) return s;
        segments[i] = '${m[1]}=${odbcEscape(pwd)}';
        return segments.join(';');
      case ConnectionMode.dsn:
        final parts = <String>['DSN=${odbcEscape(dsn)}'];
        if (user.isNotEmpty && useUser && !overridden('UID')) parts.add('UID=${odbcEscape(user)}');
        if (pwd.isNotEmpty && !overridden('PWD')) parts.add('PWD=${odbcEscape(pwd)}');
        auth.forEach((k, v) => parts.add('$k=${odbcEscape(v)}'));
        extraParams.forEach((k, v) => parts.add('$k=${odbcEscape(v)}'));
        return parts.join(';');
      case ConnectionMode.driver:
        final t = template;
        final parts = <String>['DRIVER=${_braced(driver)}'];
        void add(String? key, String value) {
          if (key == null || value.isEmpty) return;
          parts.add('$key=${odbcEscape(value)}');
        }

        if (t.portInServer && port.isNotEmpty) {
          add(t.hostKey, '$host${t.portSeparator}$port');
        } else {
          add(t.hostKey, host);
          add(t.portKey, port);
        }
        add(t.databaseKey, database);
        if (useUser && !overridden(t.userKey)) add(t.userKey, user);
        if (!overridden(t.passwordKey)) add(t.passwordKey, pwd);
        auth.forEach((k, v) => parts.add('$k=${odbcEscape(v)}'));
        t.defaults.forEach((k, v) {
          if (!extraParams.keys.any((e) => e.toLowerCase() == k.toLowerCase())) {
            parts.add('$k=$v');
          }
        });
        extraParams.forEach((k, v) => parts.add('$k=${odbcEscape(v)}'));
        return parts.join(';');
    }
  }

  static final _passwordKeyword = RegExp(r'^\s*(PWD|PASSWORD)\s*=', caseSensitive: false);

  /// Moves a password written in an ODBC connection string to [password],
  /// which is kept in the vault instead of connections.json. The keyword is
  /// left empty (`PWD=`) and filled by [buildConnectionString]. Returns true
  /// when the configuration changed.
  bool movePasswordToVault() {
    if (mode != ConnectionMode.connectionString) return false;
    final segments = splitOdbcSegments(connectionString);
    var moved = false;
    for (var i = 0; i < segments.length; i++) {
      final m = _passwordKeyword.firstMatch(segments[i]);
      if (m == null) continue;
      final value = segments[i].substring(m.end).trim();
      if (value.isEmpty) continue;
      password = parseOdbcParams('x=$value')['x'] ?? value;
      savePassword = true;
      segments[i] = '${m[1]}=';
      moved = true;
    }
    if (moved) connectionString = segments.join(';');
    return moved;
  }

  /// Connection string with the password masked (for logs and UI).
  String get maskedConnectionString =>
      buildConnectionString(overridePassword: password.isEmpty ? '' : '****')
          .replaceAllMapped(RegExp(r'(PWD|PASSWORD)=([^;]*)', caseSensitive: false), (m) => '${m[1]}=****');

  bool get needsPasswordPrompt =>
      !savePassword && (authMethod == AuthMethod.password || authMethod.usesPassword) && (user.isNotEmpty || isNative);

  String get subtitle {
    switch (mode) {
      case ConnectionMode.native:
        final d = nativeDriverById(nativeDriver);
        final hp = [host, if (port.isNotEmpty) port].join(':');
        final where = connectionString.trim().isNotEmpty ? connectionString.replaceAll(RegExp(r'//[^@/]*@'), '//') : hp;
        return [d?.label ?? nativeDriver, if (where.isNotEmpty) where, if (database.isNotEmpty) database].join(' · ');
      case ConnectionMode.dsn:
        return 'DSN: $dsn';
      case ConnectionMode.connectionString:
        return 'Stringa di connessione';
      case ConnectionMode.driver:
        final hp = [host, if (port.isNotEmpty) port].join(':');
        // Driver given as a library path: show the recognised product instead.
        final t = template;
        final drv = driver.contains('/') || driver.contains(r'\')
            ? (t == DriverTemplate.generic ? driver.split(RegExp(r'[\\/]')).last : t.label)
            : driver;
        final db = t.fileBased ? database.split(RegExp(r'[\\/]')).last : database;
        return [drv, if (hp.isNotEmpty) hp, if (db.isNotEmpty) db].join(' · ');
    }
  }

  /// JSON for connections.json. Passwords and secrets are only included with
  /// [includePassword] (copies in memory): on disk they live in the vault.
  Map<String, Object?> toJson({bool includePassword = false}) => {
    'id': id,
    'name': name,
    'mode': mode.name,
    'dsn': dsn,
    'driver': driver,
    'host': host,
    'port': port,
    'database': database,
    'user': user,
    if (includePassword) 'password': password,
    if (includePassword && secretParams.isNotEmpty) 'secretParams': secretParams,
    'savePassword': savePassword,
    'connectionString': connectionString,
    'extraParams': extraParams,
    'type': type.name,
    'folder': folder,
    'readOnly': readOnly,
    'autoCommit': autoCommit,
    'defaultCatalog': defaultCatalog,
    'allDatabases': allDatabases,
    'loginTimeout': loginTimeout,
    'queryTimeout': queryTimeout,
    'bootstrapQueries': bootstrapQueries,
    'description': description,
    if (nativeDriver.isNotEmpty) 'nativeDriver': nativeDriver,
    'authMethod': authMethod.name,
    if (authParams.isNotEmpty) 'authParams': authParams,
  };

  factory ConnectionConfig.fromJson(Map<String, Object?> j) => ConnectionConfig(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Connessione',
    mode: ConnectionMode.values.asNameMap()[j['mode']] ?? ConnectionMode.driver,
    dsn: j['dsn'] as String? ?? '',
    driver: j['driver'] as String? ?? '',
    host: j['host'] as String? ?? '',
    port: j['port'] as String? ?? '',
    database: j['database'] as String? ?? '',
    user: j['user'] as String? ?? '',
    password: j['password'] as String? ?? '',
    savePassword: j['savePassword'] as bool? ?? true,
    connectionString: j['connectionString'] as String? ?? '',
    extraParams: (j['extraParams'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {},
    type: ConnectionType.values.asNameMap()[j['type']] ?? ConnectionType.development,
    folder: j['folder'] as String? ?? '',
    readOnly: j['readOnly'] as bool? ?? false,
    autoCommit: j['autoCommit'] as bool? ?? true,
    defaultCatalog: j['defaultCatalog'] as String? ?? '',
    allDatabases: j['allDatabases'] as bool? ?? true,
    loginTimeout: j['loginTimeout'] as int? ?? 15,
    queryTimeout: j['queryTimeout'] as int? ?? 0,
    bootstrapQueries: j['bootstrapQueries'] as String? ?? '',
    description: j['description'] as String? ?? '',
    nativeDriver: j['nativeDriver'] as String? ?? '',
    authMethod: AuthMethod.values.asNameMap()[j['authMethod']] ?? AuthMethod.password,
    authParams: (j['authParams'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {},
    secretParams: (j['secretParams'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {},
  );
}

String _braced(String v) => v.startsWith('{') || v.startsWith('/') ? v : '{$v}';

/// Parses driver parameters written one per line and/or separated by `;`
/// (`a=1;b=2`). Braced values (`{x;y}`) may contain `;` and are unwrapped,
/// since [odbcEscape] adds the braces back when building the string.
Map<String, String> parseOdbcParams(String text) {
  final out = <String, String>{};
  final buf = StringBuffer();
  var inBraces = false;
  void flush() {
    final s = buf.toString();
    buf.clear();
    final i = s.indexOf('=');
    if (i <= 0) return;
    final k = s.substring(0, i).trim();
    var v = s.substring(i + 1).trim();
    if (k.isEmpty) return;
    if (v.length >= 2 && v.startsWith('{') && v.endsWith('}')) v = v.substring(1, v.length - 1).replaceAll('}}', '}');
    out[k] = v;
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inBraces) {
      if (ch == '}') {
        if (i + 1 < text.length && text[i + 1] == '}') {
          buf.write('}}');
          i++;
          continue;
        }
        inBraces = false;
      }
      buf.write(ch);
    } else if (ch == ';' || ch == '\n' || ch == '\r') {
      flush();
    } else {
      if (ch == '{') inBraces = true;
      buf.write(ch);
    }
  }
  flush();
  return out;
}

/// Escapes a value for an ODBC connection string attribute.
/// Splits an ODBC connection string on `;`, keeping braced values (`{a;b}`)
/// and the text of every segment as written.
List<String> splitOdbcSegments(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  var inBraces = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inBraces) {
      if (ch == '}') {
        if (i + 1 < text.length && text[i + 1] == '}') {
          buf.write('}}');
          i++;
          continue;
        }
        inBraces = false;
      }
    } else if (ch == ';') {
      out.add(buf.toString());
      buf.clear();
      continue;
    } else if (ch == '{') {
      inBraces = true;
    }
    buf.write(ch);
  }
  out.add(buf.toString());
  return out;
}

String odbcEscape(String v) {
  if (v.contains(';') || v.contains('{') || v.contains('}') || v.trim() != v) {
    return '{${v.replaceAll('}', '}}')}}';
  }
  return v;
}

/// Knowledge about the connection string keywords used by common drivers.
class DriverTemplate {
  const DriverTemplate({
    required this.id,
    required this.label,
    required this.pattern,
    this.hostKey = 'SERVER',
    this.portKey = 'PORT',
    this.databaseKey = 'DATABASE',
    this.userKey = 'UID',
    this.passwordKey = 'PWD',
    this.defaultPort = '',
    this.portInServer = false,
    this.portSeparator = ',',
    this.defaults = const {},
    this.fileBased = false,
    this.icon = AppIcons.database,
    this.color = const Color(0xFF607D8B),
  });

  final String id;
  final String label;
  final String pattern;
  final String? hostKey;
  final String? portKey;
  final String? databaseKey;
  final String? userKey;
  final String? passwordKey;
  final String defaultPort;
  final bool portInServer;
  final String portSeparator;
  final Map<String, String> defaults;

  /// The database is a local file (SQLite, Access, …).
  final bool fileBased;
  final IconData icon;
  final Color color;

  static const generic = DriverTemplate(id: 'generic', label: 'Generico ODBC', pattern: r'$^');

  static const all = <DriverTemplate>[
    DriverTemplate(
      id: 'sqlserver',
      label: 'Microsoft SQL Server',
      pattern: r'sql server|msodbcsql',
      portInServer: true,
      defaultPort: '1433',
      // MARS: several result sets open at once on the same connection (SQL
      // editors share it), otherwise "Connection is busy with results…".
      defaults: {'TrustServerCertificate': 'yes', 'MARS_Connection': 'yes'},
      icon: AppIcons.server,
      color: Color(0xFFC62828),
    ),
    DriverTemplate(
      id: 'freetds',
      label: 'FreeTDS (SQL Server / Sybase)',
      pattern: r'freetds|tdsodbc',
      defaultPort: '1433',
      icon: AppIcons.server,
      color: Color(0xFFAD1457),
    ),
    DriverTemplate(
      id: 'redshift',
      label: 'Amazon Redshift',
      pattern: r'redshift',
      defaultPort: '5439',
      icon: AppIcons.cloud,
      color: Color(0xFF8C4FFF),
    ),
    DriverTemplate(
      id: 'postgres',
      label: 'PostgreSQL',
      pattern: r'postgres|psqlodbc',
      defaultPort: '5432',
      icon: AppIcons.database,
      color: Color(0xFF336791),
    ),
    DriverTemplate(
      id: 'mysql',
      label: 'MySQL / MariaDB',
      pattern: r'mysql|maria',
      defaultPort: '3306',
      userKey: 'USER',
      passwordKey: 'PASSWORD',
      icon: AppIcons.database,
      color: Color(0xFF00758F),
    ),
    DriverTemplate(
      id: 'oracle',
      label: 'Oracle',
      pattern: r'oracle|sqora',
      hostKey: 'DBQ',
      portKey: null,
      databaseKey: null,
      icon: AppIcons.database,
      color: Color(0xFFF80000),
    ),
    DriverTemplate(
      id: 'db2',
      label: 'IBM Db2',
      pattern: r'db2|ibm',
      hostKey: 'HOSTNAME',
      defaultPort: '50000',
      defaults: {'PROTOCOL': 'TCPIP'},
      icon: AppIcons.database,
      color: Color(0xFF1F70C1),
    ),
    DriverTemplate(
      id: 'sqlite',
      label: 'SQLite',
      pattern: r'sqlite',
      hostKey: null,
      portKey: null,
      userKey: null,
      passwordKey: null,
      fileBased: true,
      icon: AppIcons.file,
      color: Color(0xFF0F80CC),
    ),
    DriverTemplate(
      id: 'access',
      label: 'Microsoft Access',
      pattern: r'access|\.mdb',
      hostKey: null,
      portKey: null,
      databaseKey: 'DBQ',
      fileBased: true,
      icon: AppIcons.file,
      color: Color(0xFFA4373A),
    ),
    DriverTemplate(
      id: 'snowflake',
      label: 'Snowflake',
      pattern: r'snowflake',
      portKey: null,
      icon: AppIcons.snowflake,
      color: Color(0xFF29B5E8),
    ),
    DriverTemplate(
      id: 'firebird',
      label: 'Firebird',
      pattern: r'firebird',
      hostKey: null,
      portKey: null,
      databaseKey: 'DBNAME',
      userKey: 'USER',
      passwordKey: 'PASSWORD',
      icon: AppIcons.fire,
      color: Color(0xFFE65100),
    ),
    DriverTemplate(
      id: 'bigquery',
      label: 'Google BigQuery (ODBC)',
      pattern: r'bigquery',
      hostKey: null,
      portKey: null,
      databaseKey: 'Catalog',
      userKey: null,
      passwordKey: null,
      icon: AppIcons.cloud,
      color: Color(0xFF4285F4),
    ),
    DriverTemplate(
      id: 'databricks',
      label: 'Databricks / Spark',
      pattern: r'databricks|spark|simba spark',
      hostKey: 'Host',
      portKey: 'Port',
      defaultPort: '443',
      databaseKey: 'Schema',
      defaults: {'ThriftTransport': '2', 'SSL': '1'},
      icon: AppIcons.cloud,
      color: Color(0xFFFF3621),
    ),
    DriverTemplate(
      id: 'athena',
      label: 'Amazon Athena',
      pattern: r'athena',
      hostKey: 'Endpoint',
      portKey: null,
      databaseKey: 'Schema',
      userKey: null,
      passwordKey: null,
      icon: AppIcons.cloud,
      color: Color(0xFF8C4FFF),
    ),
    DriverTemplate(
      id: 'mongodb_odbc',
      label: 'MongoDB (Atlas SQL ODBC)',
      pattern: r'mongo',
      defaultPort: '27017',
      icon: AppIcons.leaf,
      color: Color(0xFF00684A),
    ),
    DriverTemplate(
      id: 'cassandra_odbc',
      label: 'Apache Cassandra (ODBC)',
      pattern: r'cassandra',
      hostKey: 'Host',
      defaultPort: '9042',
      databaseKey: 'DefaultKeyspace',
      icon: AppIcons.blur,
      color: Color(0xFF1287B1),
    ),
    DriverTemplate(
      id: 'clickhouse',
      label: 'ClickHouse',
      pattern: r'clickhouse',
      hostKey: 'Host',
      defaultPort: '8123',
      databaseKey: 'Database',
      userKey: 'Username',
      passwordKey: 'Password',
      icon: AppIcons.barChart,
      color: Color(0xFFFFCC01),
    ),
    DriverTemplate(
      id: 'trino',
      label: 'Trino / Presto',
      pattern: r'trino|presto|starburst',
      hostKey: 'Host',
      defaultPort: '8080',
      databaseKey: 'Catalog',
      userKey: 'User',
      passwordKey: 'Password',
      icon: AppIcons.hub,
      color: Color(0xFFDD00A1),
    ),
    DriverTemplate(
      id: 'duckdb',
      label: 'DuckDB',
      pattern: r'duckdb',
      hostKey: null,
      portKey: null,
      userKey: null,
      passwordKey: null,
      fileBased: true,
      icon: AppIcons.file,
      color: Color(0xFFFBC02D),
    ),
  ];

  static DriverTemplate forDriver(String driver) {
    final d = driver.toLowerCase();
    for (final t in all) {
      if (RegExp(t.pattern).hasMatch(d)) return t;
    }
    return generic;
  }
}
