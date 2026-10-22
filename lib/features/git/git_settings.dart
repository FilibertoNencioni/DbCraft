// Project sync settings. Shared choices live in `.dbcraft/git.json`
// (committed with the project); personal toggles in
// `.dbcraft/git.local.json` (git-ignored). The remote URL and the author
// are stored in the repository configuration itself.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../state/app_state.dart';
import '../../ui/widgets/common.dart';
import 'git_service.dart';

class GitSettings {
  GitSettings({this.rebase = true, this.autoPush = false});

  /// Pull strategy: rebase (linear history) or merge. Shared.
  bool rebase;

  /// Push automatically after each commit. Personal.
  bool autoPush;

  static File _shared(Directory root) => File(p.join(root.path, '.dbcraft', 'git.json'));
  static File _local(Directory root) => File(p.join(root.path, '.dbcraft', 'git.local.json'));

  static Future<Map<String, Object?>> _read(File f) async {
    try {
      if (await f.exists()) return (jsonDecode(await f.readAsString()) as Map).cast();
    } catch (_) {}
    return {};
  }

  static Future<GitSettings> load(Directory root) async {
    final s = await _read(_shared(root));
    final l = await _read(_local(root));
    return GitSettings(rebase: s['pullStrategy'] != 'merge', autoPush: l['autoPush'] as bool? ?? false);
  }

  Future<void> save(Directory root) async {
    const enc = JsonEncoder.withIndent('  ');
    final s = _shared(root), l = _local(root);
    await s.parent.create(recursive: true);
    await s.writeAsString('${enc.convert({'pullStrategy': rebase ? 'rebase' : 'merge'})}\n');
    await l.writeAsString('${enc.convert({'autoPush': autoPush})}\n');
  }
}

/// Remote URL, pull strategy, history, auto-push and author.
Future<void> showGitSettingsDialog(BuildContext context) =>
    showSheet<void>(context, builder: (_) => const _GitSettingsDialog());

class _GitSettingsDialog extends StatefulWidget {
  const _GitSettingsDialog();
  @override
  State<_GitSettingsDialog> createState() => _GitSettingsDialogState();
}

class _GitSettingsDialogState extends State<_GitSettingsDialog> {
  late final AppState app = AppScope.read(context);
  late final GitService git = GitService(app.workspace.root);
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  GitSettings? _settings;
  bool _isRepo = false;
  bool _history = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await GitSettings.load(app.workspace.root);
    var repo = false, history = false;
    try {
      repo = await git.isRepo();
      if (repo) {
        _url.text = await git.remoteUrl() ?? '';
        final (n, e) = await git.author();
        _name.text = n ?? '';
        _email.text = e ?? '';
      }
      history = await git.historyIncluded();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _settings = s;
        _isRepo = repo;
        _history = history;
      });
    }
  }

  Future<void> _save() async {
    final s = _settings;
    if (s == null) return;
    setState(() => _saving = true);
    final ok = await guarded(context, () async {
      await s.save(app.workspace.root);
      if (_isRepo) {
        await git.setRemote(_url.text);
        await git.setAuthor(_name.text, _email.text);
        await git.ensureGitignore(includeHistory: _history);
      }
    }, title: 'Impostazioni Git non salvate');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final s = _settings;
    return SheetScaffold(
      title: 'Sincronizzazione con Git',
      onSubmit: s == null || _saving ? null : _save,
      body: s == null
          ? const SizedBox(
              height: 240,
              child: Center(child: Spinner(size: Spinner.large)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormGroup(
                  title: 'Repository remoto',
                  footer: _isRepo
                      ? 'Le credenziali sono gestite da Git (credential helper o chiave SSH), non da DbCraft.'
                      : 'Inizializza prima il repository dal pannello Progetto.',
                  children: [
                    FormRow(
                      label: 'URL (origin)',
                      child: MacTextField(
                        controller: _url,
                        enabled: _isRepo,
                        mono: true,
                        hint: 'git@github.com:team/progetto-db.git',
                      ),
                    ),
                  ],
                ),
                FormGroup(
                  title: 'Sincronizzazione',
                  children: [
                    FormRow(
                      label: 'Pull',
                      help: 'Strategia condivisa con il team',
                      child: Segmented<bool>(
                        value: s.rebase,
                        items: const [(true, 'Rebase', null), (false, 'Merge', null)],
                        onChanged: (v) => setState(() => s.rebase = v),
                      ),
                    ),
                    FormRow(
                      label: 'Push automatico dopo il commit',
                      help: 'Solo su questo computer',
                      child: DbSwitch(value: s.autoPush, onChanged: (v) => setState(() => s.autoPush = v)),
                    ),
                    FormRow(
                      label: 'Includi la cronologia delle query',
                      help: 'history.json contiene le query eseguite: di solito resta personale',
                      child: DbSwitch(value: _history, onChanged: _isRepo ? (v) => setState(() => _history = v) : null),
                    ),
                  ],
                ),
                FormGroup(
                  title: 'Autore dei commit',
                  footer: 'Salvati nella configurazione di questo repository.',
                  children: [
                    FormRow(
                      label: 'Nome',
                      child: MacTextField(controller: _name, enabled: _isRepo),
                    ),
                    FormRow(
                      label: 'Email',
                      child: MacTextField(controller: _email, enabled: _isRepo),
                    ),
                  ],
                ),
                Text(
                  'Il vault (vault.json, vault.key) e i file temporanei sono sempre esclusi tramite .gitignore; '
                  'prima di ogni commit DbCraft verifica che nessun file contenga password in chiaro.',
                  style: uiText(TypeSize.caption, color: c.textSecondary, height: 1.3),
                ),
              ],
            ),
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: 'Salva', onPressed: s == null || _saving ? null : _save),
      ],
    );
  }
}
