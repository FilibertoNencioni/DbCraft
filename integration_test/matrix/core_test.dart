// Core cases of the test matrix (docs/test-plan.md §6): connection, navigator,
// SQL editor, result grid, data editing, object editor and data transfer, on
// the real app against one target.
//
//   flutter test integration_test/matrix/core_test.dart -d macos \
//     --dart-define=TARGET=sqlite --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix
import 'dart:convert';
import 'dart:io';

import 'package:dbcraft/services/data_transfer.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/ui/dialogs/export_dialog.dart' show streamQuery;
import 'package:dbcraft/ui/editors/sql_editor_view.dart';
import 'package:dbcraft/ui/navigator/navigator_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness.dart';
import 'ui.dart';
import 'targets.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('core', (tester) async {
    final t = current;
    await t.prepare?.call();
    final app = await startApp(tester, connections: [t.connection()]);
    final dc = app.connections.first;
    await shot(tester, '00_home');

    // --- CON ---------------------------------------------------------------
    await check(tester, 'CON-01', () async {
      await openTablesFolder(tester, dc.config.name, t.navPath);
      expect(dc.isConnected, isTrue);
      record('CON-01/dialect', Outcome.ok, '${dc.dialect.family.name} · ${dc.dialect.dbmsName} · ${dc.dialect.dbmsVersion}');
      await shot(tester, 'con01_connected');
      app.openConnectionInfo(dc);
      await settle(tester, 2000);
      await shot(tester, 'con01_info');
    });
    if (!dc.isConnected) return;

    // --- NAV ---------------------------------------------------------------
    const seedTables = ['dipendenti', 'reparti', 'progetti', 'assegnazioni', 'tipi', 'Tabella Strana', 'senza_pk', 'solo_unique', 'grande', 'audit', 'con_check'];
    await check(tester, 'NAV-01', () async {
      await doubleTap(tester, nav('Tabelle').first);
      await waitFor(tester, nav('dipendenti'), seconds: 20);
      final missing = [for (final n in seedTables) if (nav(n).evaluate().isEmpty) n];
      await doubleTap(tester, nav('Viste').first);
      await waitFor(tester, nav('v_dipendenti_reparto'));
      if (nav('v_progetti_ore').evaluate().isEmpty) missing.add('v_progetti_ore');
      await shot(tester, 'nav01_tree');
      // Children of a table with every part.
      await navExpand(tester, 'dipendenti');
      for (final part in ['Colonne', 'Chiavi', 'Chiavi esterne', 'Riferimenti', 'Indici']) {
        if (nav(part).evaluate().isEmpty) missing.add('dipendenti/$part');
      }
      await navExpand(tester, 'Colonne');
      await shot(tester, 'nav01_table_children');
      for (final c in ['nome', 'cognome', 'stipendio', 'reparto_id']) {
        if (nav(c).evaluate().isEmpty && find.descendant(of: find.byType(NavigatorPanel), matching: find.textContaining(c)).evaluate().isEmpty) {
          missing.add('colonna $c');
        }
      }
      await navExpand(tester, 'dipendenti');
      expect(missing, isEmpty, reason: 'oggetti mancanti nel navigator');
    });

    await check(tester, 'NAV-03', () async {
      final filter = find.descendant(of: find.byType(NavigatorPanel), matching: find.byType(EditableText)).first;
      await tester.enterText(filter, 'strana');
      await settle(tester, 1200);
      await shot(tester, 'nav03_filter');
      expect(nav('Tabella Strana'), findsWidgets);
      expect(nav('dipendenti'), findsNothing);
      await tester.enterText(filter, 'città');
      await settle(tester, 1200);
      await shot(tester, 'nav03_filter_unicode');
      await tester.enterText(filter, '');
      await settle(tester, 1200);
      expect(nav('dipendenti'), findsWidgets);
    });

    await check(tester, 'NAV-05', () async {
      await tester.tap(nav('Tabella Strana').first, buttons: kSecondaryButton);
      await settle(tester, 800);
      await shot(tester, 'nav05_table_menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 400);
      await tester.tap(nav('Tabelle').first, buttons: kSecondaryButton);
      await settle(tester, 800);
      await shot(tester, 'nav05_folder_menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 400);
      await tester.tap(nav(dc.config.name).first, buttons: kSecondaryButton);
      await settle(tester, 800);
      await shot(tester, 'nav05_connection_menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 400);
    });

    // --- SQL ---------------------------------------------------------------
    await check(tester, 'SQL-04', () async {
      final tab = await editor(tester, app, 'SELECT r.nome, COUNT(*) AS n FROM dipendenti d JOIN reparti r ON r.id = d.reparto_id GROUP BY r.nome ORDER BY r.nome');
      await runEditor(tester, tab);
      await shot(tester, 'sql04_select');
      final m = lastModel(tab);
      expect(m.rows.length, 4);
      final l3 = await t.query('SELECT COUNT(*) FROM dipendenti');
      expect(m.rows.fold<int>(0, (s, r) => s + int.parse('${r.values[1]}')), int.parse(l3.first.first.trim()));
    });

    await check(tester, 'SQL-05', () async {
      final tab = await editor(
        tester,
        app,
        'UPDATE progetti SET budget = budget + 1 WHERE codice = \'CAS-01\';\n'
        '${t.badSql};\n'
        'SELECT codice, budget FROM progetti ORDER BY codice;\n',
      );
      var prompted = false;
      await runEditor(tester, tab, onDialog: () async {
        if (find.text('Errore nello script').evaluate().isNotEmpty) {
          prompted = true;
          await shot(tester, 'sql05_error_prompt');
          await tester.tap(find.text('Continua').last);
          await tester.pump(const Duration(milliseconds: 300));
        }
      });
      await shot(tester, 'sql05_stats');
      expect(prompted, isTrue, reason: 'nessuna richiesta dopo l\'errore');
      final stats = tab.results.lastWhere((r) => r.stats != null).stats!;
      expect(stats['Errori'], '1');
      expect(stats['Query eseguite'], '2 / 3');
      expect(await t.scalar("SELECT budget FROM progetti WHERE codice = 'CAS-01'"), anyOf('120001', '120001.0', '120001.00'));
    });

    await check(tester, 'SQL-07', () async {
      final tab = await editor(tester, app, t.paramSql);
      await runEditor(tester, tab, onDialog: () async {
        if (find.text('Parametri della query').evaluate().isNotEmpty) {
          final fields = find.descendant(of: find.byType(Dialog).hitTestable(), matching: find.byType(EditableText));
          final f = fields.evaluate().isNotEmpty ? fields : find.byType(EditableText);
          await shot(tester, 'sql07_params');
          // The last two fields of the screen belong to the parameter sheet.
          final all = f.evaluate().toList();
          await tester.enterText(find.byWidget(all[all.length - 2].widget), '3000');
          await tester.enterText(find.byWidget(all.last.widget), '2');
          await tester.pump(const Duration(milliseconds: 200));
          await tester.tap(find.text('Esegui').last);
          await tester.pump(const Duration(milliseconds: 300));
        }
      });
      await shot(tester, 'sql07_result');
      final expected = await t.scalar('SELECT COUNT(*) FROM dipendenti WHERE stipendio > 3000 AND reparto_id = 2');
      expect('${lastModel(tab).rows.length}', expected);
    });

    await check(tester, 'SQL-12', () async {
      final tab = await editor(tester, app, 'SELEC * FRM dipendenti');
      await runEditor(tester, tab);
      await shot(tester, 'sql12_syntax_error');
      final err = tab.results.last.error;
      expect(err, isNotNull);
      record('SQL-12/message', Outcome.ok, err!);
    });

    if (t.printSql != null) {
      await check(tester, 'SQL-09', () async {
        final tab = await editor(tester, app, t.printSql!);
        await runEditor(tester, tab);
        await shot(tester, 'sql09_output');
        expect(tab.serverOutput.join('\n'), contains('ciao dal server'));
      });
    } else {
      record('SQL-09', Outcome.notApplicable, 'il DBMS non ha messaggi del server');
    }

    if (t.multiResultSql != null) {
      await check(tester, 'SQL-10', () async {
        final tab = await editor(tester, app, t.multiResultSql!);
        await runEditor(tester, tab);
        await shot(tester, 'sql10_multi');
        expect(tab.results.where((r) => r.model != null).length, 2);
      });
    } else {
      record('SQL-10', Outcome.notApplicable, 'il DBMS non restituisce più result set');
    }

    await check(tester, 'SQL-11', () async {
      final tab = await editor(tester, app, 'SELECT * FROM dipendenti d JOIN reparti r ON r.id = d.reparto_id WHERE d.stipendio > 3000');
      SqlEditorView.dispatch(tab, SqlCommand.explain);
      for (var i = 0; i < 100 && (tab.running || tab.results.isEmpty); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await settle(tester, 800);
      await shot(tester, 'sql11_explain');
      expect(tab.results.any((r) => r.model != null), isTrue, reason: tab.results.map((r) => r.error).join());
    });

    await check(tester, 'SQL-13', () async {
      await tester.tap(find.byTooltip('Query Manager (⇧⌘H)'));
      await waitFor(tester, find.text('Query Manager'));
      await settle(tester, 800);
      await shot(tester, 'sql13_history');
      expect(app.history.any((h) => h.sql.contains('SELEC * FRM')), isTrue);
      await tester.tap(find.text('Fine').last);
      await settle(tester);
    });

    await check(tester, 'SQL-17', () async {
      for (final item in ['Genera SELECT', 'Genera INSERT', 'Genera UPDATE', 'Genera DELETE', 'Genera DDL']) {
        await navMenu(tester, 'Tabella Strana', item);
        await settle(tester, 1000);
      }
      await shot(tester, 'sql17_generated');
      final tab = app.currentTab as SqlEditorTab;
      record('SQL-17/ddl', Outcome.ok, tab.controller.text);
      // SELECT must run as generated.
      final sel = app.tabs.whereType<SqlEditorTab>().firstWhere((e) => e.controller.text.trimLeft().toUpperCase().startsWith('SELECT') && e.controller.text.contains('Strana'));
      app.activate(sel);
      await settle(tester);
      await runEditor(tester, sel);
      expect(sel.results.last.error, isNull, reason: sel.results.last.error);
      expect(lastModel(sel).rows.length, 2);
    });

    // --- GRD ---------------------------------------------------------------
    await check(tester, 'GRD-04', () async {
      final tab = await editor(tester, app, 'SELECT * FROM tipi ORDER BY id');
      await runEditor(tester, tab);
      await shot(tester, 'grd04_types');
      final m = lastModel(tab);
      final cli = await t.query('SELECT id, i_big, dec_38 FROM tipi ORDER BY id');
      final col = {for (var i = 0; i < m.columns.length; i++) m.columns[i].name.toLowerCase(): i};
      final diffs = <String>[];
      for (var r = 0; r < cli.length; r++) {
        final row = m.rows[r].values;
        for (final (name, idx) in [('i_big', 1), ('dec_38', 2)]) {
          final app = '${row[col[name]!] ?? ''}';
          final srv = cli[r][idx];
          if (num.tryParse(app) != num.tryParse(srv) || (app.contains('.') && srv.contains('.') && app.replaceAll(RegExp(r'0+$'), '') != srv.replaceAll(RegExp(r'0+$'), ''))) {
            diffs.add('riga ${r + 1} $name: app=$app server=$srv');
          }
        }
      }
      final unicode = '${m.rows[1].values[col['testo']!]}';
      if (!unicode.contains('😀👍🏽') || !unicode.contains('שלום')) diffs.add('Unicode alterato: $unicode');
      expect(diffs, isEmpty);
    });

    await check(tester, 'GRD-01', () async {
      final table = (await dc.metadata!.findTable(null, null, 'grande'))!;
      app.openTable(dc, table, page: 1);
      final tab = app.currentTab as TableEditorTab;
      final m = await waitModel(tester, tab);
      await shot(tester, 'grd01_first_page');
      final first = m.rows.length;
      await m.fetchNext();
      await settle(tester, 500);
      expect(m.rows.length, greaterThan(first));
      final sw = Stopwatch()..start();
      await m.fetchAll();
      await settle(tester, 500);
      await shot(tester, 'grd01_all');
      expect(m.rows.length, 200000);
      final ids = m.rows.map((r) => r.values.first).toSet();
      expect(ids.length, 200000, reason: 'righe duplicate');
      record('GRD-01/fetchAll', Outcome.ok, '${sw.elapsedMilliseconds} ms per 200k righe');
    });

    await check(tester, 'GRD-05', () async {
      final table = (await dc.metadata!.findTable(null, null, 'Tabella Strana'))!;
      app.openTable(dc, table, page: 1);
      final tab = app.currentTab as TableEditorTab;
      final m = await waitModel(tester, tab);
      expect(m.isEditable, isTrue, reason: 'tabella con PK non modificabile');
      final col = m.columns.indexWhere((c) => c.name == 'colonna con spazi');
      m.setValue(0, col, 'modificato ✓');
      final nr = m.addRow();
      m.setValue(nr, 0, 3);
      m.setValue(nr, m.columns.indexWhere((c) => c.name == 'order'), 'terzo');
      m.toggleDelete([1]);
      await settle(tester, 500);
      await shot(tester, 'grd05_pending');
      await m.saveChanges();
      await settle(tester, 800);
      await shot(tester, 'grd05_saved');
      final q = t.quoteIdent;
      final rows = await t.query('SELECT ${q('Id')}, ${q('colonna con spazi')}, ${q('order')} FROM ${q('Tabella Strana')} ORDER BY ${q('Id')}');
      expect(rows.map((r) => r.first).toList(), ['1', '3']);
      expect(rows.first[1], 'modificato ✓');
    });

    await check(tester, 'GRD-07', () async {
      final table = (await dc.metadata!.findTable(null, null, 'senza_pk'))!;
      app.openTable(dc, table, page: 1);
      final m = await waitModel(tester, app.currentTab as TableEditorTab);
      await shot(tester, 'grd07_no_pk');
      record('GRD-07/no_pk', Outcome.ok, 'modificabile=${m.isEditable} chiave=${m.keyColumns} virtuale=${m.keyIsVirtual}');
      if (!m.isEditable) return;
      // A row that has a twin: the save must refuse and change nothing.
      final codice = m.columns.indexWhere((c) => c.name == 'codice');
      final valore = m.columns.indexWhere((c) => c.name == 'valore');
      final twin = [for (var i = 0; i < m.view.length; i++) if (m.rowAt(i).values[codice] == 'b') i].first;
      m.setValue(twin, valore, 20);
      Object? error;
      try {
        await m.saveChanges();
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: 'modifica di una riga duplicata accettata');
      expect(await t.scalar("SELECT COUNT(*) FROM senza_pk WHERE valore = 2"), '2');
      m.cancelChanges();
      // A unique row: the save succeeds and touches one row.
      final single = [for (var i = 0; i < m.view.length; i++) if (m.rowAt(i).values[codice] == 'a') i].first;
      m.setValue(single, valore, 11);
      await m.saveChanges();
      expect(await t.scalar("SELECT valore FROM senza_pk WHERE codice = 'a'"), '11');
    });

    await check(tester, 'GRD-08', () async {
      final table = (await dc.metadata!.findTable(null, null, 'con_check'))!;
      app.openTable(dc, table, page: 1);
      final m = await waitModel(tester, app.currentTab as TableEditorTab);
      final eta = m.columns.indexWhere((c) => c.name == 'eta');
      m.setValue(0, eta, 31);
      m.setValue(1, eta, 999); // violates the CHECK
      Object? error;
      try {
        await m.saveChanges();
      } catch (e) {
        error = e;
      }
      await settle(tester, 800);
      await shot(tester, 'grd08_violation');
      expect(error, isNotNull, reason: 'nessun errore sulla violazione del CHECK');
      expect(await t.scalar('SELECT eta FROM con_check WHERE id = 1'), '30', reason: 'salvataggio non annullato per intero');
      expect(m.isDirty, isTrue, reason: 'modifiche perse dopo l\'errore');
      m.cancelChanges();
    });

    // --- XFR ---------------------------------------------------------------
    await check(tester, 'XFR-01', () async {
      final dir = Directory('$outDir/export')..createSync(recursive: true);
      final cols = ['id', 'i_big', 'dec_38', 'testo', 'bin', 'nota'];
      final page = await dc.main!.execute('SELECT ${cols.join(', ')} FROM tipi WHERE id <> 5 ORDER BY id', fetchSize: 100);
      final problems = <String>[];
      for (final f in ExportFormat.values) {
        final o = ExportOptions(tableName: 'tipi', dialect: dc.dialect)..format = f;
        final file = File('${dir.path}/tipi.${f.extension}');
        await DataExporter.exportToFile(file, cols, Stream.value(page.rows), o);
        final text = file.readAsStringSync();
        if (!text.contains('😀')) problems.add('${f.name}: emoji persa');
        if (f == ExportFormat.json) {
          try {
            final j = jsonDecode(text);
            if ((j as List).length != page.rows.length) problems.add('json: righe ${j.length}');
          } catch (e) {
            problems.add('json non valido: $e');
          }
        }
        if (f == ExportFormat.csv) {
          final parsed = parseCsv(text);
          if (parsed.length != page.rows.length + 1) problems.add('csv: ${parsed.length} righe');
        }
      }
      // XML well-formedness through python.
      final xml = await Process.run('python3', ['-I', '-c', 'import sys,xml.dom.minidom;xml.dom.minidom.parse(sys.argv[1])', '${dir.path}/tipi.xml']);
      if (xml.exitCode != 0) problems.add('xml non valido: ${xml.stderr}');
      expect(problems, isEmpty);
    });

    await check(tester, 'XFR-02', () async {
      final table = (await dc.metadata!.findTable(null, null, 'grande'))!;
      final file = File('$outDir/export/grande.csv');
      final o = ExportOptions(tableName: 'grande', dialect: dc.dialect)..format = ExportFormat.csv;
      final sw = Stopwatch()..start();
      final n = await DataExporter.exportToFile(file, ['id', 'gruppo', 'testo', 'importo', 'creato'], streamQuery(dc, 'SELECT * FROM ${dc.dialect.tableName(table)}', const []), o);
      expect(n, 200000);
      final lines = file.readAsLinesSync().length;
      expect(lines, 200001);
      record('XFR-02/time', Outcome.ok, '${sw.elapsedMilliseconds} ms, ${file.lengthSync()} byte');
    });

    await shot(tester, '99_end');
    // Last: on some drivers cancelling crashes the app (D-006).
    if (t.sleepSql != null) {
      await check(tester, 'SQL-08', () async {
        final tab = await editor(tester, app, t.sleepSql!);
        final button = find.descendant(of: find.byType(SqlEditorView), matching: find.text('Esegui'));
        await tester.tap(button.first);
        await settle(tester, 2000);
        expect(tab.running, isTrue);
        await shot(tester, 'sql08_running');
        final sw = Stopwatch()..start();
        await tester.tap(find.text('Interrompi').first);
        while (tab.running && sw.elapsed.inSeconds < 25) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await shot(tester, 'sql08_cancelled');
        expect(tab.running, isFalse, reason: 'query non interrotta');
        record('SQL-08/latency', Outcome.ok, '${sw.elapsedMilliseconds} ms');
      });
    } else {
      record('SQL-08', Outcome.notApplicable, 'nessuna funzione di attesa nel DBMS');
    }

    await finish(tester, app);
  });
}
