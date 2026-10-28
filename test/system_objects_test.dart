// System databases and schemas: the per DBMS rules and the "Sistema" folder
// of the navigator.

import 'package:dbcraft/services/metadata_service.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/services/storage.dart';
import 'package:dbcraft/services/system_objects.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/navigator/nav_nodes.dart';
import 'package:dbcraft/ui/navigator/navigator_panel.dart';
import 'package:dbcraft/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design/helpers.dart';

SqlDialect dialect(String dbmsName) => SqlDialect(dbmsName: dbmsName);

/// Connection to [dbmsName] whose catalog functions list [tables]
/// (catalog, schema) pairs; [current] is the database it opens.
DbConnection connection(
  String dbmsName,
  List<(String?, String?)> tables, {
  String? current,
  bool catalogs = true,
  String user = '',
  ScriptedSession? session,
}) {
  final s = session ?? ScriptedSession();
  s.catalogs['tables'] = [
    for (final (c, sch) in tables) [c, sch, 't', 'TABLE', null],
  ];
  final dc = scriptedConnection(s, dbmsName: dbmsName);
  dc.config.user = user;
  dc.metadata = MetadataService(s, {
    'dbmsName': dbmsName,
    'identifierQuote': '"',
    'catalogUsage': catalogs ? 1 : 0,
    'schemaUsage': 1,
    'currentCatalog': ?current,
  });
  return dc;
}

List<String> labels(Iterable<NavNode> nodes) => [for (final n in nodes) n.label];

SystemFolderNode systemFolder(List<NavNode> nodes) => nodes.whereType<SystemFolderNode>().single;

void main() {
  group('rules per DBMS', () {
    test('databases', () {
      final mssql = dialect('Microsoft SQL Server');
      for (final n in ['master', 'model', 'msdb', 'tempdb', 'TempDB']) {
        expect(isSystemCatalog(mssql, n), isTrue, reason: n);
      }
      expect(isSystemCatalog(mssql, 'Vendite'), isFalse);

      final pg = dialect('PostgreSQL');
      expect(isSystemCatalog(pg, 'template0'), isTrue);
      expect(isSystemCatalog(pg, 'template1'), isTrue);
      expect(isSystemCatalog(pg, 'postgres'), isFalse, reason: 'database di manutenzione, resta visibile');

      final mysql = dialect('MySQL');
      for (final n in ['mysql', 'sys', 'performance_schema', 'information_schema']) {
        expect(isSystemCatalog(mysql, n), isTrue, reason: n);
      }
      expect(isSystemCatalog(mysql, 'shop'), isFalse);

      expect(isSystemCatalog(dialect('MongoDB'), 'admin'), isTrue);
      expect(isSystemCatalog(dialect('MongoDB'), 'local'), isTrue);
      expect(isSystemCatalog(dialect('MongoDB'), 'shop'), isFalse);
      expect(isSystemCatalog(dialect('Cassandra'), 'system_schema'), isTrue);
      expect(isSystemCatalog(dialect('Cassandra'), 'shop'), isFalse);
      expect(isSystemCatalog(dialect('Snowflake'), 'SNOWFLAKE'), isTrue);
      expect(isSystemCatalog(dialect('ClickHouse'), 'system'), isTrue);
      expect(isSystemCatalog(dialect('SQLite'), 'main'), isFalse);
    });

    test('schemas', () {
      final mssql = dialect('Microsoft SQL Server');
      for (final n in ['sys', 'INFORMATION_SCHEMA', 'guest', 'db_owner', 'db_datareader']) {
        expect(isSystemSchema(mssql, n), isTrue, reason: n);
      }
      expect(isSystemSchema(mssql, 'dbo'), isFalse);

      final pg = dialect('PostgreSQL');
      for (final n in ['pg_catalog', 'pg_toast', 'pg_temp_3', 'information_schema']) {
        expect(isSystemSchema(pg, n), isTrue, reason: n);
      }
      expect(isSystemSchema(pg, 'public'), isFalse);

      final oracle = dialect('Oracle');
      expect(isSystemSchema(oracle, 'SYS'), isTrue);
      expect(isSystemSchema(oracle, 'APEX_230100'), isTrue);
      expect(isSystemSchema(oracle, 'HR'), isFalse);

      final db2 = dialect('DB2/LINUXX8664');
      expect(isSystemSchema(db2, 'SYSIBM'), isTrue);
      expect(isSystemSchema(db2, 'NULLID'), isTrue);
      expect(isSystemSchema(db2, 'DB2INST1'), isFalse);

      expect(isSystemSchema(dialect('Snowflake'), 'INFORMATION_SCHEMA'), isTrue);
      expect(isSystemSchema(dialect('Snowflake'), 'PUBLIC'), isFalse);
    });
  });

  group('navigator', () {
    test('SQL Server system databases go to the folder, at the end', () async {
      final dc = connection('Microsoft SQL Server', [
        for (final c in ['master', 'model', 'msdb', 'tempdb', 'Vendite', 'Magazzino']) (c, 'dbo'),
      ], current: 'Vendite');
      final nodes = await ConnectionNode(dc).load();
      final cats = nodes.where((n) => n is CatalogNode || n is SystemFolderNode).toList();
      expect(labels(cats), ['Magazzino', 'Vendite', 'Sistema']);
      final folder = systemFolder(nodes);
      expect(labels(folder.items), ['master', 'model', 'msdb', 'tempdb']);
      expect(folder.detail, '4');
      expect(folder.children, folder.items, reason: 'già pronta da aprire');
    });

    test('the database the connection opens stays in sight', () async {
      final dc = connection('Microsoft SQL Server', [
        for (final c in ['master', 'msdb', 'Vendite']) (c, 'dbo'),
      ], current: 'master');
      final nodes = await ConnectionNode(dc).load();
      expect(labels(nodes.whereType<CatalogNode>()), ['master', 'Vendite']);
      expect(labels(systemFolder(nodes).items), ['msdb']);
    });

    test('no folder without system objects', () async {
      final dc = connection('Microsoft SQL Server', [('Vendite', 'dbo')], current: 'Vendite');
      expect((await ConnectionNode(dc).load()).whereType<SystemFolderNode>(), isEmpty);
    });

    test('PostgreSQL system schemas of a database', () async {
      final dc = connection('PostgreSQL', [
        for (final s in ['public', 'pg_catalog', 'information_schema', 'pg_toast', 'app']) ('shop', s),
      ], current: 'shop');
      final nodes = await CatalogNode(dc, 'shop').load();
      expect(labels(nodes), ['app', 'public', 'Sistema']);
      expect(labels(systemFolder(nodes).items), ['information_schema', 'pg_catalog', 'pg_toast']);
      expect(systemFolder(nodes).key, 'sys:scripted:shop');
    });

    test('Oracle: ORACLE_MAINTAINED users, the schema of the login stays in sight', () async {
      final s = ScriptedSession()
        ..on(
          'FROM dba_users',
          Rows(
            ['USERNAME', 'ORACLE_MAINTAINED'],
            [
              ['SYS', 'Y'],
              ['SYSTEM', 'Y'],
              ['NEW_INTERNAL', 'Y'],
              ['HR', 'N'],
            ],
          ),
        );
      final dc = connection(
        'Oracle',
        [for (final sch in ['SYS', 'SYSTEM', 'NEW_INTERNAL', 'XDB', 'HR']) (null, sch)],
        catalogs: false,
        user: 'system',
        session: s,
      );
      final nodes = await ConnectionNode(dc).load();
      expect(labels(nodes.whereType<SchemaNode>()), ['HR', 'SYSTEM']);
      expect(labels(systemFolder(nodes).items), ['NEW_INTERNAL', 'SYS', 'XDB']);
    });

    test('schema changes reach the databases inside the folder', () {
      final dc = connection('Microsoft SQL Server', const []);
      final root = ConnectionNode(dc);
      final master = CatalogNode(dc, 'master')..children = [];
      root.children = [CatalogNode(dc, 'Vendite'), SystemFolderNode('sys:scripted', [master])];
      expect(nodesForSchemaChanges(root, const [SchemaScope.catalog('master')]), [master]);
    });

    testWidgets('the folder opens on demand and the preference hides it', (tester) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = await testApp(tester);
      app.connections.add(
        connection('Microsoft SQL Server', [
          for (final c in ['master', 'msdb', 'Vendite']) (c, 'dbo'),
        ], current: 'Vendite'),
      );
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: NavigatorPanel()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prova'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('Vendite'), findsOneWidget);
      expect(find.text('Sistema'), findsOneWidget);
      expect(find.text('master'), findsNothing, reason: 'cartella chiusa');

      await tester.tap(find.text('Sistema'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('master'), findsOneWidget);
      expect(find.text('msdb'), findsOneWidget);

      app.settings.hideSystemObjects = true;
      await tester.runAsync(app.saveSettings);
      await tester.pumpAndSettle();
      expect(find.text('Sistema'), findsNothing);
      expect(find.text('master'), findsNothing);
      expect(find.text('Vendite'), findsOneWidget);
    });
  });

  test('the preference defaults to the folder and round-trips', () {
    expect(AppSettings().hideSystemObjects, isFalse);
    expect(AppSettings.fromJson(const {}).hideSystemObjects, isFalse);
    final s = AppSettings(hideSystemObjects: true);
    expect(AppSettings.fromJson(s.toJson()).hideSystemObjects, isTrue);
  });
}
