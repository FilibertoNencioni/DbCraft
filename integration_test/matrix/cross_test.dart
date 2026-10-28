// Cases across DBMS (test matrix §5 phase 6): several connections at once
// (CON-14), schema migration between different DBMS (CMP-02), SQL INSERT
// export run on another DBMS (XFR-04) and data compare across DBMS (DCM-02).
//
//   flutter test integration_test/matrix/cross_test.dart -d macos \
//     --dart-define=TARGET=cross --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix
import 'dart:async';

import 'package:dbcraft/features/data_compare/data_compare_tab.dart' hide CompareSide;
import 'package:dbcraft/features/schema/schema_compare_view.dart';
import 'package:dbcraft/services/data_transfer.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/dialogs/export_dialog.dart' show streamQuery;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness.dart';
import 'targets.dart';

/// (source target, destination target, destination catalog, destination schema).
const _pairs = [
  ('sqlite', 'pg', 'dbcraft', 'da_sqlite'),
  ('pg', 'mysql', 'dbc_da_pg', null),
  ('mysql', 'mssql', 'dbcraft', 'da_mysql'),
  ('mssql', 'pg', 'dbcraft', 'da_mssql'),
  ('mariadb', 'sqlite', null, null),
];

String? _schemaOf(String t) => switch (t) { 'pg' => 'public', 'mssql' => 'dbo', _ => null };
String? _catalogOf(String t) => switch (t) { 'pg' || 'mssql' || 'mysql' || 'mariadb' => 'dbcraft', _ => null };

Future<void> _prepareDestination(DbConnection d, String target, String? catalog, String? schema) async {
  switch (target) {
    case 'pg':
      await d.main!.execute('DROP SCHEMA IF EXISTS $schema CASCADE');
      await d.main!.execute('CREATE SCHEMA $schema');
    case 'mssql':
      await d.main!.execute("IF SCHEMA_ID('$schema') IS NOT NULL BEGIN DECLARE @s nvarchar(max) = ''; SELECT @s += 'DROP TABLE $schema.' + QUOTENAME(name) + ';' FROM sys.tables WHERE schema_id = SCHEMA_ID('$schema'); EXEC(@s); EXEC('DROP SCHEMA $schema') END");
      await d.main!.execute("EXEC('CREATE SCHEMA $schema')");
    case 'mysql' || 'mariadb':
      await d.main!.execute('DROP DATABASE IF EXISTS $catalog');
      await d.main!.execute('CREATE DATABASE $catalog');
    default:
      break;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('cross', (tester) async {
    for (final id in ['sqlite', 'pg', 'mysql', 'mariadb', 'mssql']) {
      await targets[id]!.prepare?.call();
    }
    // SQLite destination: an empty file.
    final cmp = sqliteDb.replaceAll('sqlite_run.db', 'sqlite_cross.db');
    final app = await startApp(tester, connections: [
      for (final id in ['sqlite', 'pg', 'mysql', 'mariadb', 'mssql']) targets[id]!.connection(),
      {'id': 'sqlite_dst', 'name': 'SQLite destinazione', 'mode': 'driver', 'driver': 'SQLite3', 'database': cmp},
    ]);
    DbConnection conn(String id) => app.connections.firstWhere((c) => c.config.id == id);

    // CON-14: every connection at once, a query on each in parallel.
    await check(tester, 'CON-14', () async {
      for (final c in app.connections) {
        await app.connect(c);
      }
      final counts = await Future.wait([
        for (final id in ['sqlite', 'pg', 'mysql', 'mariadb', 'mssql']) conn(id).main!.execute('SELECT COUNT(*) FROM dipendenti'),
      ]);
      await settle(tester, 1000);
      await shot(tester, 'con14_all_connected');
      record('CON-14/counts', Outcome.ok, counts.map((p) => p.rows.first.first).join(', '));
      expect(counts.map((p) => '${p.rows.first.first}').toSet().length, 1, reason: 'risultati diversi tra le sessioni');
    });

    for (final (src, dst, dCat, dSchema) in _pairs) {
      final name = '$src→$dst';
      await check(tester, 'CMP-02/$name', () async {
        final s = conn(src);
        final d = dst == 'sqlite' ? conn('sqlite_dst') : conn(dst);
        await _prepareDestination(d, dst, dCat, dSchema);
        final tab = app.openFeatureTab(SchemaCompareTab(source: s, sourceCatalog: _catalogOf(src), sourceSchema: _schemaOf(src))..target = CompareSide(d, dCat, dSchema));
        await settle(tester, 1500);
        await tester.tap(find.text('Confronta').last);
        for (var i = 0; i < 600 && tab.diff == null; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await settle(tester, 1500);
        expect(tab.diff, isNotNull, reason: 'confronto non completato');
        await shot(tester, 'cmp02_${src}_$dst');
        await tester.tap(find.text('Esegui sulla destinazione').last);
        String? error;
        for (var i = 0; i < 100 && find.text('Eseguire lo script?').evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.tap(find.text('Esegui').last);
        for (var i = 0; i < 1200; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.text('Esecuzione interrotta').evaluate().isNotEmpty) {
            if (find.text('Mostra dettagli').evaluate().isNotEmpty) await tester.tap(find.text('Mostra dettagli').last);
            await settle(tester, 400);
            await shot(tester, 'cmp02_${src}_${dst}_error');
            error = 'errore (vedi cmp02_${src}_${dst}_error.png)';
            await tester.tap(find.text('OK').last);
            await settle(tester, 300);
            break;
          }
          if (find.text('Eseguire lo script?').evaluate().isEmpty && i > 20) break;
        }
        await settle(tester, 1000);
        expect(error, isNull, reason: error);
        tab.diff = null;
        await tester.tap(find.text('Confronta').last);
        for (var i = 0; i < 600 && tab.diff == null; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await settle(tester, 1000);
        await shot(tester, 'cmp02_${src}_${dst}_after');
        final left = tab.diff!.tables.where((x) => '${x.status}' != 'DiffStatus.identical').map((x) => x.id).toList();
        record('CMP-02/$name/left', left.isEmpty ? Outcome.ok : Outcome.limited, left.isEmpty ? 'nessuna differenza' : 'differenze residue: ${left.join(', ')}');

      });
    }

    // DCM-02: the same "progetti" (identical seed) compared across DBMS.
    for (final (src, dst) in const [('pg', 'mysql'), ('pg', 'mssql'), ('mysql', 'mariadb'), ('mssql', 'sqlite'), ('sqlite', 'pg')]) {
      await check(tester, 'DCM-02/$src→$dst', () async {
        final s = conn(src), d = conn(dst);
        final st = (await s.metadata!.findTable(_catalogOf(src), _schemaOf(src), 'progetti'))!;
        final dc = app.openFeatureTab(DataCompareTab(source: s, sourceTable: st));
        await settle(tester, 2000);
        await dc.setConnection(dc.tgt, d);
        if (_catalogOf(dst) != null) await dc.setCatalog(dc.tgt, _catalogOf(dst));
        if (_schemaOf(dst) != null) await dc.setSchema(dc.tgt, _schemaOf(dst));
        final dt = (await d.metadata!.findTable(_catalogOf(dst), _schemaOf(dst), 'progetti'))!;
        await dc.setTable(dc.tgt, dt);
        await dc.run();
        await settle(tester, 1000);
        await shot(tester, 'dcm02_${src}_$dst');
        record('DCM-02/$src→$dst/counts', Outcome.ok, '${dc.result?.counts} ${dc.error ?? ''}');
        expect(dc.result?.inSync, isTrue, reason: 'dati identici giudicati diversi: ${dc.result?.counts} ${dc.error ?? ''}');
      });
    }

    // XFR-04: "reparti" exported as SQL INSERT from one DBMS, run on another.
    for (final (src, dst) in const [('pg', 'mysql'), ('mysql', 'mssql'), ('mssql', 'pg'), ('sqlite', 'mariadb')]) {
      await check(tester, 'XFR-04/$src→$dst', () async {
        final s = conn(src), d = conn(dst);
        try {
          await d.main!.execute('DROP TABLE reparti_imp');
        } catch (_) {}
        await d.main!.execute('CREATE TABLE reparti_imp (id INTEGER PRIMARY KEY, nome VARCHAR(100) NOT NULL, sede VARCHAR(100))');
        final st = (await s.metadata!.findTable(_catalogOf(src), _schemaOf(src), 'reparti'))!;
        final rows = <List<Object?>>[];
        await for (final p in streamQuery(s, 'SELECT id, nome, sede FROM ${s.dialect.tableName(st)} ORDER BY id', const [])) {
          rows.addAll(p);
        }
        final o = ExportOptions(tableName: 'reparti_imp', dialect: d.dialect)..format = ExportFormat.sql;
        final script = DataExporter.exportAll(['id', 'nome', 'sede'], rows, o);
        record('XFR-04/$src→$dst/script', Outcome.ok, script.replaceAll('\n', ' ⏎ '));
        for (final stmt in script.split(RegExp(r';\s*(\n|$)')).map((x) => x.trim()).where((x) => x.isNotEmpty)) {
          await d.main!.execute(stmt);
        }
        final n = await d.main!.execute('SELECT COUNT(*) FROM reparti_imp');
        expect('${n.rows.first.first}', '${rows.length}');
        await d.main!.execute('DROP TABLE reparti_imp');
      });
    }

    unawaited(Future<void>.value());
    await finish(tester, app);
  });
}
