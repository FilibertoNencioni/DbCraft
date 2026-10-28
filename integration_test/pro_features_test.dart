// End-to-end smoke test of the PRO features on the real application (demo
// SQLite database through ODBC): every new editor, panel and dialog is
// opened and rendered, so layout errors and runtime exceptions fail the test.
//
//   flutter test integration_test/pro_features_test.dart -d macos \
//     --dart-define=DEMO_DB=$PWD/sample/demo.db \
//     --dart-define=SHOT_DIR=/tmp/dbcraft-shots
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dbcraft/features/ai/ai.dart';
import 'package:dbcraft/features/data_compare/data_compare_tab.dart';
import 'package:dbcraft/features/mock_data/mock_data_dialog.dart';
import 'package:dbcraft/features/performance/perf_dashboard.dart';
import 'package:dbcraft/features/performance/visual_plan.dart';
import 'package:dbcraft/features/query_builder/query_builder_tab.dart';
import 'package:dbcraft/features/schema/schema_compare_view.dart';
import 'package:dbcraft/main.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/ui/dialogs/app_dialogs.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const demoDb = String.fromEnvironment('DEMO_DB');
const sqliteOdbc = String.fromEnvironment('SQLITE_ODBC', defaultValue: '/opt/homebrew/lib/libsqlite3odbc.dylib');
const shotDir = String.fromEnvironment('SHOT_DIR');

final _shotKey = GlobalKey();

Future<void> shot(WidgetTester tester, String name) async {
  await settle(tester, 400);
  if (shotDir.isEmpty) return;
  final ro = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final img = await ro.toImage(pixelRatio: 1);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  Directory(shotDir).createSync(recursive: true);
  File('$shotDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
}

Future<void> settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> waitFor(WidgetTester tester, Finder f, {int seconds = 15}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return;
  }
  await shot(tester, 'zz_failure');
  throw TestFailure('Timeout waiting for $f');
}

Future<void> closeDialog(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await settle(tester, 400);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('DbCraft PRO features', (tester) async {
    expect(demoDb, isNotEmpty, reason: 'pass --dart-define=DEMO_DB=...');
    final tmp = Directory.systemTemp.createTempSync('dbcraft_pro');
    final db = File('${tmp.path}/demo.db');
    File(demoDb).copySync(db.path);
    final db2 = File('${tmp.path}/demo2.db');
    File(demoDb).copySync(db2.path);
    final ws = Directory('${tmp.path}/ws')..createSync();
    File('${ws.path}/connections.json').writeAsStringSync(
      jsonEncode([
        {'id': 'demo', 'name': 'Demo SQLite', 'mode': 'driver', 'driver': sqliteOdbc, 'database': db.path},
        {'id': 'copy', 'name': 'Copia SQLite', 'mode': 'driver', 'driver': sqliteOdbc, 'database': db2.path},
      ]),
    );

    tester.view.physicalSize = const Size(1500, 920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await AppState.load(workspaceDir: ws);
    app.settings.themeMode = ThemeMode.light;
    await tester.pumpWidget(RepaintBoundary(key: _shotKey, child: DbCraftApp(state: app)));
    await settle(tester);
    BuildContext ctx() => tester.element(find.byType(HomePage));

    final dc = app.connections.first;
    final dc2 = app.connections[1];
    await app.connect(dc);
    await app.connect(dc2);
    app.select(dc);
    final table = (await dc.metadata!.findTable(null, null, 'dipendenti'))!;
    // The vault keeps passwords out of connections.json.
    expect(File('${ws.path}/vault.json').existsSync(), isTrue);

    // Sidebar panels: Cloud and Git.
    await tester.tap(find.byTooltip('Storage'));
    await shot(tester, 'p01_cloud_panel');
    await tester.tap(find.byTooltip('Git'));
    await shot(tester, 'p02_git_panel');
    await tester.tap(find.byTooltip('Database'));
    await settle(tester);

    // SQL editor → results → chart.
    final sql = await app.openSqlEditor(
      dc,
      initialSql: 'SELECT r.nome AS reparto, COUNT(*) AS dipendenti, AVG(d.stipendio) AS media\n'
          'FROM dipendenti d JOIN reparti r ON r.id = d.reparto_id GROUP BY r.nome',
    );
    await settle(tester);
    await sql.executeRaw(_NoUi(), sql.controller.text);
    await waitFor(tester, find.text('Grafico'));
    await tester.tap(find.text('Grafico').last);
    await shot(tester, 'p03_chart');

    // Visual query builder.
    app.openFeatureTab(QueryBuilderTab(dc, initialTable: table));
    await settle(tester, 2000);
    await shot(tester, 'p04_query_builder');

    // ER diagram edit mode.
    app.openErDiagram(dc, null, null);
    await waitFor(tester, find.text('Modifica'));
    await settle(tester, 1500);
    await tester.tap(find.text('Modifica').last);
    await settle(tester, 1500);
    await shot(tester, 'p05_erd_edit');

    // Schema and data compare.
    app.openFeatureTab(SchemaCompareTab(source: dc));
    await settle(tester, 1500);
    await shot(tester, 'p06_schema_compare');
    app.openFeatureTab(DataCompareTab(source: dc, sourceTable: table));
    await settle(tester, 1500);
    await shot(tester, 'p07_data_compare');

    // Performance dashboard (SQLite: explains what is available) and visual plan.
    app.openFeatureTab<PerformanceDashboardTab>(PerformanceDashboardTab(dc));
    await settle(tester, 1500);
    await shot(tester, 'p08_performance');
    await showVisualPlan(ctx(), dc, 'SELECT * FROM dipendenti d JOIN reparti r ON r.id = d.reparto_id WHERE d.stipendio > 3000');
    await settle(tester, 2000);
    await shot(tester, 'p09_visual_plan');

    // AI chat (no key: the tab still renders).
    app.openFeatureTab(AiChatTab(dc));
    await settle(tester);
    await shot(tester, 'p10_ai_chat');

    // Mock data dialog.
    showMockDataDialog(ctx(), dc, table);
    await settle(tester, 2000);
    await shot(tester, 'p11_mock_data');
    await tester.tap(find.text('Chiudi').last);
    await settle(tester);

    // Settings pages.
    showSettingsDialog(ctx());
    await settle(tester);
    for (final (page, name) in const [
      ('Analisi', 'p12_settings_analysis'),
      ('Sicurezza', 'p13_settings_security'),
      ('Assistente AI', 'p14_settings_ai'),
    ]) {
      await tester.tap(find.text(page).last);
      await shot(tester, name);
    }
    Navigator.of(tester.element(find.text('Assistente AI').last)).pop();
    await settle(tester);

    // Connection dialog: built-in drivers and enterprise authentication.
    await tester.tap(find.byTooltip('Nuova connessione').first);
    await settle(tester);
    await tester.tap(find.text('Integrato').last);
    await shot(tester, 'p15_native_driver');
    await tester.tap(find.text('Annulla').last);
    await settle(tester);

    // Simplified analyst view.
    app.settings.simpleMode = true;
    await app.saveSettings();
    app.openTable(dc, table);
    await settle(tester, 2000);
    await shot(tester, 'p16_simple_mode');
    app.settings.simpleMode = false;

    // Dark theme pass on the busiest editor.
    app.settings.themeMode = ThemeMode.dark;
    await app.saveSettings();
    app.activate(app.tabs.firstWhere((t) => t is QueryBuilderTab));
    await shot(tester, 'p17_dark_query_builder');

    for (final t in List.of(app.tabs)) {
      app.closeTab(t);
    }
    await settle(tester);
    await app.disconnectAll();
  });
}

class _NoUi implements ExecutionUi {
  @override
  Future<Map<String, Object?>?> askParameters(List<String> names, Map<String, Object?> previous) async => {};
  @override
  Future<bool> confirm(String title, String message) async => true;
  @override
  Future<bool> ensureConnected(c) async => true;
}
