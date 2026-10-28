// Screenshots of the design and administration tools (README, DESIGN.md),
// rendered on the real platform with real fonts. The data come from
// scripted sessions, so no server is needed:
//
//   flutter test integration_test/design_screens_test.dart -d macos \
//     --dart-define=SHOT_DIR=/tmp/dbcraft-shots

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dbcraft/features/design/model/extra_defs.dart';
import 'package:dbcraft/features/design/model/nosql_defs.dart';
import 'package:dbcraft/features/design/ui/extra_dialogs.dart';
import 'package:dbcraft/features/design/ui/nosql_dialogs.dart';
import 'package:dbcraft/features/design/ui/security_tab.dart';
import 'package:dbcraft/features/design/ui/table_permissions.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/design/helpers.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');
final _key = GlobalKey();

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  if (shotDir.isEmpty) return;
  final ro = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final img = await ro.toImage(pixelRatio: 1);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  Directory(shotDir).createSync(recursive: true);
  File('$shotDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
}

ScriptedSession _postgres() => ordersSession()
  ..on(
    'FROM pg_roles r ORDER',
    Rows(
      ['rolname', 'rolcanlogin', 'rolinherit', 'rolcreatedb', 'comment'],
      [
        ['mario', true, true, true, 'Sviluppatore'],
        ['anna', true, true, false, null],
        ['lettori', false, true, false, null],
        ['scrittori', false, true, false, null],
        ['pg_monitor', false, true, false, null],
      ],
    ),
  )
  ..on(
    'pg_auth_members',
    Rows(
      ['role_name', 'member_name', 'admin_option'],
      [
        ['lettori', 'mario', false],
      ],
    ),
  )
  ..on(
    'aclexplode',
    (String sql) => sql.contains('relname = ')
        ? Rows(
            ['grantee', 'privilege_type', 'is_grantable'],
            [
              ['lettori', 'SELECT', false],
              ['mario', 'UPDATE', true],
            ],
          )
        : Rows(
            ['kind', 'schema_name', 'object_name', 'sub', 'privilege_type', 'is_grantable'],
            [
              ['rel', 'app', 'orders', 'r', 'SELECT', false],
              ['rel', 'app', 'orders', 'r', 'INSERT', true],
              ['rel', 'app', 'customers', 'r', 'SELECT', false],
            ],
          ),
  );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('design screens', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 760));
    final app = (await tester.runAsync(
      () => AppState.load(workspaceDir: Directory.systemTemp.createTempSync('shots')),
    ))!;
    late BuildContext ctx;
    Future<void> show(Widget w) async {
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (c, child) => RepaintBoundary(key: _key, child: child!),
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  ctx = c;
                  return w;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> sheet(Future<Object?> Function() open, String name) async {
      open();
      await tester.pumpAndSettle();
      await shot(tester, name);
      Navigator.of(ctx).pop();
      await tester.pumpAndSettle();
    }

    final dc = scriptedConnection(_postgres());
    final tab = SecurityTab(dc);
    await show(Builder(builder: tab.buildView));
    await tester.tap(find.text('mario'));
    await tester.pumpAndSettle();
    await shot(tester, '15_security_manager');
    await tester.tap(find.text('Permessi'));
    await tester.pumpAndSettle();
    await shot(tester, '16_security_grants');

    await show(
      TablePermissionsPage(
        connection: dc,
        table: DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE'),
      ),
    );
    await shot(tester, '17_table_permissions');

    final pg = SqlDialect(dbmsName: 'PostgreSQL', dbmsVersion: '16.4');
    await show(const SizedBox.expand());
    await sheet(
      () => showPolicyDialog(
        ctx,
        dialect: pg,
        table: 'ordini',
        schema: 'app',
        roles: const ['venditori', 'capi_area'],
        rowSecurityOn: false,
        initial: const PolicyDef(
          name: 'propri',
          table: 'ordini',
          schema: 'app',
          command: PolicyCommand.select,
          roles: ['venditori'],
          using: 'owner = current_user',
        ),
      ),
      '18_policy_sheet',
    );
    final cassandra = SqlDialect(dbmsName: 'Apache Cassandra', dbmsVersion: '5.0.2');
    await sheet(
      () => showCqlTableDialog(
        ctx,
        dialect: cassandra,
        keyspace: 'iot',
        initial: const CqlTableDef(
          keyspace: 'iot',
          name: 'letture',
          columns: [
            CqlColumn('sensore', 'text', kind: CqlColumnKind.partition),
            CqlColumn('giorno', 'date', kind: CqlColumnKind.partition),
            CqlColumn('ora', 'timestamp', kind: CqlColumnKind.clustering, descending: true),
            CqlColumn('valore', 'double'),
          ],
          defaultTtl: 2592000,
          comment: 'Letture dei sensori',
        ),
      ),
      '19_cassandra_table',
    );
    await sheet(
      () => showMongoIndexDialog(
        ctx,
        database: 'shop',
        collection: 'ordini',
        fields: const ['codice', 'data', 'stato'],
        initial: const MongoIndexDef(
          database: 'shop',
          collection: 'ordini',
          name: 'ix_codice_data',
          keys: [MongoIndexKey('codice'), MongoIndexKey('data', '-1')],
          unique: true,
          partialFilter: r'{stato: {$ne: "annullato"}}',
        ),
      ),
      '20_mongodb_index',
    );
    tab.dispose();
  });
}
