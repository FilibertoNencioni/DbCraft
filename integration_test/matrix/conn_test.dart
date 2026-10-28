// Connection cases of the test matrix (CON-01…CON-15): the connection sheet
// in its three ODBC modes, test results and errors, passwords and the vault,
// production and read-only connections, manual commit, initialization
// queries, folders and a server going down.
//
//   flutter test integration_test/matrix/conn_test.dart -d macos \
//     --dart-define=TARGET=sqlite --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix
import 'dart:convert';
import 'dart:io';

import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/actions.dart';
import 'package:dbcraft/ui/editors/sql_editor_view.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:dbcraft/ui/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness.dart';
import 'targets.dart';
import 'ui.dart';

Future<void> openNewConnection(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Nuova connessione').first);
  await waitFor(tester, find.text('Prova connessione'));
  await settle(tester, 1200);
}

Future<void> pickMode(WidgetTester tester, String mode) async {
  await tester.tap(find.descendant(of: find.byType(SheetScaffold), matching: find.text(mode)).last);
  await settle(tester, 500);
}

Future<void> fillForm(WidgetTester tester, List<(String, String, int)> form) async {
  for (final (label, value, index) in form) {
    await fill(tester, label, value, index: index);
  }
  await settle(tester, 300);
}

/// Presses "Prova connessione" and returns the status text.
Future<String> testConnection(WidgetTester tester, {int seconds = 40}) async {
  await tester.tap(find.text('Prova connessione'));
  await tester.pump(const Duration(milliseconds: 300));
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end) && find.text('Connessione in corso…').evaluate().isNotEmpty) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await settle(tester, 400);
  final texts = find
      .descendant(of: find.byType(SheetScaffold), matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '')
      .where((t) => t.startsWith('Connesso in') || t.startsWith('Connessione non riuscita'))
      .toList();
  return texts.join(' | ');
}

Future<void> closeSheet(WidgetTester tester) async {
  await tester.tap(find.text('Annulla').last);
  await settle(tester, 600);
}

/// Runs [sql] in a new editor through the UI; answers the confirmations
/// with [confirm] and returns the editor.
Future<dynamic> runWithConfirm(
  WidgetTester tester,
  AppState app,
  DbConnection dc,
  String sql, {
  required bool? confirm,
  List<String>? titles,
}) async {
  final tab = await app.openSqlEditor(dc, initialSql: sql);
  await settle(tester, 500);
  await tester.tap(find.descendant(of: find.byType(SqlEditorView), matching: find.text('Esegui')).first);
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    for (final title in ['Connessione di produzione', 'Istruzione pericolosa']) {
      if (find.text(title).evaluate().isNotEmpty) {
        titles?.add(title);
        await shot(tester, 'confirm_${title.replaceAll(' ', '_')}');
        if (confirm == null) continue;
        await tester.tap(find.text(confirm ? 'Continua' : 'Annulla').last, warnIfMissed: false);
        if (confirm && find.text(title).evaluate().isNotEmpty) {
          // Buttons may be labelled differently: take the default action.
          final buttons = find.descendant(
            of: find.ancestor(of: find.text(title), matching: find.byType(Dialog)),
            matching: find.byType(Text),
          );
          record('CON/confirm-buttons', Outcome.ok, buttons.evaluate().map((e) => (e.widget as Text).data).join(', '));
        }
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    if (!tab.running && i > 5) break;
  }
  await settle(tester, 400);
  return tab;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('connections', (tester) async {
    final t = current;
    await t.prepare?.call();
    final ws = Directory.systemTemp.createTempSync('dbcraft_matrix_ws');
    final app = await startApp(tester, workspace: ws);
    BuildContext ctx() => tester.element(find.byType(HomePage));

    // CON-01: the sheet in "Driver ODBC" mode with the template fields.
    await check(tester, 'CON-01', () async {
      await openNewConnection(tester);
      await shot(tester, 'con01_sheet_empty');
      await fill(tester, 'Nome', 'Da dialogo');
      await fillForm(tester, t.form);
      await shot(tester, 'con01_sheet_filled');
      final status = await testConnection(tester);
      await shot(tester, 'con01_tested');
      expect(status, startsWith('Connesso in'), reason: status);
      record('CON-01/test', Outcome.ok, status);
      await tester.tap(find.text('Crea').last);
      await settle(tester, 1000);
      expect(app.connections.map((c) => c.config.name), contains('Da dialogo'));
      final json = File('${ws.path}/connections.json').readAsStringSync();
      expect(json.contains('DbCraft_Test1'), isFalse, reason: 'password in chiaro in connections.json');
    });

    // CON-02: DSN mode.
    await check(tester, 'CON-02', () async {
      await openNewConnection(tester);
      await pickMode(tester, 'DSN');
      await fill(tester, 'Nome', 'Da DSN');
      await fill(tester, 'Data Source', 'DbCraftMatrix_${t.id}');
      for (final (label, value, _) in t.form.where((f) => f.$1 == 'Utente' || f.$1 == 'Password')) {
        await fill(tester, label, value);
      }
      final status = await testConnection(tester);
      await shot(tester, 'con02_dsn');
      expect(status, startsWith('Connesso in'), reason: status);
      await tester.tap(find.text('Crea').last);
      await settle(tester, 800);
    });

    // CON-03: connection string mode.
    await check(tester, 'CON-03', () async {
      await openNewConnection(tester);
      await pickMode(tester, 'Stringa');
      await fill(tester, 'Nome', 'Da stringa');
      final field = find.descendant(of: find.byType(SheetScaffold), matching: find.byType(EditableText));
      // The connection string is the first multi-line field after the name/folder.
      final candidates = field.evaluate().where((e) => (e.widget as EditableText).maxLines != 1).toList();
      await tester.enterText(find.byWidget(candidates.first.widget), t.connectionString);
      await settle(tester, 300);
      final status = await testConnection(tester);
      await shot(tester, 'con03_string');
      expect(status, startsWith('Connesso in'), reason: status);
      await tester.tap(find.text('Crea').last);
      await settle(tester, 800);
      // A password written inside the string.
      final saved = (jsonDecode(File('${ws.path}/connections.json').readAsStringSync()) as List).cast<Map>().firstWhere((e) => e['name'] == 'Da stringa');
      final clear = '${saved['connectionString']}'.contains('DbCraft_Test1');
      record('CON-03/password', clear ? Outcome.defect : Outcome.ok,
          clear ? 'la password scritta nella stringa resta in chiaro in connections.json' : 'stringa salvata senza password');
    });

    // CON-04: failures are reported, fast and without freezing the UI.
    await check(tester, 'CON-04', () async {
      final variants = <String, List<(String, String, int)>>{
        'driver inesistente': [('Driver', 'Driver Che Non Esiste', 0)],
        if (t.form.any((f) => f.$1 == 'Host')) 'porta chiusa': [('Host', '127.0.0.1', 0), ('Host', '1', 1)],
        if (t.form.any((f) => f.$1 == 'Host')) 'host irraggiungibile': [('Host', '10.255.255.1', 0)],
        if (t.form.any((f) => f.$1 == 'Password')) 'password errata': [('Password', 'sbagliata', 0)],
        if (t.form.any((f) => f.$1 == 'Database')) 'database inesistente': [('Database', 'non_esiste', 0)],
        if (t.form.any((f) => f.$1 == 'File')) 'file in cartella inesistente': [('File', '/non/esiste/x.db', 0)],
      };
      final problems = <String>[];
      for (final MapEntry(key: name, value: change) in variants.entries) {
        await openNewConnection(tester);
        await fillForm(tester, t.form);
        await fillForm(tester, change);
        final sw = Stopwatch()..start();
        final status = await testConnection(tester, seconds: 60);
        final ms = sw.elapsedMilliseconds;
        await shot(tester, 'con04_${name.replaceAll(' ', '_')}');
        record('CON-04/$name', status.startsWith('Connesso') ? Outcome.defect : Outcome.ok, '$ms ms · $status');
        if (status.startsWith('Connesso')) problems.add('$name: connessione riuscita');
        if (status.isEmpty) problems.add('$name: nessun messaggio');
        if (ms > 30000) problems.add('$name: ${ms ~/ 1000} s');
        await closeSheet(tester);
      }
      expect(problems, isEmpty);
    });

    // CON-06: password not saved → asked at connect.
    if (!t.form.any((f) => f.$1 == 'Password')) record('CON-06', Outcome.notApplicable, 'il DBMS non usa password');
    if (t.form.any((f) => f.$1 == 'Password')) {
      await check(tester, 'CON-06', () async {
        final cfg = ConnectionConfig.fromJson({
          ...t.connection(),
          'id': 'nopwd',
          'name': 'Senza password',
          'savePassword': false,
        });
        final dc = await app.addConnection(cfg);
        final saved = (jsonDecode(File('${ws.path}/connections.json').readAsStringSync()) as List).cast<Map>().firstWhere((e) => e['id'] == 'nopwd');
        record('CON-06/saved', Outcome.ok, jsonEncode(saved));
        expect(jsonEncode(saved).contains('DbCraft_Test1'), isFalse, reason: 'password salvata con "Salva password" spento');
        final pwd = t.form.firstWhere((f) => f.$1 == 'Password').$2;
        final fut = ensureConnected(ctx(), dc);
        await waitFor(tester, find.textContaining('Password per'));
        await shot(tester, 'con06_prompt');
        await tester.enterText(find.byType(EditableText).last, pwd);
        await tester.tap(find.text('OK').last);
        await settle(tester, 300);
        expect(await fut.timeout(const Duration(seconds: 40)), isTrue);
        await dc.disconnect();
      });
    }

    // CON-07: production asks before modifying data.
    await check(tester, 'CON-07', () async {
      final dc = await app.addConnection(
        ConnectionConfig.fromJson({...t.connection(), 'id': 'prod', 'name': 'Produzione', 'type': 'production'}),
      );
      await app.connect(dc);
      final before = await t.scalar("SELECT budget FROM progetti WHERE codice = 'HD-03'");
      final titles = <String>[];
      await runWithConfirm(
        tester,
        app,
        dc,
        "UPDATE progetti SET budget = budget + 7 WHERE codice = 'HD-03'",
        confirm: false,
        titles: titles,
      );
      expect(titles, contains('Connessione di produzione'));
      expect(
        await t.scalar("SELECT budget FROM progetti WHERE codice = 'HD-03'"),
        before,
        reason: 'modifica eseguita dopo Annulla',
      );
      await runWithConfirm(
        tester,
        app,
        dc,
        "UPDATE progetti SET budget = budget + 7 WHERE codice = 'HD-03'",
        confirm: true,
      );
      final after = await t.scalar("SELECT budget FROM progetti WHERE codice = 'HD-03'");
      expect(num.parse(after) - num.parse(before), 7, reason: 'modifica non eseguita dopo la conferma');
      // A SELECT does not ask.
      final titles2 = <String>[];
      await runWithConfirm(tester, app, dc, 'SELECT * FROM progetti', confirm: null, titles: titles2);
      expect(titles2, isEmpty);
      await shot(tester, 'con07_production');
      await dc.disconnect();
    });

    // CON-08: read-only connection.
    await check(tester, 'CON-08', () async {
      final dc = await app.addConnection(
        ConnectionConfig.fromJson({...t.connection(), 'id': 'ro', 'name': 'Sola lettura', 'readOnly': true}),
      );
      await app.connect(dc);
      final before = await t.scalar("SELECT budget FROM progetti WHERE codice = 'ERP-07'");
      final tab = await runWithConfirm(
        tester,
        app,
        dc,
        "UPDATE progetti SET budget = budget + 1 WHERE codice = 'ERP-07'",
        confirm: true,
      );
      await shot(tester, 'con08_readonly_update');
      final after = await t.scalar("SELECT budget FROM progetti WHERE codice = 'ERP-07'");
      record(
        'CON-08/update',
        after == before ? Outcome.ok : Outcome.defect,
        after == before
            ? 'UPDATE rifiutato: ${tab.results.isEmpty ? '' : tab.results.last.error}'
            : 'UPDATE eseguito su connessione in sola lettura',
      );
      expect(after, before, reason: 'UPDATE eseguito su una connessione in sola lettura');
      await dc.disconnect();
    });

    // CON-09: manual commit, pending counter, commit, rollback, disconnect check.
    await check(tester, 'CON-09', () async {
      final dc = await app.addConnection(
        ConnectionConfig.fromJson({...t.connection(), 'id': 'manual', 'name': 'Manuale', 'autoCommit': false}),
      );
      await app.connect(dc);
      final before = await t.scalar("SELECT budget FROM progetti WHERE codice = 'CRM-22'");
      await runWithConfirm(
        tester,
        app,
        dc,
        "UPDATE progetti SET budget = budget + 100 WHERE codice = 'CRM-22'",
        confirm: true,
      );
      await runWithConfirm(
        tester,
        app,
        dc,
        "UPDATE progetti SET budget = budget + 100 WHERE codice = 'CRM-22'",
        confirm: true,
      );
      await shot(tester, 'con09_pending');
      expect(dc.pendingStatements, 2);
      await dc.rollback();
      expect(await t.scalar("SELECT budget FROM progetti WHERE codice = 'CRM-22'"), before);
      await runWithConfirm(
        tester,
        app,
        dc,
        "UPDATE progetti SET budget = budget + 100 WHERE codice = 'CRM-22'",
        confirm: true,
      );
      // Disconnecting asks what to do with the open transaction.
      final fut = disconnectWithCheck(ctx(), dc);
      await waitFor(tester, find.text('Transazione aperta'));
      await shot(tester, 'con09_disconnect_prompt');
      await tester.tap(find.text('Commit').last);
      await fut.timeout(const Duration(seconds: 20));
      final after = await t.scalar("SELECT budget FROM progetti WHERE codice = 'CRM-22'");
      expect(num.parse(after) - num.parse(before), 100);
      expect(dc.isConnected, isFalse);
    });

    // CON-10: initialization queries on every session.
    await check(tester, 'CON-10', () async {
      final (boot, read, expected) = t.bootstrap;
      final dc = await app.addConnection(
        ConnectionConfig.fromJson({...t.connection(), 'id': 'boot', 'name': 'Bootstrap', 'bootstrapQueries': '$boot;'}),
      );
      await app.connect(dc);
      final r = await dc.main!.execute(read);
      expect('${r.rows.first.first}'.trim(), expected);
      await dc.reconnect();
      final r2 = await dc.main!.execute(read);
      expect('${r2.rows.first.first}'.trim(), expected, reason: 'non riapplicata dopo la riconnessione');
      await dc.disconnect();
    });

    // CON-11: folders survive a restart; CON-12: reconnect / disconnect all.
    await check(tester, 'CON-11', () async {
      await app.addConnection(
        ConnectionConfig.fromJson({...t.connection(), 'id': 'f1', 'name': 'In cartella', 'folder': 'Clienti/Test'}),
      );
      await settle(tester, 800);
      await shot(tester, 'con11_folder');
      final reloaded = await AppState.load(workspaceDir: ws);
      final f = reloaded.connections.firstWhere((c) => c.config.name == 'In cartella');
      expect(f.config.folder, 'Clienti/Test');
      expect(reloaded.connections.length, app.connections.length);
      // Passwords come back from the vault.
      final json = jsonDecode(File('${ws.path}/connections.json').readAsStringSync()) as List;
      expect(json.every((e) => (e as Map)['password'] == null), isTrue);
    });

    await check(tester, 'CON-12', () async {
      final dcs = app.connections.where((c) => c.config.savePassword).take(2).toList();
      for (final dc in dcs) {
        await app.connect(dc);
      }
      await dcs.first.reconnect();
      expect(dcs.first.isConnected, isTrue);
      await app.disconnectAll();
      await settle(tester, 500);
      expect(app.connections.any((c) => c.isConnected), isFalse);
    });

    // CON-15: the server goes away and comes back.
    final down = t.serverDown;
    if (down == null) {
      record('CON-15', Outcome.notApplicable, 'database su file');
    } else {
      await check(tester, 'CON-15', () async {
        final dc = app.connections.first;
        await app.connect(dc);
        await Process.run(down.stop.first, down.stop.sublist(1));
        final sw = Stopwatch()..start();
        Object? error;
        try {
          await dc.main!.execute('SELECT 1').timeout(const Duration(seconds: 60));
        } catch (e) {
          error = e;
        }
        record('CON-15/error', error == null ? Outcome.defect : Outcome.ok, '${sw.elapsedMilliseconds} ms · $error');
        await shot(tester, 'con15_down');
        await Process.run(down.start.first, down.start.sublist(1));
        for (var i = 0; i < 60; i++) {
          try {
            await t.scalar('SELECT 1');
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
        }
        await dc.reconnect();
        final r = await dc.main!.execute('SELECT 1');
        expect(r.rows, isNotEmpty);
        expect(error, isNotNull);
      });
    }

    await finish(tester, app);
  });
}
