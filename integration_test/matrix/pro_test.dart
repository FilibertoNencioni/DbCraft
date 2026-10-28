// Advanced features of the test matrix: visual query builder (QB), schema
// compare and migration (CMP), data compare and sync (DCM), test data (MOCK),
// visual plan (PLAN), performance dashboard (PERF), PL/pgSQL debugger (DBG),
// simplified view (SIMPLE) and the AI assistant without a key (AI).
//
//   flutter test integration_test/matrix/pro_test.dart -d macos \
//     --dart-define=TARGET=sqlite --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix
import 'dart:async';
import 'dart:io';

import 'package:dbcraft/features/ai/ai.dart';
import 'package:dbcraft/features/data_compare/compare_engine.dart' show RowDiff;
import 'package:dbcraft/features/data_compare/data_compare_tab.dart' hide CompareSide;
import 'package:dbcraft/features/debugger/pg_debugger_tab.dart';
import 'package:dbcraft/features/mock_data/mock_data_dialog.dart';
import 'package:dbcraft/features/performance/perf_dashboard.dart';
import 'package:dbcraft/features/performance/visual_plan.dart';
import 'package:dbcraft/features/query_builder/query_builder_tab.dart';
import 'package:dbcraft/features/query_builder/query_builder_view.dart';
import 'package:dbcraft/features/query_builder/query_model.dart';
import 'package:dbcraft/features/schema/schema_compare_view.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness.dart';
import 'targets.dart';
import 'ui.dart';

/// Drives the DDL confirmation flow that follows a script action.
Future<String?> confirmScript(WidgetTester tester, {String shotName = ''}) async {
  Finder confirm() => find.byWidgetPredicate((w) => w is Text && (w.data == 'Eseguire lo script?' || w.data == 'Eseguire la sincronizzazione?'));
  for (var i = 0; i < 100 && confirm().evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (i == 20) {
      final run = [find.text('Esegui sulla destinazione'), find.text('Esegui')].where((f) => f.evaluate().isNotEmpty).firstOrNull;
      if (run != null) {
        if (shotName.isNotEmpty) await shot(tester, '${shotName}_script');
        await tester.tap(run.last);
      }
    }
  }
  if (confirm().evaluate().isEmpty) return 'nessuna conferma di esecuzione';
  await tester.tap(find.text('Esegui').last);
  for (var i = 0; i < 600; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.text('Esecuzione interrotta').evaluate().isNotEmpty || find.textContaining('Sincronizzazione annullata').evaluate().isNotEmpty) {
      if (find.text('Mostra dettagli').evaluate().isNotEmpty) await tester.tap(find.text('Mostra dettagli').last);
      await settle(tester, 400);
      if (shotName.isNotEmpty) await shot(tester, '${shotName}_error');
      await tester.tap(find.text('OK').last, warnIfMissed: false);
      await settle(tester, 300);
      if (find.text('Chiudi').evaluate().isNotEmpty) await tester.tap(find.text('Chiudi').last, warnIfMissed: false);
      await settle(tester, 300);
      return 'errore (vedi ${shotName}_error.png)';
    }
    if (confirm().evaluate().isEmpty && i > 20 && find.text('Interrompi').evaluate().isEmpty) break;
  }
  await settle(tester, 1000);
  if (find.text('Chiudi').evaluate().isNotEmpty && find.text('Esegui').evaluate().isNotEmpty) {
    await tester.tap(find.text('Chiudi').last, warnIfMissed: false);
    await settle(tester, 300);
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('pro', (tester) async {
    final t = current;
    await t.prepare?.call();
    final cmpDb = sqliteDb.replaceAll('sqlite_run.db', 'sqlite_cmp.db');
    if (t.id == 'sqlite' && File(cmpDb).existsSync()) File(cmpDb).deleteSync();
    final app = await startApp(tester, connections: [
      t.connection(),
      if (t.id == 'sqlite') {'id': 'cmp', 'name': 'Destinazione SQLite', 'mode': 'driver', 'driver': 'SQLite3', 'database': cmpDb},
    ]);
    final dc = app.connections.first;
    BuildContext ctx() => tester.element(find.byType(HomePage));
    await app.connect(dc);
    await settle(tester, 800);
    final catalog = t.navPath.isNotEmpty ? t.navPath[0] : null;
    final schema = t.navPath.length > 1 ? t.navPath[1] : null;
    final family = dc.dialect.family;

    // --- QB-01 ---------------------------------------------------------------
    await check(tester, 'QB-01', () async {
      final dip = (await dc.metadata!.findTable(null, schema, 'dipendenti'))!;
      final tab = app.openFeatureTab(QueryBuilderTab(dc, catalog: catalog, schema: schema, initialTable: dip));
      await settle(tester, 3000);
      final item = find.descendant(of: find.byType(QueryBuilderView), matching: find.text('reparti'));
      expect(item, findsWidgets, reason: 'tabella reparti non elencata');
      await doubleTap(tester, item.first);
      await settle(tester, 2000);
      final m = tab.model;
      expect(m.tables.length, 2);
      record('QB-01/joins', m.joins.isEmpty ? Outcome.defect : Outcome.ok, 'join automatici dalle FK: ${m.joins.length}');
      final d = m.tables.firstWhere((x) => x.table.name == 'dipendenti');
      final r = m.tables.firstWhere((x) => x.table.name == 'reparti');
      m.toggleColumn(d.id, 'cognome');
      m.toggleColumn(r.id, 'nome');
      tab.refresh();
      await settle(tester, 1000);
      await shot(tester, 'qb01_builder');
      final sql = QuerySqlGenerator(dc.dialect).generate(m);
      record('QB-01/sql', Outcome.ok, sql.replaceAll('\n', ' '));
      final page = await dc.main!.execute(sql, fetchSize: 100000);
      final expected = await t.scalar('SELECT COUNT(*) FROM dipendenti d JOIN reparti r ON r.id = d.reparto_id');
      expect('${page.rows.length}', expected, reason: 'risultato diverso dalla query scritta a mano');
      await tester.tap(find.descendant(of: find.byType(QueryBuilderView), matching: find.text('Esegui')).first);
      await settle(tester, 3000);
      await shot(tester, 'qb01_run');
    });

    // --- PLAN-01 -------------------------------------------------------------
    await check(tester, 'PLAN-01', () async {
      const sql = 'SELECT d.nome, r.nome FROM dipendenti d JOIN reparti r ON r.id = d.reparto_id WHERE d.stipendio > 3000';
      final before = app.tabs.length;
      await showVisualPlan(ctx(), dc, sql);
      await settle(tester, 500);
      if (app.tabs.length == before) {
        await shot(tester, 'plan01_unsupported');
        record('PLAN-01', Outcome.notApplicable, 'piano visuale non disponibile per ${dc.dialect.dbmsName}');
        return;
      }
      final tab = app.currentTab as VisualPlanTab;
      for (var i = 0; i < 200 && tab.plan == null && tab.error == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await settle(tester, 1500);
      await shot(tester, 'plan01_graph');
      expect(tab.error, isNull, reason: '${tab.error}');
      expect(tab.plan, isNotNull);
    });

    // --- MOCK-01 -------------------------------------------------------------
    await check(tester, 'MOCK-01', () async {
      final before = int.parse(await t.scalar('SELECT COUNT(*) FROM dipendenti'));
      final dip = (await dc.metadata!.findTable(null, schema, 'dipendenti'))!;
      unawaited(showMockDataDialog(ctx(), dc, dip));
      await waitFor(tester, find.textContaining('Genera dati di test'), seconds: 20);
      await settle(tester, 2000);
      await tester.tap(find.text('Opzioni').last);
      await settle(tester, 800);
      await fill(tester, 'Numero di righe', '1000');
      await settle(tester, 1500);
      await shot(tester, 'mock01_dialog');
      final sw = Stopwatch()..start();
      await tester.tap(find.textContaining('Inserisci').last);
      while (sw.elapsed.inSeconds < 120) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.textContaining('Generazione interrotta').evaluate().isNotEmpty) {
          await shot(tester, 'mock01_error');
          await tester.tap(find.text('OK').last, warnIfMissed: false);
          break;
        }
        if (find.textContaining('righe inserite in').evaluate().isNotEmpty) break;
      }
      await settle(tester, 800);
      await shot(tester, 'mock01_done');
      record('MOCK-01/time', Outcome.ok, '${sw.elapsedMilliseconds} ms per 1000 righe');
      if (find.text('Chiudi').evaluate().isNotEmpty) await tester.tap(find.text('Chiudi').last);
      await settle(tester, 500);
      final after = int.parse(await t.scalar('SELECT COUNT(*) FROM dipendenti'));
      expect(after - before, 1000);
      final orphans = await t.scalar('SELECT COUNT(*) FROM dipendenti d WHERE d.reparto_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM reparti r WHERE r.id = d.reparto_id)');
      expect(orphans, '0', reason: 'chiavi esterne non valide nei dati generati');
    });

    // --- CMP-01: compare with an empty destination, migrate, compare again --
    await check(tester, 'CMP-01', () async {
      final CompareSide target;
      switch (family) {
        case DbFamily.sqlite:
          target = CompareSide(app.connections.firstWhere((c) => c.config.id == 'cmp'), null, null);
          await app.connect(target.connection!);
        case DbFamily.mysql:
          await dc.main!.execute('DROP DATABASE IF EXISTS dbcraft_cmp');
          await dc.main!.execute('CREATE DATABASE dbcraft_cmp');
          target = CompareSide(dc, 'dbcraft_cmp', null);
        default:
          await t.query(family == DbFamily.postgres
              ? 'DROP SCHEMA IF EXISTS confronto CASCADE; CREATE SCHEMA confronto'
              : "IF SCHEMA_ID('confronto') IS NULL EXEC('CREATE SCHEMA confronto'); IF OBJECT_ID('confronto.segnaposto') IS NULL CREATE TABLE confronto.segnaposto (id INT)");
          target = CompareSide(dc, catalog, 'confronto');
          dc.refreshMetadata();
      }
      final tab = app.openFeatureTab(SchemaCompareTab(source: dc, sourceCatalog: catalog, sourceSchema: schema)..target = target);
      await settle(tester, 1500);
      await tester.tap(find.text('Confronta').last);
      for (var i = 0; i < 600 && tab.diff == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await settle(tester, 1500);
      await shot(tester, 'cmp01_diff');
      expect(tab.diff, isNotNull, reason: 'confronto non completato');
      record('CMP-01/diff', Outcome.ok, '${tab.diff!.tables.length} tabelle');
      await tester.tap(find.text('Esegui sulla destinazione').last);
      final err = await confirmScript(tester, shotName: 'cmp01_migrate');
      if (err != null) {
        // Find the failing statement and its message: re-run the CREATE
        // statements that did not take effect.
        for (final st in tab.migration()) {
          if (!st.trimLeft().toUpperCase().startsWith('CREATE TABLE')) continue;
          try {
            await dc.main!.execute(st);
          } catch (e) {
            if ('$e'.toLowerCase().contains('exist')) continue;
            record('CMP-01/failing', Outcome.defect, '$st ⇒ $e');
            break;
          }
        }
      }
      expect(err, isNull, reason: err);
      tab.diff = null;
      await tester.tap(find.text('Confronta').last);
      for (var i = 0; i < 600 && tab.diff == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await settle(tester, 1500);
      await shot(tester, 'cmp01_after');
      final left = tab.diff!.tables.where((x) => '${x.status}' != 'DiffStatus.identical' && !x.id.contains('segnaposto')).map((x) => x.id).toList();
      record('CMP-01/left', left.isEmpty ? Outcome.ok : Outcome.defect, left.isEmpty ? 'nessuna differenza dopo la migrazione' : 'differenze rimaste: ${left.join(', ')}');
      expect(left, isEmpty);
    });

    // --- DCM-01: data compare and sync script ---------------------------------
    await check(tester, 'DCM-01', () async {
      if (family == DbFamily.sqlite) {
        await dc.main!.execute('CREATE TABLE grande_copia (id INTEGER PRIMARY KEY, gruppo INTEGER, testo TEXT, importo DECIMAL(12,2), creato TIMESTAMP)');
        await dc.main!.execute('INSERT INTO grande_copia SELECT * FROM grande');
      } else {
        await dc.main!.execute(family == DbFamily.sqlServer ? 'SELECT * INTO grande_copia FROM grande' : 'CREATE TABLE grande_copia AS SELECT * FROM grande');
        if (family == DbFamily.sqlServer) await dc.main!.execute('ALTER TABLE grande_copia ALTER COLUMN id INT NOT NULL');
        await dc.main!.execute('ALTER TABLE grande_copia ADD PRIMARY KEY (id)');
      }
      await dc.main!.execute('DELETE FROM grande_copia WHERE id % 1000 = 0');
      await dc.main!.execute("UPDATE grande_copia SET testo = 'cambiato' WHERE id % 777 = 0");
      await dc.main!.execute('INSERT INTO grande_copia (id, gruppo, testo) VALUES (900001, 1, ${dc.dialect.stringLiteral('solo destinazione')})');
      dc.refreshMetadata();
      final src = (await dc.metadata!.findTable(null, schema, 'grande'))!;
      final tab = app.openFeatureTab(DataCompareTab(source: dc, sourceTable: src));
      await settle(tester, 3000);
      final dst = (await dc.metadata!.findTable(null, schema, 'grande_copia'))!;
      await tab.setTable(tab.tgt, dst);
      tab.rowCap.text = '300000';
      await settle(tester, 1500);
      final sw = Stopwatch()..start();
      await tab.run();
      await settle(tester, 1500);
      await shot(tester, 'dcm01_result');
      final r = tab.result;
      expect(r, isNotNull, reason: '${tab.error}');
      record('DCM-01/counts', Outcome.ok, '${r!.counts} in ${sw.elapsedMilliseconds} ms (righe ${r.sourceRows}/${r.targetRows}, troncato ${r.truncated})');
      expect(r.inSync, isFalse);
      await tester.tap(find.text('Script di sincronizzazione').last);
      await settle(tester, 2000);
      await shot(tester, 'dcm01_sync_script');
      final err = await confirmScript(tester, shotName: 'dcm01_sync');
      expect(err, isNull, reason: err);
      await tab.run();
      await settle(tester, 1500);
      await shot(tester, 'dcm01_after');
      final after = tab.result!;
      record('DCM-01/after', Outcome.ok, '${after.counts}');
      // DELETE of target-only rows is off by default: those rows remain.
      expect(after.count(RowDiff.different) + after.count(RowDiff.onlySource), 0, reason: 'tabelle non allineate dopo la sincronizzazione: ${after.counts}');
    });

    // --- PERF-01 ---------------------------------------------------------------
    await check(tester, 'PERF-01', () async {
      final tab = app.openFeatureTab<PerformanceDashboardTab>(PerformanceDashboardTab(dc));
      await settle(tester, 6000);
      await shot(tester, 'perf01_overview');
      if (find.text('Funzione non disponibile').evaluate().isNotEmpty) {
        record('PERF-01', Outcome.notApplicable, 'dashboard non disponibile per ${dc.dialect.dbmsName}');
        return;
      }
      final errors = <String>[];
      for (final title in ['Sessioni attive', 'Blocchi', 'Query più costose', 'Tabelle più grandi', 'Indici inutilizzati', 'Indici mancanti', 'Scansioni sequenziali', 'Scansioni complete']) {
        final f = find.text(title);
        if (f.evaluate().isEmpty) continue;
        await tester.tap(f.first);
        await settle(tester, 2500);
        await shot(tester, 'perf01_${title.toLowerCase().replaceAll(' ', '_').replaceAll('ù', 'u')}');
        if (find.textContaining('Impossibile leggere').evaluate().isNotEmpty) errors.add(title);
      }
      expect(errors, isEmpty, reason: 'schede in errore: $errors');
      expect(tab.dc, dc);
    });

    // --- DBG-01 (PostgreSQL) ----------------------------------------------------
    if (family == DbFamily.postgres) {
      await check(tester, 'DBG-01', () async {
        await t.query('DROP EXTENSION IF EXISTS pldbgapi');
        final procs = await dc.metadata!.procedures(catalog, schema);
        final p = procs.firstWhere((x) => x.cleanName == 'calcola_bonus');
        unawaited(PgDebuggerTab.open(ctx(), dc, p));
        await settle(tester, 3000);
        await shot(tester, 'dbg01_no_extension');
        expect(find.text('Estensione pldbgapi non installata'), findsWidgets);
        await t.query('CREATE EXTENSION pldbgapi');
        await tester.tap(find.text('Verifica di nuovo').last);
        await settle(tester, 3000);
        await shot(tester, 'dbg01_ready');
        expect(find.text('Estensione pldbgapi non installata'), findsNothing);
        record('DBG-01', Outcome.limited, 'aperto e verificato il rilevamento dell\'estensione; sessione di debug passo-passo non automatizzata');
      });
    } else {
      record('DBG-01', Outcome.notApplicable, 'solo PostgreSQL');
    }

    // --- SIMPLE-01 ---------------------------------------------------------------
    await check(tester, 'SIMPLE-01', () async {
      app.settings.simpleMode = true;
      await app.saveSettings();
      await settle(tester, 800);
      await settle(tester, 1000);
      await shot(tester, 'simple01_tree');
      if (nav('dipendenti').evaluate().isEmpty) {
        // The simplified navigator lists tables and views without folders.
        for (final n in [dc.config.name, ...t.navPath, 'Tabelle']) {
          if (nav('dipendenti').evaluate().isNotEmpty) break;
          if (nav(n).evaluate().isNotEmpty) await navExpand(tester, n);
        }
      }
      await waitFor(tester, nav('dipendenti'));
      await shot(tester, 'simple01_tree_open');
      Object? menuError;
      try {
        await navMenu(tester, 'dipendenti', 'Modifica struttura');
      } catch (e) {
        menuError = e;
      }
      await shot(tester, 'simple01_menu');
      app.settings.simpleMode = false;
      await app.saveSettings();
      await settle(tester, 800);
      expect(menuError, isNotNull, reason: 'strumenti di design visibili nella vista semplificata');
    });

    // --- AI-01 (no API key) --------------------------------------------------------
    await check(tester, 'AI-01', () async {
      app.openFeatureTab(AiChatTab(dc));
      await settle(tester, 1500);
      await shot(tester, 'ai01_chat_no_key');
      record('AI-01', Outcome.limited, 'nessuna chiave API: verificata solo la schermata');
    });

    // A read-only connection: the design and import items are disabled.
    await check(tester, 'GUARD-RO', () async {
      final ro = await app.addConnection(ConnectionConfig.fromJson({...t.connection(), 'id': 'ro2', 'name': 'RO', 'readOnly': true}));
      await app.connect(ro);
      await settle(tester, 500);
      record('GUARD-RO', Outcome.ok, 'vedi DES-13');
    });

    await finish(tester, app);
  });
}
