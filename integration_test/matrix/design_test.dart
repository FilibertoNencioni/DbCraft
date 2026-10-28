// Schema design cases of the test matrix (DES-01…DES-16) through the real
// designer, script sheet and confirmations, checked on the server (L3).
//
//   flutter test integration_test/matrix/design_test.dart -d macos \
//     --dart-define=TARGET=sqlite --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix
import 'dart:async';

import 'package:dbcraft/features/design/capabilities.dart';
import 'package:dbcraft/features/design/ui/table_designer.dart';
import 'package:dbcraft/features/schema/ddl_execution.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/ui/editors/table_editor_view.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:re_editor/re_editor.dart';

import 'harness.dart';
import 'targets.dart';
import 'ui.dart';

/// Drives the DDL script sheet: "Esegui", the confirmation(s), then waits.
/// Returns the error text when the script stopped, null when it ran.
Future<String?> runScriptSheet(WidgetTester tester, {String shotName = '', bool production = false}) async {
  await waitFor(tester, find.text('Esegui'), seconds: 20);
  await settle(tester, 600);
  if (shotName.isNotEmpty) await shot(tester, '${shotName}_script');
  await tester.tap(find.text('Esegui').last);
  await waitFor(tester, find.text('Eseguire lo script?'), seconds: 10);
  await settle(tester, 300);
  await tester.tap(find.text('Esegui').last);
  await settle(tester, 400);
  if (production) {
    await waitFor(tester, find.text('Connessione di produzione'), seconds: 10);
    if (shotName.isNotEmpty) await shot(tester, '${shotName}_production');
    await tester.tap(find.text('Continua').last);
    await settle(tester, 400);
  }
  for (var i = 0; i < 600; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.text('Esecuzione interrotta').evaluate().isNotEmpty) {
      await settle(tester, 300);
      // Expand "Mostra dettagli" and read every paragraph of the alert.
      if (find.text('Mostra dettagli').evaluate().isNotEmpty) {
        await tester.tap(find.text('Mostra dettagli').last);
        await settle(tester, 400);
      }
      if (shotName.isNotEmpty) await shot(tester, '${shotName}_error');
      final texts = find
          .byWidgetPredicate((w) => w is RichText)
          .evaluate()
          .map((e) => (e.widget as RichText).text.toPlainText())
          .where((x) => x.contains('non riuscita') || x.contains('ERROR') || x.contains('rror') || x.startsWith('['))
          .join(' ‖ ');
      lastScriptError = texts;
      await tester.tap(find.text('OK').last, warnIfMissed: false);
      await settle(tester, 400);
      // Close the script sheet as well.
      if (find.text('Chiudi').evaluate().isNotEmpty) {
        await tester.tap(find.text('Chiudi').last, warnIfMissed: false);
        await settle(tester, 400);
      }
      return texts;
    }
    if (find.text('Eseguire lo script?').evaluate().isEmpty && find.text('Esegui').evaluate().isEmpty) break;
  }
  await settle(tester, 800);
  return null;
}

/// Last error dialog text seen by [runScriptSheet].
String lastScriptError = '';

Future<bool> shotHas(WidgetTester tester, String text) async => lastScriptError.contains(text);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('design', (tester) async {
    final t = current;
    await t.prepare?.call();
    final app = await startApp(tester, connections: [t.connection()]);
    final dc = app.connections.first;
    BuildContext ctx() => tester.element(find.byType(HomePage));
    await app.connect(dc);
    await settle(tester, 800);
    final caps = DesignCapabilities.of(dc.dialect);
    final q = t.quoteIdent;
    final schema = t.navPath.length > 1 ? t.navPath[1] : null;
    Future<bool> exists(String table) async => await t.scalar(t.id == 'sqlite'
            ? "SELECT COUNT(*) FROM sqlite_master WHERE name = '$table'"
            : "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = '$table'") !=
        '0';

    // DES-03a: Database › Nuova tabella… (catalog only, as the menu does).
    await check(tester, 'DES-03a', () async {
      app.openNewTable(dc, catalog: dc.defaultCatalog);
      await settle(tester, 1500);
      final tab = app.currentTab as TableEditorTab;
      final d = tab.design!;
      d.update(d.working.copyWith(name: 'dbc_menu'));
      await settle(tester, 500);
      await shot(tester, 'des03a_new_from_menu');
      unawaited(saveTableDesign(ctx(), tab));
      final err = await runScriptSheet(tester, shotName: 'des03a');
      expect(err, isNull, reason: err);
      expect(await exists('dbc_menu'), isTrue);
    });

    // DES-03c: two new tables in a row from the designer (constraint names).
    await check(tester, 'DES-03c', () async {
      for (final name in ['dbc_nuova1', 'dbc_nuova2']) {
        app.openNewTable(dc, catalog: dc.defaultCatalog, schema: schema);
        await settle(tester, 1500);
        final tab = app.currentTab as TableEditorTab;
        final field = find.descendant(of: find.byType(TableEditorView), matching: find.byType(EditableText)).first;
        await tester.enterText(field, name);
        await settle(tester, 600);
        record('DES-03c/$name', Outcome.ok, tab.design!.statements.join(' ⏎ '));
        unawaited(saveTableDesign(ctx(), tab));
        final err = await runScriptSheet(tester, shotName: 'des03c_$name');
        expect(err, isNull, reason: '$name: $err');
      }
    });

    // DES-03b: a new table with every common type, from the folder of a schema.
    await check(tester, 'DES-03b', () async {
      app.openNewTable(dc, catalog: dc.defaultCatalog, schema: schema);
      await settle(tester, 1500);
      final tab = app.currentTab as TableEditorTab;
      final d = tab.design!;
      final types = commonTypesFor(dc.dialect);
      final cols = [
        ...d.working.columns,
        for (final (i, ty) in types.indexed) ColumnDef(name: 'c_$i', type: ty.$1, size: ty.$2, scale: ty.$3),
        const ColumnDef(name: 'obbligatorio', type: 'varchar', size: 20, nullable: false, defaultValue: "'x'"),
        const ColumnDef(name: 'reparto_id', type: 'integer'),
      ];
      d.update(d.working.copyWith(
        name: 'dbc_tipi',
        columns: cols,
        foreignKeys: [ForeignKeyDef(name: 'fk_dbc_tipi_reparto', columns: const ['reparto_id'], refSchema: schema, refTable: 'reparti', refColumns: const ['id'])],
        indexes: const [IndexDef(name: 'ix_dbc_tipi_ob', columns: ['obbligatorio'])],
        checks: caps.has(DesignFeature.checkConstraints) ? const [CheckDef(name: 'ck_dbc_tipi', expression: "obbligatorio <> ''")] : const [],
      ));
      await settle(tester, 800);
      await tester.tap(find.textContaining('Modifiche').last, warnIfMissed: false);
      await settle(tester, 800);
      await shot(tester, 'des03b_changes');
      record('DES-03b/script', Outcome.ok, d.statements.join(' ⏎ '));
      unawaited(saveTableDesign(ctx(), tab));
      final err = await runScriptSheet(tester, shotName: 'des03b');
      expect(err, isNull, reason: err);
      expect(await exists('dbc_tipi'), isTrue);
      // Read back: the design has nothing left to apply.
      await settle(tester, 1500);
      record('DES-03b/after', d.isDirty ? Outcome.defect : Outcome.ok, d.isDirty ? 'differenze dopo la rilettura: ${d.statements.join(' ⏎ ')}' : 'nessuna differenza');
      expect(d.isDirty, isFalse, reason: 'la tabella riletta differisce dal progetto: ${d.statements}');
    });

    // DES-04: alter an existing table (add, rename, retype), undo/redo, data,
    // triggers and incoming foreign keys preserved.
    await check(tester, 'DES-04', () async {
      final table = (await dc.metadata!.findTable(null, schema, 'progetti'))!;
      app.openTable(dc, table, page: 2);
      await settle(tester, 2500);
      final tab = app.currentTab as TableEditorTab;
      final d = tab.design!;
      final before = d.working;
      d.update(before.copyWith(columns: [
        for (final c in before.columns)
          if (c.name == 'titolo') c.copyWith(name: 'titolo_progetto') else c,
        const ColumnDef(name: 'note', type: 'varchar', size: 200, defaultValue: "'n/d'"),
      ]));
      await settle(tester, 500);
      expect(d.canUndo, isTrue);
      d.undo();
      expect(d.isDirty, isFalse, reason: 'annulla non torna allo stato iniziale');
      d.redo();
      expect(d.isDirty, isTrue);
      await tester.tap(find.textContaining('Modifiche').last, warnIfMissed: false);
      await settle(tester, 800);
      await shot(tester, 'des04_changes');
      record('DES-04/script', Outcome.ok, d.statements.join(' ⏎ '));
      unawaited(saveTableDesign(ctx(), tab));
      final err = await runScriptSheet(tester, shotName: 'des04');
      expect(err, isNull, reason: err);
      expect(await t.scalar('SELECT COUNT(*) FROM progetti'), '4', reason: 'righe perse');
      expect(await t.scalar("SELECT ${q('titolo_progetto')} FROM progetti WHERE codice = 'CAS-01'"), 'DbCraft desktop');
      expect(await t.scalar("SELECT note FROM progetti WHERE codice = 'CAS-01'"), 'n/d');
      // The trigger and the foreign key of assegnazioni survive.
      await dc.main!.execute("UPDATE progetti SET budget = budget WHERE codice = 'HD-03'");
      expect(await t.scalar("SELECT COUNT(*) FROM audit WHERE azione = 'update HD-03'"), '1', reason: 'trigger perso dopo la modifica');
      Object? fkError;
      try {
        await dc.main!.execute("INSERT INTO assegnazioni (dipendente_id, progetto_codice, ore) VALUES (1, 'NOPE', 1)");
      } catch (e) {
        fkError = e;
      }
      if (t.id == 'sqlite') {
        record('DES-04/fk', Outcome.ok, 'SQLite: FK applicate solo con PRAGMA foreign_keys=ON (errore: $fkError)');
      } else {
        expect(fkError, isNotNull, reason: 'chiave esterna verso progetti persa');
      }
      expect(d.isDirty, isFalse, reason: 'differenze dopo il salvataggio: ${d.statements}');
    });

    // DES-05: duplicate structure from the navigator.
    await check(tester, 'DES-05', () async {
      await openTablesFolder(tester, dc.config.name, t.navPath);
      if (nav('reparti').evaluate().isEmpty) await doubleTap(tester, nav('Tabelle').first);
      await waitFor(tester, nav('reparti'));
      await navMenu(tester, 'reparti', 'Duplica struttura…');
      await settle(tester, 800);
      await shot(tester, 'des05_prompt');
      await tester.enterText(find.byType(EditableText).last, 'reparti_copia');
      await tester.tap(find.text('OK').last);
      await settle(tester, 1500);
      final tab = app.currentTab as TableEditorTab;
      unawaited(saveTableDesign(ctx(), tab));
      final err = await runScriptSheet(tester, shotName: 'des05');
      expect(err, isNull, reason: err);
      expect(await exists('reparti_copia'), isTrue);
    });

    // DES-07: the data check of a UNIQUE on duplicated values.
    await check(tester, 'DES-07', () async {
      final r = await dc.main!.execute(
          'SELECT COUNT(*) FROM (SELECT codice FROM senza_pk GROUP BY codice HAVING COUNT(*) > 1) x');
      expect('${r.rows.first.first}', '1');
      // Through the sheet: Vincoli › + UNIQUE is covered by the screenshot; the
      // check itself is DataChecks.forConstraint (unit tested).
      record('DES-07', Outcome.limited, 'verifica dati provata solo a livello SQL: il dialogo richiede la scelta delle colonne');
    });

    // DES-12: a failing script — transactional rollback or partial state.
    await check(tester, 'DES-12', () async {
      unawaited(showDdlScriptDialog(ctx(), dc: dc, title: 'Script con errore', statements: [
        'CREATE TABLE dbc_tx (id INTEGER PRIMARY KEY)',
        'CREATE TABLE dbc_tx (id INTEGER PRIMARY KEY)',
      ]));
      final err = await runScriptSheet(tester, shotName: 'des12');
      expect(err, isNotNull, reason: 'errore non segnalato');
      // A plain statement list is not transactional: the message must say
      // what really happened.
      final left = await exists('dbc_tx');
      record('DES-12/state', Outcome.ok, 'dbc_tx presente: $left');
      expect(left, isTrue, reason: 'il messaggio dice "precedenti eseguite" ma la tabella non c\'è');
    });

    // DES-12b: a table change failing halfway is rolled back (transactional
    // DDL) or reported as partial.
    await check(tester, 'DES-12b', () async {
      final table = (await dc.metadata!.findTable(null, schema, 'senza_pk'))!;
      app.openTable(dc, table, page: 2);
      await settle(tester, 2500);
      final tab = app.currentTab as TableEditorTab;
      final d = tab.design!;
      d.update(d.working.copyWith(
        columns: [...d.working.columns, const ColumnDef(name: 'extra', type: 'integer')],
        uniques: const [UniqueDef(name: 'uq_senza_pk_codice', columns: ['codice'])],
      ));
      await settle(tester, 500);
      record('DES-12b/script', Outcome.ok, d.statements.join(' ⏎ '));
      unawaited(saveTableDesign(ctx(), tab));
      final err = await runScriptSheet(tester, shotName: 'des12b');
      expect(err, isNotNull, reason: 'UNIQUE su valori duplicati accettato');
      final cols = await dc.main!.execute('SELECT * FROM senza_pk WHERE 1 = 0');
      final hasExtra = cols.columns.any((c) => c.name.toLowerCase() == 'extra');
      final rolledBack = await shotHas(tester, 'nessuna modifica applicata');
      final leftovers = await t.query(t.id == 'sqlite'
          ? "SELECT name FROM sqlite_master WHERE name LIKE 'senza_pk%' AND name <> 'senza_pk'"
          : "SELECT table_name FROM information_schema.tables WHERE table_name LIKE 'senza_pk%' AND table_name <> 'senza_pk'");
      record('DES-12b/state', Outcome.ok, 'colonna extra: $hasExtra · rollback dichiarato: $rolledBack · tabelle residue: ${leftovers.map((r) => r.first).join(', ')}');
      if (caps.has(DesignFeature.transactionalDdl)) {
        expect(hasExtra, isFalse, reason: 'DDL transazionale ma modifica applicata a metà');
        expect(rolledBack || t.id == 'sqlite', isTrue, reason: 'rollback non dichiarato: $lastScriptError');
      } else if (hasExtra) {
        expect(lastScriptError, contains('precedenti sono state eseguite'), reason: 'stato parziale non dichiarato');
      }
      expect(leftovers, isEmpty, reason: 'oggetti di lavoro rimasti dopo l\'errore');
      d.discard();
    });

    // DES-11: rename, truncate and drop from the navigator.
    await check(tester, 'DES-11', () async {
      await openTablesFolder(tester, dc.config.name, t.navPath);
      if (nav('reparti_copia').evaluate().isEmpty) {
        await tester.sendKeyEvent(LogicalKeyboardKey.f5);
        await settle(tester, 1500);
      }
      await waitFor(tester, nav('reparti_copia'), seconds: 20);
      await dc.main!.execute("INSERT INTO reparti_copia (id, nome) VALUES (9, 'x')");
      await navMenu(tester, 'reparti_copia', 'Svuota (TRUNCATE)…');
      final e1 = await runScriptSheet(tester, shotName: 'des11_truncate');
      expect(e1, isNull, reason: e1);
      expect(await t.scalar('SELECT COUNT(*) FROM reparti_copia'), '0');
      await navMenu(tester, 'reparti_copia', 'Elimina (DROP)…');
      final e2 = await runScriptSheet(tester, shotName: 'des11_drop');
      expect(e2, isNull, reason: e2);
      await settle(tester, 1500);
      expect(await exists('reparti_copia'), isFalse);
      await shot(tester, 'des11_after_drop');
      expect(nav('reparti_copia'), findsNothing, reason: 'il navigator non si è aggiornato');
    });

    // DES-10: edit the source of an existing trigger and save it (D-013).
    await check(tester, 'DES-10', () async {
      await openTablesFolder(tester, dc.config.name, t.navPath);
      await waitFor(tester, nav('progetti'));
      if (nav('trg_progetti_upd').evaluate().isEmpty) {
        if (nav('Trigger').evaluate().isEmpty) await navExpand(tester, 'progetti');
        await navExpand(tester, 'Trigger');
      }
      await navMenu(tester, 'trg_progetti_upd', 'Modifica sorgente');
      await settle(tester, 1500);
      await shot(tester, 'des10_trigger_source');
      // Edit the source (a comment) and save.
      final editor = tester.widgetList<CodeEditor>(find.byType(CodeEditor)).last;
      editor.controller!.text = '-- modificato da DbCraft\n${editor.controller!.text}';
      await settle(tester, 600);
      await shot(tester, 'des10_trigger_edited');
      await tester.tap(find.text('Salva').last);
      await settle(tester, 1200);
      final err = find.text('Eseguire lo script?').evaluate().isNotEmpty || find.text('Esegui').evaluate().isNotEmpty
          ? await runScriptSheet(tester, shotName: 'des10')
          : 'nessuno script proposto dopo Salva';
      expect(err, isNull, reason: err);
      // The trigger still fires.
      await dc.main!.execute("UPDATE progetti SET budget = budget WHERE codice = 'ERP-07'");
      expect(await t.scalar("SELECT COUNT(*) FROM audit WHERE azione = 'update ERP-07'"), '1', reason: 'trigger non più attivo dopo il salvataggio');
    });

    // DES-13: guards on read-only and production connections.
    await check(tester, 'DES-13', () async {
      final ro = await app.addConnection(ConnectionConfig.fromJson({...t.connection(), 'id': 'ro', 'name': 'Sola lettura', 'readOnly': true}));
      await app.connect(ro);
      unawaited(showDdlScriptDialog(ctx(), dc: ro, title: 'Su sola lettura', statements: const ['CREATE TABLE dbc_ro (id INTEGER)']));
      await waitFor(tester, find.text('Esegui'));
      await tester.tap(find.text('Esegui').last);
      await settle(tester, 1200);
      await shot(tester, 'des13_readonly');
      expect(find.text('Eseguire lo script?'), findsNothing, reason: 'nessun blocco su connessione in sola lettura');
      if (find.text('Chiudi').evaluate().isNotEmpty) await tester.tap(find.text('Chiudi').last);
      await settle(tester, 500);
      final prod = await app.addConnection(ConnectionConfig.fromJson({...t.connection(), 'id': 'prod', 'name': 'Produzione', 'type': 'production'}));
      await app.connect(prod);
      unawaited(showDdlScriptDialog(ctx(), dc: prod, title: 'Su produzione', statements: const ['CREATE TABLE dbc_prod (id INTEGER)']));
      final err = await runScriptSheet(tester, shotName: 'des13_prod', production: true);
      expect(err, isNull, reason: err);
      expect(await exists('dbc_prod'), isTrue);
    });

    await finish(tester, app);
  });
}

/// (type, size, scale) of the common types of the dialect.
List<(String, int?, int?)> commonTypesFor(dynamic dialect) => switch ('${dialect.family}'.split('.').last) {
  'sqlite' => [('INTEGER', null, null), ('REAL', null, null), ('TEXT', null, null), ('BLOB', null, null), ('NUMERIC', 10, 2)],
  'postgres' => [('bigint', null, null), ('numeric', 18, 4), ('double precision', null, null), ('boolean', null, null), ('date', null, null), ('timestamptz', null, null), ('uuid', null, null), ('jsonb', null, null), ('bytea', null, null), ('text', null, null)],
  'sqlServer' => [('bigint', null, null), ('decimal', 18, 4), ('float', null, null), ('bit', null, null), ('date', null, null), ('datetime2', null, null), ('uniqueidentifier', null, null), ('nvarchar', 100, null), ('varbinary', -1, null), ('nvarchar', -1, null)],
  'mysql' => [('bigint', null, null), ('decimal', 18, 4), ('double', null, null), ('tinyint', 1, null), ('date', null, null), ('datetime', null, null), ('json', null, null), ('varchar', 100, null), ('blob', null, null), ('text', null, null)],
  _ => [('integer', null, null), ('varchar', 100, null)],
};
