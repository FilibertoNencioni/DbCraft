// Targets of the test matrix: how to connect, how to check the server side
// (L3, through the DBMS command line client) and the dialect specific SQL the
// cases need. Selected with --dart-define=TARGET=<id>.
import 'dart:io';

import 'harness.dart' show target;

/// Root of the repository, passed with --dart-define=REPO=$PWD.
final String repo = const String.fromEnvironment('REPO').isNotEmpty
    ? const String.fromEnvironment('REPO')
    : throw StateError('--dart-define=REPO=<root of the repository> is required');
const _pwd = 'DbCraft_Test1';

class Target {
  const Target({
    required this.id,
    required this.connection,
    required this.cli,
    this.sleepSql,
    this.printSql,
    this.multiResultSql,
    this.badSql = 'SELECT * FROM tabella_inesistente',
    this.paramSql = 'SELECT id, nome, stipendio FROM dipendenti WHERE stipendio > :minimo AND reparto_id = ?',
    this.prepare,
    this.form = const [],
    this.connectionString = '',
    this.bootstrap = const ('', '', ''),
    this.serverDown,
    this.quote = ('"', '"'),
    this.scriptWithBlocks = '',
    this.scriptCheck = '',
    this.encodingProbe = "SELECT 'città', hex('città'), length('città')",
    this.navPath = const [],
    this.scriptDelimiter,
  });

  /// A script using the MySQL client DELIMITER command (SQL-06b).
  final String? scriptDelimiter;

  /// Navigator nodes between the connection and its "Tabelle" folder.
  final List<String> navPath;

  /// Shows the bytes a non-ASCII literal of the SQL text arrives as.
  final String encodingProbe;

  /// Identifier quotes of the command line client.
  final (String, String) quote;
  String quoteIdent(String name) => '${quote.$1}$name${quote.$2}';

  /// A script with procedural blocks (SQL-06) and a query returning 1 once
  /// it ran completely.
  final String scriptWithBlocks;
  final String scriptCheck;

  /// Fields of the connection sheet in "Driver ODBC" mode: (label, value,
  /// index of the field in the row). The Host row has host (0) and port (1).
  final List<(String, String, int)> form;

  /// A complete connection string for the "Stringa" mode.
  final String connectionString;

  /// (initialization query, query reading its effect, expected value).
  final (String, String, String) bootstrap;

  /// Stops and restarts the server (CON-15); null = not applicable.
  final ({List<String> stop, List<String> start})? serverDown;

  final String id;

  /// connections.json entry (password included: the app moves it to the vault).
  final Map<String, Object?> Function() connection;

  /// Command line that runs one SQL statement and prints tab separated rows.
  final List<String> Function(String sql) cli;

  /// A statement running ~30 s (cancel test); null = not available.
  final String? sleepSql;

  /// A statement printing a server message; null = not available.
  final String? printSql;

  /// A statement returning two result sets; null = not available.
  final String? multiResultSql;
  final String badSql;
  final String paramSql;

  /// Resets the dataset before the suite.
  final Future<void> Function()? prepare;

  /// Runs [sql] on the server (L3) and returns the rows as lists of strings.
  Future<List<List<String>>> query(String sql) async {
    final cmd = cli(sql);
    final r = await Process.run(cmd.first, cmd.sublist(1));
    if (r.exitCode != 0) throw StateError('L3 failed (${r.exitCode}): ${r.stderr}\n$sql');
    var out = r.stdout as String;
    if (id == 'cassandra') {
      // cqlsh: header, dashes, rows, "(n rows)".
      final lines = out.split('\n');
      final dash = lines.indexWhere((l) => l.trim().startsWith('---'));
      out = lines.skip(dash + 1).where((l) => !l.trim().startsWith('(') && l.trim().isNotEmpty).map((l) => l.split('|').map((c) => c.trim()).join('\t')).join('\n');
    }
    return out
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.split('\t'))
        .toList();
  }

  Future<String> scalar(String sql) async => (await query(sql)).first.first.trim();
}

final sqliteDb = '$repo/build/matrix/data/sqlite_run.db';

Future<void> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) throw StateError('$exe ${args.join(' ')}: ${r.stderr}');
}

final targets = <String, Target>{
  'sqlite': Target(
    id: 'sqlite',
    connection: () => {
      'id': 'sqlite',
      'name': 'Matrix SQLite',
      'mode': 'driver',
      'driver': 'SQLite3',
      'database': sqliteDb,
    },
    cli: (sql) => ['/usr/bin/sqlite3', '-separator', '\t', sqliteDb, sql],
    form: [('Driver', 'SQLite3', 0), ('File', sqliteDb, 0)],
    connectionString: 'Driver=SQLite3;Database=$sqliteDb',
    bootstrap: ('PRAGMA cache_size = 1234', 'PRAGMA cache_size', '1234'),
    scriptWithBlocks: '''CREATE TABLE blk (x INTEGER, y INTEGER);
CREATE TRIGGER trg_blk AFTER INSERT ON blk
BEGIN
  UPDATE blk SET y = NEW.x * 2 WHERE x = NEW.x;
  INSERT INTO audit (tabella, azione) VALUES ('blk', 'insert');
END;
INSERT INTO blk (x) VALUES (21);
''',
    scriptCheck: 'SELECT COUNT(*) FROM blk WHERE y = 42',
    prepare: () async {
      final f = File(sqliteDb);
      if (f.existsSync()) f.deleteSync();
      File('$repo/build/matrix/data/sqlite.db').copySync(sqliteDb);
    },
  ),
  'pg': Target(
    id: 'pg',
    connection: () => {
      'id': 'pg',
      'name': 'Matrix PostgreSQL',
      'mode': 'driver',
      'driver': 'PostgreSQL Unicode',
      'host': '127.0.0.1',
      'port': '55432',
      'database': 'dbcraft',
      'user': 'dbcraft',
      'password': _pwd,
    },
    navPath: ['dbcraft', 'public'],
    encodingProbe: "SELECT 'città', encode(convert_to('città', 'UTF8'), 'hex'), length('città')",
    form: [('Driver', 'PostgreSQL Unicode', 0), ('Host', '127.0.0.1', 0), ('Host', '55432', 1), ('Database', 'dbcraft', 0), ('Utente', 'dbcraft', 0), ('Password', _pwd, 0)],
    connectionString: 'Driver={PostgreSQL Unicode};Server=127.0.0.1;Port=55432;Database=dbcraft;Uid=dbcraft;Pwd=$_pwd',
    bootstrap: ("SET application_name = 'dbcraft_boot'", 'SHOW application_name', 'dbcraft_boot'),
    scriptWithBlocks: r'''CREATE FUNCTION f_blk(a integer) RETURNS integer AS $$
BEGIN
  IF a > 0 THEN
    RETURN a * 2;
  END IF;
  RETURN 0;
END;
$$ LANGUAGE plpgsql;
DO $body$ BEGIN PERFORM f_blk(1); END $body$;
''',
    scriptCheck: 'SELECT CASE WHEN f_blk(21) = 42 THEN 1 ELSE 0 END',
    serverDown: (stop: ['docker', 'stop', 'dbcraft-matrix-pg-1'], start: ['docker', 'start', 'dbcraft-matrix-pg-1']),
    cli: (sql) => ['docker', 'exec', 'dbcraft-matrix-pg-1', 'psql', '-U', 'dbcraft', '-d', 'dbcraft', '-At', '-F', '\t', '-c', sql],
    sleepSql: 'SELECT pg_sleep(30)',
    printSql: "DO \$\$ BEGIN RAISE NOTICE 'ciao dal server'; END \$\$",
    prepare: () => _run('bash', ['$repo/tool/test_matrix/seed/load.sh', 'pg']),
  ),
  'mssql': Target(
    id: 'mssql',
    connection: () => {
      'id': 'mssql',
      'name': 'Matrix SQL Server',
      'mode': 'driver',
      'driver': 'ODBC Driver 18 for SQL Server',
      'host': '127.0.0.1',
      'port': '51433',
      'database': 'dbcraft',
      'user': 'sa',
      'password': _pwd,
      'extraParams': {'TrustServerCertificate': 'yes'},
    },
    navPath: ['dbcraft', 'dbo'],
    encodingProbe: "SELECT N'città', CONVERT(VARCHAR(40), CAST(N'città' AS VARBINARY(40)), 2), LEN(N'città')",
    form: [('Driver', 'ODBC Driver 18 for SQL Server', 0), ('Host', '127.0.0.1', 0), ('Host', '51433', 1), ('Database', 'dbcraft', 0), ('Utente', 'sa', 0), ('Password', _pwd, 0)],
    connectionString: 'Driver={ODBC Driver 18 for SQL Server};Server=127.0.0.1,51433;Database=dbcraft;Uid=sa;Pwd=$_pwd;TrustServerCertificate=yes',
    bootstrap: ('SET LANGUAGE Italiano', 'SELECT @@LANGUAGE', 'Italiano'),
    quote: ('[', ']'),
    scriptWithBlocks: '''CREATE PROCEDURE p_blk @a INT AS
BEGIN
  SET NOCOUNT ON;
  IF @a > 0
  BEGIN
    SELECT @a * 2 AS doppio;
  END;
  SELECT 1 AS fine;
END
GO
EXEC p_blk 21;
''',
    scriptCheck: "SELECT COUNT(*) FROM sys.procedures WHERE name = 'p_blk'",
    serverDown: (stop: ['docker', 'stop', 'dbcraft-design-mssql-1'], start: ['docker', 'start', 'dbcraft-design-mssql-1']),
    cli: (sql) => [
      'docker', 'exec', 'dbcraft-design-mssql-1', '/opt/mssql-tools18/bin/sqlcmd', '-C', '-S', 'localhost', //
      '-U', 'sa', '-P', _pwd, '-d', 'dbcraft', '-h', '-1', '-W', '-s', '\t', '-Q', 'SET NOCOUNT ON; $sql',
    ],
    sleepSql: "WAITFOR DELAY '00:00:30'",
    printSql: "PRINT 'ciao dal server'",
    multiResultSql: 'SELECT 1 AS a; SELECT 2 AS b',
    prepare: () => _run('bash', ['$repo/tool/test_matrix/seed/load.sh', 'mssql']),
  ),
  'mysql': Target(
    id: 'mysql',
    connection: () => {
      'id': 'mysql',
      'name': 'Matrix MySQL',
      'mode': 'driver',
      'driver': 'MariaDB ODBC Driver',
      'host': '127.0.0.1',
      'port': '53306',
      'database': 'dbcraft',
      'user': 'root',
      'password': _pwd,
    },
    navPath: ['dbcraft'],
    encodingProbe: "SELECT 'città', HEX('città'), CHAR_LENGTH('città')",
    form: [('Driver', 'MariaDB ODBC Driver', 0), ('Host', '127.0.0.1', 0), ('Host', '53306', 1), ('Database', 'dbcraft', 0), ('Utente', 'root', 0), ('Password', _pwd, 0)],
    connectionString: 'Driver={MariaDB ODBC Driver};Server=127.0.0.1;Port=53306;Database=dbcraft;Uid=root;Pwd=$_pwd',
    bootstrap: ("SET @boot = 'ok'", 'SELECT @boot', 'ok'),
    quote: ('`', '`'),
    scriptWithBlocks: r'''CREATE PROCEDURE p_blk(IN a INT)
BEGIN
  IF a > 0 THEN
    SELECT a * 2 AS doppio;
  END IF;
  SELECT 1 AS fine;
END;
CALL p_blk(21);
''',
    scriptDelimiter: r'''DELIMITER $$
CREATE PROCEDURE p_dlm(IN a INT)
BEGIN
  SELECT a;
END $$
DELIMITER ;
CALL p_dlm(1);
''',
    scriptCheck: "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE() AND routine_name = 'p_blk'",
    serverDown: (stop: ['docker', 'stop', 'dbcraft-design-mysql-1'], start: ['docker', 'start', 'dbcraft-design-mysql-1']),
    cli: (sql) => ['docker', 'exec', 'dbcraft-design-mysql-1', 'mysql', '--default-character-set=utf8mb4', '-uroot', '-p$_pwd', 'dbcraft', '-N', '-B', '-e', sql],
    sleepSql: 'SELECT SLEEP(30)',
    multiResultSql: 'CALL due_risultati()',
    prepare: () => _run('bash', ['$repo/tool/test_matrix/seed/load.sh', 'mysql']),
  ),
  'mariadb': Target(
    id: 'mariadb',
    connection: () => {
      'id': 'mariadb',
      'name': 'Matrix MariaDB',
      'mode': 'driver',
      'driver': 'MariaDB ODBC Driver',
      'host': '127.0.0.1',
      'port': '53307',
      'database': 'dbcraft',
      'user': 'root',
      'password': _pwd,
    },
    navPath: ['dbcraft'],
    encodingProbe: "SELECT 'città', HEX('città'), CHAR_LENGTH('città')",
    form: [('Driver', 'MariaDB ODBC Driver', 0), ('Host', '127.0.0.1', 0), ('Host', '53307', 1), ('Database', 'dbcraft', 0), ('Utente', 'root', 0), ('Password', _pwd, 0)],
    connectionString: 'Driver={MariaDB ODBC Driver};Server=127.0.0.1;Port=53307;Database=dbcraft;Uid=root;Pwd=$_pwd',
    bootstrap: ("SET @boot = 'ok'", 'SELECT @boot', 'ok'),
    quote: ('`', '`'),
    scriptWithBlocks: r'''CREATE PROCEDURE p_blk(IN a INT)
BEGIN
  IF a > 0 THEN
    SELECT a * 2 AS doppio;
  END IF;
  SELECT 1 AS fine;
END;
CALL p_blk(21);
''',
    scriptDelimiter: r'''DELIMITER $$
CREATE PROCEDURE p_dlm(IN a INT)
BEGIN
  SELECT a;
END $$
DELIMITER ;
CALL p_dlm(1);
''',
    scriptCheck: "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE() AND routine_name = 'p_blk'",
    serverDown: (stop: ['docker', 'stop', 'dbcraft-design-mariadb-1'], start: ['docker', 'start', 'dbcraft-design-mariadb-1']),
    cli: (sql) => ['docker', 'exec', 'dbcraft-design-mariadb-1', 'mariadb', '--default-character-set=utf8mb4', '-uroot', '-p$_pwd', 'dbcraft', '-N', '-B', '-e', sql],
    sleepSql: 'SELECT SLEEP(30)',
    multiResultSql: 'CALL due_risultati()',
    prepare: () => _run('bash', ['$repo/tool/test_matrix/seed/load.sh', 'mariadb']),
  ),
  'mongo': Target(
    id: 'mongo',
    connection: () => {
      'id': 'mongo',
      'name': 'Matrix MongoDB',
      'mode': 'native',
      'nativeDriver': 'mongodb',
      'host': '127.0.0.1',
      'port': '57017',
      'database': 'negozio',
      'user': 'dbcraft',
      'password': _pwd,
      'extraParams': {'authSource': 'admin'},
    },
    // L3: a JavaScript expression printed by mongosh.
    cli: (js) => ['docker', 'exec', 'dbcraft-design-mongo-1', 'mongosh', '-u', 'dbcraft', '-p', _pwd, '--authenticationDatabase', 'admin', '--quiet', 'negozio', '--eval', js],
    navPath: ['negozio'],
    prepare: () => _run('bash', ['-c', 'docker exec -i dbcraft-design-mongo-1 mongosh -u dbcraft -p $_pwd --quiet < $repo/tool/test_matrix/seed/mongo.js']),
  ),
  'redis': Target(
    id: 'redis',
    connection: () => {
      'id': 'redis',
      'name': 'Matrix Redis',
      'mode': 'native',
      'nativeDriver': 'redis',
      'host': '127.0.0.1',
      'port': '56379',
      'password': _pwd,
    },
    cli: (cmd) => ['docker', 'exec', 'dbcraft-design-redis-1', 'sh', '-c', 'redis-cli -a $_pwd --no-auth-warning $cmd'],
    prepare: () => _run('bash', ['$repo/tool/test_matrix/seed/redis.sh']),
  ),
  'cassandra': Target(
    id: 'cassandra',
    connection: () => {
      'id': 'cassandra',
      'name': 'Matrix Cassandra',
      'mode': 'native',
      'nativeDriver': 'cassandra',
      'host': '127.0.0.1',
      'port': '59042',
      'database': 'negozio',
      'user': 'cassandra',
      'password': 'cassandra',
    },
    cli: (cql) => ['docker', 'exec', 'dbcraft-design-cassandra-1', 'cqlsh', '-u', 'cassandra', '-p', 'cassandra', '-e', cql],
    navPath: ['negozio'],
    prepare: () => _run('bash', ['$repo/tool/test_matrix/seed/cassandra.sh']),
  ),
};

Target get current {
  final t = targets[target];
  if (t == null) throw StateError('Unknown TARGET "$target": ${targets.keys.join(', ')}');
  return t;
}
