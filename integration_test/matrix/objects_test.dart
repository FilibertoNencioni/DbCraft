// Object editor, result grid, SQL editor tools and data transfer cases of the
// test matrix (OBJ, GRD-02/03/09/10, SQL-01/02/03/06/14/15, XFR-03/04).
//
//   flutter test integration_test/matrix/objects_test.dart -d macos \
//     --dart-define=TARGET=sqlite --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix
import 'dart:async';
import 'dart:io';

import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/ui/dialogs/import_dialog.dart';
import 'package:dbcraft/ui/editors/sql_code_editor.dart';
import 'package:dbcraft/ui/editors/sql_editor_view.dart';
import 'package:dbcraft/ui/editors/table_editor_view.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:dbcraft/ui/results/result_grid.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:re_editor/re_editor.dart';

import 'harness.dart';
import 'targets.dart';
import 'ui.dart';

/// Answers the macOS save panel of file_selector with [path].
void mockSavePanel(WidgetTester tester, String path) {
  const channel = 'dev.flutter.pigeon.file_selector_macos.FileSelectorApi.displaySavePanel';
  tester.binding.defaultBinaryMessenger.setMockMessageHandler(
    channel,
    (_) async => const StandardMessageCodec().encodeMessage(<Object?>[path]),
  );
}

void mockOpenPanel(WidgetTester tester, List<String> paths) {
  const channel = 'dev.flutter.pigeon.file_selector_macos.FileSelectorApi.displayOpenPanel';
  tester.binding.defaultBinaryMessenger.setMockMessageHandler(
    channel,
    (_) async => const StandardMessageCodec().encodeMessage(<Object?>[paths]),
  );
}

/// Text of every code editor on screen.
String codeText(WidgetTester tester) =>
    tester.widgetList<CodeEditor>(find.byType(CodeEditor)).map((w) => w.controller?.text ?? '').join('\n');

Finder gridText(String text) => find.descendant(of: find.byType(ResultGrid), matching: find.text(text));

Future<void> gridMenu(WidgetTester tester, String cell, List<String> path) async {
  await tester.tap(gridText(cell).first, buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
  await settle(tester, 600);
  for (final item in path) {
    final f = find.text(item);
    if (f.evaluate().isEmpty) throw TestFailure('voce "$item" non trovata nel menu della cella');
    await tester.tap(f.last);
    await settle(tester, 600);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('objects', (tester) async {
    final t = current;
    await t.prepare?.call();
    final app = await startApp(tester, connections: [t.connection()]);
    final dc = app.connections.first;
    BuildContext ctx() => tester.element(find.byType(HomePage));
    await app.connect(dc);
    await settle(tester, 1000);
    Future<dynamic> table(String name) async => (await dc.metadata!.findTable(null, null, name))!;

    // --- OBJ ---------------------------------------------------------------
    await check(tester, 'OBJ-01', () async {
      app.openTable(dc, await table('dipendenti'));
      await settle(tester, 2000);
      final tab = app.currentTab as TableEditorTab;
      final pages = ['Proprietà', 'Dati', 'Colonne', 'Vincoli', 'Indici', 'DDL', 'Diagramma', 'Permessi', 'Modifiche'];
      final missing = <String>[];
      for (final p in pages) {
        final f = find.descendant(of: find.byType(Scaffold).first, matching: find.text(p));
        if (f.evaluate().isEmpty) {
          missing.add(p);
          continue;
        }
        await tester.tap(f.last);
        await settle(tester, 1500);
        await shot(tester, 'obj01_${p.toLowerCase().replaceAll('à', 'a')}');
      }
      record('OBJ-01/pages', Outcome.ok, 'assenti: ${missing.join(', ')}');
      // Data page filter.
      await tester.tap(find.text('Dati').last);
      await settle(tester, 1500);
      final where = find.descendant(of: find.byType(TableEditorView), matching: find.byType(EditableText));
      await tester.enterText(where.at(0), 'stipendio > 4000');
      await tester.enterText(where.at(1), 'stipendio DESC');
      await tester.tap(find.text('Applica').last);
      await settle(tester, 2000);
      await shot(tester, 'obj01_filtered');
      final m = await waitModel(tester, tab);
      await m.fetchAll();
      final expected = await t.scalar('SELECT COUNT(*) FROM dipendenti WHERE stipendio > 4000');
      expect('${m.rows.length}', expected);
      final firsts = m.rows.take(3).map((r) => num.parse('${r.values[m.columns.indexWhere((c) => c.name == 'stipendio')]}')).toList();
      expect(firsts[0] >= firsts[1] && firsts[1] >= firsts[2], isTrue, reason: 'ORDER BY ignorato');
    });

    await check(tester, 'OBJ-02', () async {
      app.openTable(dc, await table('v_progetti_ore'));
      await settle(tester, 2000);
      for (final p in ['Dati', 'DDL', 'Definizione']) {
        final f = find.text(p);
        if (f.evaluate().isEmpty) {
          record('OBJ-02/$p', Outcome.defect, 'pagina assente');
          continue;
        }
        await tester.tap(f.last);
        await settle(tester, 1500);
        await shot(tester, 'obj02_view_${p.toLowerCase()}');
      }
      expect(codeText(tester).toUpperCase(), contains('SUM'), reason: 'definizione della vista non mostrata');
    });

    await check(tester, 'OBJ-03', () async {
      await openTablesFolder(tester, dc.config.name, t.navPath);
      if (nav('progetti').evaluate().isEmpty) await doubleTap(tester, nav('Tabelle').first);
      await waitFor(tester, nav('progetti'));
      await navExpand(tester, 'progetti');
      await navExpand(tester, 'Trigger');
      await shot(tester, 'obj03_trigger_node');
      await navMenu(tester, 'trg_progetti_upd', 'Modifica sorgente');
      await settle(tester, 1500);
      await shot(tester, 'obj03_trigger_source');
      expect(codeText(tester), contains('INSERT INTO audit'), reason: 'sorgente del trigger non letto');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 600);
      if (find.text('Annulla').evaluate().isNotEmpty) {
        await tester.tap(find.text('Annulla').last);
        await settle(tester, 600);
      }
    });

    // --- GRD ---------------------------------------------------------------
    late SqlEditorTab sel;
    await check(tester, 'GRD-02', () async {
      sel = await editor(tester, app, 'SELECT id, nome, cognome, stipendio FROM dipendenti ORDER BY id');
      await runEditor(tester, sel);
      final m = lastModel(sel);
      final stip = m.columns.indexWhere((c) => c.name == 'stipendio');
      m.sortBy(stip, ascending: false);
      await settle(tester, 500);
      await shot(tester, 'grd02_sorted');
      final top = num.parse('${m.rowAt(0).values[stip]}');
      final max = num.parse(await t.scalar('SELECT MAX(stipendio) FROM dipendenti WHERE id <= ${m.rows.length}'));
      expect(top, max);
      m.sortBy(null);
      m.setQuickFilter('Esposito');
      await settle(tester, 500);
      await shot(tester, 'grd02_quick_filter');
      expect(m.view.every((i) => m.rows[i].values.any((v) => '$v'.contains('Esposito'))), isTrue);
      expect(m.view, isNotEmpty);
      m.setQuickFilter('');
      await tester.tap(find.text('Record').last);
      await settle(tester, 800);
      await shot(tester, 'grd02_record');
      await tester.tap(find.text('Griglia').last);
      await settle(tester, 500);
    });

    await check(tester, 'GRD-03', () async {
      final m = lastModel(sel);
      final first = '${m.rowAt(0).values[1]}';
      final results = <String, String>{};
      for (final path in [
        ['Copia'],
        ['Copia con intestazioni'],
        ['Copia come', 'CSV'],
        ['Copia come', 'JSON'],
        ['Copia come', 'Markdown'],
        ['Copia come', 'SQL INSERT'],
      ]) {
        await Clipboard.setData(const ClipboardData(text: ''));
        await gridMenu(tester, first, path);
        results[path.join('/')] = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      }
      record('GRD-03/clipboard', Outcome.ok, results.entries.map((e) => '${e.key}=${e.value.replaceAll('\n', '⏎')}').join(' ‖ '));
      expect(results.values.where((v) => v.isEmpty), isEmpty, reason: 'una copia ha prodotto appunti vuoti');
      expect(results['Copia come/SQL INSERT'], contains('INSERT INTO'));
    });

    await check(tester, 'GRD-09', () async {
      final tab = await editor(tester, app, 'SELECT r.nome AS reparto, COUNT(*) AS n, AVG(d.stipendio) AS media FROM dipendenti d JOIN reparti r ON r.id = d.reparto_id GROUP BY r.nome');
      await runEditor(tester, tab);
      await tester.tap(find.text('Grafico').last);
      await settle(tester, 1500);
      await shot(tester, 'grd09_chart_default');
      final png = '$outDir/export/chart.png';
      Directory('$outDir/export').createSync(recursive: true);
      if (File(png).existsSync()) File(png).deleteSync();
      mockSavePanel(tester, png);
      await tester.tap(find.byTooltip('Esporta il grafico come PNG…').first);
      await settle(tester, 2500);
      expect(File(png).existsSync(), isTrue, reason: 'PNG non scritto');
      final bytes = File(png).readAsBytesSync();
      expect(bytes.sublist(1, 4), 'PNG'.codeUnits);
      await tester.tap(find.text('Griglia').last);
      await settle(tester, 500);
    });

    await check(tester, 'GRD-10', () async {
      final tab = await editor(tester, app, 'SELECT id, bin, testo FROM tipi WHERE id IN (5, 6) ORDER BY id');
      final sw = Stopwatch()..start();
      await runEditor(tester, tab);
      record('GRD-10/query', Outcome.ok, '${sw.elapsedMilliseconds} ms per BLOB 5 MB + testo 1 MB');
      await shot(tester, 'grd10_big_values');
      final m = lastModel(tab);
      final bin = m.rows[0].values[1];
      final text = m.rows[1].values[2];
      record('GRD-10/sizes', Outcome.ok, 'bin=${bin is List ? bin.length : bin.runtimeType} testo=${'$text'.length}');
      expect(bin is List && bin.length == 5242880, isTrue, reason: 'BLOB letto parzialmente: ${bin is List ? bin.length : bin}');
      expect('$text'.length, 1048576, reason: 'testo letto parzialmente');
      // The value editor opens on the big text.
      final sw2 = Stopwatch()..start();
      await tester.tap(find.descendant(of: find.byType(ResultGrid), matching: find.textContaining('abab')).first,
          buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await settle(tester, 600);
      sw2.reset();
      await tester.tap(find.text('Visualizza / modifica valore…').last);
      await tester.pump();
      while (find.textContaining('1048576 caratteri').evaluate().isEmpty && sw2.elapsed.inSeconds < 60) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final open = sw2.elapsedMilliseconds;
      final frames = <int>[];
      for (var i = 0; i < 5; i++) {
        final f = Stopwatch()..start();
        await tester.pump(const Duration(milliseconds: 16));
        frames.add(f.elapsedMilliseconds);
      }
      // Typing one character in the editor.
      final ft = Stopwatch()..start();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      final typing = ft.elapsedMilliseconds;
      final slow = open > 3000 || frames.any((f) => f > 500) || typing > 500;
      record('GRD-10/editor', slow ? Outcome.defect : Outcome.ok, 'apertura $open ms · fotogrammi ${frames.join('/')} ms · tasto $typing ms (testo 1 MB)');
      await shot(tester, 'grd10_value_editor');
      record('GRD-10/editable', Outcome.ok, 'risultato modificabile: ${m.isEditable} (chiave ${m.keyColumns})');
      for (final b in ['Annulla', 'Fine']) {
        if (find.text(b).evaluate().isNotEmpty) {
          await tester.tap(find.text(b).last, warnIfMissed: false);
          break;
        }
      }
      await settle(tester, 600);
    });

    // --- SQL editor tools ----------------------------------------------------
    await check(tester, 'SQL-02', () async {
      final tab = await editor(tester, app, 'SELECT d. FROM dipendenti d');
      final pb = SqlPromptsBuilder(() => tab.connection, () => tab.controller.text, enabled: () => true);
      final c = tester.element(find.byType(CodeEditor).last);
      // First calls warm the metadata cache.
      for (var i = 0; i < 3; i++) {
        pb.build(c, const CodeLine('SELECT * FROM dip'), const CodeLineSelection.collapsed(index: 0, offset: 17));
        pb.build(c, const CodeLine('SELECT d. FROM dipendenti d'), const CodeLineSelection.collapsed(index: 0, offset: 9));
        pb.build(c, const CodeLine('SELECT * FROM "Tab'), const CodeLineSelection.collapsed(index: 0, offset: 18));
        await settle(tester, 1000);
      }
      final tables = pb.build(c, const CodeLine('SELECT * FROM dip'), const CodeLineSelection.collapsed(index: 0, offset: 17));
      final cols = pb.build(c, const CodeLine('SELECT d. FROM dipendenti d'), const CodeLineSelection.collapsed(index: 0, offset: 9));
      final kw = pb.build(c, const CodeLine('sel'), const CodeLineSelection.collapsed(index: 0, offset: 3));
      final strange = pb.build(c, const CodeLine('SELECT * FROM Tab'), const CodeLineSelection.collapsed(index: 0, offset: 17));
      record('SQL-02/strana', Outcome.ok, strange?.prompts.map((e) => e.word).take(5).join(', ') ?? 'nessun suggerimento');
      expect(tables?.prompts.map((e) => e.word), contains('dipendenti'));
      expect(cols?.prompts.map((e) => e.word), containsAll(['nome', 'cognome', 'stipendio']));
      expect(kw?.prompts.first.word, 'SELECT');
    });

    await check(tester, 'SQL-03', () async {
      const ugly = "select d.nome,r.nome as reparto from dipendenti d join reparti r on r.id=d.reparto_id where d.stipendio>3000 and r.nome like 'R%' order by 1";
      final tab = await editor(tester, app, ugly);
      SqlEditorView.dispatch(tab, SqlCommand.format);
      await settle(tester, 800);
      await shot(tester, 'sql03_formatted');
      final formatted = tab.controller.text;
      record('SQL-03/format', Outcome.ok, formatted.replaceAll('\n', '⏎'));
      expect(formatted, isNot(ugly));
      expect(formatted.contains("'R%'"), isTrue, reason: 'letterale alterato dalla formattazione');
      await runEditor(tester, tab);
      expect(tab.results.last.error, isNull, reason: 'lo SQL formattato non è più valido: ${tab.results.last.error}');
      final n = await t.scalar("SELECT COUNT(*) FROM dipendenti d JOIN reparti r ON r.id = d.reparto_id WHERE d.stipendio > 3000 AND r.nome LIKE 'R%'");
      expect('${lastModel(tab).rows.length}', n);
      // Find and replace bar.
      SqlEditorView.dispatch(tab, SqlCommand.find);
      await settle(tester, 800);
      await shot(tester, 'sql03_find');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 400);
    });

    await check(tester, 'SQL-06', () async {
      final tab = await editor(tester, app, t.scriptWithBlocks);
      var prompted = false;
      await runEditor(tester, tab, onDialog: () async {
        if (find.text('Errore nello script').evaluate().isNotEmpty) {
          prompted = true;
          await shot(tester, 'sql06_error');
          await tester.tap(find.text('Annulla').last, warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 300));
        }
      });
      await shot(tester, 'sql06_blocks');
      final errors = tab.results.where((r) => r.error != null).map((r) => r.error).toList();
      expect(prompted, isFalse, reason: 'blocco procedurale spezzato: $errors');
      expect(errors, isEmpty);
      expect(await t.scalar(t.scriptCheck), '1');
    });

    if (t.scriptDelimiter != null) {
      await check(tester, 'SQL-06b', () async {
        final tab = await editor(tester, app, t.scriptDelimiter!);
        await runEditor(tester, tab, onDialog: () async {
          if (find.text('Errore nello script').evaluate().isNotEmpty) {
            await tester.tap(find.text('Annulla').last, warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 300));
          }
        });
        await shot(tester, 'sql06b_delimiter');
        final errors = tab.results.where((r) => r.error != null).map((r) => r.error).toList();
        expect(errors, isEmpty, reason: 'DELIMITER non gestito');
      });
    }

    await check(tester, 'SQL-14', () async {
      final tab = await editor(tester, app, '-- script persistente\nSELECT 42;');
      await settle(tester, 2500);
      final file = tab.file;
      record('SQL-14/file', Outcome.ok, '${file?.path}');
      expect(file, isNotNull, reason: 'script non salvato nel workspace');
      tab.controller.text = '-- modificato\nSELECT 43;';
      await settle(tester, 3000);
      expect(file!.readAsStringSync(), contains('SELECT 43'), reason: 'salvataggio automatico non avvenuto');
      await tester.tap(find.byTooltip('Script').first);
      await settle(tester, 1000);
      await shot(tester, 'sql14_scripts_panel');
      await tester.tap(find.byTooltip('Database').first);
      await settle(tester, 500);
    });

    await check(tester, 'SQL-15', () async {
      final tab = await editor(tester, app, 'SELECT id, nome FROM reparti WHERE id < 3');
      app.openNewView(dc, definition: tab.controller.text);
      await settle(tester, 2000);
      await shot(tester, 'sql15_new_view');
      expect(app.currentTab, isA<TableEditorTab>());
    });

    // --- XFR -----------------------------------------------------------------
    await check(tester, 'XFR-03', () async {
      final csv = File('$outDir/export/import.csv');
      csv.parent.createSync(recursive: true);
      csv.writeAsStringSync(
        'Id,order,select,colonna con spazi,MaiuscoleMinuscole,città,punto.nel.nome\n'
        '10,"con, virgola",1,"con ""virgolette""",x,Forlì,a\n'
        '11,riga due,,vuoto=NULL,y,"multi\nriga",b\n'
        '12,emoji 😀,3,c,z,東京,c\n',
      );
      unawaited(showImportDialog(ctx(), dc, await table('Tabella Strana'), initialPath: csv.path));
      await settle(tester, 2000);
      await shot(tester, 'xfr03_import_dialog');
      await tester.tap(find.text('Importa').last);
      await settle(tester, 3000);
      await shot(tester, 'xfr03_imported');
      final q = t.quoteIdent;
      final rows = await t.query('SELECT ${q('Id')}, ${q('order')}, ${q('select')}, ${q('città')} FROM ${q('Tabella Strana')} WHERE ${q('Id')} >= 10 ORDER BY ${q('Id')}');
      record('XFR-03/rows', Outcome.ok, rows.map((r) => r.join('|')).join(' ‖ '));
      expect(await t.scalar('SELECT COUNT(*) FROM ${q('Tabella Strana')} WHERE ${q('Id')} >= 10'), '3');
      expect(rows[0][1], 'con, virgola');
      expect(rows.last[1], 'emoji 😀');
      expect(rows.last[3], '東京');
    });

    await check(tester, 'XFR-03b', () async {
      // 10.000 rows: speed of the row by row import.
      final csv = File('$outDir/export/import_big.csv');
      final b = StringBuffer('id,gruppo,testo,importo,creato\n');
      for (var i = 300001; i <= 310000; i++) {
        b.writeln('$i,${i % 7},import $i,${(i % 1000) / 10},2024-01-01 00:00:00');
      }
      csv.writeAsStringSync(b.toString());
      unawaited(showImportDialog(ctx(), dc, await table('grande'), initialPath: csv.path));
      await settle(tester, 2000);
      final sw = Stopwatch()..start();
      await tester.tap(find.text('Importa').last);
      while (find.text('Importa CSV in grande').evaluate().isNotEmpty && sw.elapsed.inSeconds < 300) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      record('XFR-03b/time', Outcome.ok, '${sw.elapsedMilliseconds} ms per 10.000 righe');
      expect(await t.scalar('SELECT COUNT(*) FROM grande WHERE id > 300000'), '10000');
    });

    // ROB-03: identifiers that need quoting, through the SQL editor.
    await check(tester, 'ROB-03', () async {
      final q = dc.dialect.quoteIdent;
      final stmts = {
        'select città': 'SELECT ${q('città')} FROM ${q('Tabella Strana')}',
        'select punto': 'SELECT ${q('punto.nel.nome')} FROM ${q('Tabella Strana')}',
        'select riservate': 'SELECT ${q('order')}, ${q('select')} FROM ${q('Tabella Strana')}',
        'update città': "UPDATE ${q('Tabella Strana')} SET ${q('città')} = 'Città' WHERE ${q('Id')} = 1",
        'insert città': "INSERT INTO ${q('Tabella Strana')} (${q('Id')}, ${q('città')}) VALUES (77, 'x')",
        'insert città param': "INSERT INTO ${q('Tabella Strana')} (${q('Id')}, ${q('città')}) VALUES (78, ?)",
      };
      // How a non-ASCII literal reaches the server.
      final enc = await dc.main!.execute(t.encodingProbe);
      record('ROB-03/encoding', Outcome.ok, "${t.encodingProbe} → ${enc.rows.first.join(' | ')}");
      final failures = <String>[];
      for (final MapEntry(key: name, value: sql) in stmts.entries) {
        try {
          await dc.main!.execute(sql, params: sql.contains('?') ? ['y'] : const []);
          record('ROB-03/$name', Outcome.ok, sql);
        } catch (e) {
          failures.add('$name: $e');
          record('ROB-03/$name', Outcome.defect, '$sql → $e');
        }
      }
      expect(failures, isEmpty);
    });

    await finish(tester, app);
  });
}
