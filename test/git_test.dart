import 'dart:io';

import 'package:dbcraft/features/git/git_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('porcelain v2', () {
    test('branch headers and entries', () {
      const out =
          '# branch.oid 1234567890abcdef\x00'
          '# branch.head main\x00'
          '# branch.upstream origin/main\x00'
          '# branch.ab +2 -1\x00'
          '1 .M N... 100644 100644 100644 aaa bbb scripts/Script 1.sql\x00'
          '1 A. N... 000000 100644 100644 000 ccc connections.json\x00'
          '1 D. N... 100644 000000 000000 ddd 000 old.sql\x00'
          '2 R. N... 100644 100644 100644 eee eee R100 scripts/new name.sql\x00scripts/old name.sql\x00'
          'u UU N... 100644 100644 100644 100644 h1 h2 h3 settings.json\x00'
          '? scripts/untracked file.sql\x00';
      final s = parseStatusV2(out);
      expect(s.branch, 'main');
      expect(s.oid, '1234567890abcdef');
      expect(s.upstream, 'origin/main');
      expect(s.ahead, 2);
      expect(s.behind, 1);
      expect(s.hasConflicts, isTrue);
      expect(s.files.first.path, 'settings.json', reason: 'conflicts first');
      final byPath = {for (final f in s.files) f.path: f};
      expect(byPath['scripts/Script 1.sql']!.kind, GitChangeKind.modified);
      expect(byPath['connections.json']!.kind, GitChangeKind.added);
      expect(byPath['old.sql']!.letter, 'D');
      expect(byPath['scripts/new name.sql']!.origPath, 'scripts/old name.sql');
      expect(byPath['scripts/new name.sql']!.kind, GitChangeKind.renamed);
      expect(byPath['scripts/untracked file.sql']!.untracked, isTrue);
      expect(s.files.length, 6);
    });

    test('initial and detached', () {
      final s = parseStatusV2('# branch.oid (initial)\x00# branch.head (detached)\x00');
      expect(s.hasCommits, isFalse);
      expect(s.branch, isNull);
      expect(s.clean, isTrue);
    });
  });

  test('log parsing', () {
    const out =
        'abc1234567\x1fAnna Rossi\x1fanna@example.com\x1f2026-10-01T10:20:30+02:00\x1fAggiunge script\x1e\n'
        'def\x1fLuca\x1fl@x.it\x1f2026-09-30T08:00:00Z\x1fPrimo commit\x1e\n';
    final log = parseLog(out);
    expect(log.length, 2);
    expect(log.first.shortHash, 'abc1234');
    expect(log.first.author, 'Anna Rossi');
    expect(log.first.subject, 'Aggiunge script');
    expect(log.first.date.toUtc(), DateTime.utc(2026, 10, 1, 8, 20, 30));
    expect(log.last.shortHash, 'def');
  });

  group('.gitignore', () {
    test('adds a managed block keeping user lines', () {
      final out = mergeGitignore('build/\n# mine\n*.log\n', ['vault.json', '*.log', 'vault.key'])!;
      expect(out, 'build/\n# mine\n*.log\n\n$kGitignoreHeader\nvault.json\nvault.key\n');
      expect(mergeGitignore(out, ['vault.json', 'vault.key']), isNull, reason: 'idempotent');
    });

    test('extends the existing block and removes toggled patterns', () {
      const start = '$kGitignoreHeader\nvault.json\nhistory.json\n\nuser.txt\n';
      final out = mergeGitignore(start, ['vault.json', '*.tmp'], remove: ['history.json'])!;
      expect(out, '$kGitignoreHeader\nvault.json\n*.tmp\n\nuser.txt\n');
      expect(GitService.gitignoreIgnoresHistory(out), isFalse);
      expect(GitService.gitignoreIgnoresHistory(start), isTrue);
      expect(GitService.gitignoreIgnoresHistory(''), isTrue, reason: 'history ignored by default');
    });

    test('empty file', () {
      expect(mergeGitignore('', ['a']), '$kGitignoreHeader\na\n');
    });
  });

  group('secret scan', () {
    test('detects credentials', () {
      expect(scanForSecrets('[{"name": "db", "password": "s3cret"}]'), isNotEmpty);
      expect(scanForSecrets('{"clientSecret":"abc"}'), isNotEmpty);
      expect(scanForSecrets('{"secretParams": {"token": "x"}}'), isNotEmpty);
      expect(scanForSecrets('{"connectionString": "Driver=X;UID=a;PWD=hunter2;"}'), isNotEmpty);
      expect(scanForSecrets('-----BEGIN RSA PRIVATE KEY-----\nabc'), isNotEmpty);
      expect(scanForSecrets('key = sk-ant-api03-abcdefghijklmnopqrstuv'), isNotEmpty);
    });

    test('ignores empty values and flags', () {
      expect(scanForSecrets('[{"name": "db", "password": "", "savePassword": true, "secretParams": {}}]'), isEmpty);
      expect(scanForSecrets('{"connectionString": "Driver=X;PWD={password};"}'), isEmpty);
      expect(scanForSecrets('select * from users where password = :p'), isEmpty);
    });
  });

  group('real repositories', () {
    late Directory tmp;
    late String? gitPath;
    // Isolate the tests from the user's global configuration.
    final env = {
      'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_AUTHOR_NAME': 'Test',
      'GIT_AUTHOR_EMAIL': 'test@example.com',
      'GIT_COMMITTER_NAME': 'Test',
      'GIT_COMMITTER_EMAIL': 'test@example.com',
    };

    setUpAll(() async => gitPath = await GitService.locateGit());

    setUp(() async => tmp = await Directory.systemTemp.createTemp('dbcraft_git_test_'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<GitService> workspace(String name) async {
      final d = Directory(p.join(tmp.path, name));
      await Directory(p.join(d.path, 'scripts')).create(recursive: true);
      return GitService(d, gitPath: gitPath, environment: env);
    }

    Future<void> write(GitService g, String path, String content) async {
      final f = File(p.join(g.root.path, path));
      await f.parent.create(recursive: true);
      await f.writeAsString(content);
    }

    test('init, ignore secrets, commit, log, diff, discard', () async {
      if (gitPath == null) return markTestSkipped('git not installed');
      final g = await workspace('ws');
      expect(await g.isRepo(), isFalse);
      await write(g, 'vault.json', '{"data": "x"}');
      await write(g, 'vault.key', 'abc');
      await write(g, 'history.json', '[]');
      await write(g, 'connections.json', '[{"name": "db", "password": ""}]');
      await write(g, 'scripts/Script-1.sql', 'select 1;\n');
      await g.init();
      expect(await g.isRepo(), isTrue);
      final ignore = await File(p.join(g.root.path, '.gitignore')).readAsString();
      expect(ignore, contains('vault.json'));
      expect(ignore, contains('history.json'));

      final st = await g.status();
      final paths = st.files.map((f) => f.path).toSet();
      expect(paths, containsAll(['connections.json', 'scripts/Script-1.sql', '.gitignore']));
      expect(paths.intersection({'vault.json', 'vault.key', 'history.json'}), isEmpty);

      await g.commit('Primo commit');
      expect((await g.status()).clean, isTrue);
      final log = await g.log();
      expect(log.single.subject, 'Primo commit');

      await write(g, 'scripts/Script-1.sql', 'select 2;\n');
      final changed = (await g.status()).files.single;
      expect(changed.kind, GitChangeKind.modified);
      final diff = await g.diffFile(changed);
      expect(diff, contains('-select 1;'));
      expect(diff, contains('+select 2;'));
      await g.discard(changed);
      expect(await File(p.join(g.root.path, 'scripts/Script-1.sql')).readAsString(), 'select 1;\n');

      // Including the history un-ignores it.
      await g.ensureGitignore(includeHistory: true);
      expect(await g.historyIncluded(), isTrue);
      expect((await g.status()).files.map((f) => f.path), contains('history.json'));
    });

    test('commit is blocked by clear text passwords', () async {
      if (gitPath == null) return markTestSkipped('git not installed');
      final g = await workspace('ws');
      await g.init();
      await write(g, 'connections.json', '[{"name": "db", "password": "hunter2"}]');
      await expectLater(g.commit('Con password'), throwsA(isA<GitSecretException>()));
      // Nothing stays staged and no commit was made.
      expect(await g.log(), isEmpty);
      final st = await g.status();
      expect(st.files.every((f) => f.untracked), isTrue);
    });

    test('push, connect a second workspace, pull changes', () async {
      if (gitPath == null) return markTestSkipped('git not installed');
      final remote = Directory(p.join(tmp.path, 'remote.git'));
      await remote.create();
      final bare = await Process.run(gitPath!, ['init', '--bare', '-b', 'main', remote.path], environment: env);
      expect(bare.exitCode, 0, reason: '${bare.stderr}');

      final a = await workspace('a');
      await write(a, 'scripts/report.sql', 'select * from t;\n');
      await write(a, 'connections.json', '[]');
      await a.init();
      await a.setRemote(remote.path);
      await a.commit('Script iniziale');
      await a.push();
      final sa = await a.status();
      expect(sa.upstream, 'origin/main');
      expect(sa.ahead, 0);

      // Second computer: local files exist already, remote history adopted.
      final b = await workspace('b');
      await write(b, 'connections.json', '[{"name": "locale"}]');
      final update = await b.connect(remote.path);
      expect(update.changedFiles, contains('scripts/report.sql'));
      expect(update.touchesWorkspace, isTrue);
      expect(await File(p.join(b.root.path, 'scripts/report.sql')).exists(), isTrue);
      final sb = await b.status();
      expect(sb.branch, 'main');
      expect(sb.upstream, 'origin/main');
      expect(sb.files.map((f) => f.path), contains('connections.json'), reason: 'local version kept as a change');

      // A change made on A arrives on B with pull (local changes autostashed).
      await write(a, 'scripts/report.sql', 'select * from t where x = 1;\n');
      await a.commit('Filtro');
      await a.push();
      final pulled = await b.pull(rebase: true);
      expect(pulled.changedFiles, ['scripts/report.sql']);
      expect(await File(p.join(b.root.path, 'scripts/report.sql')).readAsString(), contains('x = 1'));
      expect(await File(p.join(b.root.path, 'connections.json')).readAsString(), contains('locale'));
    });

    test('conflicting pull is detected and can be aborted', () async {
      if (gitPath == null) return markTestSkipped('git not installed');
      final remote = Directory(p.join(tmp.path, 'remote.git'));
      await remote.create();
      await Process.run(gitPath!, ['init', '--bare', '-b', 'main', remote.path], environment: env);
      final a = await workspace('a');
      await write(a, 'scripts/q.sql', 'select 1;\n');
      await a.init();
      await a.setRemote(remote.path);
      await a.commit('Base');
      await a.push();
      final b = await workspace('b');
      await b.connect(remote.path);

      await write(a, 'scripts/q.sql', 'select 2;\n');
      await a.commit('A');
      await a.push();
      await write(b, 'scripts/q.sql', 'select 3;\n');
      await b.commit('B');

      await expectLater(
        b.pull(rebase: true),
        throwsA(isA<GitConflictException>().having((e) => e.files, 'files', ['scripts/q.sql'])),
      );
      expect((await b.status()).hasConflicts, isTrue);
      await b.abortPull();
      expect((await b.status()).hasConflicts, isFalse);
      expect(await File(p.join(b.root.path, 'scripts/q.sql')).readAsString(), 'select 3;\n');
      await expectLater(b.push(), throwsA(isA<GitException>().having((e) => e.message, 'message', contains('Pull'))));
    });
  });
}
