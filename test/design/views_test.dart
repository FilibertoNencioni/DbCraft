// Phase 5: views and materialized views (DDL per DBMS, definition from the
// catalog, view editor).

import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/ddl/object_ddl.dart';
import 'package:dbcraft/features/design/model/object_defs.dart';
import 'package:dbcraft/features/design/view_design.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/ui/editors/table_editor_view.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const v = ViewDef(schema: 'app', name: 'active', definition: 'SELECT id, name FROM customers WHERE active = 1');

Matcher note(String text) => allOf(hasLength(1), everyElement(allOf(startsWith('--'), contains(text))));

void main() {
  test('the query of a stored CREATE VIEW', () {
    expect(splitViewSql('CREATE VIEW [dbo].[v] AS SELECT a AS b FROM t WITH CHECK OPTION;'), (
      query: 'SELECT a AS b FROM t',
      check: ViewCheckOption.cascaded,
    ));
    expect(splitViewSql('CREATE VIEW "my view" (a, b) AS\n  SELECT 1, 2').query, 'SELECT 1, 2');
    expect(
      splitViewSql('create or replace secure view db.s.v comment=\'x as y\' as select 1 as x').query,
      'select 1 as x',
    );
    expect(splitViewSql('SELECT x FROM t WITH LOCAL CHECK OPTION'), (
      query: 'SELECT x FROM t',
      check: ViewCheckOption.local,
    ));
    expect(splitViewSql('  SELECT 1;  ').query, 'SELECT 1');
  });

  group('DDL', () {
    test('create with check option', () {
      final withCheck = v.copyWith(checkOption: ViewCheckOption.local);
      const q = 'SELECT id, name FROM customers WHERE active = 1';
      expectPerFamily((d) => ObjectDdl(d).createView(withCheck), {
        'pg': 'CREATE VIEW app.active AS\n$q\nWITH LOCAL CHECK OPTION',
        'mssql': 'CREATE VIEW app.active AS\n$q\nWITH CHECK OPTION',
        'mysql': 'CREATE VIEW app.active AS\n$q\nWITH LOCAL CHECK OPTION',
        'mariadb': 'CREATE VIEW app.active AS\n$q\nWITH LOCAL CHECK OPTION',
        'oracle': 'CREATE VIEW "app"."active" AS\n$q\nWITH CHECK OPTION',
        'db2': 'CREATE VIEW "app"."active" AS\n$q\nWITH LOCAL CHECK OPTION',
        'sqlite': 'CREATE VIEW app.active AS\n$q',
        'firebird': 'CREATE VIEW "app"."active" AS\n$q\nWITH CHECK OPTION',
        'snowflake': 'CREATE VIEW "app"."active" AS\n$q',
      });
    });

    test('materialized', () {
      final m = v.copyWith(materialized: true, withData: false);
      expectPerFamily((d) => ObjectDdl(d).createView(m), {
        'pg': 'CREATE MATERIALIZED VIEW app.active AS\n${v.definition}\nWITH NO DATA',
        'mssql': note('non supporta'),
        'mysql': note('non supporta'),
        'mariadb': note('non supporta'),
        'oracle': 'CREATE MATERIALIZED VIEW "app"."active" AS\n${v.definition}',
        'db2': note('non supporta'),
        'sqlite': note('non supporta'),
        'firebird': note('non supporta'),
        'snowflake': 'CREATE MATERIALIZED VIEW "app"."active" AS\n${v.definition}',
      });
      expect(ObjectDdl(sqlDialects['pg']!).dropView(m, cascade: true), ['DROP MATERIALIZED VIEW app.active CASCADE']);
      expect(ObjectDdl(sqlDialects['pg']!).refreshMaterializedView(m), ['REFRESH MATERIALIZED VIEW app.active']);
      expect(ObjectDdl(sqlDialects['oracle']!).refreshMaterializedView(m), [
        "BEGIN DBMS_MVIEW.REFRESH('app.active'); END;",
      ]);
    });

    test('a changed query is replaced in place where possible', () {
      final from = v.copyWith(originalName: 'active');
      final to = from.copyWith(definition: 'SELECT id FROM customers');
      expect(ObjectDdl(sqlDialects['pg']!).alterView(from, to), [
        'CREATE OR REPLACE VIEW app.active AS\nSELECT id FROM customers',
      ]);
      expect(ObjectDdl(sqlDialects['mssql']!).alterView(from, to), [
        'CREATE OR ALTER VIEW app.active AS\nSELECT id FROM customers',
      ]);
      expect(ObjectDdl(sqlDialects['firebird']!).alterView(from, to).single, startsWith('CREATE OR ALTER VIEW'));
      // SQL Server 2014: no OR ALTER.
      final old = ObjectDdl(dialectAt('mssql', '12.00.6024')).alterView(from, to);
      expect(old.skip(1), ['DROP VIEW app.active', 'CREATE VIEW app.active AS\nSELECT id FROM customers']);
      expect(old.first, contains('permessi'));
      expect(ObjectDdl(sqlDialects['sqlite']!).alterView(from, to).last, startsWith('CREATE VIEW'));
      expect(ObjectDdl(sqlDialects['pg']!).alterView(from, from), isEmpty);
    });

    test('SQL Server: no database prefix, the script runs in the database', () {
      final ddl = ObjectDdl(sqlDialects['mssql']!);
      final inDb = v.copyWith(catalog: 'shop');
      expect(ddl.createView(inDb).single, startsWith('CREATE VIEW app.active AS'));
      expect(ddl.dropView(inDb), ['DROP VIEW app.active']);
      expect(ddl.scriptCatalog('shop'), 'shop');
      expect(ObjectDdl(sqlDialects['pg']!).scriptCatalog('shop'), isNull);
      expect(ObjectDdl(sqlDialects['pg']!).createView(inDb).single, startsWith('CREATE VIEW shop.app.active'));
    });

    test('rename, comments, kind change', () {
      final from = v.copyWith(originalName: 'active');
      expect(ObjectDdl(sqlDialects['pg']!).alterView(from, from.copyWith(name: 'clienti_attivi')), [
        'ALTER VIEW app.active RENAME TO clienti_attivi',
      ]);
      expect(ObjectDdl(sqlDialects['mysql']!).renameView(from, 'x'), ['RENAME TABLE app.active TO app.x']);
      final mssql = ObjectDdl(sqlDialects['mssql']!).alterView(from, from.copyWith(name: 'x'));
      expect(mssql.skip(1), ['DROP VIEW app.active', 'CREATE VIEW app.x AS\n${v.definition}']);
      expect(ObjectDdl(sqlDialects['pg']!).alterView(from, from.copyWith(comment: 'Clienti')), [
        "COMMENT ON VIEW app.active IS 'Clienti'",
      ]);
      final toMat = ObjectDdl(sqlDialects['pg']!).alterView(from, from.copyWith(materialized: true));
      expect(toMat.skip(1), ['DROP VIEW app.active', 'CREATE MATERIALIZED VIEW app.active AS\n${v.definition}']);
    });
  });

  group('catalog', () {
    final t = DbTable(catalog: 'db', schema: 'app', name: 'active', type: 'VIEW');

    test('PostgreSQL', () async {
      final s = ScriptedSession()
        ..on(
          'pg_get_viewdef',
          Rows(
            ['def', 'relkind', 'options', 'comment', 'check_option'],
            [
              [' SELECT id\n   FROM customers;', 'v', 'security_barrier=true', 'Attivi', 'LOCAL'],
            ],
          ),
        );
      final d = (await DesignCatalog.of(scriptedConnection(s))!.viewDef(t))!;
      expect(d.definition, 'SELECT id\n   FROM customers');
      expect(d.checkOption, ViewCheckOption.local);
      expect(d.securityBarrier, isTrue);
      expect(d.comment, 'Attivi');
    });

    test('SQL Server', () async {
      final s = ScriptedSession()
        ..on(
          'sys.sql_modules',
          Rows(
            ['definition', 'with_check_option', 'bound', 'comment'],
            [
              ['CREATE VIEW app.active WITH SCHEMABINDING AS\nSELECT id FROM app.customers', 1, 1, null],
            ],
          ),
        );
      final dc = scriptedConnection(s, dbmsName: 'Microsoft SQL Server', dbmsVersion: '16.00.4135');
      final d = (await DesignCatalog.of(dc)!.viewDef(t))!;
      expect(d.definition, 'SELECT id FROM app.customers');
      expect(d.schemaBinding, isTrue);
      expect(d.checkOption, ViewCheckOption.cascaded);
      expect(s.executed.single, contains("OBJECT_ID(N'[db].[app].[active]')"));
    });

    test('SQLite and Oracle materialized views', () async {
      final lite = ScriptedSession()
        ..on(
          'sqlite_master',
          Rows(
            ['sql'],
            [
              ['CREATE VIEW active AS SELECT 1 AS x'],
            ],
          ),
        );
      final d = await DesignCatalog.of(scriptedConnection(lite, dbmsName: 'SQLite', dbmsVersion: '3.45.1'))!.viewDef(t);
      expect(d!.definition, 'SELECT 1 AS x');
      final ora = ScriptedSession()
        ..on('all_views', Rows(['def'], const []))
        ..on(
          'all_mviews',
          Rows(
            ['def'],
            [
              ['SELECT 1 FROM dual'],
            ],
          ),
        );
      final m = await DesignCatalog.of(scriptedConnection(ora, dbmsName: 'Oracle', dbmsVersion: '23.0'))!.viewDef(t);
      expect(m!.materialized, isTrue);
      final none = ScriptedSession();
      expect(await DesignCatalog.of(scriptedConnection(none))!.viewDef(t), isNull);
    });
  });

  test('ViewDesign', () {
    final d = ViewDesign.existing(sqlDialects['pg']!, v);
    expect(d.isDirty, isFalse);
    d.update(d.working.copyWith(definition: 'SELECT 1'));
    expect(d.statements.first, contains('OR REPLACE non toglie'));
    expect(d.statements.last, 'CREATE OR REPLACE VIEW app.active AS\nSELECT 1');
    d.discard();
    expect(d.isDirty, isFalse);
    final n = ViewDesign.create(sqlDialects['pg']!, schema: 'app', definition: 'SELECT 2');
    expect(n.errors, ['Inserisci il nome della vista']);
    n.update(n.working.copyWith(name: 'due'));
    expect(n.statements, ['CREATE VIEW app.due AS\nSELECT 2']);
  });

  group('view editor', () {
    Future<(TableEditorTab, ScriptedSession)> open(
      WidgetTester tester,
      TableEditorTab Function(ScriptedSession s) make,
    ) async {
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = ordersSession();
      final app = await testApp(tester);
      final tab = make(s);
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(body: TableEditorView(tab: tab)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (tab, s);
    }

    Future<void> runScript(WidgetTester tester) async {
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    testWidgets('create a view from a query', (tester) async {
      late ScriptedSession session;
      final (tab, s) = await open(tester, (s) {
        session = s;
        return TableEditorTab.createView(scriptedConnection(s), schema: 'app', definition: 'SELECT id FROM app.orders');
      });
      expect(find.text('Nuova vista'), findsWidgets);
      await tester.enterText(find.widgetWithText(TextField, '').first, 'order_ids');
      await tester.pumpAndSettle();
      expect(tab.title, 'order_ids');
      session.on('CREATE VIEW', (String sql) {
        session.catalogs['tables']!.add([null, 'app', 'order_ids', 'VIEW', null]);
        return Rows(const [], const []);
      });
      await tester.tap(find.text('Crea vista'));
      await tester.pumpAndSettle();
      expect(find.textContaining('CREATE VIEW app.order_ids AS\nSELECT id FROM app.orders;'), findsOneWidget);
      await runScript(tester);
      expect(s.executed, contains('CREATE VIEW app.order_ids AS\nSELECT id FROM app.orders'));
      expect(tab.isNew, isFalse);
      expect(tab.table.name, 'order_ids');
    });

    testWidgets('the definition page of an existing view edits and saves', (tester) async {
      final (tab, s) = await open(tester, (s) {
        s.catalogs['tables']!.add([null, 'app', 'v_orders', 'VIEW', null]);
        s.on(
          'pg_get_viewdef',
          Rows(
            ['def', 'relkind', 'options', 'comment', 'check_option'],
            [
              ['SELECT id FROM app.orders', 'v', '', null, 'NONE'],
            ],
          ),
        );
        return TableEditorTab(
          scriptedConnection(s),
          DbTable(catalog: null, schema: 'app', name: 'v_orders', type: 'VIEW'),
          initialPage: 8,
        );
      });
      expect(tab.viewDesign, isNotNull);
      expect(find.text('Definizione'), findsOneWidget);
      expect(find.text('Vincoli'), findsNothing, reason: 'views have no constraint page');
      tab.viewDesign!.update(tab.viewDesign!.working.copyWith(definition: 'SELECT id, qty FROM app.orders'));
      await tester.pumpAndSettle();
      expect(tab.isDirty, isTrue);
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(s.executed, contains('CREATE OR REPLACE VIEW app.v_orders AS\nSELECT id, qty FROM app.orders'));
    });
  });
}
