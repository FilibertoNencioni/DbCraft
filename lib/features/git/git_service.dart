// Project synchronization with Git ("sync projects with Git" of DBeaver
// PRO). The project is the workspace folder: scripts, connections and
// settings. Secrets live in the vault, which is never committed.
//
// Uses the `git` command line through Process (no new packages). Auth is
// left to the user's credential helper / SSH agent; prompts are disabled so
// a command never hangs waiting for input.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class GitException implements Exception {
  GitException(this.message, {this.details});
  final String message;

  /// Raw git output, shown on demand.
  final String? details;

  @override
  String toString() => details == null || details!.trim().isEmpty ? message : '$message\n\n${details!.trim()}';
}

/// The pull stopped on conflicting changes.
class GitConflictException extends GitException {
  GitConflictException(this.files, {super.details})
    : super(
        'Conflitto con le modifiche remote in ${files.length} file. Risolvi i conflitti oppure annulla '
        'l\'operazione per tornare allo stato precedente.',
      );
  final List<String> files;
}

/// The commit was blocked because staged files contain credentials.
class GitSecretException extends GitException {
  GitSecretException(this.findings)
    : super(
        'Commit annullato: alcuni file contengono credenziali in chiaro.\n\n'
        '${findings.map((f) => '• ${f.file}: ${f.reason}').join('\n')}\n\n'
        'Sposta le password nel vault (salva di nuovo la connessione) o escludi il file nel .gitignore.',
      );
  final List<SecretFinding> findings;
}

class GitResult {
  const GitResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
  String get output => [stdout.trim(), stderr.trim()].where((e) => e.isNotEmpty).join('\n');
}

// ---------------------------------------------------------------------------
// Status (porcelain v2)
// ---------------------------------------------------------------------------

enum GitChangeKind { modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted, ignored }

class GitFileChange {
  const GitFileChange({
    required this.path,
    required this.kind,
    this.origPath,
    this.indexStatus = '.',
    this.worktreeStatus = '.',
  });

  final String path;
  final String? origPath;
  final GitChangeKind kind;

  /// X and Y of the porcelain format ('.' = unchanged).
  final String indexStatus;
  final String worktreeStatus;

  bool get untracked => kind == GitChangeKind.untracked;
  bool get conflicted => kind == GitChangeKind.conflicted;

  /// One-letter badge shown in the list.
  String get letter => switch (kind) {
    GitChangeKind.untracked || GitChangeKind.added => 'N',
    GitChangeKind.deleted => 'D',
    GitChangeKind.renamed => 'R',
    GitChangeKind.copied => 'C',
    GitChangeKind.conflicted => '!',
    GitChangeKind.typeChanged => 'T',
    GitChangeKind.ignored => 'I',
    GitChangeKind.modified => 'M',
  };

  String get label => switch (kind) {
    GitChangeKind.untracked => 'Nuovo, non ancora nel repository',
    GitChangeKind.added => 'Aggiunto',
    GitChangeKind.deleted => 'Eliminato',
    GitChangeKind.renamed => 'Rinominato${origPath == null ? '' : ' da $origPath'}',
    GitChangeKind.copied => 'Copiato${origPath == null ? '' : ' da $origPath'}',
    GitChangeKind.conflicted => 'In conflitto',
    GitChangeKind.typeChanged => 'Tipo modificato',
    GitChangeKind.ignored => 'Ignorato',
    GitChangeKind.modified => 'Modificato',
  };
}

class GitStatus {
  GitStatus({this.branch, this.oid, this.upstream, this.ahead = 0, this.behind = 0, List<GitFileChange>? files})
    : files = files ?? [];

  /// Null when detached.
  final String? branch;

  /// Null before the first commit.
  final String? oid;
  final String? upstream;
  final int ahead;
  final int behind;
  final List<GitFileChange> files;

  bool get hasCommits => oid != null;
  bool get clean => files.isEmpty;
  bool get hasConflicts => files.any((f) => f.conflicted);
}

GitChangeKind _kindFromXY(String xy) {
  final x = xy.isNotEmpty ? xy[0] : '.', y = xy.length > 1 ? xy[1] : '.';
  bool any(String c) => x == c || y == c;
  if (any('D')) return GitChangeKind.deleted;
  if (any('A')) return GitChangeKind.added;
  if (any('R')) return GitChangeKind.renamed;
  if (any('C')) return GitChangeKind.copied;
  if (any('T')) return GitChangeKind.typeChanged;
  return GitChangeKind.modified;
}

/// Splits the first [n] space separated fields; the rest of the line is
/// returned as the last element (paths may contain spaces).
List<String> _fields(String line, int n) {
  final out = <String>[];
  var pos = 0;
  for (var i = 0; i < n; i++) {
    final sp = line.indexOf(' ', pos);
    if (sp < 0) {
      out.add(line.substring(pos));
      return out;
    }
    out.add(line.substring(pos, sp));
    pos = sp + 1;
  }
  out.add(line.substring(pos));
  return out;
}

/// Parses `git status --porcelain=v2 --branch -z`.
GitStatus parseStatusV2(String out) {
  String? branch, oid, upstream;
  var ahead = 0, behind = 0;
  final files = <GitFileChange>[];
  final entries = out.split('\x00');
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (e.isEmpty) continue;
    if (e.startsWith('# ')) {
      final f = _fields(e.substring(2), 1);
      final value = f.length > 1 ? f[1] : '';
      switch (f[0]) {
        case 'branch.oid':
          oid = value == '(initial)' ? null : value;
        case 'branch.head':
          branch = value == '(detached)' ? null : value;
        case 'branch.upstream':
          upstream = value;
        case 'branch.ab':
          final m = RegExp(r'\+(\d+) -(\d+)').firstMatch(value);
          if (m != null) {
            ahead = int.parse(m[1]!);
            behind = int.parse(m[2]!);
          }
      }
      continue;
    }
    switch (e[0]) {
      case '1':
        // 1 XY sub mH mI mW hH hI path
        final f = _fields(e, 8);
        if (f.length < 9) continue;
        files.add(
          GitFileChange(
            path: f[8],
            kind: _kindFromXY(f[1]),
            indexStatus: f[1][0],
            worktreeStatus: f[1].length > 1 ? f[1][1] : '.',
          ),
        );
      case '2':
        // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
        final f = _fields(e, 9);
        if (f.length < 10) continue;
        final orig = i + 1 < entries.length ? entries[++i] : null;
        files.add(
          GitFileChange(
            path: f[9],
            origPath: orig,
            kind: f[8].startsWith('C') ? GitChangeKind.copied : GitChangeKind.renamed,
            indexStatus: f[1][0],
            worktreeStatus: f[1].length > 1 ? f[1][1] : '.',
          ),
        );
      case 'u':
        // u XY sub m1 m2 m3 mW h1 h2 h3 path
        final f = _fields(e, 10);
        if (f.length < 11) continue;
        files.add(
          GitFileChange(
            path: f[10],
            kind: GitChangeKind.conflicted,
            indexStatus: f[1][0],
            worktreeStatus: f[1].length > 1 ? f[1][1] : '.',
          ),
        );
      case '?':
        files.add(
          GitFileChange(path: e.substring(2), kind: GitChangeKind.untracked, indexStatus: '?', worktreeStatus: '?'),
        );
      case '!':
        files.add(
          GitFileChange(path: e.substring(2), kind: GitChangeKind.ignored, indexStatus: '!', worktreeStatus: '!'),
        );
    }
  }
  files.sort((a, b) {
    if (a.conflicted != b.conflicted) return a.conflicted ? -1 : 1;
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });
  return GitStatus(branch: branch, oid: oid, upstream: upstream, ahead: ahead, behind: behind, files: files);
}

// ---------------------------------------------------------------------------
// Log
// ---------------------------------------------------------------------------

class GitCommit {
  const GitCommit({
    required this.hash,
    required this.author,
    required this.email,
    required this.date,
    required this.subject,
  });
  final String hash;
  final String author;
  final String email;
  final DateTime date;
  final String subject;
  String get shortHash => hash.length > 7 ? hash.substring(0, 7) : hash;
}

/// `git log` format used by [parseLog] (fields 0x1F, records 0x1E).
const kGitLogFormat = '--format=%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e';

List<GitCommit> parseLog(String out) {
  final list = <GitCommit>[];
  for (final rec in out.split('\x1e')) {
    final r = rec.trim();
    if (r.isEmpty) continue;
    final f = r.split('\x1f');
    if (f.length < 5) continue;
    list.add(
      GitCommit(
        hash: f[0],
        author: f[1],
        email: f[2],
        date: DateTime.tryParse(f[3])?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
        subject: f.sublist(4).join(' '),
      ),
    );
  }
  return list;
}

// ---------------------------------------------------------------------------
// .gitignore and secret scan
// ---------------------------------------------------------------------------

const kGitignoreHeader = '# DbCraft: segreti e file locali (non rimuovere)';

/// Patterns that must never be committed.
const kGitRequiredIgnores = [
  'vault.json',
  'vault.key',
  '*.tmp',
  '.dbcraft/*.local.json',
  '*.pem',
  '*.p12',
  '*.pfx',
  '.env',
  '.DS_Store',
  'Thumbs.db',
];

/// The personal query history (toggle "Includi la cronologia").
const kGitHistoryFile = 'history.json';

/// Returns the new .gitignore content adding the missing [required]
/// patterns (and removing [remove] from the DbCraft block), or null when
/// nothing changes. User lines are never touched.
String? mergeGitignore(String existing, List<String> required, {List<String> remove = const []}) {
  final lines = existing.replaceAll('\r\n', '\n').split('\n');
  final present = {for (final l in lines) l.trim()};
  var changed = false;
  // Remove patterns from the managed block only.
  if (remove.isNotEmpty) {
    final start = lines.indexWhere((l) => l.trim() == kGitignoreHeader);
    if (start >= 0) {
      for (var i = start + 1; i < lines.length && lines[i].trim().isNotEmpty; i++) {
        if (remove.contains(lines[i].trim())) {
          lines.removeAt(i--);
          changed = true;
        }
      }
    }
  }
  final missing = [
    for (final r in required)
      if (!present.contains(r) && !present.contains('/$r')) r,
  ];
  if (missing.isEmpty && !changed) return null;
  if (missing.isNotEmpty) {
    final start = lines.indexWhere((l) => l.trim() == kGitignoreHeader);
    if (start >= 0) {
      var end = start + 1;
      while (end < lines.length && lines[end].trim().isNotEmpty) {
        end++;
      }
      lines.insertAll(end, missing);
    } else {
      while (lines.isNotEmpty && lines.last.trim().isEmpty) {
        lines.removeLast();
      }
      if (lines.isNotEmpty) lines.add('');
      lines
        ..add(kGitignoreHeader)
        ..addAll(missing);
    }
  }
  var out = lines.join('\n');
  if (!out.endsWith('\n')) out = '$out\n';
  return out;
}

class SecretFinding {
  const SecretFinding(this.file, this.reason);
  final String file;
  final String reason;
}

final _secretKeyRe = RegExp(
  r'"(password|passwd|pwd|secret|clientSecret|client_secret|apiKey|api_key|privateKey|private_key|accessToken|'
  r'access_token|refreshToken|refresh_token|secretAccessKey|secret_access_key|sessionToken)"\s*:\s*"((?:[^"\\]|\\.)*)"',
  caseSensitive: false,
);
final _connStringPwdRe = RegExp(
  // Inside an ODBC-style "KEY=value;" list only (not SQL text like "password = :p").
  r'(?:^|[;"])\s*(?:pwd|password)\s*=\s*([^;"\s{$:?][^;"]*)',
  caseSensitive: false,
);
final _secretParamsRe = RegExp(r'"secretParams"\s*:\s*\{\s*"');
final _privateKeyRe = RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----');
final _anthropicKeyRe = RegExp(r'sk-ant-[A-Za-z0-9_\-]{16,}');
final _awsKeyRe = RegExp(r'\bAKIA[0-9A-Z]{16}\b');

/// Looks for credentials in clear text in a file about to be committed.
List<String> scanForSecrets(String content) {
  final out = <String>[];
  for (final m in _secretKeyRe.allMatches(content)) {
    if (m[2]!.isNotEmpty) {
      out.add('campo "${m[1]}" valorizzato');
      break;
    }
  }
  if (_secretParamsRe.hasMatch(content)) out.add('parametri segreti ("secretParams")');
  if (_connStringPwdRe.hasMatch(content)) out.add('password in una stringa di connessione');
  if (_privateKeyRe.hasMatch(content)) out.add('chiave privata');
  if (_anthropicKeyRe.hasMatch(content)) out.add('chiave API di Anthropic');
  if (_awsKeyRe.hasMatch(content)) out.add('chiave di accesso AWS');
  return out;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// What a pull / connect changed in the working tree.
class GitUpdate {
  const GitUpdate(this.changedFiles);
  final List<String> changedFiles;
  bool get changed => changedFiles.isNotEmpty;

  /// The app must reload connections / settings / scripts.
  bool get touchesWorkspace => changedFiles.any(
    (f) => f == 'connections.json' || f == 'settings.json' || f == kGitHistoryFile || f.startsWith('scripts/'),
  );
}

class GitService {
  GitService(this.root, {this.gitPath, Map<String, String>? environment}) : _extraEnv = environment ?? const {};

  final Directory root;

  /// Explicit git executable; located on PATH when null.
  String? gitPath;
  final Map<String, String> _extraEnv;

  static const _local = Duration(seconds: 30);
  static const _network = Duration(minutes: 2);

  /// Finds git on PATH and in the usual install locations (GUI apps on
  /// macOS do not inherit the shell PATH).
  static Future<String?> locateGit() async {
    final exe = Platform.isWindows ? 'git.exe' : 'git';
    final sep = Platform.isWindows ? ';' : ':';
    final dirs = [
      ...(Platform.environment['PATH'] ?? '').split(sep).where((e) => e.isNotEmpty),
      if (Platform.isMacOS) ...['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'],
      if (Platform.isLinux) ...['/usr/bin', '/usr/local/bin', '/snap/bin'],
      if (Platform.isWindows) ...[r'C:\Program Files\Git\cmd', r'C:\Program Files (x86)\Git\cmd'],
    ];
    for (final d in dirs) {
      final f = File(p.join(d, exe));
      if (await f.exists()) return f.path;
    }
    return null;
  }

  Future<String> _git() async {
    final g = gitPath ??= await locateGit();
    if (g == null) {
      throw GitException(
        'Git non è installato o non è nel PATH. Installa Git (git-scm.com'
        '${Platform.isMacOS ? ' oppure "xcode-select --install"' : ''}) e riprova.',
      );
    }
    return g;
  }

  Map<String, String> get _env => {
    'GIT_TERMINAL_PROMPT': '0',
    'GCM_INTERACTIVE': 'never',
    'LC_ALL': 'C',
    'LANG': 'C',
    // Never open an editor (merge messages, rebase todo lists).
    'GIT_EDITOR': 'true',
    'GIT_SEQUENCE_EDITOR': 'true',
    'GIT_MERGE_AUTOEDIT': 'no',
    ..._extraEnv,
  };

  /// Runs git in the workspace; [check] turns a non-zero exit into a
  /// [GitException].
  Future<GitResult> run(List<String> args, {Duration timeout = _local, bool check = true}) async {
    final git = await _git();
    final Process proc;
    try {
      proc = await Process.start(
        git,
        ['-c', 'core.quotepath=off', '-c', 'color.ui=never', ...args],
        workingDirectory: root.path,
        environment: _env,
      );
    } on ProcessException catch (e) {
      throw GitException('Impossibile avviare git: ${e.message}');
    }
    unawaited(proc.stdin.close());
    final out = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final err = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      proc.kill();
      throw GitException(
        'Git non ha risposto entro ${timeout.inSeconds} secondi (git ${args.first}). '
        'Controlla la rete e le credenziali del repository remoto.',
      );
    }
    final r = GitResult(code, await out, await err);
    if (check && !r.ok) throw _error(args, r);
    return r;
  }

  GitException _error(List<String> args, GitResult r) {
    final text = r.output;
    final low = text.toLowerCase();
    if (low.contains('please tell me who you are') || low.contains('unable to auto-detect email')) {
      return GitException(
        'Nome ed email dell\'autore non configurati: impostali nelle impostazioni di Git.',
        details: text,
      );
    }
    if (low.contains('authentication failed') ||
        low.contains('could not read username') ||
        low.contains('terminal prompts disabled') ||
        low.contains('permission denied (publickey)') ||
        low.contains('host key verification failed')) {
      return GitException(
        'Accesso al repository remoto non riuscito: configura le credenziali (credential helper '
        'o chiave SSH nell\'agente) e riprova.',
        details: text,
      );
    }
    if (low.contains('could not resolve host') ||
        low.contains('unable to access') ||
        low.contains('connection timed out')) {
      return GitException(
        'Repository remoto non raggiungibile: controlla l\'indirizzo e la connessione di rete.',
        details: text,
      );
    }
    if (low.contains('repository not found') || low.contains('does not appear to be a git repository')) {
      return GitException('Repository remoto non trovato: controlla l\'URL e i permessi.', details: text);
    }
    if (low.contains('[rejected]') || low.contains('non-fast-forward') || low.contains('fetch first')) {
      return GitException(
        'Il repository remoto contiene modifiche che non hai ancora: esegui Pull (o Sincronizza) '
        'prima di Push.',
        details: text,
      );
    }
    if (low.contains('no upstream') || low.contains('no tracking information')) {
      return GitException(
        'Il ramo corrente non è collegato a un ramo remoto: esegui Push per pubblicarlo.',
        details: text,
      );
    }
    return GitException('Comando git ${args.first} non riuscito.', details: text);
  }

  // -------------------------------------------------------------------------
  // Repository
  // -------------------------------------------------------------------------

  static String _canon(String path) {
    try {
      return p.normalize(Directory(path).resolveSymbolicLinksSync());
    } catch (_) {
      return p.normalize(path);
    }
  }

  /// True when the workspace itself is the root of a repository (a parent
  /// repository, e.g. a dotfiles repo in the home folder, does not count).
  Future<bool> isRepo() async {
    final r = await run(['rev-parse', '--show-toplevel'], check: false);
    if (!r.ok) return false;
    final top = r.stdout.trim();
    return top.isNotEmpty && _canon(top) == _canon(root.path);
  }

  Future<void> init({String branch = 'main'}) async {
    final r = await run(['init', '-b', branch], check: false);
    if (!r.ok) {
      // git < 2.28 has no -b.
      await run(['init']);
      await run(['symbolic-ref', 'HEAD', 'refs/heads/$branch']);
    }
    await ensureGitignore();
  }

  File get _gitignore => File(p.join(root.path, '.gitignore'));

  /// Writes the required patterns in .gitignore. History is ignored unless
  /// [includeHistory] (null: keep the current choice).
  Future<bool> ensureGitignore({bool? includeHistory}) async {
    final f = _gitignore;
    final existing = await f.exists() ? await f.readAsString() : '';
    final history = includeHistory ?? !gitignoreIgnoresHistory(existing, defaultValue: true);
    final merged = mergeGitignore(existing, [
      ...kGitRequiredIgnores,
      if (!history) kGitHistoryFile,
    ], remove: history ? const [kGitHistoryFile] : const []);
    if (merged == null) return false;
    await f.writeAsString(merged);
    return true;
  }

  /// Whether .gitignore excludes the query history ([defaultValue] for a
  /// workspace without a DbCraft block yet).
  static bool gitignoreIgnoresHistory(String content, {bool defaultValue = true}) {
    final lines = content.split('\n').map((e) => e.trim()).toList();
    if (!lines.contains(kGitignoreHeader)) return defaultValue || lines.contains(kGitHistoryFile);
    return lines.contains(kGitHistoryFile) || lines.contains('/$kGitHistoryFile');
  }

  Future<bool> historyIncluded() async {
    final f = _gitignore;
    return !gitignoreIgnoresHistory(await f.exists() ? await f.readAsString() : '');
  }

  Future<GitStatus> status() async {
    final r = await run(['status', '--porcelain=v2', '--branch', '-z', '--untracked-files=all']);
    return parseStatusV2(r.stdout);
  }

  Future<String?> remoteUrl({String name = 'origin'}) async {
    final r = await run(['remote', 'get-url', name], check: false);
    return r.ok && r.stdout.trim().isNotEmpty ? r.stdout.trim() : null;
  }

  Future<void> setRemote(String url, {String name = 'origin'}) async {
    final u = url.trim();
    if (u.isEmpty) {
      if (await remoteUrl(name: name) != null) await run(['remote', 'remove', name]);
      return;
    }
    if (await remoteUrl(name: name) == null) {
      await run(['remote', 'add', name, u]);
    } else {
      await run(['remote', 'set-url', name, u]);
    }
  }

  Future<(String?, String?)> author() async {
    final n = await run(['config', '--get', 'user.name'], check: false);
    final e = await run(['config', '--get', 'user.email'], check: false);
    String? v(GitResult r) => r.ok && r.stdout.trim().isNotEmpty ? r.stdout.trim() : null;
    return (v(n), v(e));
  }

  /// Sets the author in the repository configuration (not global).
  Future<void> setAuthor(String name, String email) async {
    if (name.trim().isNotEmpty) await run(['config', 'user.name', name.trim()]);
    if (email.trim().isNotEmpty) await run(['config', 'user.email', email.trim()]);
  }

  Future<void> fetch() => run(['fetch', '--prune', 'origin'], timeout: _network);

  Future<String?> _head() async {
    final r = await run(['rev-parse', '--verify', '-q', 'HEAD'], check: false);
    return r.ok ? r.stdout.trim() : null;
  }

  Future<List<String>> _changedBetween(String? from, String? to) async {
    if (to == null || from == to) return const [];
    if (from == null) {
      final r = await run(['ls-tree', '-r', '--name-only', '-z', to]);
      return r.stdout.split('\x00').where((e) => e.isNotEmpty).toList();
    }
    final r = await run(['diff', '--name-only', '-z', from, to]);
    return r.stdout.split('\x00').where((e) => e.isNotEmpty).toList();
  }

  Future<bool> _inProgress(String name) async =>
      await FileSystemEntity.type(p.join(root.path, '.git', name)) != FileSystemEntityType.notFound;

  /// Pulls the remote changes (rebase or merge, local changes stashed
  /// around the operation).
  Future<GitUpdate> pull({bool rebase = true}) async {
    final st = await status();
    if (st.hasConflicts) {
      throw GitConflictException([
        for (final f in st.files)
          if (f.conflicted) f.path,
      ]);
    }
    if (await remoteUrl() == null) throw GitException('Nessun repository remoto configurato.');
    final before = await _head();
    if (st.upstream == null) {
      // First pull of a branch that is not tracking yet.
      await fetch();
      final b = st.branch ?? 'main';
      final exists = await run(['rev-parse', '--verify', '-q', 'refs/remotes/origin/$b'], check: false);
      if (!exists.ok) return const GitUpdate([]);
      if (before == null) return _adoptRemote(b);
      await run(['branch', '--set-upstream-to=origin/$b'], check: false);
    }
    final r = await run(
      [
        'pull',
        if (rebase) '--rebase' else ...['--no-rebase', '--allow-unrelated-histories'],
        '--autostash',
        'origin',
        ?st.branch,
      ],
      timeout: _network,
      check: false,
    );
    if (!r.ok) {
      final after = await status();
      if (after.hasConflicts || r.output.contains('CONFLICT')) {
        throw GitConflictException([
          for (final f in after.files)
            if (f.conflicted) f.path,
        ], details: r.output);
      }
      throw _error(['pull'], r);
    }
    return GitUpdate(await _changedBetween(before, await _head()));
  }

  /// Aborts a pull that stopped on conflicts (rebase or merge).
  Future<void> abortPull() async {
    if (await _inProgress('rebase-merge') || await _inProgress('rebase-apply')) {
      await run(['rebase', '--abort']);
    } else if (await _inProgress('MERGE_HEAD')) {
      await run(['merge', '--abort']);
    }
    // Both aborts re-apply the autostash of the pull.
  }

  /// Publishes the commits (sets the upstream on the first push).
  Future<void> push() async {
    final st = await status();
    final branch = st.branch;
    if (branch == null) throw GitException('Nessun ramo attivo (HEAD scollegato): impossibile eseguire Push.');
    if (!st.hasCommits) throw GitException('Nessun commit da pubblicare: esegui prima un commit.');
    if (await remoteUrl() == null) throw GitException('Nessun repository remoto configurato.');
    if (st.upstream == null) {
      await run(['push', '--set-upstream', 'origin', branch], timeout: _network);
    } else {
      await run(['push', 'origin', 'HEAD'], timeout: _network);
    }
  }

  /// Connects the workspace to an existing remote repository. When the
  /// remote already has content and the workspace has no commits, the
  /// remote history is adopted keeping the local files: local versions of
  /// shared files show up as changes (to commit or discard) and files that
  /// exist only remotely are restored.
  Future<GitUpdate> connect(String url) async {
    if (!await isRepo()) await init();
    await setRemote(url);
    await fetch();
    final heads = await run(['ls-remote', '--symref', 'origin', 'HEAD'], timeout: _network, check: false);
    final m = RegExp(r'ref: refs/heads/(\S+)\s+HEAD').firstMatch(heads.stdout);
    String? remoteBranch = m?[1];
    if (remoteBranch == null) {
      final b = await run(['branch', '-r', '--format=%(refname:short)'], check: false);
      final list = b.stdout
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.startsWith('origin/') && e != 'origin/HEAD');
      if (list.isNotEmpty) remoteBranch = list.first.substring('origin/'.length);
    }
    if (remoteBranch == null) return const GitUpdate([]); // empty remote: push will publish
    if (await _head() == null) return _adoptRemote(remoteBranch);
    return pull();
  }

  Future<GitUpdate> _adoptRemote(String branch) async {
    await run(['symbolic-ref', 'HEAD', 'refs/heads/$branch']);
    await run(['reset', '-q', 'origin/$branch']);
    await run(['branch', '--set-upstream-to=origin/$branch'], check: false);
    final deleted = await run(['ls-files', '--deleted', '-z']);
    final restore = deleted.stdout.split('\x00').where((e) => e.isNotEmpty).toList();
    if (restore.isNotEmpty) await run(['checkout', '--', ...restore]);
    await ensureGitignore();
    return GitUpdate(restore);
  }

  /// Files that are tracked although ignored (e.g. a vault committed by
  /// mistake before .gitignore existed).
  Future<List<String>> _trackedIgnored() async {
    final r = await run(['ls-files', '-ci', '--exclude-standard', '-z'], check: false);
    return r.stdout.split('\x00').where((e) => e.isNotEmpty).toList();
  }

  Future<List<String>> _staged() async {
    final r = await run(['diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z']);
    return r.stdout.split('\x00').where((e) => e.isNotEmpty).toList();
  }

  /// Scans the staged files for credentials in clear text.
  Future<List<SecretFinding>> scanStaged() async {
    final findings = <SecretFinding>[];
    for (final path in await _staged()) {
      final name = p.basename(path).toLowerCase();
      if (name == 'vault.json' || name == 'vault.key') {
        findings.add(SecretFinding(path, 'vault delle credenziali'));
        continue;
      }
      final f = File(p.join(root.path, path));
      try {
        if (!await f.exists() || await f.length() > 5 * 1024 * 1024) continue;
        final content = await f.readAsString();
        for (final reason in scanForSecrets(content)) {
          findings.add(SecretFinding(path, reason));
        }
      } catch (_) {
        // Binary or unreadable files are not scanned.
      }
    }
    return findings;
  }

  /// Commits all the changes of the workspace. Aborts (unstaging
  /// everything) when credentials are found in the staged files.
  Future<void> commit(String message) async {
    final msg = message.trim();
    if (msg.isEmpty) throw GitException('Scrivi un messaggio di commit.');
    await ensureGitignore();
    final ignored = await _trackedIgnored();
    if (ignored.isNotEmpty) await run(['rm', '--cached', '-q', '--', ...ignored]);
    await run(['add', '-A']);
    final findings = await scanStaged();
    if (findings.isNotEmpty) {
      await run(['reset', '-q'], check: false);
      throw GitSecretException(findings);
    }
    final staged = await run(['diff', '--cached', '--quiet'], check: false);
    if (staged.ok) throw GitException('Nessuna modifica da salvare nel commit.');
    await run(['commit', '-q', '-m', msg]);
  }

  Future<List<GitCommit>> log({int limit = 50}) async {
    final r = await run(['log', '-n', '$limit', kGitLogFormat], check: false);
    if (!r.ok) return const []; // no commits yet
    return parseLog(r.stdout);
  }

  /// Diff of one file against the last commit (or its content if new).
  Future<String> diffFile(GitFileChange f) async {
    if (f.untracked) {
      final file = File(p.join(root.path, f.path));
      try {
        final text = await file.readAsString();
        return text.split('\n').map((l) => '+$l').join('\n');
      } catch (_) {
        return '(file binario)';
      }
    }
    final head = await _head();
    final args = head == null
        ? ['diff', '--cached', '--no-color', '--', f.path]
        : ['diff', '--no-color', 'HEAD', '--', f.path, ?f.origPath];
    final r = await run(args);
    return r.stdout.isEmpty ? '(nessuna differenza di contenuto)' : r.stdout;
  }

  /// Diff of a commit (for the history list).
  Future<String> showCommit(String hash) async {
    final r = await run(['show', '--no-color', '--stat', '--patch', '--format=%H%n%an <%ae>%n%aI%n%n%B', hash]);
    return r.stdout;
  }

  /// Discards the local changes of [f]; new files are deleted.
  Future<void> discard(GitFileChange f) async {
    if (f.untracked) {
      final file = File(p.join(root.path, f.path));
      if (await file.exists()) await file.delete();
      return;
    }
    final head = await _head();
    if (head == null || f.kind == GitChangeKind.added) {
      await run(['rm', '--cached', '-q', '-f', '--', f.path], check: false);
      final file = File(p.join(root.path, f.path));
      if (f.kind == GitChangeKind.added && await file.exists()) await file.delete();
      return;
    }
    await run(['checkout', 'HEAD', '--', f.path, ?f.origPath]);
    if (f.kind == GitChangeKind.renamed) {
      final file = File(p.join(root.path, f.path));
      if (await file.exists()) await file.delete();
    }
  }
}
