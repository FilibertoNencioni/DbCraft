// NoSQL targets of the test matrix (mongo, redis, cassandra): connection,
// navigator, native query languages and the SQL subset, result grid and
// editing, export, server down (CON, NAV, SQL-16, GRD, XFR, CON-15).
//
//   flutter test integration_test/matrix/nosql_test.dart -d macos \
//     --dart-define=TARGET=mongo --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix
import 'dart:convert';
import 'dart:io';

import 'package:dbcraft/services/data_transfer.dart';
import 'package:dbcraft/ui/dialogs/export_dialog.dart' show streamQuery;
import 'package:dbcraft/ui/widgets/sheets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness.dart';
import 'targets.dart';
import 'ui.dart';

/// (name, statement, expected rows or null, L3 check after (query, expected)).
typedef Stmt = (String, String, int?, (String, String)?);

const _mongo = <Stmt>[
  ('find', "db.ordini.find({stato: 'pagato'}).sort({numero: -1}).limit(5)", 5, null),
  ('findOne', 'db.clienti.findOne({_id: 1})', 1, null),
  ('count', "db.ordini.countDocuments({stato: 'spedito'})", 1, null),
  ('aggregate', "db.ordini.aggregate([{\$group: {_id: '\$stato', n: {\$sum: 1}}}, {\$sort: {_id: 1}}])", 4, null),
  ('distinct', "db.ordini.distinct('stato')", null, null),
  ('insertOne', "db.clienti.insertOne({_id: 10, nome: 'Nuovo', citta: 'Forlì'})", null, ("db.clienti.countDocuments({_id: 10})", '1')),
  ('updateMany', "db.clienti.updateMany({citta: 'Forlì'}, {\$set: {regione: 'ER'}})", null, ("db.clienti.countDocuments({regione: 'ER'})", '2')),
  ('deleteOne', 'db.clienti.deleteOne({_id: 10})', null, ('db.clienti.countDocuments({_id: 10})', '0')),
  ('sql select', "SELECT * FROM ordini WHERE stato = 'annullato' AND numero < 100 ORDER BY numero DESC LIMIT 3", 3, null),
  ('sql count', 'SELECT COUNT(*) FROM grande WHERE gruppo IN (1, 2)', 1, null),
  ('sql update', "UPDATE clienti SET email = 'nuova@esempio.it' WHERE _id = 2", null, ("db.clienti.findOne({_id: 2}).email", 'nuova@esempio.it')),
  ('types', "db.tipi.find({_id: 'tutti'})", 1, null),
  ('view', 'db.v_ordini_pagati.find().limit(3)', 3, null),
  ('show', 'show collections', null, null),
  ('error', 'db.ordini.find({\$bogus: 1})', -1, null),
];

const _redis = <Stmt>[
  ('get', 'GET stringa', null, null),
  ('unicode', 'GET unicode', null, null),
  ('hgetall', 'HGETALL cliente:1', null, null),
  ('lrange', 'LRANGE coda 0 -1', 5, null),
  ('zrange', 'ZRANGE classifica 0 -1 WITHSCORES', null, null),
  ('xrange', 'XRANGE eventi - +', 2, null),
  ('ttl', 'TTL con_ttl', null, null),
  ('set', 'SET nuova "dal test"', null, ('GET nuova', 'dal test')),
  ('incr', 'INCR contatore', null, ('GET contatore', '43')),
  ('sql key', 'SELECT * FROM cliente:1', null, null),
  ('sql pattern', 'SELECT * FROM cliente:*', 2, null),
  ('sql spazi', 'SELECT * FROM "chiave con spazi"', null, null),
  ('select db1', 'SELECT 1', null, null),
  ('scan db1', 'SCAN 0 MATCH k:1* COUNT 100', null, null),
  ('error', 'COMANDO_INESISTENTE x', -1, null),
];

const _cassandra = <Stmt>[
  ('select', 'SELECT * FROM clienti', 3, null),
  ('collections', 'SELECT tag, telefoni, attributi, residenza FROM clienti WHERE id = 1', 1, null),
  ('partition', "SELECT * FROM letture WHERE sensore = 's1' AND giorno = '2024-01-01'", 2, null),
  ('types', 'SELECT * FROM tipi', 1, null),
  ('insert', "INSERT INTO clienti (id, nome) VALUES (10, 'Nuovo')", null, ('SELECT COUNT(*) FROM negozio.clienti WHERE id = 10', '1')),
  ('update', "UPDATE clienti SET email = 'x@esempio.it' WHERE id = 10", null, null),
  ('delete', 'DELETE FROM clienti WHERE id = 10', null, ('SELECT COUNT(*) FROM negozio.clienti WHERE id = 10', '0')),
  ('allow filtering', 'SELECT * FROM grande WHERE gruppo = 7 LIMIT 10 ALLOW FILTERING', 10, null),
  ('error', 'SELECT * FROM tabella_inesistente', -1, null),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('nosql', (tester) async {
    final t = current;
    await t.prepare?.call();
    final app = await startApp(tester, connections: [t.connection()]);
    final dc = app.connections.first;

    // CON-01 / NAV-01: connect from the navigator, browse.
    await check(tester, 'CON-01', () async {
      await doubleTap(tester, nav(dc.config.name).first);
      for (var i = 0; i < 300 && !dc.isConnected; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(dc.isConnected, isTrue);
      record('CON-01/dialect', Outcome.ok, '${dc.dialect.family.name} · ${dc.dialect.dbmsName} · ${dc.dialect.dbmsVersion}');
      await settle(tester, 2000);
      await shot(tester, 'con01_connected');
    });
    if (!dc.isConnected) return;

    await check(tester, 'NAV-01', () async {
      for (final n in t.navPath) {
        await waitFor(tester, nav(n), seconds: 20);
        await navExpand(tester, n);
      }
      if (nav('Tabelle').evaluate().isNotEmpty) await navExpand(tester, 'Tabelle');
      await settle(tester, 1500);
      await shot(tester, 'nav01_tree');
      final expected = switch (t.id) {
        'mongo' => ['ordini', 'clienti', 'tipi', 'grande'],
        'cassandra' => ['clienti', 'letture', 'tipi', 'grande'],
        _ => <String>[],
      };
      final missing = [for (final e in expected) if (nav(e).evaluate().isEmpty) e];
      expect(missing, isEmpty, reason: 'mancano nel navigator: $missing');
    });

    // CON-16: the connection sheet in "Integrato" mode.
    await check(tester, 'CON-16', () async {
      app.openConnectionInfo(dc);
      await settle(tester, 1500);
      await shot(tester, 'con16_info');
      await tester.tap(find.byTooltip('Nuova connessione').first);
      await waitFor(tester, find.text('Prova connessione'));
      await settle(tester, 800);
      await tester.tap(find.descendant(of: find.byType(SheetScaffold), matching: find.text('Integrato')).last);
      await settle(tester, 800);
      await shot(tester, 'con16_native_sheet');
      await tester.tap(find.text('Annulla').last);
      await settle(tester, 500);
    });

    // SQL-16: native language and SQL subset through the editor.
    final stmts = switch (t.id) {
      'mongo' => _mongo,
      'redis' => _redis,
      _ => _cassandra,
    };
    for (final (name, sql, rows, after) in stmts) {
      await check(tester, 'SQL-16/$name', () async {
        final tab = await app.openSqlEditor(dc, initialSql: sql);
        await settle(tester, 300);
        await runEditor(tester, tab);
        final err = tab.results.isEmpty ? 'nessun risultato' : tab.results.last.error;
        final model = tab.results.where((r) => r.model != null).lastOrNull?.model;
        final n = model?.rows.length;
        record('SQL-16/$name/result', Outcome.ok, err ?? 'righe: $n · colonne: ${model?.columns.map((c) => c.name).join(', ')}');
        if (rows == -1) {
          expect(err, isNotNull, reason: 'errore non segnalato');
          await shot(tester, 'sql16_${name.replaceAll(' ', '_')}');
          return;
        }
        expect(err, isNull, reason: err);
        if (rows != null) expect(n, rows);
        if (after != null) expect(await t.scalar(after.$1), after.$2);
        if (name == 'types' || name == 'collections' || name == 'hgetall' || name == 'aggregate') {
          await shot(tester, 'sql16_${name.replaceAll(' ', '_')}');
        }
        app.closeTab(tab);
      });
    }

    // GRD-01 / XFR-02: the 100.000 items of "grande".
    await check(tester, 'GRD-01', () async {
      final sql = switch (t.id) { 'mongo' => 'db.grande.find()', 'redis' => 'SELECT * FROM k:*', _ => 'SELECT * FROM grande' };
      final tab = await app.openSqlEditor(dc, initialSql: sql, catalog: t.id == 'redis' ? 'db1' : null);
      await runEditor(tester, tab, seconds: 120);
      final m = lastModel(tab);
      final first = m.rows.length;
      final sw = Stopwatch()..start();
      await m.fetchAll();
      await settle(tester, 500);
      await shot(tester, 'grd01_all');
      record('GRD-01/fetch', Outcome.ok, 'prima pagina $first, totale ${m.rows.length} in ${sw.elapsedMilliseconds} ms');
      expect(m.rows.length, 100000);
    });

    await check(tester, 'XFR-02', () async {
      final sql = switch (t.id) { 'mongo' => 'db.grande.find()', 'redis' => 'HGETALL cliente:1', _ => 'SELECT * FROM grande' };
      final file = File('$outDir/export/grande.json')..parent.createSync(recursive: true);
      final page = await dc.main!.execute(sql, fetchSize: 10);
      final cols = page.columns.map((c) => c.name).toList();
      final o = ExportOptions(tableName: 'grande', dialect: dc.dialect)..format = ExportFormat.json;
      final n = await DataExporter.exportToFile(file, cols, streamQuery(dc, sql, const []), o);
      final decoded = jsonDecode(file.readAsStringSync()) as List;
      record('XFR-02/rows', Outcome.ok, '$n righe esportate');
      expect(decoded.length, n);
      if (t.id != 'redis') expect(n, 100000);
    });

    // GRD-05: editing a document / row in the grid.
    await check(tester, 'GRD-05', () async {
      final sql = switch (t.id) { 'mongo' => 'db.clienti.find()', 'redis' => 'HGETALL cliente:2', _ => 'SELECT * FROM clienti' };
      final tab = await app.openSqlEditor(dc, initialSql: sql);
      await runEditor(tester, tab);
      final m = lastModel(tab);
      await settle(tester, 800);
      await shot(tester, 'grd05_grid');
      record('GRD-05/editable', Outcome.ok, 'modificabile: ${m.isEditable} · chiave ${m.keyColumns}');
      if (!m.isEditable) return;
      final col = m.columns.indexWhere((c) => c.name == (t.id == 'redis' ? 'value' : 'nome'));
      if (col < 0) {
        record('GRD-05', Outcome.limited, 'colonna da modificare non trovata: ${m.columns.map((c) => c.name)}');
        return;
      }
      final row = t.id == 'redis' ? m.rows.indexWhere((r) => '${r.values.first}' == 'nome') : m.rows.indexWhere((r) => '${r.values.first}' == '2');
      m.setValue(row < 0 ? 0 : row, col, 'Anna Modificata ✓');
      await m.saveChanges();
      final check = switch (t.id) {
        'mongo' => ('db.clienti.findOne({_id: 2}).nome', 'Anna Modificata ✓'),
        'redis' => ('HGET cliente:2 nome', 'Anna Modificata ✓'),
        _ => ('SELECT nome FROM negozio.clienti WHERE id = 2', 'Anna Modificata ✓'),
      };
      final got = await t.query(check.$1);
      expect(got.map((r) => r.join(' ').trim()).join(' '), contains(check.$2));
    });

    // CON-15: the server goes away and comes back.
    await check(tester, 'CON-15', () async {
      final container = 'dbcraft-design-${t.id}-1';
      await Process.run('docker', ['stop', container]);
      final sw = Stopwatch()..start();
      Object? error;
      try {
        await dc.main!.execute(t.id == 'redis' ? 'PING' : (t.id == 'mongo' ? 'db.clienti.findOne()' : 'SELECT * FROM clienti')).timeout(const Duration(seconds: 60));
      } catch (e) {
        error = e;
      }
      record('CON-15/error', error == null ? Outcome.defect : Outcome.ok, '${sw.elapsedMilliseconds} ms · $error');
      await Process.run('docker', ['start', container]);
      await Process.run('docker', ['compose', '-f', 'tool/design_db/compose.yml', 'up', '-d', '--wait', t.id == 'mongo' ? 'mongo' : t.id],
          workingDirectory: repo);
      await dc.reconnect();
      await dc.main!.execute(t.id == 'redis' ? 'PING' : (t.id == 'mongo' ? 'db.clienti.findOne()' : 'SELECT * FROM clienti'));
      expect(error, isNotNull);
    });

    await finish(tester, app);
  });
}

