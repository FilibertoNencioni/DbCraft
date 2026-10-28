// Application-wide cases of the test matrix: vault and master password
// (VLT-01), Git projects and the secret scan (GIT-01/02), preferences
// (PRF-01), unsaved changes and persistence (UI-01, UI-03), dark theme (UI-04).
//
//   flutter test integration_test/matrix/appwide_test.dart -d macos \
//     --dart-define=TARGET=app --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix
import 'dart:async';
import 'dart:io';

import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:dbcraft/features/git/git_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness.dart';
import 'targets.dart';
import 'ui.dart';

Future<String> git(String dir, List<String> args) async {
  final r = await Process.run('git', args, workingDirectory: dir);
  return '${r.stdout}${r.stderr}'.trim();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('appwide', (tester) async {
    final sqlite = targets['sqlite']!;
    await sqlite.prepare!();
    final ws = Directory.systemTemp.createTempSync('dbcraft_matrix_ws');
    final app = await startApp(tester, workspace: ws, connections: [sqlite.connection()]);
    BuildContext ctx() => tester.element(find.byType(HomePage));
    final dc = app.connections.first;

    // --- PRF-01: preferences applied at once and kept -------------------------
    await check(tester, 'PRF-01', () async {
      app.settings.fetchSize = 50;
      app.settings.nullText = '(nullo)';
      await app.saveSettings();
      await app.connect(dc);
      final tab = await app.openSqlEditor(dc, initialSql: 'SELECT * FROM tipi ORDER BY id');
      await runEditor(tester, tab);
      await shot(tester, 'prf01_null_text');
      expect(find.text('(nullo)'), findsWidgets, reason: 'testo NULL non applicato');
      final big = await app.openSqlEditor(dc, initialSql: 'SELECT * FROM grande');
      await runEditor(tester, big);
      expect(lastModel(big).rows.length, 50, reason: 'dimensione di fetch non applicata');
      app.settings.themeMode = ThemeMode.dark;
      await app.saveSettings();
      await settle(tester, 1000);
      await shot(tester, 'ui04_dark_grid');
      final again = await AppState.load(workspaceDir: ws);
      expect(again.settings.fetchSize, 50);
      expect(again.settings.nullText, '(nullo)');
      app.settings.themeMode = ThemeMode.light;
      app.settings.fetchSize = 200;
      app.settings.nullText = '[NULL]';
      await app.saveSettings();
    });

    // --- UI-01: closing a table with unsaved data changes asks first ----------
    await check(tester, 'UI-01', () async {
      final t = (await dc.metadata!.findTable(null, null, 'reparti'))!;
      app.openTable(dc, t, page: 1);
      final tab = app.currentTab as TableEditorTab;
      final m = await waitModel(tester, tab);
      m.setValue(0, 2, 'cambiata');
      await settle(tester, 400);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await settle(tester, 800);
      final asked = app.tabs.contains(tab);
      await shot(tester, 'ui01_close_dirty');
      record('UI-01/asked', asked ? Outcome.ok : Outcome.defect, asked ? 'scheda non chiusa: richiesta mostrata' : 'scheda chiusa senza chiedere');
      for (final label in ['Annulla', 'Non salvare', 'Scarta']) {
        if (find.text(label).evaluate().isNotEmpty) {
          await tester.tap(find.text(label).last);
          break;
        }
      }
      await settle(tester, 500);
      m.cancelChanges();
      expect(asked, isTrue);
    });

    // --- GIT-01 / GIT-02 -------------------------------------------------------
    final remote = Directory.systemTemp.createTempSync('dbcraft_matrix_remote');
    await Process.run('git', ['init', '--bare', '-b', 'main', remote.path]);
    await check(tester, 'GIT-01', () async {
      await tester.tap(find.byTooltip('Git').first);
      await settle(tester, 1500);
      await shot(tester, 'git01_panel');
      await tester.tap(find.text('Inizializza repository').last);
      await settle(tester, 3000);
      await shot(tester, 'git01_initialized');
      expect(Directory('${ws.path}/.git').existsSync(), isTrue, reason: 'repository non creato');
      final ignore = File('${ws.path}/.gitignore').readAsStringSync();
      record('GIT-01/gitignore', Outcome.ok, ignore.replaceAll('\n', ' ⏎ '));
      expect(ignore, contains('vault'), reason: 'vault non escluso');
      await git(ws.path, ['config', 'user.name', 'Test Matrix']);
      await git(ws.path, ['config', 'user.email', 'matrix@example.invalid']);
      final msg = find.descendant(of: find.byType(GitPanel), matching: find.byType(EditableText));
      await tester.enterText(msg.last, 'primo commit dal test');
      await settle(tester, 800);
      await tester.tap(find.text('Commit').last);
      await settle(tester, 3000);
      await shot(tester, 'git01_committed');
      final log = await git(ws.path, ['log', '--oneline']);
      record('GIT-01/log', Outcome.ok, log);
      expect(log, contains('primo commit dal test'));
      final tracked = await git(ws.path, ['ls-files']);
      expect(tracked.contains('vault'), isFalse, reason: 'vault nel repository: $tracked');
      await git(ws.path, ['remote', 'add', 'origin', remote.path]);
      await git(ws.path, ['push', '-u', 'origin', 'main']);
      expect(await git(remote.path, ['log', '--oneline', 'main']), contains('primo commit dal test'));
    });

    await check(tester, 'GIT-02', () async {
      // A password inside a connection string (D-007) and a plain one.
      await app.addConnection(ConnectionConfig.fromJson({
        'id': 'str',
        'name': 'Stringa con password',
        'mode': 'connectionString',
        'connectionString': 'Driver={PostgreSQL Unicode};Server=x;Uid=u;Pwd=Segreto_Nella_Stringa1',
      }));
      await settle(tester, 1000);
      await tester.tap(find.byTooltip('Database').first);
      await settle(tester, 1000);
      await tester.tap(find.byTooltip('Git').first);
      await settle(tester, 800);
      await tester.tap(find.descendant(of: find.byType(GitPanel), matching: find.byTooltip('Altre azioni')).first);
      await settle(tester, 600);
      await tester.tap(find.text('Aggiorna').last);
      for (var i = 0; i < 50 && find.descendant(of: find.byType(GitPanel), matching: find.byType(EditableText)).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await shot(tester, 'git02_panel');
      final msg = find.descendant(of: find.byType(GitPanel), matching: find.byType(EditableText));
      await tester.enterText(msg.last, 'connessione con stringa');
      await settle(tester, 800);
      await tester.tap(find.text('Commit').last);
      await settle(tester, 3000);
      await shot(tester, 'git02_after_commit');
      final warned = find.text('Credenziali nei file').evaluate().isNotEmpty;
      final log = await git(ws.path, ['log', '--oneline']);
      final leaked = (await git(ws.path, ['log', '-p'])).contains('Segreto_Nella_Stringa1');
      record('GIT-02/result', leaked && !warned ? Outcome.defect : Outcome.ok, 'avviso: $warned · password nel commit: $leaked · $log');
      if (warned) {
        if (find.text('Mostra dettagli').evaluate().isNotEmpty) await tester.tap(find.text('Mostra dettagli').last);
        await settle(tester, 500);
        await shot(tester, 'git02_warning_details');
        final details = find.byWidgetPredicate((w) => w is RichText).evaluate().map((e) => (e.widget as RichText).text.toPlainText()).where((x) => x.contains('json') || x.contains('password') || x.contains('Pwd')).join(' ‖ ');
        record('GIT-02/details', Outcome.ok, details);
        await tester.tap(find.text('OK').last, warnIfMissed: false);
        await settle(tester, 500);
      }
      expect(leaked && !warned, isFalse, reason: 'password della stringa di connessione committata senza avviso');
    });

    // --- VLT-01: master password, lock and unlock --------------------------------
    await check(tester, 'VLT-01', () async {
      await app.vault.setMasterPassword('Master_Test1!');
      expect(app.vault.usesMasterPassword, isTrue);
      app.lockUi();
      await settle(tester, 1500);
      await shot(tester, 'vlt01_locked');
      final field = find.byType(EditableText).last;
      await tester.enterText(field, 'sbagliata');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester, 2000);
      await shot(tester, 'vlt01_wrong');
      expect(app.vault.isLocked || find.textContaining('Password').evaluate().isNotEmpty, isTrue);
      final ok = await app.unlockUi('Master_Test1!');
      await settle(tester, 1500);
      await shot(tester, 'vlt01_unlocked');
      expect(ok, isTrue);
      // Nothing in the workspace holds a secret in clear text.
      final leaks = <String>[];
      for (final f in ws.listSync(recursive: true).whereType<File>()) {
        if (f.path.contains('/.git/')) continue;
        final text = f.readAsStringSync(encoding: const SystemEncoding());
        if (text.contains('Master_Test1!')) leaks.add(f.path);
      }
      expect(leaks, isEmpty, reason: 'master password in chiaro: $leaks');
      // Restart: the vault starts locked.
      final again = await AppState.load(workspaceDir: ws);
      record('VLT-01/restart', Outcome.ok, 'bloccato all\'avvio: ${again.vault.isLocked}');
      expect(again.vault.isLocked, isTrue);
      await app.vault.setMasterPassword(null);
    });

    // --- UI-03: persistence after a restart --------------------------------------
    await check(tester, 'UI-03', () async {
      final again = await AppState.load(workspaceDir: ws);
      final names = again.connections.map((c) => c.config.name).toList();
      record('UI-03/state', Outcome.ok, 'connessioni ${names.length}, cronologia ${again.history.length}');
      expect(names, containsAll(['Matrix SQLite', 'Stringa con password']));
      expect(again.history, isNotEmpty);
    });

    unawaited(Future<void>.value());
    expect(ctx(), isNotNull);
    await finish(tester, app);
  });
}
