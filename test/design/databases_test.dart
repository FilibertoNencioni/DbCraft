// Phase 4: databases and schemas (DDL per DBMS, catalog, sheets, actions).

import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/ddl/object_ddl.dart';
import 'package:dbcraft/features/design/model/object_defs.dart';
import 'package:dbcraft/features/design/ui/object_actions.dart' as objects;
import 'package:dbcraft/features/design/ui/object_dialogs.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// The statements are a single note (comment) containing [text].
Matcher note(String text) => allOf(hasLength(1), everyElement(allOf(startsWith('--'), contains(text))));

Future<BuildContext> host(WidgetTester tester, {AppState? app}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext ctx;
  Widget child = MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox();
        },
      ),
    ),
  );
  if (app != null) child = AppScope(state: app, child: child);
  await tester.pumpWidget(child);
  return ctx;
}

Future<T> settled<T>(WidgetTester tester, Future<T> f) async {
  var done = false;
  late T value;
  f.then((v) {
    value = v;
    done = true;
  });
  await tester.pumpAndSettle();
  expect(done, isTrue, reason: 'La finestra non si è chiusa');
  return value;
}

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  group('database DDL', () {
    test('create', () {
      const db = DatabaseDef(
        name: 'shop',
        owner: 'app',
        encoding: 'UTF8',
        collation: 'it_IT.UTF-8',
        template: 'template0',
        connectionLimit: 20,
        recoveryModel: 'SIMPLE',
        retentionDays: 7,
        comment: 'Negozio',
      );
      expectPerFamily((d) => ObjectDdl(d).createDatabase(db), {
        'pg': [
          "CREATE DATABASE shop OWNER app TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'it_IT.UTF-8' CONNECTION LIMIT 20",
          "COMMENT ON DATABASE shop IS 'Negozio'",
        ],
        'mssql': [
          'CREATE DATABASE shop COLLATE it_IT.UTF-8',
          'ALTER DATABASE shop SET RECOVERY SIMPLE',
          'ALTER AUTHORIZATION ON DATABASE::shop TO app',
        ],
        'mysql': 'CREATE DATABASE shop CHARACTER SET UTF8 COLLATE it_IT.UTF-8',
        'mariadb': "CREATE DATABASE shop CHARACTER SET UTF8 COLLATE it_IT.UTF-8 COMMENT 'Negozio'",
        'oracle': note('PDB'),
        'db2': note('CLP'),
        'sqlite': note('non supportato'),
        'firebird': note('via ODBC'),
        'snowflake': '''CREATE DATABASE "shop" DATA_RETENTION_TIME_IN_DAYS = 7 COMMENT = 'Negozio\'''',
      });
      expect(ObjectDdl(sqlDialects['snowflake']!).createDatabase(const DatabaseDef(name: 'tmp', transient: true)), [
        'CREATE TRANSIENT DATABASE "tmp"',
      ]);
    });

    test('alter, rename, drop', () {
      const from = DatabaseDef(name: 'shop', owner: 'app', connectionLimit: -1, recoveryModel: 'FULL');
      final to = from.copyWith(name: 'store', owner: 'admin', connectionLimit: 5, recoveryModel: 'SIMPLE');
      expect(ObjectDdl(sqlDialects['pg']!).alterDatabase(from, to), [
        'ALTER DATABASE shop RENAME TO store',
        'ALTER DATABASE store OWNER TO admin',
        'ALTER DATABASE store CONNECTION LIMIT 5',
      ]);
      expect(ObjectDdl(sqlDialects['mssql']!).alterDatabase(from, to), [
        'ALTER DATABASE shop MODIFY NAME = store',
        'ALTER DATABASE store SET RECOVERY SIMPLE',
        'ALTER AUTHORIZATION ON DATABASE::store TO admin',
      ]);
      expect(ObjectDdl(sqlDialects['mysql']!).alterDatabase(from, to).first, contains('non supportato'));
      expect(
        ObjectDdl(sqlDialects['pg']!).alterDatabase(from, from.copyWith(encoding: 'LATIN1')).single,
        contains('non si cambiano'),
      );
      expectPerFamily((d) => ObjectDdl(d).dropDatabase('shop', force: true), {
        'pg': 'DROP DATABASE shop WITH (FORCE)',
        'mssql': ['ALTER DATABASE shop SET SINGLE_USER WITH ROLLBACK IMMEDIATE', 'DROP DATABASE shop'],
        'mysql': 'DROP DATABASE shop',
        'mariadb': 'DROP DATABASE shop',
        'oracle': note('PDB'),
        'db2': note('CLP'),
        'sqlite': 'DROP DATABASE shop',
        'firebird': note('via ODBC'),
        'snowflake': 'DROP DATABASE "shop"',
      });
      expect(ObjectDdl(dialectAt('pg', '12.9')).dropDatabase('shop', force: true), [
        allOf(startsWith('--'), contains('PostgreSQL 13')),
        'DROP DATABASE shop',
      ]);
    });
  });

  group('schema DDL', () {
    test('create', () {
      const s = SchemaDef(name: 'sales', catalog: 'shop', owner: 'app', comment: 'Vendite', retentionDays: 3);
      final noted = note('non supportato');
      expectPerFamily((d) => ObjectDdl(d).createSchema(s), {
        'pg': ['CREATE SCHEMA sales AUTHORIZATION app', "COMMENT ON SCHEMA sales IS 'Vendite'"],
        'mssql': [
          'CREATE SCHEMA sales AUTHORIZATION app',
          "EXEC sp_addextendedproperty @name = N'MS_Description', @value = N'Vendite', @level0type = N'SCHEMA', @level0name = N'sales'",
        ],
        'mysql': noted,
        'mariadb': noted,
        'oracle': note('utente'),
        'db2': ['CREATE SCHEMA "sales" AUTHORIZATION "app"', 'COMMENT ON SCHEMA "sales" IS \'Vendite\''],
        'sqlite': noted,
        'firebird': noted,
        'snowflake': '''CREATE SCHEMA "shop"."sales" DATA_RETENTION_TIME_IN_DAYS = 3 COMMENT = 'Vendite\'''',
      });
    });

    test('alter, rename, drop', () {
      const s = SchemaDef(name: 'sales', owner: 'app');
      expect(ObjectDdl(sqlDialects['pg']!).alterSchema(s, s.copyWith(name: 'vendite', owner: 'admin')), [
        'ALTER SCHEMA sales RENAME TO vendite',
        'ALTER SCHEMA vendite OWNER TO admin',
      ]);
      expect(ObjectDdl(sqlDialects['mssql']!).alterSchema(s, s.copyWith(owner: 'admin')), [
        'ALTER AUTHORIZATION ON SCHEMA::sales TO admin',
      ]);
      expect(ObjectDdl(sqlDialects['mssql']!).renameSchema(s, 'x').single, contains('TRANSFER'));
      expectPerFamily((d) => ObjectDdl(d).dropSchema(s, cascade: true), {
        'pg': 'DROP SCHEMA sales CASCADE',
        'mssql': [startsWith('--'), 'DROP SCHEMA sales'],
        'mysql': note('non supportato'),
        'mariadb': note('non supportato'),
        'oracle': note('utente'),
        'db2': [startsWith('--'), 'DROP SCHEMA "sales" RESTRICT'],
        'sqlite': note('non supportato'),
        'firebird': note('non supportato'),
        'snowflake': 'DROP SCHEMA "sales" CASCADE',
      });
    });
  });

  group('catalog', () {
    test('PostgreSQL databases and schemas', () async {
      final s = ScriptedSession()
        ..on(
          'FROM pg_database',
          Rows(
            ['datname', 'owner', 'encoding', 'datcollate', 'datctype', 'datconnlimit', 'spcname', 'comment'],
            [
              ['shop', 'app', 'UTF8', 'C', 'C', -1, 'pg_default', 'Negozio'],
            ],
          ),
        )
        ..on(
          'FROM pg_namespace',
          Rows(
            ['nspname', 'owner', 'comment'],
            [
              ['public', 'postgres', null],
              ['sales', 'app', 'Vendite'],
            ],
          ),
        )
        ..on(
          'FROM pg_roles',
          Rows(
            ['rolname'],
            [
              ['app'],
              ['postgres'],
            ],
          ),
        );
      final cat = DesignCatalog.of(scriptedConnection(s))!;
      final db = (await cat.database('SHOP'))!;
      expect(db.owner, 'app');
      expect(db.connectionLimit, -1);
      expect(db.comment, 'Negozio');
      expect((await cat.schemaDef('shop', 'sales'))!.owner, 'app');
      final choices = await cat.databaseChoices();
      expect(choices.owners, ['app', 'postgres']);
      expect(choices.encodings, contains('UTF8'));
    });

    test('SQL Server schemas of another database', () async {
      final s = ScriptedSession()
        ..on(
          r'shop\.sys\.schemas',
          Rows(
            ['name', 'owner', 'comment'],
            [
              ['dbo', 'dbo', null],
            ],
          ),
        );
      final dc = scriptedConnection(s, dbmsName: 'Microsoft SQL Server', dbmsVersion: '16.00.4135');
      final schemas = await DesignCatalog.of(dc)!.schemaDefs('shop');
      expect(schemas.single.name, 'dbo');
      expect(schemas.single.catalog, 'shop');
    });
  });

  group('sheets', () {
    testWidgets('database sheet shows the fields of the DBMS and the script', (tester) async {
      final ctx = await host(tester);
      final f = showDatabaseDialog(ctx, dialect: sqlDialects['mssql']!, taken: {'master'});
      await tester.pumpAndSettle();
      expect(find.text('Modello di recupero'), findsOneWidget);
      expect(find.text('Codifica'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'master');
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      expect(find.text('Esiste già un database "master"'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'shop');
      await tester.pumpAndSettle();
      expect(find.textContaining('CREATE DATABASE shop;'), findsOneWidget);
      await tester.tap(find.text('Crea'));
      final db = (await settled(tester, f))!;
      expect(db.name, 'shop');
    });

    testWidgets('drop sheet wants the name typed', (tester) async {
      final ctx = await host(tester);
      final f = showDropDialog(
        ctx,
        title: 'Elimina database',
        objectLabel: 'il database shop',
        confirmName: 'shop',
        options: const [DropOption('force', 'Chiudi le sessioni attive')],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elimina'));
      await tester.pumpAndSettle();
      expect(find.text('Elimina database'), findsOneWidget, reason: 'still open');
      await tester.enterText(find.byType(TextField), 'shop');
      await tester.tap(find.text('Chiudi le sessioni attive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elimina'));
      expect(await settled(tester, f), {'force'});
    });
  });

  group('actions', () {
    testWidgets('create a database outside the transaction', (tester) async {
      final s = ScriptedSession();
      final own = ScriptedSession();
      final dc = scriptedConnection(s, autoCommit: false)..sessionOpener = (_) async => own;
      final ctx = await host(tester, app: await testApp(tester));
      final f = objects.createDatabase(ctx, dc);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'shop');
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      expect(await settled(tester, f), isTrue);
      expect(own.executed, ['CREATE DATABASE shop']);
      expect(s.executed.where((x) => x.startsWith('CREATE')), isEmpty);
      await drain(tester);
    });

    testWidgets('PostgreSQL refuses to drop the connected database', (tester) async {
      final dc = scriptedConnection(ScriptedSession())..info = {'databaseName': 'shop'};
      final ctx = await host(tester, app: await testApp(tester));
      final f = objects.dropDatabase(ctx, dc, 'shop');
      await tester.pumpAndSettle();
      expect(find.text('Impossibile eliminare'), findsOneWidget);
      await tester.tap(find.text('OK'));
      expect(await settled(tester, f), isFalse);
    });

    testWidgets('SQL Server creates a schema in the chosen database', (tester) async {
      final s = ScriptedSession();
      final dc = scriptedConnection(s, dbmsName: 'Microsoft SQL Server', dbmsVersion: '16.00.4135');
      final ctx = await host(tester, app: await testApp(tester));
      final f = objects.createSchema(ctx, dc, 'shop');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'sales');
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      expect(await settled(tester, f), isTrue);
      expect(s.log, containsAllInOrder(['use shop', 'exec: CREATE SCHEMA sales']));
      expect(dc.mainCatalog, 'shop');
      await drain(tester);
    });
  });
}
