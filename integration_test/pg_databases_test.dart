// Every database of a PostgreSQL server in one connection, in the real app:
// the navigator lists them, tables, editors and the DDL of the design tools
// work on the database of their objects, a database used by an editor can be
// dropped.
//
//   tool/design_db/up.sh   (or: docker compose -f tool/design_db/compose.yml up -d pg)
//   flutter test integration_test/pg_databases_test.dart -d macos
import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/ddl_script.dart';
import 'package:dbcraft/features/design/model/extra_defs.dart';
import 'package:dbcraft/features/schema/ddl_execution.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/ui/navigator/navigator_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'matrix/harness.dart';
import 'matrix/ui.dart';

Future<List<Object?>> _col(DbSession s, String sql) async {
  final r = await s.execute(sql);
  if (r.cursorId != null) await s.closeCursor(r.cursorId!);
  return [for (final row in r.rows) row.first];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('postgres: every database in one connection', (tester) async {
    final app = await startApp(tester, connections: [
      {
        'id': 'pgt',
        'name': 'PG test',
        'mode': 'driver',
        'driver': 'PostgreSQL Unicode',
        'host': '127.0.0.1',
        'port': '55432',
        'database': 'dbcraft',
        'user': 'dbcraft',
        'password': 'DbCraft_Test1',
      },
    ]);
    final dc = app.connections.first;
    await tester.runAsync(dc.connect);
    expect(dc.routesDatabases, isTrue);
    final m = dc.main!;
    await tester.runAsync(() async {
      for (final db in ['zz_other', 'zz_drop']) {
        await _col(m, 'DROP DATABASE IF EXISTS $db');
        await _col(m, 'CREATE DATABASE $db');
      }
      await _col(dc.metaFor('zz_other')!, "CREATE TABLE zz_city AS SELECT 'Pisa'::text AS name");
    });
    dc.schemaChanged();
    await settle(tester);

    // Navigator: the databases, the initial one marked; extensions belong
    // to each database.
    await navExpand(tester, 'PG test');
    await waitFor(tester, nav('zz_other'));
    expect(nav('predefinito'), findsOneWidget);
    expect(nav('Estensioni'), findsNothing);
    await navExpand(tester, 'zz_other');
    await waitFor(tester, nav('Estensioni'));
    await navExpand(tester, 'public');
    await waitFor(tester, nav('Tabelle'));
    await navExpand(tester, 'Tabelle');
    await waitFor(tester, nav('zz_city'));
    await shot(tester, 'pg_databases_navigator');

    // A table of another database opens with its data.
    await doubleTap(tester, nav('zz_city').first);
    final t = app.tabs.whereType<TableEditorTab>().last;
    expect(t.table.catalog, 'zz_other');
    app.openTable(dc, t.table, page: 1);
    final data = await waitModel(tester, t);
    expect(data.rows.single.values, ['Pisa']);

    // SQL editors run on their database and switch with the picker.
    final e = await app.openSqlEditor(dc, catalog: 'zz_other', initialSql: 'SELECT current_database()');
    await runEditor(tester, e);
    expect(lastModel(e).rows.first.values.first, 'zz_other');
    e.catalog = 'dbcraft';
    await runEditor(tester, e);
    expect(lastModel(e).rows.first.values.first, 'dbcraft');

    Future<void> run(DdlScript script) async {
      final f = runDdlScript(tester.element(find.byType(NavigatorPanel)), dc, script);
      await waitFor(tester, find.text('Esegui'));
      await tester.tap(find.text('Esegui').last);
      DdlResult? r;
      f.then((x) => r = x);
      for (var i = 0; i < 100 && r == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      expect(r?.error, isNull);
      expect(r?.executed, script.statements.length);
    }

    // DDL of the design tools goes to the database of its objects, wherever
    // the editors are (dbcraft here).
    await run(const DdlScript(['CREATE TABLE public.zz_t (id int)'], scope: SchemaScope.schema('zz_other', 'public')));
    await run(const DdlScript(['CREATE EXTENSION pg_trgm'], scope: SchemaScope.schema('zz_other', null)));

    await tester.runAsync(() async {
      expect(await _col(dc.metaFor('zz_other')!, "SELECT to_regclass('public.zz_t')::text"), ['zz_t']);
      expect(await _col(dc.metaFor('dbcraft')!, "SELECT to_regclass('public.zz_t')::text"), [null]);
      final cat = DesignCatalog.of(dc)!;
      final other = await cat.extras(ExtraKind.extensions, catalog: 'zz_other');
      expect(other.firstWhere((x) => x.name == 'pg_trgm').catalog, 'zz_other');
      expect((await cat.extras(ExtraKind.extensions, catalog: 'dbcraft')).map((x) => x.name), isNot(contains('pg_trgm')));

      // An editor used zz_drop: closing its sessions lets PostgreSQL drop it.
      await dc.useCatalog('zz_drop');
      await _col(dc.main!, 'SELECT 1');
      await dc.closeDatabase('zz_drop');
      expect(dc.mainCatalog, 'dbcraft');
      await _col(dc.main!, 'DROP DATABASE zz_drop');
      await _col(dc.main!, 'DROP DATABASE zz_other WITH (FORCE)');
    });
    await finish(tester, app);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
