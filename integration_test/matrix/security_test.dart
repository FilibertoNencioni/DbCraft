// Users, roles and permissions through the "Utenti e ruoli" tab (SEC-01…
// SEC-05): a user with a password and a SELECT grant is created from the
// script sheet, then it logs in for real (L3) and the password must never
// appear in the preview, the clipboard or the query history.
//
//   flutter test integration_test/matrix/security_test.dart -d macos \
//     --dart-define=TARGET=pg --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix/security
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbcraft/features/design/ddl/security/security_ddl.dart';
import 'package:dbcraft/features/design/ddl_script.dart';
import 'package:dbcraft/features/design/model/security_defs.dart';
import 'package:dbcraft/features/design/ui/security_tab.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness.dart';
import 'targets.dart';

const _pwd = 'Utente_Segreto_9!';

/// Runs a query as the new user (L3). Returns (exit code, output).
Future<(int, String)> asUser(String target, String user, String sql) async {
  final List<String> cmd = switch (target) {
    'pg' => ['docker', 'exec', '-e', 'PGPASSWORD=$_pwd', 'dbcraft-matrix-pg-1', 'psql', '-h', '127.0.0.1', '-U', user, '-d', 'dbcraft', '-Atc', sql],
    'mssql' => ['docker', 'exec', 'dbcraft-design-mssql-1', '/opt/mssql-tools18/bin/sqlcmd', '-C', '-S', 'localhost', '-U', user, '-P', _pwd, '-d', 'dbcraft', '-b', '-h', '-1', '-Q', sql],
    'mysql' => ['docker', 'exec', 'dbcraft-design-mysql-1', 'mysql', '-h', '127.0.0.1', '-u$user', '-p$_pwd', 'dbcraft', '-N', '-e', sql],
    _ => ['docker', 'exec', 'dbcraft-design-mariadb-1', 'mariadb', '-h', '127.0.0.1', '-u$user', '-p$_pwd', 'dbcraft', '-N', '-e', sql],
  };
  final r = await Process.run(cmd.first, cmd.sublist(1));
  return (r.exitCode, '${r.stdout}${r.stderr}'.trim());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('security', (tester) async {
    final t = current;
    // Leftovers of a previous run; PostgreSQL default USAGE on public.
    final cleanup = switch (t.id) {
      'pg' => 'DROP OWNED BY dbc_utente; DROP ROLE IF EXISTS dbc_utente',
      'mssql' => "IF USER_ID('dbc_utente') IS NOT NULL DROP USER dbc_utente; IF SUSER_ID('dbc_utente') IS NOT NULL DROP LOGIN dbc_utente",
      _ => "DROP USER IF EXISTS 'dbc_utente'@'%'",
    };
    try {
      await t.query(cleanup);
    } catch (_) {}
    if (t.id == 'pg') await t.query('GRANT USAGE ON SCHEMA public TO PUBLIC');
    final app = await startApp(tester, connections: [t.connection()]);
    final dc = app.connections.first;
    BuildContext ctx() => tester.element(find.byType(HomePage));
    await app.connect(dc);
    final family = dc.dialect.family;
    final catalog = family == DbFamily.sqlServer ? 'dbcraft' : null;
    final ddl = SecurityDdl.forFamily(dc.dialect);
    final user = family == DbFamily.sqlServer ? 'dbc_utente' : 'dbc_utente';
    final schema = t.navPath.length > 1 ? t.navPath[1] : null;

    late SecurityTab tab;
    await check(tester, 'SEC-01', () async {
      tab = app.openFeatureTab(SecurityTab(dc, catalog: catalog));
      for (var i = 0; i < 100 && tab.principals.isEmpty && tab.loadError == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await settle(tester, 1500);
      await shot(tester, 'sec01_list');
      expect(tab.loadError, isNull, reason: '${tab.loadError}');
      record('SEC-01/principals', Outcome.ok, tab.principals.map((p) => '${p.kind.name}:${p.name}').take(30).join(', '));
      expect(tab.principals, isNotEmpty);
    });

    await check(tester, 'SEC-02', () async {
      final table = (await dc.metadata!.findTable(null, schema, 'progetti'))!;
      final on = GrantDef(
        privilege: '',
        target: GrantTarget.table,
        catalog: ddl.catalogInGrants ? table.catalog : null,
        schema: table.schema,
        object: table.name,
      );
      if (ddl.kinds.contains(PrincipalKind.login)) {
        await tab.create(ctx(), PrincipalKind.login);
        await settle(tester, 800);
        tab.design!.update(tab.design!.working.copyWith(name: user));
        tab.design!.setPassword(_pwd);
        await settle(tester, 500);
        await shot(tester, 'sec02_login');
        unawaited(tab.save(ctx()));
        await _runSheet(tester, 'sec02_login');
      }
      await tab.create(ctx(), PrincipalKind.user);
      await settle(tester, 800);
      final d = tab.design!;
      d.update(d.working.copyWith(name: user, login: family == DbFamily.sqlServer ? user : null));
      if (family != DbFamily.sqlServer) d.setPassword(_pwd);
      d.setGrant(on, 'SELECT', true);
      await settle(tester, 800);
      await shot(tester, 'sec02_user');
      final preview = d.script().statements.join('\n');
      record('SEC-02/script', Outcome.ok, d.script().statements.map(DdlScript.masked).join(' ⏎ '));
      unawaited(tab.save(ctx()));
      // SEC-03: the visible script and the clipboard never hold the password.
      await waitFor(tester, find.text('Esegui'), seconds: 20);
      await settle(tester, 500);
      await shot(tester, 'sec03_preview');
      final visible = find.byWidgetPredicate((w) => w is RichText).evaluate().map((e) => (e.widget as RichText).text.toPlainText()).join('\n');
      expect(visible.contains(_pwd), isFalse, reason: 'password visibile nell\'anteprima');
      await Clipboard.setData(const ClipboardData(text: ''));
      await tester.tap(find.text('Copia').last);
      await settle(tester, 500);
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      record('SEC-03/clipboard', clip.contains(_pwd) ? Outcome.defect : Outcome.ok, clip.replaceAll('\n', ' ⏎ '));
      expect(clip.contains(_pwd), isFalse, reason: 'password copiata negli appunti');
      await _runSheet(tester, 'sec02_user');
      expect(preview, isNotEmpty);
      // The user logs in, reads, cannot write.
      final (rc, out) = await asUser(t.id, user, 'SELECT COUNT(*) FROM progetti');
      record('SEC-02/select', rc == 0 ? Outcome.ok : Outcome.defect, out);
      expect(rc, 0, reason: 'il nuovo utente non riesce a leggere: $out');
      final (rc2, out2) = await asUser(t.id, user, "UPDATE progetti SET budget = 0 WHERE codice = 'HD-03'");
      record('SEC-02/update', rc2 != 0 ? Outcome.ok : Outcome.defect, out2);
      expect(rc2, isNot(0), reason: 'UPDATE consentito senza permesso');
    });

    await check(tester, 'SEC-03', () async {
      final hist = app.history.map((h) => h.sql).join('\n');
      final files = Directory(app.workspace.root.path).listSync(recursive: true).whereType<File>()
          .where((f) => f.readAsStringSync(encoding: const SystemEncoding()).contains(_pwd)).map((f) => f.path).toList();
      record('SEC-03/history', Outcome.ok, 'voci in cronologia: ${app.history.length}; file con la password: $files');
      expect(hist.contains(_pwd), isFalse, reason: 'password nella cronologia');
      expect(files, isEmpty, reason: 'password in chiaro nel workspace');
      expect(jsonEncode(app.history.map((h) => h.sql).toList()).contains(_pwd), isFalse);
    });

    await check(tester, 'SEC-04', () async {
      await tab.load();
      await settle(tester, 1000);
      final p = tab.principals.firstWhere((x) => x.name.toLowerCase() == user && x.kind == PrincipalKind.user);
      unawaited(tab.drop(ctx(), p));
      await settle(tester, 1000);
      await shot(tester, 'sec04_drop');
      if (find.textContaining('DROP OWNED').evaluate().isNotEmpty) await tester.tap(find.textContaining('DROP OWNED').last);
      await tester.enterText(find.byType(EditableText).last, p.display);
      await settle(tester, 400);
      await tester.tap(find.text('Elimina').last);
      await _runSheet(tester, 'sec04_drop');
      if (ddl.kinds.contains(PrincipalKind.login)) {
        await tab.load();
        final l = tab.principals.where((x) => x.name.toLowerCase() == user && x.kind == PrincipalKind.login).firstOrNull;
        if (l != null) {
          unawaited(tab.drop(ctx(), l));
          await settle(tester, 1000);
          await tester.enterText(find.byType(EditableText).last, l.display);
          await settle(tester, 400);
          await tester.tap(find.text('Elimina').last);
          await _runSheet(tester, 'sec04_drop_login');
        }
      }
      final (rc, out) = await asUser(t.id, user, 'SELECT 1');
      record('SEC-04/login', rc != 0 ? Outcome.ok : Outcome.defect, out);
      expect(rc, isNot(0), reason: 'utente ancora attivo dopo l\'eliminazione');
    });

    await finish(tester, app);
  });
}

Future<void> _runSheet(WidgetTester tester, String name) async {
  for (var i = 0; i < 100 && find.text('Eseguire lo script?').evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (i == 10 && find.text('Esegui').evaluate().isNotEmpty) await tester.tap(find.text('Esegui').last);
  }
  if (find.text('Eseguire lo script?').evaluate().isEmpty) throw TestFailure('$name: nessuna conferma');
  await tester.tap(find.text('Esegui').last);
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.text('Esecuzione interrotta').evaluate().isNotEmpty) {
      if (find.text('Mostra dettagli').evaluate().isNotEmpty) await tester.tap(find.text('Mostra dettagli').last);
      await settle(tester, 400);
      await shot(tester, '${name}_error');
      await tester.tap(find.text('OK').last);
      await settle(tester, 300);
      if (find.text('Chiudi').evaluate().isNotEmpty) await tester.tap(find.text('Chiudi').last);
      throw TestFailure('$name: script interrotto (vedi ${name}_error.png)');
    }
    if (find.text('Eseguire lo script?').evaluate().isEmpty && i > 10 && find.text('Esegui').evaluate().isEmpty) break;
  }
  await settle(tester, 1000);
}
