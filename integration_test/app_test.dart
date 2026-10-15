// End-to-end test driving the real application against the demo SQLite
// database through the SQLite ODBC driver.
//
//   flutter test integration_test/app_test.dart -d macos \
//     --dart-define=DEMO_DB=$PWD/sample/demo.db \
//     --dart-define=SQLITE_ODBC=/opt/homebrew/lib/libsqlite3odbc.dylib \
//     --dart-define=SHOT_DIR=/tmp/dbcraft-shots
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dbcraft/main.dart';
import 'package:dbcraft/odbc/odbc_session.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/ui/dialogs/app_dialogs.dart';
import 'package:dbcraft/ui/editors/sql_code_editor.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const demoDb = String.fromEnvironment('DEMO_DB');
const sqliteOdbc = String.fromEnvironment(
  'SQLITE_ODBC',
  defaultValue: '/opt/homebrew/lib/libsqlite3odbc.dylib',
);
const shotDir = String.fromEnvironment('SHOT_DIR');

final _shotKey = GlobalKey();

Future<void> shot(WidgetTester tester, String name, {bool settleFirst = true}) async {
  if (shotDir.isEmpty) return;
  if (settleFirst) await tester.pump(const Duration(milliseconds: 300));
  final ro = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final img = await ro.toImage(pixelRatio: 1);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  Directory(shotDir).createSync(recursive: true);
  File('$shotDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
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

Future<void> settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> doubleTap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(f);
  await settle(tester, 400);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('DbCraft end-to-end', (tester) async {
    expect(demoDb, isNotEmpty, reason: 'pass --dart-define=DEMO_DB=...');
    final tmp = Directory.systemTemp.createTempSync('dbcraft_it');
    final db = File('${tmp.path}/demo.db');
    File(demoDb).copySync(db.path);
    final ws = Directory('${tmp.path}/ws')..createSync();
    File('${ws.path}/connections.json').writeAsStringSync(
      jsonEncode([
        {
          'id': 'demo',
          'name': 'Demo SQLite',
          'mode': 'driver',
          'driver': sqliteOdbc,
          'database': db.path,
          'type': 'development',
        },
        {
          'id': 'prod',
          'name': 'SQL Server Produzione',
          'mode': 'driver',
          'driver': 'ODBC Driver 17 for SQL Server',
          'host': 'sql.esempio.local',
          'port': '1433',
          'database': 'ERP',
          'user': 'sa',
          'type': 'production',
          'folder': 'Clienti',
        },
      ]),
    );

    tester.view.physicalSize = const Size(1500, 920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = await AppState.load(workspaceDir: ws);
    state.settings.themeMode = ThemeMode.light;
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: DbCraftApp(state: state),
      ),
    );
    await settle(tester);
    await shot(tester, '01_home');

    // Connect + expand through the navigator.
    await doubleTap(tester, find.text('Demo SQLite').first);
    await waitFor(tester, find.text('Tabelle'));
    await doubleTap(tester, find.text('Tabelle'));
    await waitFor(tester, find.text('dipendenti'));
    await doubleTap(tester, find.text('Viste'));
    await waitFor(tester, find.text('v_dipendenti_reparto'));
    await shot(tester, '02_navigator');

    // Table editor.
    await doubleTap(tester, find.text('dipendenti').first);
    await waitFor(tester, find.text('Nome qualificato'));
    await settle(tester);
    await shot(tester, '03_table_properties');

    await tester.tap(find.text('Dati').last);
    await waitFor(tester, find.text('utente1@esempio.it'));
    await settle(tester);
    await shot(tester, '04_table_data');

    // Inline edit + save.
    await doubleTap(tester, find.text('utente1@esempio.it'));
    await waitFor(tester, find.byType(TextField).last);
    final editor = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == 'utente1@esempio.it',
    );
    await tester.enterText(editor, 'modificato@esempio.it');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, 400);
    await shot(tester, '05_table_edit_pending');
    await tester.tap(find.text('Salva (⌘S)'));
    await settle(tester, 1500);
    await shot(tester, '05b_after_save');
    final check = await OdbcSession.open('Driver=$sqliteOdbc;Database=${db.path}').timeout(const Duration(seconds: 20));
    final r = await check.execute('SELECT email FROM dipendenti WHERE id = 1').timeout(const Duration(seconds: 20));
    expect(r.rows.first.first, 'modificato@esempio.it');
    await check.close();

    // Constraints & DDL pages.
    await tester.tap(find.text('Chiavi').last);
    await settle(tester);
    await shot(tester, '06_table_constraints');
    await tester.tap(find.text('DDL').last);
    await settle(tester);
    await shot(tester, '07_table_ddl');

    // SQL editor.
    await tester.tap(find.byTooltip('Nuovo editor SQL (⌘N)').first);
    await settle(tester);
    final tab = state.tabs.whereType<SqlEditorTab>().last;
    tab.connection = state.connections.first;
    tab.controller.text =
        '-- Stipendio medio per reparto\n'
        'SELECT r.nome AS reparto, COUNT(*) AS dipendenti, ROUND(AVG(d.stipendio), 2) AS media\n'
        'FROM dipendenti d\n'
        'JOIN reparti r ON r.id = d.reparto_id\n'
        'GROUP BY r.nome\n'
        'ORDER BY media DESC;\n\n'
        'SELECT * FROM dipendenti WHERE stipendio > :minimo;\n';
    await settle(tester);
    await tester.tap(find.text('Esegui'));
    await waitFor(tester, find.text('Ricerca e Sviluppo'));
    await settle(tester);
    await shot(tester, '08_sql_results');

    // Sidebar: the toolbar button slides it away and back; the editor, its
    // results and the expanded navigator tree all survive.
    await tester.tap(find.byTooltip('Nascondi barra laterale (⌘0)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    await shot(tester, '08b_sidebar_sliding', settleFirst: false);
    await settle(tester, 400);
    await shot(tester, '08c_sidebar_hidden');
    expect(find.text('Ricerca e Sviluppo'), findsOneWidget);
    expect(find.text('v_dipendenti_reparto'), findsNothing);
    await tester.tap(find.byTooltip('Mostra barra laterale (⌘0)'));
    await settle(tester, 400);
    expect(find.text('v_dipendenti_reparto'), findsOneWidget);
    expect(find.text('Ricerca e Sviluppo'), findsOneWidget);
    expect(tab.controller.text, startsWith('-- Stipendio medio'));

    // Script execution (with an error and a parameter dialog).
    tab.controller.text =
        'UPDATE progetti SET budget = budget * 1.1 WHERE reparto_id = 1;\n'
        'SELECT * FROM tabella_inesistente;\n'
        'SELECT codice, titolo, budget FROM progetti;\n';
    await settle(tester, 300);
    await tester.tap(find.byTooltip('Esegui tutto lo script (⌥X)'));
    await waitFor(tester, find.text('Errore nello script'));
    await shot(tester, '09_script_error_prompt');
    await tester.tap(find.text('Continua'));
    await waitFor(tester, find.text('Statistiche'));
    await settle(tester);
    await shot(tester, '10_script_stats');

    // Record view of the current result.
    await tester.tap(find.text('progetti').last);
    await settle(tester, 300);
    await tester.tap(find.text('Record'));
    await settle(tester);
    await shot(tester, '10b_record_view');
    await tester.tap(find.text('Griglia'));
    await settle(tester, 300);

    // Export of the result set to the clipboard (CSV).
    await tester.tap(find.byTooltip('Esporta…').last);
    await waitFor(tester, find.text('Copia negli appunti'));
    await shot(tester, '10c_export_dialog');
    await tester.tap(find.text('Copia negli appunti'));
    await settle(tester, 1500);
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clip?.text, startsWith('codice,titolo,budget'));

    // Autocompletion provider (tables, keywords, columns through aliases).
    final ctx = tester.element(find.byType(CodeEditor));
    final pb = SqlPromptsBuilder(() => tab.connection, () => tab.controller.text, enabled: () => true);
    tab.controller.text = 'SELECT d. FROM dipendenti d';
    await settle(tester, 300);
    pb.build(
      ctx,
      const CodeLine('SELECT * FROM dip'),
      const CodeLineSelection.collapsed(index: 0, offset: 17),
    );
    pb.build(
      ctx,
      const CodeLine('SELECT d. FROM dipendenti d'),
      const CodeLineSelection.collapsed(index: 0, offset: 9),
    );
    await settle(tester, 1500);
    final tables = pb.build(
      ctx,
      const CodeLine('SELECT * FROM dip'),
      const CodeLineSelection.collapsed(index: 0, offset: 17),
    );
    expect(tables!.prompts.map((e) => e.word), contains('dipendenti'));
    final kw = pb.build(ctx, const CodeLine('sel'), const CodeLineSelection.collapsed(index: 0, offset: 3));
    expect(kw!.prompts.first.word, 'SELECT');
    final cols = pb.build(
      ctx,
      const CodeLine('SELECT d. FROM dipendenti d'),
      const CodeLineSelection.collapsed(index: 0, offset: 9),
    );
    expect(cols!.prompts.map((e) => e.word), containsAll(['nome', 'cognome', 'stipendio']));

    // Navigator context menu.
    await tester.tap(find.text('reparti').first, buttons: kSecondaryButton);
    await waitFor(tester, find.text('Genera DDL'));
    await shot(tester, '10e_context_menu');
    await tester.tap(find.text('Genera DDL'));
    await settle(tester, 1500);
    expect(
      state.tabs.whereType<SqlEditorTab>().any((t) => t.controller.text.contains('CREATE TABLE reparti')),
      isTrue,
    );

    // Query manager.
    await tester.tap(find.byTooltip('Query Manager (⌘⇧H)'));
    await waitFor(tester, find.text('Query Manager'));
    await settle(tester);
    await shot(tester, '10f_history');
    await tester.tap(find.byIcon(Icons.close).last);
    await settle(tester);

    // Autocomplete helper data & ER diagram.
    state.openErDiagram(state.connections.first, null, null);
    await waitFor(tester, find.textContaining('relazioni'));
    await settle(tester, 2500);
    await tester.tap(find.byTooltip('Disposizione automatica'));
    await settle(tester);
    await shot(tester, '11_er_diagram');

    // Connection dialog.
    await tester.tap(find.byTooltip('Nuova connessione').first);
    await waitFor(tester, find.text('Prova connessione'));
    await settle(tester, 1500);
    await shot(tester, '12_connection_dialog');
    await tester.tap(find.text('Produzione').last);
    final form = find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Avanzate'), 120, scrollable: form);
    await tester.tap(find.text('Avanzate'));
    await settle(tester, 400);
    await shot(tester, '12a_connection_production');
    await tester.scrollUntilVisible(find.text('Stringa risultante'), 120, scrollable: form);
    await settle(tester, 400);
    await shot(tester, '12b_connection_advanced');
    await tester.tap(find.text('Annulla').last);
    await settle(tester);

    // Preferences.
    showSettingsDialog(tester.element(find.byType(HomePage)));
    await waitFor(tester, find.text('Aspetto'));
    await settle(tester, 500);
    await shot(tester, '12c_settings');
    await tester.tap(find.byTooltip('Chiudi').last);
    await settle(tester);

    // Dark theme.
    state.settings.themeMode = ThemeMode.dark;
    await state.saveSettings();
    state.activate(state.tabs.whereType<SqlEditorTab>().last);
    await settle(tester);
    await shot(tester, '13_dark');

    await state.shutdown();
    await settle(tester, 300);
  });
}
