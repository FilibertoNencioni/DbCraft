// Round-trip tests of the design tools against real database servers:
// every object is created with the generated DDL, read back from the
// catalog and compared with the definition it came from (the diff must be
// empty), then altered and dropped. It proves at once that the DDL is right
// and that reading the catalog is faithful.
//
//   tool/design_db/up.sh
//   flutter test integration_test/design_db_test.dart -d macos \
//     --dart-define=DESIGN_TARGETS=sqlite,pg,mssql,mysql,mariadb,oracle,firebird
//
// SQLite needs no server (a temporary file through the SQLite ODBC driver).
// The other targets connect with the ODBC connection strings below, which
// match tool/design_db/compose.yml and the driver names registered by
// Database ▸ Driver ODBC installati…; override one with
// --dart-define=DESIGN_<TARGET>='Driver=…;…' (e.g. DESIGN_ORACLE). Snowflake
// runs only with DESIGN_SNOWFLAKE. See docs/design-testing.md.
import 'dart:io';

import 'package:dbcraft/features/design/capabilities.dart';
import 'package:dbcraft/features/schema/ddl_builder.dart';
import 'package:dbcraft/features/schema/schema_diff.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:dbcraft/features/schema/schema_snapshot.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const targetList = String.fromEnvironment('DESIGN_TARGETS', defaultValue: 'sqlite');
const sqliteOdbc = String.fromEnvironment('SQLITE_ODBC', defaultValue: '/opt/homebrew/lib/libsqlite3odbc.dylib');

class DesignTarget {
  const DesignTarget(this.key, this.family, this.connectionString, {this.mariaDb = false});
  final String key;
  final DbFamily family;
  final String connectionString;
  final bool mariaDb;
}

/// Connection strings: the --dart-define value, or the compose default.
const _targets = <DesignTarget>[
  DesignTarget(
    'pg',
    DbFamily.postgres,
    String.fromEnvironment(
      'DESIGN_PG',
      defaultValue:
          'Driver={PostgreSQL Unicode};Server=127.0.0.1;Port=55432;Database=dbcraft;Uid=dbcraft;Pwd=DbCraft_Test1',
    ),
  ),
  DesignTarget(
    'mssql',
    DbFamily.sqlServer,
    String.fromEnvironment(
      'DESIGN_MSSQL',
      defaultValue:
          'Driver={ODBC Driver 18 for SQL Server};Server=127.0.0.1,51433;Database=dbcraft;Uid=sa;Pwd=DbCraft_Test1;'
          'TrustServerCertificate=yes',
    ),
  ),
  DesignTarget(
    'mysql',
    DbFamily.mysql,
    String.fromEnvironment(
      'DESIGN_MYSQL',
      defaultValue:
          'Driver={MariaDB ODBC Driver};Server=127.0.0.1;Port=53306;Database=dbcraft;Uid=dbcraft;Pwd=DbCraft_Test1',
    ),
  ),
  DesignTarget(
    'mariadb',
    DbFamily.mysql,
    String.fromEnvironment(
      'DESIGN_MARIADB',
      defaultValue:
          'Driver={MariaDB ODBC Driver};Server=127.0.0.1;Port=53307;Database=dbcraft;Uid=dbcraft;Pwd=DbCraft_Test1',
    ),
    mariaDb: true,
  ),
  DesignTarget(
    'oracle',
    DbFamily.oracle,
    String.fromEnvironment(
      'DESIGN_ORACLE',
      defaultValue: 'Driver={Oracle 23 ODBC driver};Dbq=//127.0.0.1:51521/FREEPDB1;Uid=dbcraft;Pwd=DbCraft_Test1',
    ),
  ),
  DesignTarget(
    'firebird',
    DbFamily.firebird,
    String.fromEnvironment(
      'DESIGN_FIREBIRD',
      defaultValue:
          'Driver={Firebird/InterBase(r) driver};Dbname=127.0.0.1/53050:/var/lib/firebird/data/dbcraft.fdb;'
          'Uid=dbcraft;Pwd=DbCraft_Test1;Charset=UTF8',
    ),
  ),
  DesignTarget(
    'db2',
    DbFamily.db2,
    String.fromEnvironment(
      'DESIGN_DB2',
      defaultValue:
          'Driver={IBM DB2 ODBC DRIVER};Database=dbcraft;Hostname=127.0.0.1;Port=55000;Protocol=TCPIP;'
          'Uid=db2inst1;Pwd=DbCraft_Test1',
    ),
  ),
  DesignTarget('snowflake', DbFamily.snowflake, String.fromEnvironment('DESIGN_SNOWFLAKE')),
];

Future<DbConnection> connect(DesignTarget t) async {
  var cs = t.connectionString;
  if (t.key == 'sqlite') {
    final dir = await Directory.systemTemp.createTemp('dbcraft_design');
    cs = 'Driver=$sqliteOdbc;Database=${dir.path}/design.db';
  }
  final dc = DbConnection(
    ConnectionConfig(id: t.key, name: t.key, mode: ConnectionMode.connectionString, connectionString: cs),
  );
  await dc.connect();
  return dc;
}

/// Runs [statements] (DdlBuilder conventions) on the main session.
Future<void> run(DbConnection dc, List<String> statements) async {
  for (final s in executableStatements(statements)) {
    final r = await dc.main!.execute(s);
    if (r.cursorId != null) await dc.main!.closeCursor(r.cursorId!);
  }
  dc.schemaChanged();
}

/// [expected] as read back from the database.
Future<TableDef> readBack(DbConnection dc, TableDef expected) async {
  final t = await dc.metadata!.findTable(expected.catalog, expected.schema, expected.name);
  expect(t, isNotNull, reason: 'Tabella ${expected.name} non trovata');
  return TableDef.fromDetails(await dc.metadata!.tableDetails(t!));
}

/// Changes still needed to turn [actual] into [expected] (empty = faithful).
List<String> differences(DbConnection dc, TableDef expected, TableDef actual) {
  final family = dc.dialect.family;
  final diff = SchemaDiff.compare(
    SchemaSnapshot(tables: [expected.copyWith(catalog: null, schema: null)], family: family),
    SchemaSnapshot(tables: [actual.copyWith(catalog: null, schema: null)], family: family),
  );
  return [for (final c in diff.changes) c.label];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final wanted = targetList.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
  final targets = [
    if (wanted.contains('sqlite')) const DesignTarget('sqlite', DbFamily.sqlite, ''),
    for (final t in _targets)
      if (wanted.contains(t.key) && t.connectionString.isNotEmpty) t,
  ];

  for (final target in targets) {
    group(target.key, () {
      late DbConnection dc;
      final suffix = DateTime.now().millisecondsSinceEpoch % 100000;

      setUpAll(() async => dc = await connect(target));
      tearDownAll(() async => dc.disconnect());

      test('the DBMS and its version are recognized', () {
        final d = dc.dialect;
        expect(d.family, target.family);
        expect(d.isMariaDb, target.mariaDb);
        expect(d.version, isNotNull, reason: 'SQL_DBMS_VER: ${d.dbmsVersion}');
        expect(DesignCapabilities.of(d).has(DesignFeature.createTable), isTrue);
      });

      test('table round trip', () async {
        final b = DdlBuilder(dc.dialect);
        final table = TableDef(
          name: 'dbc_rt_$suffix',
          columns: const [
            ColumnDef(name: 'id', type: 'integer', nullable: false),
            ColumnDef(name: 'name', type: 'varchar', size: 50, nullable: false),
            ColumnDef(name: 'note', type: 'varchar', size: 200),
          ],
          primaryKey: PrimaryKeyDef(name: 'pk_dbc_rt_$suffix', columns: const ['id']),
        );
        await run(dc, b.createTable(table));
        try {
          expect(differences(dc, table, await readBack(dc, table)), isEmpty);
        } finally {
          await run(dc, b.dropTable(table));
        }
        expect(await dc.metadata!.findTable(null, null, table.name), isNull);
      });
    });
  }
}
