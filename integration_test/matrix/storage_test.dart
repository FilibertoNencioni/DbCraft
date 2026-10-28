// Storage panel cases of the test matrix (CLD-01…CLD-07) against local
// emulators: S3 (RustFS) and Azure Blob Storage (Azurite).
//
//   flutter test integration_test/matrix/storage_test.dart -d macos \
//     --dart-define=TARGET=s3 --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/storage/backends/object_storage.dart';
import 'package:dbcraft/storage/storage_accounts.dart';
import 'package:dbcraft/storage/ui/storage_actions.dart';
import 'package:dbcraft/storage/ui/storage_browser_tab.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'harness.dart';

const _bucket = 'dbcraft-test';
const _azuriteKey = 'Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==';

(StorageAccount, Map<String, String>) account({bool wrong = false}) => switch (target) {
  's3' => (
    StorageAccount(
      name: wrong ? 'S3 sbagliato' : 'RustFS locale',
      provider: StorageProvider.aws,
      authKind: StorageAuthKind.awsKeys,
      fields: {StorageField.accessKeyId: 'dbcraft', StorageField.region: 'us-east-1', StorageField.endpoint: 'http://127.0.0.1:59000', StorageField.pathStyle: 'true'},
    ),
    {StorageSecret.secretAccessKey: wrong ? 'sbagliata' : 'DbCraft_Test1'},
  ),
  _ => (
    StorageAccount(
      name: wrong ? 'Azure sbagliato' : 'Azurite locale',
      provider: StorageProvider.azure,
      authKind: StorageAuthKind.azureSharedKey,
      fields: {StorageField.storageAccount: 'devstoreaccount1', StorageField.endpoint: 'http://127.0.0.1:60000/devstoreaccount1'},
    ),
    {StorageSecret.accountKey: wrong ? 'c2JhZ2xpYXRh' : _azuriteKey},
  ),
};

Future<String> sha(File f) async => (await sha256.bind(f.openRead()).first).toString();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('storage', (tester) async {
    final app = await startApp(tester);
    BuildContext ctx() => tester.element(find.byType(HomePage));
    final store = StorageAccountsStore.of(app);
    final (acc, secrets) = account();
    late ObjectStorage s;
    final dir = Directory('$outDir/files')..createSync(recursive: true);
    final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final prefix = 'run_$run/';

    await check(tester, 'CLD-01', () async {
      await store.add(acc, secrets);
      s = await createObjectStorage(acc, secrets);
      final buckets = await s.listBuckets();
      record('CLD-01/buckets', Outcome.ok, buckets.map((b) => b.name).join(', '));
      expect(buckets.map((b) => b.name), contains(_bucket));
      await tester.tap(find.byTooltip('Storage').first);
      await settle(tester, 1500);
      await shot(tester, 'cld01_panel');
      final json = File('${app.workspace.root.path}/storage_accounts.json').readAsStringSync();
      expect(json.contains(secrets.values.first), isFalse, reason: 'segreto in chiaro in storage_accounts.json');
    });

    await check(tester, 'CLD-02', () async {
      unawaited(storageNewFolder(ctx(), s, _bucket, prefix));
      await waitFor(tester, find.text('Nome della cartella'));
      await tester.enterText(find.byType(EditableText).last, 'cartella con spazi àè');
      await tester.tap(find.text('OK').last);
      await settle(tester, 1500);
      final page = await s.list(_bucket, prefix: prefix);
      record('CLD-02/list', Outcome.ok, '${page.folders.map((o) => o.key)} ${page.files.map((o) => o.key)}');
      expect(page.folders.any((p) => p.key.contains('cartella con spazi àè')), isTrue);
      app.openFeatureTab(StorageBrowserTab(store: store, account: acc, bucket: _bucket, prefix: prefix));
      await settle(tester, 2500);
      await shot(tester, 'cld02_browser');
    });

    final small = File('${dir.path}/piccolo àè 😀.txt')..writeAsStringSync('ciao dal test ${'x' * 1000}');
    final big = File('${dir.path}/grande.bin');
    if (!big.existsSync() || big.lengthSync() != 64 << 20) {
      final r = Random(1);
      final sink = big.openWrite();
      for (var i = 0; i < 64; i++) {
        sink.add(List<int>.generate(1 << 20, (_) => r.nextInt(256)));
      }
      await sink.close();
    }
    final sql = File('${dir.path}/query.sql')..writeAsStringSync('SELECT 42 AS risposta;');

    await check(tester, 'CLD-03', () async {
      final sw = Stopwatch()..start();
      final ok = storageUploadPaths(ctx(), s, _bucket, prefix, [small.path, big.path, sql.path]);
      while (sw.elapsed.inSeconds < 300) {
        await tester.pump(const Duration(milliseconds: 200));
        if (sw.elapsed.inMilliseconds > 1500 && sw.elapsed.inMilliseconds < 1800) await shot(tester, 'cld03_uploading');
        var done = false;
        unawaited(ok.then((_) => done = true));
        await tester.pump(const Duration(milliseconds: 50));
        if (done) break;
      }
      expect(await ok, isTrue);
      record('CLD-03/upload', Outcome.ok, '${sw.elapsedMilliseconds} ms per 64 MB + 2 file');
      for (final f in [small, big]) {
        final name = p.basename(f.path);
        final o = await s.stat(_bucket, '$prefix$name');
        expect(o.size, f.lengthSync());
        final back = File('${dir.path}/scaricato_$name');
        if (back.existsSync()) back.deleteSync();
        final sw2 = Stopwatch()..start();
        await s.download(_bucket, o.key, back);
        record('CLD-03/download', Outcome.ok, '${o.key}: ${sw2.elapsedMilliseconds} ms');
        expect(await sha(back), await sha(f), reason: 'contenuto diverso dopo il download di ${o.key}');
      }
      await shot(tester, 'cld03_done');
    });

    await check(tester, 'CLD-05', () async {
      final key = '$prefix${p.basename(small.path)}';
      final link = await s.shareLink(_bucket, key, const Duration(hours: 1));
      record('CLD-05/link', Outcome.ok, '$link');
      final r = await Process.run('curl', ['-s', '-o', '/dev/null', '-w', '%{http_code}', '$link']);
      final ascii = await s.shareLink(_bucket, '${prefix}grande.bin', const Duration(hours: 1));
      final ra = await Process.run('curl', ['-s', '-o', '/dev/null', '-w', '%{http_code}', '$ascii']);
      final body403 = await Process.run('curl', ['-s', '$link']);
      record('CLD-05/http', Outcome.ok, 'nome non ASCII: HTTP ${r.stdout} · nome ASCII: HTTP ${ra.stdout} · ${'${body403.stdout}'.replaceAll('\n', ' ').substring(0, '${body403.stdout}'.length.clamp(0, 300))}');
      expect(r.stdout, '200', reason: 'link firmato non scaricabile');
      final body = await Process.run('curl', ['-s', '$link']);
      expect(body.stdout, small.readAsStringSync());
      final short = await s.shareLink(_bucket, key, const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(seconds: 4));
      final r2 = await Process.run('curl', ['-s', '-o', '/dev/null', '-w', '%{http_code}', '$short']);
      record('CLD-05/expired', r2.stdout == '200' ? Outcome.defect : Outcome.ok, 'HTTP ${r2.stdout} dopo la scadenza');
      expect(r2.stdout, isNot('200'), reason: 'link scaduto ancora valido');
    });

    await check(tester, 'CLD-06', () async {
      final o = await s.stat(_bucket, '${prefix}query.sql');
      await storageOpenInEditor(ctx(), acc, s, o);
      await settle(tester, 2000);
      await shot(tester, 'cld06_editor');
      final tab = app.tabs.whereType<SqlEditorTab>().last;
      expect(tab.controller.text, contains('SELECT 42'));
    });

    await check(tester, 'CLD-04', () async {
      final o = await s.stat(_bucket, '${prefix}query.sql');
      unawaited(storageRename(ctx(), s, o));
      await settle(tester, 1000);
      await tester.enterText(find.byType(EditableText).last, 'rinominato.sql');
      await tester.tap(find.text('OK').last);
      await settle(tester, 2000);
      final after = await s.list(_bucket, prefix: prefix);
      final keys = after.files.map((x) => x.key).toList();
      record('CLD-04/rename', Outcome.ok, keys.join(', '));
      expect(keys, contains('${prefix}rinominato.sql'));
      expect(keys, isNot(contains('${prefix}query.sql')));
      final all = await s.listAll(_bucket, prefix);
      unawaited(storageDelete(ctx(), s, all));
      await settle(tester, 1000);
      await shot(tester, 'cld04_delete_confirm');
      for (final label in ['Elimina', 'OK', 'Continua']) {
        if (find.text(label).evaluate().isNotEmpty) {
          await tester.tap(find.text(label).last);
          break;
        }
      }
      await settle(tester, 3000);
      final left = await s.listAll(_bucket, prefix);
      expect(left, isEmpty, reason: 'oggetti rimasti: ${left.map((x) => x.key)}');
    });

    await check(tester, 'CLD-07', () async {
      final (bad, badSecrets) = account(wrong: true);
      Object? error;
      try {
        final b = await createObjectStorage(bad, badSecrets);
        await b.listBuckets();
      } catch (e) {
        error = e;
      }
      record('CLD-07/error', error == null ? Outcome.defect : Outcome.ok, '$error');
      expect(error, isNotNull);
      Object? error2;
      try {
        await s.list('bucket-inesistente-xyz');
      } catch (e) {
        error2 = e;
      }
      record('CLD-07/no-bucket', error2 == null ? Outcome.defect : Outcome.ok, '$error2');
    });

    await finish(tester, app);
  });
}
