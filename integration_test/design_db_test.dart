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
import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/ddl/code_ddl.dart';
import 'package:dbcraft/features/design/ddl/object_ddl.dart';
import 'package:dbcraft/features/design/ddl/security/security_ddl.dart';
import 'package:dbcraft/features/design/ddl_script.dart';
import 'package:dbcraft/features/design/model/object_defs.dart';
import 'package:dbcraft/features/design/model/security_defs.dart';
import 'package:dbcraft/features/design/security_design.dart';
import 'package:dbcraft/features/schema/ddl_builder.dart';
import 'package:dbcraft/features/schema/schema_diff.dart';
import 'package:dbcraft/features/schema/schema_migration.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:dbcraft/features/schema/schema_snapshot.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/navigator/nav_nodes.dart';
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

/// Runs a script with secrets as the script sheet does: passwords resolved
/// only for the server, outside the history.
Future<void> runScript(DbConnection dc, DdlScript script) async {
  if (script.catalog != null) await dc.main!.setCurrentCatalog(script.catalog!);
  for (final s in script.executable) {
    final r = await dc.unrecordedMain!.execute(script.resolve(s));
    if (r.cursorId != null) await dc.unrecordedMain!.closeCursor(r.cursorId!);
  }
  dc.schemaChanged(script.scope);
}

/// [expected] as read back from the database (ODBC metadata plus the DBMS
/// catalog).
Future<TableDef> readBack(DbConnection dc, TableDef expected) async {
  final t = await dc.metadata!.findTable(expected.catalog, expected.schema, expected.name);
  expect(t, isNotNull, reason: 'Tabella ${expected.name} non trovata');
  return DesignCatalog.of(dc)!.loadTable(t!);
}

SchemaDiff compare(DbConnection dc, TableDef wanted, TableDef actual) {
  final family = dc.dialect.family;
  return SchemaDiff.compare(
    SchemaSnapshot(tables: [wanted.copyWith(catalog: null, schema: null)], family: family),
    SchemaSnapshot(tables: [actual.copyWith(catalog: null, schema: null)], family: family),
  );
}

/// Changes still needed to turn [actual] into [expected] (empty = faithful).
List<String> differences(DbConnection dc, TableDef expected, TableDef actual) => [
  for (final c in compare(dc, expected, actual).changes) c.label,
];

/// Runs the migration from what is in the database to [wanted].
Future<void> migrateTo(DbConnection dc, TableDef wanted) async {
  final actual = await readBack(dc, wanted);
  final diff = compare(dc, wanted, actual.copyWith(catalog: wanted.catalog, schema: wanted.schema));
  await run(
    dc,
    SchemaMigration(dc.dialect).generate(diff, options: const MigrationOptions(relocate: false, dropExtra: true)),
  );
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

      test('database round trip', () async {
        final caps = DesignCapabilities.of(dc.dialect);
        if (!caps.has(DesignFeature.createDatabase) || dc.dialect.family == DbFamily.sqlite) return;
        final ddl = ObjectDdl(dc.dialect);
        final db = DatabaseDef(
          name: 'dbc_rt_db_$suffix',
          recoveryModel: dc.dialect.family == DbFamily.sqlServer ? 'SIMPLE' : null,
        );
        final cat = DesignCatalog.of(dc)!;
        await run(dc, ddl.createDatabase(db));
        try {
          final read = await cat.database(db.name);
          expect(read, isNotNull);
          if (db.recoveryModel != null) expect(read!.recoveryModel, 'SIMPLE');
          final changed = read!.copyWith(recoveryModel: db.recoveryModel == null ? null : 'FULL');
          await run(dc, ddl.alterDatabase(read, changed));
          if (db.recoveryModel != null) expect((await cat.database(db.name))!.recoveryModel, 'FULL');
        } finally {
          await run(dc, ddl.dropDatabase(db.name, force: true));
        }
        expect(await cat.database(db.name), isNull);
      });

      test('schema round trip', () async {
        final caps = DesignCapabilities.of(dc.dialect);
        if (!caps.has(DesignFeature.schemas)) return;
        final ddl = ObjectDdl(dc.dialect);
        final catalog = dc.mainCatalog;
        final s = SchemaDef(name: 'dbc_rt_sch_$suffix', catalog: catalog);
        final cat = DesignCatalog.of(dc)!;
        await run(dc, ddl.createSchema(s));
        try {
          expect(await cat.schemaDef(catalog, s.name), isNotNull);
          // The navigator lists it even when empty.
          expect(await listSchemas(dc, catalog), contains(s.name));
        } finally {
          await run(dc, ddl.dropSchema(s));
        }
        expect(await cat.schemaDef(catalog, s.name), isNull);
      });

      test('view round trip', () async {
        final b = DdlBuilder(dc.dialect);
        final ddl = ObjectDdl(dc.dialect);
        final base = TableDef(
          name: 'dbc_rv_$suffix',
          columns: const [
            ColumnDef(name: 'id', type: 'integer', nullable: false),
            ColumnDef(name: 'qty', type: 'integer'),
          ],
          primaryKey: PrimaryKeyDef(name: 'pk_dbc_rv_$suffix', columns: const ['id']),
        );
        final t = dc.dialect.quoteIdent(base.name);
        final view = ViewDef(name: 'dbc_rvv_$suffix', definition: 'SELECT id FROM $t');
        await run(dc, b.createTable(base));
        try {
          await run(dc, ddl.createView(view));
          final found = await dc.metadata!.findTable(null, null, view.name);
          expect(found, isNotNull);
          expect(found!.isView, isTrue);
          final read = (await DesignCatalog.of(dc)!.viewDef(found))!;
          expect(read.definition.toLowerCase(), contains(base.name));
          expect(read.definition.toLowerCase(), isNot(contains('create')));
          // Change the query (OR REPLACE / OR ALTER, or drop and create).
          final changed = read.copyWith(originalName: read.name, definition: 'SELECT id, qty FROM $t');
          await run(dc, ddl.alterView(read, changed));
          final again = (await DesignCatalog.of(dc)!.viewDef(found))!;
          expect(again.definition.toLowerCase(), contains('qty'));
          await run(dc, ddl.dropView(again));
          expect(await dc.metadata!.findTable(null, null, view.name), isNull);
        } finally {
          await run(dc, b.dropTable(base));
        }
      });

      test('sequence round trip', () async {
        if (!DesignCapabilities.of(dc.dialect).has(DesignFeature.sequences)) return;
        final ddl = ObjectDdl(dc.dialect);
        final cat = DesignCatalog.of(dc)!;
        final schema = dc.dialect.family == DbFamily.sqlServer ? 'dbo' : null;
        final s = SequenceDef(schema: schema, name: 'dbc_rs_$suffix', start: 10, increment: 5, maxValue: 1000);
        await run(dc, ddl.createSequence(s));
        try {
          final read = (await cat.sequences(dc.mainCatalog, schema)).firstWhere((x) => x.name == s.name);
          expect(read.start, 10);
          expect(read.increment, 5);
          expect(read.maxValue, 1000);
          await run(dc, ddl.alterSequence(read, read.copyWith(increment: 7)));
          await run(dc, ddl.restartSequence(read, 500));
          final again = (await cat.sequences(dc.mainCatalog, schema)).firstWhere((x) => x.name == s.name);
          expect(again.increment, 7);
        } finally {
          await run(dc, ddl.dropSequence(s));
        }
        expect((await cat.sequences(dc.mainCatalog, schema)).where((x) => x.name == s.name), isEmpty);
      });

      test('trigger and procedure round trip', () async {
        final caps = DesignCapabilities.of(dc.dialect);
        if (!caps.has(DesignFeature.triggers)) return;
        final b = DdlBuilder(dc.dialect);
        final code = CodeDdl(dc.dialect);
        final schema = dc.dialect.family == DbFamily.sqlServer ? 'dbo' : null;
        final base = TableDef(
          schema: schema,
          name: 'dbc_rtg_$suffix',
          columns: const [
            ColumnDef(name: 'id', type: 'integer', nullable: false),
            ColumnDef(name: 'qty', type: 'integer'),
          ],
          primaryKey: PrimaryKeyDef(name: 'pk_dbc_rtg_$suffix', columns: const ['id']),
        );
        await run(dc, b.createTable(base));
        try {
          final table = (await dc.metadata!.findTable(null, schema, base.name))!;
          final header = TriggerDef(
            schema: table.schema,
            table: table.name,
            name: 'dbc_trg_$suffix',
            timing: dc.dialect.family == DbFamily.sqlServer ? TriggerTiming.after : TriggerTiming.before,
          );
          await run(dc, code.saveTrigger(null, header.name, code.triggerTemplate(header)));
          var triggers = await DesignCatalog.of(dc)!.triggers(table);
          final t = triggers.singleWhere((x) => x.name == header.name);
          expect(t.events, {TriggerEvent.insert});
          // Saved again from its own source (replace, or drop and create).
          await run(dc, code.saveTrigger(t, t.name, t.source));
          if (code.canDisableTriggers) {
            await run(dc, code.setTriggerEnabled(t, false));
            triggers = await DesignCatalog.of(dc)!.triggers(table);
            expect(triggers.single.enabled, isFalse);
          }
          await run(dc, code.dropTrigger(t));
          expect(await DesignCatalog.of(dc)!.triggers(table), isEmpty);

          if (caps.has(DesignFeature.routines)) {
            final name = 'dbc_proc_$suffix';
            await run(
              dc,
              code.saveRoutine(code.routineTemplate(RoutineKind.procedure, null, schema, name), RoutineKind.procedure),
            );
            final p = (await dc.metadata!.procedures(dc.mainCatalog, schema)).firstWhere((x) => x.cleanName == name);
            final src = (await DesignCatalog.of(dc)!.routineSource(p))!;
            expect(src.source.toLowerCase(), contains(name));
            await run(
              dc,
              code.saveRoutine(src.source, src.kind, existing: (catalog: p.catalog, schema: p.schema, name: name)),
            );
            await run(dc, code.dropRoutine(src.kind, p.catalog, p.schema, name, arguments: src.arguments));
          }
        } finally {
          await run(dc, b.dropTable(base));
        }
      });

      test('constraints and indexes round trip', () async {
        final b = DdlBuilder(dc.dialect);
        final caps = DesignCapabilities.of(dc.dialect);
        final parent = TableDef(
          name: 'dbc_rp_$suffix',
          columns: const [ColumnDef(name: 'id', type: 'integer', nullable: false)],
          primaryKey: PrimaryKeyDef(name: 'pk_dbc_rp_$suffix', columns: const ['id']),
        );
        final child = TableDef(
          name: 'dbc_rc_$suffix',
          columns: const [
            ColumnDef(name: 'id', type: 'integer', nullable: false),
            ColumnDef(name: 'code', type: 'varchar', size: 20, nullable: false),
            ColumnDef(name: 'qty', type: 'integer'),
            ColumnDef(name: 'parent_id', type: 'integer'),
          ],
          primaryKey: PrimaryKeyDef(name: 'pk_dbc_rc_$suffix', columns: const ['id']),
          uniques: [
            UniqueDef(name: 'uq_dbc_rc_$suffix', columns: const ['code']),
          ],
          checks: [
            if (caps.has(DesignFeature.checkConstraints)) CheckDef(name: 'ck_dbc_rc_$suffix', expression: 'qty > 0'),
          ],
          foreignKeys: [
            ForeignKeyDef(
              name: 'fk_dbc_rc_$suffix',
              columns: const ['parent_id'],
              refTable: parent.name,
              refColumns: const ['id'],
              onDelete: FkRule.cascade,
            ),
          ],
          indexes: [
            if (caps.has(DesignFeature.indexes))
              IndexDef(
                name: 'ix_dbc_rc_$suffix',
                columns: const ['qty', 'parent_id'],
                descending: caps.has(DesignFeature.indexDescending) && dc.dialect.family != DbFamily.firebird
                    ? const {'qty'}
                    : const {},
              ),
          ],
        );
        await run(dc, [
          ...b.createTable(parent),
          ...b.createSchema([child]),
        ]);
        try {
          expect(differences(dc, child, await readBack(dc, child)), isEmpty);

          // Alter through the migration: another check, a second unique, no index.
          final changed = child.copyWith(
            checks: [
              if (caps.has(DesignFeature.checkConstraints)) CheckDef(name: 'ck_dbc_rc_$suffix', expression: 'qty >= 0'),
            ],
            uniques: [
              ...child.uniques,
              UniqueDef(name: 'uq_dbc_rc2_$suffix', columns: const ['code', 'qty']),
            ],
            indexes: const [],
          );
          await migrateTo(dc, changed);
          expect(differences(dc, changed, await readBack(dc, changed)), isEmpty);
        } finally {
          await run(dc, b.dropSchema([child, parent]));
        }
      });
      test('security round trip', () async {
        final d = dc.dialect;
        final ddl = SecurityDdl.forFamily(d);
        if (ddl.kinds.isEmpty || !ddl.canCreate(PrincipalKind.role)) return;
        final family = d.family;
        final catalog = family == DbFamily.sqlServer ? dc.mainCatalog : null;
        final b = DdlBuilder(d);
        final table = TableDef(
          name: 'dbc_sec_$suffix',
          columns: const [ColumnDef(name: 'id', type: 'integer', nullable: false)],
          primaryKey: PrimaryKeyDef(name: 'pk_dbc_sec_$suffix', columns: const ['id']),
        );
        await run(dc, b.createTable(table));
        final t = (await dc.metadata!.findTable(null, null, table.name))!;
        final on = GrantDef(
          privilege: '',
          target: GrantTarget.table,
          catalog: ddl.catalogInGrants ? t.catalog : null,
          schema: t.schema,
          object: t.name,
        );
        final cat = DesignCatalog.of(dc)!;
        final dropped = <PrincipalDef>[];
        String upper(String s) => family == DbFamily.oracle || family == DbFamily.firebird ? s.toUpperCase() : s;
        const password = 'DbCraft_Sec1!';
        try {
          if (ddl.kinds.contains(PrincipalKind.login)) {
            final login = PrincipalDesign.create(d, PrincipalKind.login, name: 'dbc_l_$suffix')..setPassword(password);
            await runScript(dc, login.script());
            dropped.add(login.working);
          }
          final role = PrincipalDesign.create(d, PrincipalKind.role, catalog: catalog, name: upper('dbc_r_$suffix'))
            ..setGrant(on, 'SELECT', true);
          await runScript(dc, role.script());
          dropped.insert(0, role.working);
          final user = PrincipalDesign.create(d, PrincipalKind.user, catalog: catalog, name: upper('dbc_u_$suffix'));
          if (family == DbFamily.sqlServer) {
            user.update(user.working.copyWith(login: 'dbc_l_$suffix'));
          } else {
            user.setPassword(password);
          }
          user
            ..setGrant(on, 'INSERT', true)
            ..setRole(role.working.name, true, roleHost: role.working.host);
          await runScript(dc, user.script());
          dropped.insert(0, user.working);

          final ps = await cat.principals(catalog: catalog);
          final u = ps.firstWhere((p) => p.key == user.working.key);
          final r = ps.firstWhere((p) => p.key == role.working.key);
          var access = await cat.access(u, catalog: catalog);
          expect([for (final m in access.memberOf) m.role.toLowerCase()], contains(r.name.toLowerCase()));
          expect(
            [
              for (final g in access.grants)
                if (g.objectKey == on.objectKey) g.privilege,
            ],
            ['INSERT'],
          );
          final roleAccess = await cat.access(r, catalog: catalog);
          expect(
            [
              for (final g in roleAccess.grants)
                if (g.objectKey == on.objectKey) g.privilege,
            ],
            ['SELECT'],
          );

          // Edit: INSERT → UPDATE with the grant option, out of the role.
          final edit = PrincipalDesign.existing(d, u, access, catalog: catalog)
            ..setGrant(on, 'INSERT', false)
            ..setGrant(on, 'UPDATE', true)
            ..setGrantOption(on, true)
            ..setRole(r.name, false, roleHost: r.host);
          await runScript(dc, edit.script());
          access = await cat.access(u, catalog: catalog);
          final now = [
            for (final g in access.grants)
              if (g.objectKey == on.objectKey) g,
          ];
          expect([for (final g in now) g.privilege], ['UPDATE']);
          expect(now.single.withGrantOption, isTrue);
          expect(access.memberOf.where((m) => m.role.toLowerCase() == r.name.toLowerCase()), isEmpty);
          expect(
            (await cat.objectGrants(t)).map((g) => g.grantee.name.toLowerCase()),
            containsAll([u.name.toLowerCase(), r.name.toLowerCase()]),
          );
        } finally {
          for (final p in dropped) {
            try {
              await runScript(
                dc,
                DdlScript(ddl.dropPrincipal(p), catalog: p.kind == PrincipalKind.login ? null : catalog),
              );
            } catch (_) {}
          }
          await run(dc, b.dropTable(table));
        }
        final left = await cat.principals(catalog: catalog);
        expect(left.where((p) => p.name.toLowerCase().contains('dbc_') && p.name.endsWith('$suffix')), isEmpty);
      });
    });
  }
}
