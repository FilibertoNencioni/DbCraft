// Sidebar panel "Progetto": synchronizes the workspace with a Git
// repository (status, commit, pull / push, history).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  _Page _page = _Page.changes;
  String? _selectedFile;

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
    final st = _status ?? GitStatus();
    final idle = _busy == null;
    final hasRemote = _remote != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          hasRemote ? _repoName(_remote!) : 'Repository locale',
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 2),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasRemote)
                ToolButton(icon: AppIcons.sync, tooltip: 'Sincronizza (pull e push)', onPressed: idle ? _sync : null)
              else
                ToolButton(
                  icon: AppIcons.link,
                  tooltip: 'Collega repository remoto…',
                  onPressed: idle ? _connect : null,
                ),
              PulldownButton(icon: AppIcons.more, tooltip: 'Altre azioni', entries: () => _actions(st)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: OutlineRow(
            icon: AppIcons.split,
            title: st.branch ?? 'HEAD scollegato',
            accessories: [
              if (st.behind > 0) _Drift(AppIcons.arrowDown, st.behind, '${st.behind} commit da scaricare'),
              if (st.ahead > 0) _Drift(AppIcons.arrowUp, st.ahead, '${st.ahead} commit da pubblicare'),
            ],
            tooltip: hasRemote ? 'Remoto: $_remote' : 'Nessun repository remoto collegato',
            onMenu: (pos) => showMacMenu<Object?>(context, position: pos, entries: _actions(st)),
          ),
        ),
        if (st.hasConflicts)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, 0),
            child: Notice.card(
              kind: NoticeKind.danger,
              title: 'Pull interrotto da conflitti',
              message:
                  'Risolvi i file segnati con ! con un editor o uno strumento Git, oppure annulla per tornare allo stato '
                  'precedente.',
              actions: [LinkButton(label: 'Annulla pull', small: true, onPressed: idle ? _abort : null)],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.xs),
          child: Segmented<_Page>(
            value: _page,
            expand: true,
            items: [
              (_Page.changes, st.files.isEmpty ? 'Modifiche' : 'Modifiche (${st.files.length})', null),
              (_Page.history, 'Cronologia', null),
            ],
            onChanged: (v) => setState(() => _page = v),
          ),
        ),
        Expanded(child: _page == _Page.changes ? _changesPage(st) : _historyPage(st)),
      ],
    );
  }

  /// The "…" menu of the repository header and the branch row.
  List<MenuEntry<Object?>> _actions(GitStatus st) {
    final idle = _busy == null;
    final hasRemote = _remote != null;
    return [
      MenuEntry('Sincronizza', onSelected: _sync, enabled: idle && hasRemote),
      MenuEntry('Pull', onSelected: _pull, enabled: idle && hasRemote),
      MenuEntry('Push', onSelected: _push, enabled: idle && hasRemote),
      const MenuEntry.divider(),
      MenuEntry('Aggiorna', onSelected: _refresh, enabled: idle),
      if (!hasRemote) MenuEntry('Collega repository remoto…', onSelected: _connect, enabled: idle),
      const MenuEntry.divider(),
      MenuEntry(
        'Impostazioni di sincronizzazione…',
        onSelected: () async {
          await showGitSettingsDialog(context);
          await _refresh(quiet: true);
        },
      ),
    ];
  }

  Widget _changesPage(GitStatus st) {
    if (st.files.isEmpty) {
      return const EmptyState(
        icon: AppIcons.checkCircle,
        title: 'Nessuna modifica',
        message: 'Script, connessioni e impostazioni corrispondono all\'ultimo commit.',
      );
    }
    final idle = _busy == null;
    final sel = st.files.indexWhere((f) => f.path == _selectedFile);
    final canCommit = idle && !st.hasConflicts && _message.text.trim().isNotEmpty;
    final n = st.files.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SourceList(
            dense: true,
            padding: const EdgeInsets.fromLTRB(10, Gap.xs, 10, Gap.sm),
            itemCount: n,
            selectedIndex: sel < 0 ? null : sel,
            onSelect: (i) => setState(() => _selectedFile = st.files[i].path),
            onActivate: (i) => _fileDiff(st.files[i]),
            itemBuilder: (context, i) {
              final f = st.files[i];
              return _FileRow(
                file: f,
                selected: i == sel,
                onTap: () => setState(() => _selectedFile = f.path),
                onOpen: () => _fileDiff(f),
                onDiscard: idle && !f.conflicted ? () => _discard(f) : null,
              );
            },
          ),
        ),
        // Commit composer, pinned under the files it commits.
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: DbColors.of(context).separator, width: 0.5)),
          ),
          padding: const EdgeInsets.all(Gap.sm),
          child: CallbackShortcuts(
            bindings: {_commitKey: () => canCommit ? _commit() : null},
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MacTextField(
                  controller: _message,
                  minLines: 2,
                  maxLines: 5,
                  hint: 'Messaggio di commit',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: Gap.sm),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        n == 1 ? '1 file' : '$n file',
                        style: uiText(TypeSize.small, color: DbColors.of(context).textSecondary, features: kTabular),
                      ),
                    ),
                    PushButton.primary(
                      label: 'Commit',
                      tooltip:
                          'Salva tutte le modifiche in un commit su ${st.branch ?? 'HEAD'} '
                          '(${shortcutLabel(_commitKey)})',
                      onPressed: canCommit ? _commit : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _historyPage(GitStatus st) {
    if (_log.isEmpty) {
      return const EmptyState(
        icon: AppIcons.history,
        title: 'Nessun commit',
        message: 'Scrivi un messaggio in Modifiche e premi Commit per salvare il primo.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, Gap.xs, 10, Gap.md),
      itemCount: _log.length,
      itemBuilder: (context, i) {
        final cm = _log[i];
        // `git log` lists the newest first: the first `ahead` are local only
        // (all of them before the first push).
        final local = _remote != null && (st.upstream == null || i < st.ahead);
        return ListRow(
          title: cm.subject,
          subtitle: '${cm.author} · ${_relative(cm.date)}',
          trailing: local
              ? Tooltip(
                  message: 'Da pubblicare',
                  child: Icon(AppIcons.upload, size: 14, color: DbColors.of(context).textTertiary),
                )
              : null,
          tooltip: '${cm.shortHash} · ${cm.subject}',
          onTap: () => _commitDiff(cm),
          onMenu: (pos) => showMacMenu<void>(
            context,
            position: pos,
            entries: [
              MenuEntry('Mostra le modifiche', onSelected: () => _commitDiff(cm)),
              MenuEntry('Copia hash', onSelected: () => Clipboard.setData(ClipboardData(text: cm.hash))),
            ],
          ),
        );
      },
    );
  }

  void _fileDiff(GitFileChange f) => _showDiff(f.path, () => git.diffFile(f));

  void _commitDiff(GitCommit cm) => _showDiff(cm.subject, () => git.showCommit(cm.hash));
}

enum _Page { changes, history }

const _commitKey = SingleActivator(LogicalKeyboardKey.enter, meta: true);

/// "owner/repo" from an https or scp-style remote URL.
String _repoName(String url) {
  var s = url.trim();
  if (s.endsWith('.git')) s = s.substring(0, s.length - 4);
  if (s.endsWith('/')) s = s.substring(0, s.length - 1);
  final parts = s.split(RegExp(r'[/:]')).where((e) => e.isNotEmpty).toList();
  return parts.length >= 2 ? '${parts[parts.length - 2]}/${parts.last}' : s;
}

/// Commits ahead or behind the upstream: arrow and count.
class _Drift extends StatelessWidget {
  const _Drift(this.icon, this.count, this.tooltip);
  final IconData icon;
  final int count;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final fg = RowTint.emphasizedOf(context) ? c.onSelectionEmphasized : c.textSecondary;
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          Text(
            '$count',
            style: uiText(TypeSize.small, color: fg, features: kTabular),
          ),
        ],
      ),
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

/// A changed file: status letter, name, folder on the right; a double
/// click (or Invio) shows the diff, the "…" menu also discards the change.
class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.selected,
    required this.onTap,
    required this.onOpen,
    this.onDiscard,
  });
  final GitFileChange file;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOpen;
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
      detail: dir == '.' ? null : dir,
      selected: selected,
      tooltip: '${f.path} · ${f.label}',
      onTap: onTap,
      onDoubleTap: onOpen,
      onMenu: (pos) => showMacMenu<void>(
        context,
        position: pos,
        entries: [
          MenuEntry('Mostra le differenze', onSelected: onOpen),
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
