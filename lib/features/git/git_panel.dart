// Sidebar panel "Progetto": synchronizes the workspace with a Git
// repository (status, commit, pull / push, history).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../state/app_state.dart';
import '../../state/editor_tabs.dart';
import '../../ui/widgets/common.dart';
import 'git_service.dart';
import 'git_settings.dart';

class GitPanel extends StatefulWidget {
  const GitPanel({super.key, this.onWorkspaceChanged});

  /// Called after a pull / connect changed files of the workspace
  /// (connections.json, settings.json, scripts/…): the app should reload
  /// connections, settings and the scripts list.
  final void Function(List<String> changedFiles)? onWorkspaceChanged;

  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  late final AppState app = AppScope.read(context);
  late final GitService git = GitService(app.workspace.root);
  final _message = TextEditingController();
  Timer? _timer;

  bool _loading = true;
  bool _gitMissing = false;
  bool _isRepo = false;
  GitStatus? _status;
  List<GitCommit> _log = const [];
  String? _remote;
  String? _busy;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      // Only while the panel is visible (IndexedStack disables tickers).
      if (mounted && TickerMode.valuesOf(context).enabled && _busy == null) _refresh(quiet: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _message.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = _status == null);
    try {
      if (await GitService.locateGit() == null && git.gitPath == null) {
        if (mounted) {
          setState(() {
            _gitMissing = true;
            _loading = false;
          });
        }
        return;
      }
      final repo = await git.isRepo();
      GitStatus? st;
      var log = const <GitCommit>[];
      String? remote;
      if (repo) {
        st = await git.status();
        log = await git.log();
        remote = await git.remoteUrl();
      }
      if (!mounted) return;
      setState(() {
        _gitMissing = false;
        _isRepo = repo;
        _status = st;
        _log = log;
        _remote = remote;
        _loading = false;
        if (!quiet) _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!quiet) _error = e.toString();
      });
    }
  }

  /// Runs a git operation with progress and error reporting.
  Future<void> _op(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _error = null;
    });
    try {
      await action();
    } on GitConflictException catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Conflitto');
    } on GitSecretException catch (e) {
      if (mounted) showErrorDialog(context, e.message, title: 'Credenziali nei file');
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: '$label non riuscito');
    } finally {
      if (mounted) setState(() => _busy = null);
      await _refresh(quiet: true);
    }
  }

  void _changed(GitUpdate u) {
    if (u.changed && u.touchesWorkspace) widget.onWorkspaceChanged?.call(u.changedFiles);
    if (u.changed && mounted) showToast(context, '${u.changedFiles.length} file aggiornati dal repository remoto');
  }

  Future<void> _saveEditors() async {
    for (final t in app.tabs.whereType<SqlEditorTab>()) {
      if (t.isDirty) await t.save();
    }
  }

  Future<void> _init() => _op('Inizializzazione', () async {
    await git.init();
    if (mounted) showToast(context, 'Repository creato: password e chiavi restano escluse');
  });

  Future<void> _connect() async {
    final url = await promptText(
      context,
      'Collega repository remoto',
      label: 'https://… oppure git@…:team/progetto.git',
    );
    if (url == null || url.trim().isEmpty) return;
    await _op('Collegamento', () async => _changed(await git.connect(url.trim())));
  }

  Future<void> _pull() => _op('Pull', () async {
    await _saveEditors();
    final s = await GitSettings.load(app.workspace.root);
    _changed(await git.pull(rebase: s.rebase));
  });

  Future<void> _push() => _op('Push', () async {
    await git.push();
    if (mounted) showToast(context, 'Modifiche pubblicate');
  });

  Future<void> _sync() => _op('Sincronizzazione', () async {
    await _saveEditors();
    final s = await GitSettings.load(app.workspace.root);
    _changed(await git.pull(rebase: s.rebase));
    final st = await git.status();
    if (st.hasCommits && (st.upstream == null || st.ahead > 0)) await git.push();
    if (mounted) showToast(context, 'Progetto sincronizzato');
  });

  Future<void> _commit() => _op('Commit', () async {
    await _saveEditors();
    await git.commit(_message.text);
    _message.clear();
    final s = await GitSettings.load(app.workspace.root);
    if (s.autoPush && _remote != null) await git.push();
  });

  Future<void> _discard(GitFileChange f) async {
    final ok = await confirmDialog(
      context,
      f.untracked ? 'Eliminare il file?' : 'Annullare le modifiche?',
      f.untracked
          ? '"${f.path}" non è nel repository: verrà eliminato definitivamente.'
          : 'Le modifiche locali a "${f.path}" andranno perse e il file tornerà all\'ultimo commit.',
      ok: f.untracked ? 'Elimina' : 'Annulla modifiche',
      cancel: 'Mantieni',
      destructive: true,
    );
    if (!ok) return;
    await _op('Ripristino', () async {
      await git.discard(f);
      if (f.path == 'connections.json' || f.path == 'settings.json' || f.path.startsWith('scripts/')) {
        widget.onWorkspaceChanged?.call([f.path]);
      }
    });
  }

  Future<void> _abort() => _op('Annullamento', () async {
    await git.abortPull();
    widget.onWorkspaceChanged?.call(const []);
  });

  Future<void> _showDiff(String title, Future<String> Function() load) async {
    String text;
    try {
      text = await load();
    } catch (e) {
      if (mounted) showErrorDialog(context, e);
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _DiffDialog(title: title, diff: text),
    );
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else if (_gitMissing) {
      body = EmptyState(
        icon: Icons.warning_amber_rounded,
        title: 'Git non trovato',
        message: 'Installa Git per sincronizzare script e connessioni con un repository, poi premi Riprova.',
        action: OutlinedButton(onPressed: _refresh, child: const Text('Riprova')),
      );
    } else if (!_isRepo) {
      body = EmptyState(
        icon: Icons.cloud_sync_outlined,
        title: 'Progetto non sincronizzato',
        message:
            'Salva script, connessioni e impostazioni in un repository Git per condividerli con il team. '
            'Password e chiavi restano nel vault e non vengono mai incluse.',
        action: Column(
          children: [
            PrimaryButton(label: 'Inizializza repository', onPressed: _busy == null ? _init : null),
            const SizedBox(height: Gap.sm),
            TextButton(onPressed: _busy == null ? _connect : null, child: const Text('Collega repository remoto…')),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: TypeSize.caption, color: c.danger),
                ),
              ),
          ],
        ),
      );
    } else {
      body = _repoView();
    }
    return Column(
      children: [
        SizedBox(height: 2, child: _busy != null ? const LinearProgressIndicator(minHeight: 2) : null),
        Expanded(child: body),
      ],
    );
  }

  Widget _repoView() {
    final c = DbColors.of(context);
    final st = _status ?? GitStatus();
    final idle = _busy == null;
    final hasRemote = _remote != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Branch and actions
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 0),
          child: Row(
            children: [
              Icon(Icons.call_split_rounded, size: 15, color: c.textSecondary),
              const SizedBox(width: Gap.xs),
              Flexible(
                child: Text(
                  st.branch ?? 'HEAD scollegato',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.text),
                ),
              ),
              if (st.ahead > 0) ...[
                const SizedBox(width: Gap.xs),
                Tooltip(
                  message: '${st.ahead} commit da pubblicare',
                  child: Badge2('↑${st.ahead}', color: c.accent),
                ),
              ],
              if (st.behind > 0) ...[
                const SizedBox(width: Gap.xs),
                Tooltip(
                  message: '${st.behind} commit da scaricare',
                  child: Badge2('↓${st.behind}', color: c.warning),
                ),
              ],
              const Spacer(),
              ToolButton(icon: Icons.refresh_rounded, tooltip: 'Aggiorna', onPressed: idle ? _refresh : null),
              ToolButton(
                icon: Icons.settings_outlined,
                tooltip: 'Impostazioni di sincronizzazione',
                onPressed: () async {
                  await showGitSettingsDialog(context);
                  await _refresh(quiet: true);
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, 2, Gap.md, Gap.xs),
          child: Text(
            hasRemote ? _remote! : 'Nessun repository remoto',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          child: Row(
            children: [
              if (hasRemote) ...[
                ToolButton(
                  icon: Icons.download_rounded,
                  label: 'Pull',
                  tooltip: 'Scarica le modifiche remote',
                  onPressed: idle ? _pull : null,
                ),
                ToolButton(
                  icon: Icons.upload_rounded,
                  label: 'Push',
                  tooltip: 'Pubblica i commit',
                  onPressed: idle ? _push : null,
                ),
                ToolButton(
                  icon: Icons.sync_rounded,
                  label: 'Sincronizza',
                  tooltip: 'Pull e poi Push',
                  onPressed: idle ? _sync : null,
                ),
              ] else
                TextButton(onPressed: idle ? _connect : null, child: const Text('Collega repository remoto…')),
            ],
          ),
        ),
        if (st.hasConflicts)
          Container(
            margin: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
              color: c.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(Radii.panel),
              border: Border.all(color: c.danger.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pull interrotto da conflitti',
                  style: TextStyle(fontSize: TypeSize.small, fontWeight: FontWeight.w600, color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  'Risolvi i file segnati con ! con un editor o uno strumento Git, oppure annulla per tornare allo stato '
                  'precedente.',
                  style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: idle ? _abort : null, child: const Text('Annulla pull')),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: Gap.md),
            children: [
              SectionLabel('Modifiche', trailing: st.files.isEmpty ? null : Badge2('${st.files.length}')),
              if (st.files.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
                  child: Text(
                    'Nessuna modifica dall\'ultimo commit',
                    style: TextStyle(fontSize: TypeSize.small, color: c.textTertiary),
                  ),
                )
              else
                for (final f in st.files)
                  _FileRow(
                    file: f,
                    onTap: () => _showDiff(f.path, () => git.diffFile(f)),
                    onDiscard: idle && !f.conflicted ? () => _discard(f) : null,
                  ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
                child: TextField(
                  controller: _message,
                  minLines: 2,
                  maxLines: 5,
                  style: const TextStyle(fontSize: TypeSize.body),
                  decoration: const InputDecoration(hintText: 'Messaggio di commit'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: PrimaryButton(
                    label: 'Commit',
                    icon: Icons.check_rounded,
                    tooltip: 'Salva tutte le modifiche in un commit',
                    onPressed: idle && st.files.isNotEmpty && !st.hasConflicts && _message.text.trim().isNotEmpty
                        ? _commit
                        : null,
                  ),
                ),
              ),
              const SectionLabel('Cronologia'),
              if (_log.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
                  child: Text(
                    'Nessun commit',
                    style: TextStyle(fontSize: TypeSize.small, color: c.textTertiary),
                  ),
                )
              else
                for (final cm in _log)
                  _CommitRow(commit: cm, onTap: () => _showDiff(cm.subject, () => git.showCommit(cm.hash))),
            ],
          ),
        ),
      ],
    );
  }
}

String _relative(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'adesso';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min fa';
  if (diff.inHours < 24) return diff.inHours == 1 ? '1 ora fa' : '${diff.inHours} ore fa';
  if (diff.inDays == 1) return 'ieri';
  if (diff.inDays < 7) return '${diff.inDays} giorni fa';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

class _FileRow extends StatefulWidget {
  const _FileRow({required this.file, required this.onTap, this.onDiscard});
  final GitFileChange file;
  final VoidCallback onTap;
  final VoidCallback? onDiscard;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final f = widget.file;
    final color = switch (f.kind) {
      GitChangeKind.untracked || GitChangeKind.added => c.success,
      GitChangeKind.deleted || GitChangeKind.conflicted => c.danger,
      _ => c.warning,
    };
    final dir = p.posix.dirname(f.path);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: '${f.label} — clic per vedere le differenze',
          waitDuration: const Duration(milliseconds: 600),
          child: Container(
            height: 26,
            color: _hover ? c.hover : Colors.transparent,
            padding: const EdgeInsets.only(left: Gap.md, right: Gap.xs),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: Text(
                    f.letter,
                    style: TextStyle(fontSize: TypeSize.small, fontWeight: FontWeight.w700, color: color),
                  ),
                ),
                Flexible(
                  child: Text(
                    p.posix.basename(f.path),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TypeSize.body,
                      color: c.text,
                      decoration: f.kind == GitChangeKind.deleted ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                if (dir != '.') ...[
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(
                      dir,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (_hover && widget.onDiscard != null)
                  ToolButton(
                    icon: f.untracked ? Icons.delete_outline_rounded : Icons.undo_rounded,
                    size: 14,
                    tooltip: f.untracked ? 'Elimina il file' : 'Annulla le modifiche',
                    onPressed: widget.onDiscard,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommitRow extends StatelessWidget {
  const _CommitRow({required this.commit, required this.onTap});
  final GitCommit commit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              commit.subject,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: TypeSize.body, color: c.text),
            ),
            Row(
              children: [
                Text(commit.shortHash, style: monoStyle(context, size: 11, color: c.textTertiary)),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    '${commit.author} · ${_relative(commit.date)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary, fontFeatures: kTabular),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DiffDialog extends StatelessWidget {
  const _DiffDialog({required this.title, required this.diff});
  final String title;
  final String diff;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final lines = diff.split('\n');
    final base = monoStyle(context, size: 12.5);
    Color? fg(String l) {
      if (l.startsWith('+++') || l.startsWith('---') || l.startsWith('diff ') || l.startsWith('index ')) {
        return c.textSecondary;
      }
      if (l.startsWith('+')) return c.success;
      if (l.startsWith('-')) return c.danger;
      if (l.startsWith('@@')) return c.accent;
      return null;
    }

    Color? bg(String l) {
      if (l.startsWith('+') && !l.startsWith('+++')) return c.success.withValues(alpha: 0.10);
      if (l.startsWith('-') && !l.startsWith('---')) return c.danger.withValues(alpha: 0.08);
      return null;
    }

    return Dialog(
      insetPadding: const EdgeInsets.all(Gap.xl),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 900,
        height: 640,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.md, Gap.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge),
                  ),
                  ToolButton(icon: Icons.close_rounded, tooltip: 'Chiudi', onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Divider(height: 1, color: c.separator),
            Expanded(
              child: Container(
                color: c.codeBackground,
                child: SelectionArea(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                    itemCount: lines.length,
                    itemBuilder: (_, i) => Container(
                      color: bg(lines[i]),
                      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                      child: Text(
                        lines[i],
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: base.copyWith(color: fg(lines[i])),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
