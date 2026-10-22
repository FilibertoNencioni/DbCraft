// Screenshots of the sidebar navigators (Script, Cloud, Git) with real
// content: saved scripts, a cloud account and a Git repository with local
// changes and history.
//
//   flutter test integration_test/sidebar_test.dart -d macos \
//     --dart-define=SHOT_DIR=/tmp/dbcraft-shots
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dbcraft/features/git/git_service.dart';
import 'package:dbcraft/main.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/widgets/navigation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

final _shotKey = GlobalKey();

/// Saves the sidebar column (left of the split) at 2x.
Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  if (shotDir.isEmpty) return;
  final ro = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final tabs = tester.getRect(find.byType(SidebarTabs<int>));
  const ratio = 2.0;
  final full = await ro.toImage(pixelRatio: ratio);
  final w = (tabs.right * ratio).round();
  final h = full.height;
  final rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(
    full,
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint(),
  );
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  Directory(shotDir).createSync(recursive: true);
  File('$shotDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
}

Future<void> settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> git(Directory ws, List<String> args, {DateTime? date}) async {
  final env = {
    'GIT_AUTHOR_NAME': 'Giulia Rossi',
    'GIT_AUTHOR_EMAIL': 'giulia@example.com',
    'GIT_COMMITTER_NAME': 'Giulia Rossi',
    'GIT_COMMITTER_EMAIL': 'giulia@example.com',
    if (date != null) 'GIT_AUTHOR_DATE': date.toIso8601String(),
    if (date != null) 'GIT_COMMITTER_DATE': date.toIso8601String(),
  };
  final r = await Process.run('git', args, workingDirectory: ws.path, environment: env);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sidebar navigators', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('dbcraft_sidebar');
    final ws = Directory('${tmp.path}/ws')..createSync();
    File('${ws.path}/connections.json').writeAsStringSync(
      jsonEncode([
        {'id': 'demo', 'name': 'Demo SQLite', 'mode': 'dsn', 'dsn': 'demo', 'type': 'development'},
      ]),
    );
    File('${ws.path}/cloud_accounts.json').writeAsStringSync(
      jsonEncode({
        'accounts': [
          {
            'id': 'a1',
            'name': 'Dati produzione',
            'provider': 'aws',
            'auth': 'awsProfile',
            'fields': {'profile': 'default', 'region': 'eu-south-1'},
          },
          {
            'id': 'a2',
            'name': 'Archivio report',
            'provider': 'azure',
            'auth': 'azureCli',
            'fields': {'storageAccount': 'reportarchive'},
          },
        ],
      }),
    );
    final scripts = Directory('${ws.path}/scripts')..createSync();
    final now = DateTime.now();
    for (final (name, ago) in [
      ('clienti_attivi', const Duration(minutes: 4)),
      ('ordini_per_mese', const Duration(hours: 3)),
      ('fix_indirizzi_fatturazione_duplicati', const Duration(days: 1)),
      ('report_vendite_trimestre', const Duration(days: 5)),
      ('pulizia_log', const Duration(days: 40)),
    ]) {
      final f = File('${scripts.path}/$name.sql')..writeAsStringSync('SELECT 1;\n');
      f.setLastModifiedSync(now.subtract(ago));
    }

    // Repository with history, a remote and pending changes.
    await GitService(ws).init();
    await git(ws, ['add', '-A']);
    await git(ws, ['commit', '-m', 'Importa script del team'], date: now.subtract(const Duration(days: 9)));
    File('${scripts.path}/ordini_per_mese.sql').writeAsStringSync('SELECT mese, COUNT(*) FROM ordini GROUP BY 1;\n');
    await git(ws, ['add', '-A']);
    await git(ws, ['commit', '-m', 'Raggruppa gli ordini per mese'], date: now.subtract(const Duration(days: 2)));
    // Published up to here: the last commit stays local (ahead 1).
    final bare = Directory('${tmp.path}/remote.git');
    await git(tmp, ['init', '--bare', '-b', 'main', bare.path]);
    await git(ws, ['remote', 'add', 'origin', bare.path]);
    await git(ws, ['push', '-u', 'origin', 'main']);
    await git(ws, ['remote', 'set-url', 'origin', 'git@github.com:acme/dbcraft-workspace.git']);
    File('${scripts.path}/clienti_attivi.sql').writeAsStringSync('SELECT * FROM clienti WHERE attivo = 1;\n');
    await git(ws, ['add', '-A']);
    await git(ws, [
      'commit',
      '-m',
      'Filtra i clienti disattivati dal report mensile e aggiorna le note',
    ], date: now.subtract(const Duration(hours: 5)));
    File('${scripts.path}/clienti_attivi.sql').writeAsStringSync('SELECT id, nome FROM clienti WHERE attivo = 1;\n');
    File('${scripts.path}/nuovo_report.sql').writeAsStringSync('SELECT 2;\n');
    File('${scripts.path}/pulizia_log.sql').deleteSync();
    for (final f in scripts.listSync().whereType<File>()) {
      f.setLastModifiedSync(now.subtract(const Duration(hours: 1)));
    }

    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = await AppState.load(workspaceDir: ws);
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      state.settings.themeMode = mode;
      final suffix = mode == ThemeMode.light ? 'light' : 'dark';
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shotKey,
          child: DbCraftApp(state: state),
        ),
      );
      await settle(tester);
      await shot(tester, 's0_database_$suffix');
      await tester.tap(find.byTooltip('Script'));
      await settle(tester);
      await shot(tester, 's1_scripts_$suffix');
      await tester.tap(find.byTooltip('Cloud'));
      await settle(tester);
      await shot(tester, 's2_cloud_$suffix');
      await tester.tap(find.byTooltip('Git'));
      await settle(tester, 3000);
      await shot(tester, 's3_git_$suffix');
      await tester.enterText(find.byType(EditableText).last, 'Aggiorna i report clienti');
      await tester.tap(find.text('clienti_attivi.sql'));
      await settle(tester);
      await shot(tester, 's3b_git_commit_$suffix');
      await tester.tap(find.text('Cronologia'));
      await settle(tester, 1500);
      await shot(tester, 's3c_git_history_$suffix');
      await tester.tap(find.textContaining('Modifiche'));
      await settle(tester);
      await tester.tap(find.byTooltip('Database'));
      await settle(tester);
    }

    // Deleting a script that is open in an editor: the tab closes and the
    // list reloads without touching the removed file.
    await tester.tap(find.byTooltip('Script'));
    await settle(tester);
    await tester.tap(find.text('ordini_per_mese'));
    await settle(tester);
    await tester.tap(find.text('ordini_per_mese').first, buttons: kSecondaryButton);
    await settle(tester, 400);
    await tester.tap(find.text('Elimina').last);
    await settle(tester, 400);
    await tester.tap(find.text('Elimina').last);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(File('${scripts.path}/ordini_per_mese.sql').existsSync(), isFalse);
    expect(find.text('ordini_per_mese'), findsNothing);
    await shot(tester, 's4_scripts_after_delete');
  });
}
