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
    await showSheet<void>(
      context,
      size: SheetSize.xlarge,
      builder: (context) => SheetScaffold(
        title: title,
        largeTitle: true,
        onSubmit: () => Navigator.pop(context),
        body: text.trim().isEmpty
            ? const EmptyState(icon: AppIcons.diff, title: 'Nessuna differenza')
            : DiffView.unified(text),
        actions: [PushButton.primary(label: 'Fine', onPressed: () => Navigator.pop(context))],
      ),
    );
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = const Center(child: Spinner(size: Spinner.large));
    } else if (_gitMissing) {
      body = EmptyState(
        icon: AppIcons.warning,
        title: 'Git non trovato',
        message: 'Installa Git per sincronizzare script e connessioni con un repository, poi premi Riprova.',
        action: PushButton(label: 'Riprova', onPressed: _refresh),
      );
    } else if (_error != null && _status == null) {
      body = EmptyState.error(
        _error!,
        title: 'Impossibile leggere il repository',
        action: PushButton(label: 'Riprova', onPressed: _refresh),
      );
    } else if (!_isRepo) {
      body = EmptyState(
        icon: AppIcons.git,
        title: 'Progetto non sincronizzato',
        message:
            'Salva script, connessioni e impostazioni in un repository Git per condividerli con il team. '
            'Password e chiavi restano nel vault e non vengono mai incluse.',
        action: Column(
          children: [
            PushButton.primary(label: 'Inizializza repository', onPressed: _busy == null ? _init : null),
            const SizedBox(height: Gap.sm),
            LinkButton(label: 'Collega repository remoto…', onPressed: _busy == null ? _connect : null),
          ],
        ),
      );
    } else {
      body = _repoView();
    }
    return Column(
      children: [
        LoadingLine(active: _busy != null),
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
              Icon(AppIcons.split, size: 14, color: c.textSecondary),
              const SizedBox(width: Gap.xs),
              Flexible(
                child: Text(
                  st.branch ?? 'HEAD scollegato',
                  overflow: TextOverflow.ellipsis,
                  style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text),
                ),
              ),
              if (st.ahead > 0) ...[
                const SizedBox(width: Gap.xs),
                CountBadge('↑${st.ahead}', tooltip: '${st.ahead} commit da pubblicare'),
              ],
              if (st.behind > 0) ...[
                const SizedBox(width: Gap.xs),
                CountBadge('↓${st.behind}', tooltip: '${st.behind} commit da scaricare'),
              ],
              const Spacer(),
              ToolButton(icon: AppIcons.refresh, tooltip: 'Aggiorna', onPressed: idle ? _refresh : null),
              ToolButton(
                icon: AppIcons.settings,
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
            style: uiText(TypeSize.caption, color: c.textTertiary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          child: Row(
            children: [
              if (hasRemote) ...[
                ToolButton(
                  icon: AppIcons.download,
                  label: 'Pull',
                  tooltip: 'Scarica le modifiche remote',
                  onPressed: idle ? _pull : null,
                ),
                ToolButton(
                  icon: AppIcons.upload,
                  label: 'Push',
                  tooltip: 'Pubblica i commit',
                  onPressed: idle ? _push : null,
                ),
                ToolButton(
                  icon: AppIcons.sync,
                  label: 'Sincronizza',
                  tooltip: 'Pull e poi Push',
                  onPressed: idle ? _sync : null,
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                  child: LinkButton(label: 'Collega repository remoto…', onPressed: idle ? _connect : null),
                ),
            ],
          ),
        ),
        if (st.hasConflicts)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
            child: Notice.card(
              kind: NoticeKind.danger,
              title: 'Pull interrotto da conflitti',
              message:
                  'Risolvi i file segnati con ! con un editor o uno strumento Git, oppure annulla per tornare allo stato '
                  'precedente.',
              actions: [LinkButton(label: 'Annulla pull', small: true, onPressed: idle ? _abort : null)],
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: Gap.md),
            children: [
              SectionLabel('Modifiche', trailing: st.files.isEmpty ? null : CountBadge(st.files.length)),
              if (st.files.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
                  child: Text(
                    'Nessuna modifica dall\'ultimo commit',
                    style: uiText(TypeSize.small, color: c.textTertiary),
                  ),
                )
              else
                for (final f in st.files)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                    child: _FileRow(
                      file: f,
                      onTap: () => _showDiff(f.path, () => git.diffFile(f)),
                      onDiscard: idle && !f.conflicted ? () => _discard(f) : null,
                    ),
                  ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
                child: MacTextField(
                  controller: _message,
                  minLines: 2,
                  maxLines: 5,
                  hint: 'Messaggio di commit',
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: PushButton.primary(
                    label: 'Commit',
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
                  child: Text('Nessun commit', style: uiText(TypeSize.small, color: c.textTertiary)),
                )
              else
                for (final cm in _log)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                    child: ListRow(
                      title: cm.subject,
                      subtitle: '${cm.shortHash} · ${cm.author} · ${_relative(cm.date)}',
                      tooltip: cm.hash,
                      onTap: () => _showDiff(cm.subject, () => git.showCommit(cm.hash)),
                    ),
                  ),
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

/// A changed file: status letter, name, folder on the right; click shows
/// the diff, the "…" menu discards the change.
class _FileRow extends StatelessWidget {
  const _FileRow({required this.file, required this.onTap, this.onDiscard});
  final GitFileChange file;
  final VoidCallback onTap;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final f = file;
    final color = switch (f.kind) {
      GitChangeKind.untracked || GitChangeKind.added => c.success,
      GitChangeKind.deleted || GitChangeKind.conflicted => c.danger,
      _ => c.warning,
    };
    final dir = p.posix.dirname(f.path);
    return OutlineRow(
      dense: true,
      title: p.posix.basename(f.path),
      leading: StatusLetter(f.letter, color: color),
      muted: f.kind == GitChangeKind.deleted,
      detail: dir == '.' ? null : (dir.length > 24 ? '…${dir.substring(dir.length - 23)}' : dir),
      tooltip: '${f.label} — clic per vedere le differenze',
      onTap: onTap,
      onMenu: (pos) => showMacMenu<void>(
        context,
        position: pos,
        entries: [
          MenuEntry('Mostra le differenze', onSelected: onTap),
          const MenuEntry.divider(),
          MenuEntry(
            f.untracked ? 'Elimina il file…' : 'Annulla le modifiche…',
            destructive: true,
            enabled: onDiscard != null,
            onSelected: onDiscard,
          ),
        ],
      ),
    );
  }
}
