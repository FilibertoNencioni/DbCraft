// Phase 0 of the design tools: server versions, capabilities, DDL scripts
// with secrets, schema change notifications, catalog queries.

import 'package:dbcraft/features/design/capabilities.dart';
import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/ddl_script.dart';
import 'package:dbcraft/features/schema/ddl_builder.dart';
import 'package:dbcraft/features/schema/ddl_execution.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/services/server_version.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/navigator/nav_nodes.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

OdbcException odbcError(String message, {String state = '42000'}) =>
    OdbcException('SQLExecDirect', [OdbcDiag(state, 0, message)]);

void main() {
  group('ServerVersion', () {
    test('parses the driver version strings', () {
      expect(ServerVersion.tryParse('16.00.4135'), const ServerVersion(16, 0, 4135));
      expect(ServerVersion.tryParse('16.4'), const ServerVersion(16, 4));
      expect(ServerVersion.tryParse('10.11.6-MariaDB-1:10.11.6+maria~ubu2204'), const ServerVersion(10, 11, 6));
      expect(ServerVersion.tryParse('19.00.0000'), const ServerVersion(19));
      expect(ServerVersion.tryParse('WI-V5.0.0.1306 Firebird 5.0'), const ServerVersion(5));
      expect(ServerVersion.tryParse('GoogleSQL'), isNull);
      expect(ServerVersion.tryParse(null), isNull);
    });

    test('compares', () {
      const v = ServerVersion(13, 0, 4001);
      expect(v.atLeast(13), isTrue);
      expect(v.atLeast(13, 0, 4001), isTrue);
      expect(v.atLeast(13, 0, 4002), isFalse);
      expect(v.atLeast(14), isFalse);
      expect(const ServerVersion(8, 0, 16).compareTo(const ServerVersion(8, 1)), lessThan(0));
    });

    test('dialects carry the version and tell MariaDB apart', () {
      final d = SqlDialect.fromInfo({'dbmsName': 'MySQL', 'dbmsVersion': '10.6.12-MariaDB', 'identifierQuote': '`'});
      expect(d.family, DbFamily.mysql);
      expect(d.isMariaDb, isTrue);
      expect(d.version, const ServerVersion(10, 6, 12));
      expect(sqlDialects['mysql']!.isMariaDb, isFalse);
      expect(sqlDialects['mariadb']!.isMariaDb, isTrue);
      expect(SqlDialect(dbmsName: 'PostgreSQL').version, isNull);
    });
  });

  group('DesignCapabilities', () {
    bool has(String key, DesignFeature f) => DesignCapabilities.of(sqlDialects[key]!).has(f);

    test('every SQL DBMS can design tables; missing features have a reason', () {
      for (final e in sqlDialects.entries) {
        final caps = DesignCapabilities.of(e.value);
        expect(caps.has(DesignFeature.createTable), isTrue, reason: e.key);
        expect(caps.has(DesignFeature.views), isTrue, reason: e.key);
        for (final f in DesignFeature.values) {
          if (!caps.has(f)) expect(caps.reason(f), isNotEmpty, reason: '${e.key} ${f.name}');
          if (caps.has(f)) expect(caps.reason(f), isNull);
        }
      }
    });

    test('matrix', () {
      expectPerFamily((d) => DesignCapabilities.of(d).has(DesignFeature.createDatabase), {
        'pg': true,
        'mssql': true,
        'mysql': true,
        'mariadb': true,
        'oracle': false,
        'db2': false,
        'sqlite': true,
        'firebird': false,
        'snowflake': true,
      });
      expectPerFamily((d) => DesignCapabilities.of(d).has(DesignFeature.schemas), {
        'pg': true,
        'mssql': true,
        'mysql': false,
        'mariadb': false,
        'oracle': false,
        'db2': true,
        'sqlite': false,
        'firebird': false,
        'snowflake': true,
      });
      expectPerFamily((d) => DesignCapabilities.of(d).has(DesignFeature.sequences), {
        'pg': true,
        'mssql': true,
        'mysql': false,
        'mariadb': true,
        'oracle': true,
        'db2': true,
        'sqlite': false,
        'firebird': true,
        'snowflake': true,
      });
      expectPerFamily((d) => DesignCapabilities.of(d).has(DesignFeature.users), {
        'pg': true,
        'mssql': true,
        'mysql': true,
        'mariadb': true,
        'oracle': true,
        'db2': false,
        'sqlite': false,
        'firebird': true,
        'snowflake': true,
      });
      expectPerFamily((d) => DesignCapabilities.of(d).has(DesignFeature.transactionalDdl), {
        'pg': true,
        'mssql': true,
        'mysql': false,
        'mariadb': false,
        'oracle': false,
        'db2': true,
        'sqlite': true,
        'firebird': true,
        'snowflake': false,
      });
      expectPerFamily((d) => DesignCapabilities.of(d).has(DesignFeature.fkOnUpdate), {
        'pg': true,
        'mssql': true,
        'mysql': true,
        'mariadb': true,
        'oracle': false,
        'db2': false,
        'sqlite': true,
        'firebird': true,
        'snowflake': true,
      });
      expectPerFamily((d) => DesignCapabilities.of(d).has(DesignFeature.addNotValidated), {
        'pg': true,
        'mssql': true,
        'mysql': false,
        'mariadb': false,
        'oracle': true,
        'db2': true,
        'sqlite': false,
        'firebird': false,
        'snowflake': false,
      });
      expect(has('snowflake', DesignFeature.enforcedConstraints), isFalse);
      expect(has('snowflake', DesignFeature.indexes), isFalse);
      expect(has('sqlite', DesignFeature.constraintsOnExistingTable), isFalse);
      expect(has('pg', DesignFeature.onlineIndex), isTrue);
      expect(has('pg', DesignFeature.disableConstraints), isFalse);
    });

    test('version thresholds', () {
      bool at(String key, String version, DesignFeature f) => DesignCapabilities.of(dialectAt(key, version)).has(f);
      expect(at('mysql', '8.0.15', DesignFeature.checkConstraints), isFalse);
      expect(at('mysql', '8.0.16', DesignFeature.checkConstraints), isTrue);
      expect(at('mysql', '5.7.44', DesignFeature.roles), isFalse);
      expect(at('mariadb', '10.2.0-MariaDB', DesignFeature.checkConstraints), isFalse);
      expect(at('mariadb', '10.3.39-MariaDB', DesignFeature.sequences), isTrue);
      expect(at('mariadb', '10.2.44-MariaDB', DesignFeature.sequences), isFalse);
      expect(at('mssql', '13.00.1601', DesignFeature.replaceView), isFalse);
      expect(at('mssql', '13.00.4001', DesignFeature.replaceView), isTrue);
      expect(at('mssql', '10.50.6000', DesignFeature.sequences), isFalse);
      expect(at('pg', '10.23', DesignFeature.indexInclude), isFalse);
      expect(at('firebird', 'WI-V2.5.9.27139 Firebird 2.5', DesignFeature.users), isFalse);
      expect(at('firebird', 'WI-V4.0.4.3010 Firebird 4.0', DesignFeature.indexFilter), isFalse);
      final reason = DesignCapabilities.of(dialectAt('mysql', '8.0.15')).reason(DesignFeature.checkConstraints);
      expect(reason, 'Richiede MySQL 8.0.16 o successivo');
      // Unknown version: a current server is assumed.
      expect(DesignCapabilities.of(SqlDialect(dbmsName: 'MySQL')).has(DesignFeature.checkConstraints), isTrue);
    });

    test('unknown and native DBMS', () {
      final generic = DesignCapabilities.of(SqlDialect(dbmsName: 'DuckDB'));
      expect(generic.has(DesignFeature.createTable), isTrue);
      expect(generic.has(DesignFeature.users), isFalse);
      expect(generic.reason(DesignFeature.users), contains('non riconosciuto'));
      // Native drivers: only their own tools (phase 9).
      final mongo = DesignCapabilities.of(SqlDialect(dbmsName: 'MongoDB'));
      expect(mongo.has(DesignFeature.createTable), isTrue);
      expect(mongo.has(DesignFeature.sequences), isFalse);
      expect(mongo.reason(DesignFeature.sequences), contains('MongoDB'));
    });
  });

  group('DdlScript', () {
    test('secrets are masked everywhere but on the server', () {
      final bag = SecretBag();
      final token = bag.add("'s3cret!'");
      final script = DdlScript([
        '-- Utente',
        'CREATE USER app PASSWORD $token',
        'GRANT SELECT ON t TO app',
      ], secrets: bag.values);
      expect(script.executable, hasLength(2));
      expect(script.hasSecret(script.executable.first), isTrue);
      expect(script.hasSecret(script.executable.last), isFalse);
      expect(DdlScript.masked(script.executable.first), "CREATE USER app PASSWORD '••••••'");
      expect(script.resolve(script.executable.first), "CREATE USER app PASSWORD 's3cret!'");
      final rendered = script.render(DdlBuilder(sqlDialects['pg']!));
      expect(rendered, contains("PASSWORD '••••••';"));
      expect(rendered, isNot(contains('s3cret')));
      expect(bag.add('"x"'), isNot(token));
    });

    test('result', () {
      expect(const DdlResult(total: 2, executed: 2).ok, isTrue);
      expect(const DdlResult(total: 2, executed: 1, failedIndex: 1, error: 'x').ok, isFalse);
      expect(const DdlResult.skipped().ok, isFalse);
    });
  });

  group('schema changes', () {
    test('scopes cover locations', () {
      expect(SchemaScope.connection.covers('db', 'app'), isTrue);
      expect(const SchemaScope.catalog('db').covers('DB', 'any'), isTrue);
      expect(const SchemaScope.catalog('db').covers('other', null), isFalse);
      const s = SchemaScope.schema('db', 'app');
      expect(s.covers('db', 'app'), isTrue);
      expect(s.covers(null, 'app'), isTrue);
      expect(s.covers('db', 'sales'), isFalse);
      const o = SchemaScope.object(null, 'app', 'orders');
      expect(o.coversObject('db', 'app', 'ORDERS'), isTrue);
      expect(o.coversObject('db', 'app', 'customers'), isFalse);
      expect(s.coversObject('db', 'app', 'customers'), isTrue);
    });

    test('the connection keeps the recent changes', () {
      final dc = scriptedConnection(ScriptedSession());
      final g = dc.schemaGeneration;
      var notified = 0;
      dc.addListener(() => notified++);
      dc.schemaChanged(const SchemaScope.schema(null, 'app'));
      dc.schemaChanged(const SchemaScope.object(null, 'app', 't'));
      expect(notified, 2);
      expect(dc.schemaChangesSince(g).map((s) => s.level), [SchemaLevel.schema, SchemaLevel.object]);
      expect(dc.schemaChangesSince(g + 1).single.object, 't');
      expect(dc.schemaChangesSince(dc.schemaGeneration), isEmpty);
      for (var i = 0; i < 40; i++) {
        dc.schemaChanged(const SchemaScope.schema(null, 'app'));
      }
      expect(dc.schemaChangesSince(g).single.level, SchemaLevel.connection);
    });

    test('navigator nodes to reload', () {
      final dc = scriptedConnection(ScriptedSession());
      final root = ConnectionNode(dc);
      final cat = CatalogNode(dc, 'db');
      final other = CatalogNode(dc, 'other');
      final app = SchemaNode(dc, 'db', 'app');
      final tables = ObjectFolderNode(dc, 'db', 'app', ObjectKind.tables)..children = [];
      final views = ObjectFolderNode(dc, 'db', 'app', ObjectKind.views); // never opened
      final sales = ObjectFolderNode(dc, 'db', 'sales', ObjectKind.tables)..children = [];
      root.children = [cat, other];
      cat.children = [
        app,
        SchemaNode(dc, 'db', 'sales')..children = [sales],
      ];
      app.children = [tables, views];
      other.children = [];

      expect(nodesForSchemaChanges(root, const []), isEmpty);
      expect(nodesForSchemaChanges(root, const [SchemaScope.connection]), [root]);
      expect(nodesForSchemaChanges(root, const [SchemaScope.catalog('db')]), [cat]);
      expect(nodesForSchemaChanges(root, const [SchemaScope.object('db', 'app', 'orders')]), [tables]);
      expect(nodesForSchemaChanges(root, const [SchemaScope.schema('db', null)]), [tables, sales]);
      // Without catalog nodes a catalog change reloads the connection.
      final flat = ConnectionNode(dc)..children = [SchemaNode(dc, null, 'app')];
      expect(nodesForSchemaChanges(flat, const [SchemaScope.catalog(null)]), [flat]);
    });
  });

  group('CatalogQueries', () {
    test('reads every page with lower-case keys', () async {
      final s = ScriptedSession(pageSize: 2)
        ..on(
          'pg_sequences',
          Rows(
            ['SEQUENCENAME', 'Start'],
            [
              for (var i = 0; i < 5; i++) ['s$i', i],
            ],
          ),
        );
      final rows = await CatalogQueries(s).rows('SELECT * FROM pg_sequences');
      expect(rows, hasLength(5));
      expect(rows.last, {'sequencename': 's4', 'start': 4});
    });

    test('tries the alternatives in order', () async {
      final s = ScriptedSession()
        ..on('dba_users', odbcError('[Oracle][ODBC]ORA-00942: table or view does not exist'))
        ..on(
          'all_users',
          Rows(
            ['USERNAME'],
            [
              ['SCOTT'],
            ],
          ),
        );
      final rows = await CatalogQueries(s).first(['SELECT * FROM dba_users', 'SELECT * FROM all_users']);
      expect(rows.single['username'], 'SCOTT');
      expect(s.executed, ['SELECT * FROM dba_users', 'SELECT * FROM all_users']);
    });

    test('missing privileges are reported as such', () async {
      final s = ScriptedSession()
        ..on('pg_authid', odbcError('ERROR: permission denied for table pg_authid', state: '42501'))
        ..on('broken', odbcError('syntax error'));
      expect(
        CatalogQueries(s).first(['SELECT * FROM pg_authid', 'SELECT broken']),
        throwsA(isA<CatalogPermissionException>()),
      );
      expect(CatalogQueries(s).first(['SELECT broken']), throwsA(isA<OdbcException>()));
      expect(isPermissionError(odbcError('Access denied for user x')), isTrue);
      expect(isPermissionError(odbcError('Unknown column')), isFalse);
    });

    test('design catalog results are cached until the next schema change', () async {
      final s = ScriptedSession()
        ..on(
          'sys.sequences',
          Rows(
            ['name'],
            [
              ['seq'],
            ],
          ),
        );
      final dc = scriptedConnection(s);
      final cat = DesignCatalog.of(dc)!;
      await cat.cachedRows('sequences', ['SELECT name FROM sys.sequences']);
      await cat.cachedRows('sequences', ['SELECT name FROM sys.sequences']);
      expect(s.executed, hasLength(1));
      dc.schemaChanged();
      await cat.cachedRows('sequences', ['SELECT name FROM sys.sequences']);
      expect(s.executed, hasLength(2));
      expect(DesignCatalog.of(DbConnection(ConnectionConfig(id: 'x', name: 'x'))), isNull);
    });
  });

  test('table script recreates the table from the ODBC metadata', () {
    final t = DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE', remarks: 'Ordini');
    DbColumn col(String n, bool nullable, int pos) =>
        DbColumn(name: n, dataType: 4, typeName: 'integer', size: 10, decimals: 0, nullable: nullable, position: pos);
    final details = TableDetails(
      table: t,
      columns: [col('id', false, 1), col('customer_id', true, 2)],
      primaryKey: DbPrimaryKey('pk_orders', ['id']),
      foreignKeys: [
        DbForeignKey(
          name: 'fk_orders_customers',
          pkCatalog: null,
          pkSchema: 'app',
          pkTable: 'customers',
          fkCatalog: null,
          fkSchema: 'app',
          fkTable: 'orders',
          columns: ['customer_id'],
          refColumns: ['id'],
          deleteRule: 0,
        ),
      ],
      referencedBy: [],
      indexes: [],
    );
    const plain =
        'CREATE TABLE app.orders (\n'
        '\tid integer NOT NULL,\n'
        '\tcustomer_id integer,\n'
        '\tCONSTRAINT pk_orders PRIMARY KEY (id),\n'
        '\tCONSTRAINT fk_orders_customers FOREIGN KEY (customer_id) REFERENCES app.customers (id) ON DELETE CASCADE\n'
        ')';
    const quoted =
        'CREATE TABLE "app"."orders" (\n'
        '\t"id" integer NOT NULL,\n'
        '\t"customer_id" integer,\n'
        '\tCONSTRAINT "pk_orders" PRIMARY KEY ("id"),\n'
        '\tCONSTRAINT "fk_orders_customers" FOREIGN KEY ("customer_id") REFERENCES "app"."customers" ("id") '
        'ON DELETE CASCADE\n'
        ')';
    const quotedComment = '$quoted;\n\nCOMMENT ON TABLE "app"."orders" IS \'Ordini\';';
    expectPerFamily((d) => DdlBuilder(d).tableScript(details), {
      'pg': "$plain;\n\nCOMMENT ON TABLE app.orders IS 'Ordini';",
      'mssql': allOf(startsWith('$plain;\n\n'), contains("EXEC sp_addextendedproperty @name = N'MS_Description'")),
      'mysql': "$plain COMMENT='Ordini';",
      'mariadb': "$plain COMMENT='Ordini';",
      'oracle': quotedComment,
      'db2': quotedComment,
      'sqlite': '$plain;',
      'firebird': quotedComment,
      'snowflake': quotedComment,
    });
    final view = TableDetails(
      table: DbTable(catalog: null, schema: 'app', name: 'v', type: 'VIEW'),
      columns: [col('id', false, 1)],
      primaryKey: null,
      foreignKeys: [],
      referencedBy: [],
      indexes: [],
    );
    expect(DdlBuilder(sqlDialects['pg']!).tableScript(view), contains('la definizione non è esposta'));
  });

  group('runDdlScript', () {
    Future<BuildContext> host(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return ctx;
    }

    /// Runs [script], confirming every alert with [confirm].
    Future<DdlResult> run(
      WidgetTester tester,
      DbConnection dc,
      DdlScript script, {
      List<String> confirm = const ['Esegui'],
    }) async {
      final ctx = await host(tester);
      final f = runDdlScript(ctx, dc, script);
      for (final label in confirm) {
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
      }
      await tester.pumpAndSettle();
      DdlResult? result;
      f.then((r) => result = r);
      await tester.pumpAndSettle();
      // Error alert, if any.
      if (find.text('OK').evaluate().isNotEmpty) {
        await tester.tap(find.text('OK').last);
        await tester.pumpAndSettle();
      }
      await tester.pump(const Duration(seconds: 5)); // toasts
      await tester.pumpAndSettle();
      return result!;
    }

    testWidgets('transactional script on PostgreSQL commits once', (tester) async {
      final s = ScriptedSession();
      final dc = scriptedConnection(s);
      final g = dc.schemaGeneration;
      final r = await run(
        tester,
        dc,
        const DdlScript(
          ['ALTER TABLE t ADD a int', 'ALTER TABLE t ADD b int'],
          transactional: true,
          scope: SchemaScope.object(null, 'app', 't'),
        ),
      );
      expect(r.ok, isTrue);
      expect(s.log, [
        'autocommit false',
        'exec: ALTER TABLE t ADD a int',
        'exec: ALTER TABLE t ADD b int',
        'commit',
        'autocommit true',
      ]);
      expect(dc.schemaChangesSince(g).single.object, 't');
    });

    testWidgets('a failure rolls the transaction back', (tester) async {
      final s = ScriptedSession()..on('ADD b', odbcError('column "b" already exists'));
      final dc = scriptedConnection(s);
      final r = await run(
        tester,
        dc,
        const DdlScript(['ALTER TABLE t ADD a int', 'ALTER TABLE t ADD b int'], transactional: true),
      );
      expect(r.ok, isFalse);
      expect(r.failedIndex, 1);
      expect(r.rolledBack, isTrue);
      expect(r.executed, 0);
      expect(s.log, [
        'autocommit false',
        'exec: ALTER TABLE t ADD a int',
        'exec: ALTER TABLE t ADD b int',
        'rollback',
        'autocommit true',
      ]);
    });

    testWidgets('without transactional DDL the statements run one by one', (tester) async {
      final s = ScriptedSession()..on('ADD b', odbcError('Duplicate column name'));
      final dc = scriptedConnection(s, dbmsName: 'MySQL', dbmsVersion: '8.4.0');
      final r = await run(
        tester,
        dc,
        const DdlScript(['ALTER TABLE t ADD a int', 'ALTER TABLE t ADD b int'], transactional: true),
      );
      expect(r.failedIndex, 1);
      expect(r.rolledBack, isFalse);
      expect(r.executed, 1);
      expect(s.log, ['exec: ALTER TABLE t ADD a int', 'exec: ALTER TABLE t ADD b int']);
    });

    testWidgets('passwords never reach the history', (tester) async {
      final s = ScriptedSession();
      final history = <String>[];
      final dc = scriptedConnection(s, history: history);
      final bag = SecretBag();
      final r = await run(
        tester,
        dc,
        DdlScript([
          'CREATE ROLE app LOGIN PASSWORD ${bag.add("'s3cret!'")}',
          'GRANT SELECT ON t TO app',
        ], secrets: bag.values),
      );
      expect(r.ok, isTrue);
      expect(s.executed, ["CREATE ROLE app LOGIN PASSWORD 's3cret!'", 'GRANT SELECT ON t TO app']);
      expect(history, ['GRANT SELECT ON t TO app']);
    });

    testWidgets('errors echoing a password are masked', (tester) async {
      final s = ScriptedSession()..on('CREATE ROLE', odbcError("syntax error near 's3cret!'"));
      final dc = scriptedConnection(s);
      final bag = SecretBag();
      final r = await run(
        tester,
        dc,
        DdlScript(['CREATE ROLE app LOGIN PASSWORD ${bag.add("'s3cret!'")}'], secrets: bag.values),
      );
      expect(r.error, isNot(contains('s3cret')));
      expect(r.error, contains('••••••'));
    });

    testWidgets('auto-commit only statements use a separate session in manual commit mode', (tester) async {
      final s = ScriptedSession();
      final own = ScriptedSession();
      final history = <String>[];
      final dc = scriptedConnection(s, autoCommit: false, history: history)
        ..mainCatalog = 'postgres'
        ..sessionOpener = (_) async => own;
      final r = await run(tester, dc, const DdlScript(['CREATE DATABASE shop'], autocommitOnly: true));
      expect(r.ok, isTrue);
      expect(s.log, isEmpty);
      expect(own.log, ['use postgres', 'exec: CREATE DATABASE shop', 'close']);
      expect(history, ['CREATE DATABASE shop']);
      expect(dc.pendingStatements, 0);
    });

    testWidgets('production connections ask twice; read-only ones refuse', (tester) async {
      final s = ScriptedSession();
      final dc = scriptedConnection(s, type: ConnectionType.production);
      final r = await run(tester, dc, const DdlScript(['DROP TABLE t']), confirm: ['Esegui', 'Continua']);
      expect(r.ok, isTrue);
      expect(s.executed, ['DROP TABLE t']);

      final ro = DbConnection(ConnectionConfig(id: 'ro', name: 'RO', readOnly: true));
      final ctx = await host(tester);
      final skipped = await runDdlScript(ctx, ro, const DdlScript(['DROP TABLE t']));
      expect(skipped.total, 0);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a partial run shows the error, then the script sheet closes', (tester) async {
      final ctx = await host(tester);
      final s = ScriptedSession()..on('CREATE TABLE b', odbcError('relation "b" already exists', state: '42P07'));
      final dc = scriptedConnection(s);
      bool? result;
      showDdlScriptDialog(ctx, dc: dc, title: 'Script con errore', statements: ['CREATE TABLE a (id int)', 'CREATE TABLE b (id int)'])
          .then((r) => result = r);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last); // "Eseguire lo script?"
      // The sheet's spinner keeps running under the alert.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The alert stays until it is read (it used to be popped by the sheet).
      expect(find.text('Esecuzione interrotta'), findsOneWidget);
      expect(find.textContaining('la precedente è stata eseguita'), findsWidgets);
      expect(find.text('Script con errore'), findsOneWidget);
      await tester.tap(find.text('OK').last);
      await tester.pump(const Duration(seconds: 5)); // toasts
      await tester.pumpAndSettle();
      // Part of it ran: the sheet closes instead of offering to run it again.
      expect(find.text('Script con errore'), findsNothing);
      expect(result, isFalse);
      expect(s.executed, ['CREATE TABLE a (id int)', 'CREATE TABLE b (id int)']);
    });

    testWidgets('the script sheet masks the passwords', (tester) async {
      final ctx = await host(tester);
      final dc = scriptedConnection(ScriptedSession());
      final bag = SecretBag();
      showDdlScriptDialog(
        ctx,
        dc: dc,
        script: DdlScript(['CREATE ROLE app LOGIN PASSWORD ${bag.add("'s3cret!'")}'], secrets: bag.values),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining("PASSWORD '••••••';"), findsOneWidget);
      expect(find.textContaining('s3cret'), findsNothing);
      expect(find.textContaining('password nascoste'), findsOneWidget);
      await tester.tap(find.text('Chiudi'));
      await tester.pumpAndSettle();
    });
  });
}
