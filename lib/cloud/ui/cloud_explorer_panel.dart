// Cloud Explorer (DBeaver Ultimate "Cloud Explorer"): accounts → buckets /
// containers (with region) → folders → files, browsed like a file system,
// with transfers, share links and SQL editor / CSV import integration.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import '../../ui/widgets/common.dart';
import '../cloud_accounts.dart';
import '../cloud_common.dart';
import '../storage/cloud_storage.dart';
import 'cloud_account_dialog.dart';
import 'cloud_actions.dart';
import 'cloud_browser_tab.dart';
import 'cloud_transfers.dart';

enum _Kind { account, bucket, folder, file, more }

class _Node {
  _Node(this.kind, this.account, {this.bucket, this.prefix = '', this.object, this.region, this.parent, this.token});

  final _Kind kind;
  final CloudAccount account;
  final String? bucket;

  /// Folder prefix (with trailing `/`) for buckets and folders.
  final String prefix;
  final CloudObject? object;
  final String? region;
  final _Node? parent;

  /// Continuation token of a "more" node.
  final String? token;

  List<_Node>? children;
  bool expanded = false;
  bool loading = false;
  String? error;

  bool get expandable => kind == _Kind.account || kind == _Kind.bucket || kind == _Kind.folder;

  String get label => switch (kind) {
    _Kind.account => account.name,
    _Kind.bucket => bucket!,
    _Kind.folder || _Kind.file => object!.name,
    _Kind.more => 'Carica altri…',
  };

  /// The object this node stands for (buckets as the root folder).
  CloudObject get asObject => object ?? CloudObject(bucket: bucket!, key: prefix, isFolder: true);
}

/// Left sidebar panel. Hook it as a third sidebar tab ("Storage").
class CloudExplorerPanel extends StatefulWidget {
  const CloudExplorerPanel({super.key});

  @override
  State<CloudExplorerPanel> createState() => _CloudExplorerPanelState();
}

class _VisibleNode {
  const _VisibleNode(this.node, this.depth);
  final _Node node;
  final int depth;
}

class _CloudExplorerPanelState extends State<CloudExplorerPanel> {
  final _filter = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final Map<String, _Node> _roots = {};
  _Node? _selected;
  CloudAccountsStore? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = CloudAccountsStore.of(AppScope.read(context));
    if (s != _store) {
      _store?.removeListener(_onStore);
      _store = s..addListener(_onStore);
    }
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store?.removeListener(_onStore);
    _filter.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<_Node> _rootNodes() {
    final out = <_Node>[];
    final ids = <String>{};
    for (final a in _store!.accounts) {
      ids.add(a.id);
      var n = _roots[a.id];
      // A changed account (new credentials) starts from scratch.
      if (n == null || !identical(n.account, a)) n = _roots[a.id] = _Node(_Kind.account, a);
      out.add(n);
    }
    _roots.removeWhere((k, _) => !ids.contains(k));
    return out;
  }

  Future<CloudStorage> _storage(_Node n) => _store!.storage(n.account);

  Future<List<_Node>> _load(_Node n, {String? token}) async {
    final s = await _storage(n);
    switch (n.kind) {
      case _Kind.account:
        final buckets = await s.listBuckets();
        buckets.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return [for (final b in buckets) _Node(_Kind.bucket, n.account, bucket: b.name, region: b.region, parent: n)];
      case _Kind.bucket:
      case _Kind.folder:
        final page = await s.list(n.bucket!, prefix: n.prefix, continuation: token);
        return [
          for (final f in page.folders)
            _Node(_Kind.folder, n.account, bucket: n.bucket, prefix: f.key, object: f, parent: n),
          for (final f in page.files) _Node(_Kind.file, n.account, bucket: n.bucket, object: f, parent: n),
          if (page.continuation != null)
            _Node(_Kind.more, n.account, bucket: n.bucket, parent: n, token: page.continuation),
        ];
      default:
        return const [];
    }
  }

  Future<void> _expand(_Node n) async {
    if (!n.expandable) return;
    if (n.children == null) {
      setState(() {
        n.loading = true;
        n.error = null;
        n.expanded = true;
      });
      try {
        n.children = await _load(n);
      } catch (e) {
        n.error = e.toString();
        n.children = null;
        n.expanded = false;
      } finally {
        n.loading = false;
      }
    }
    if (mounted) setState(() => n.expanded = n.children != null);
  }

  Future<void> _loadMore(_Node more) async {
    final parent = more.parent!;
    setState(() => more.loading = true);
    try {
      final next = await _load(parent, token: more.token);
      parent.children = [...parent.children!.where((c) => c != more), ...next];
    } catch (e) {
      more.error = e.toString();
    }
    more.loading = false;
    if (mounted) setState(() {});
  }

  void _toggle(_Node n) => n.expanded ? setState(() => n.expanded = false) : _expand(n);

  Future<void> _refresh(_Node? n) async {
    if (n == null) return;
    if (n.kind == _Kind.file || n.kind == _Kind.more) return _refresh(n.parent);
    if (n.kind == _Kind.account) _store!.resetClients();
    final was = n.expanded || n.children != null;
    n.children = null;
    n.error = null;
    n.expanded = false;
    if (was) await _expand(n);
    if (mounted) setState(() {});
  }

  List<_VisibleNode> _flatten(List<_Node> roots) {
    final f = _filter.text.trim().toLowerCase();
    final out = <_VisibleNode>[];
    bool matches(_Node n) {
      if (f.isEmpty || n.kind == _Kind.account || n.kind == _Kind.more) return true;
      if (n.label.toLowerCase().contains(f)) return true;
      return n.expanded && (n.children ?? const []).any(matches);
    }

    void walk(_Node n, int depth) {
      if (!matches(n)) return;
      out.add(_VisibleNode(n, depth));
      if (n.expanded && n.children != null) {
        for (final c in n.children!) {
          walk(c, depth + 1);
        }
      }
    }

    for (final r in roots) {
      walk(r, 0);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _newAccount() async {
    final a = await showCloudAccountDialog(context);
    if (a != null && mounted) {
      final n = _rootNodes().firstWhere((e) => e.account.id == a.id);
      setState(() => _selected = n);
      _expand(n);
    }
  }

  Future<void> _editAccount(_Node n) async {
    final a = await showCloudAccountDialog(context, existing: n.account);
    if (a != null && mounted) setState(() => _selected = null);
  }

  Future<void> _deleteAccount(_Node n) async {
    final ok = await confirmDialog(
      context,
      'Elimina account',
      'Rimuovere l\'account "${n.account.name}" da DbCraft? I dati nello storage non vengono toccati.',
      ok: 'Rimuovi',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await guarded(context, () => _store!.remove(n.account));
    if (mounted) setState(() => _selected = null);
  }

  void _openBrowser(_Node n) {
    final app = AppScope.read(context);
    final tab = CloudBrowserTab(store: _store!, account: n.account, bucket: n.bucket!, prefix: n.prefix);
    app.openFeatureTab<CloudBrowserTab>(
      tab,
      match: (t) => t.account.id == n.account.id && t.bucket == n.bucket && t.prefix == n.prefix,
    );
  }

  Future<void> _open(_Node n) async {
    setState(() => _selected = n);
    switch (n.kind) {
      case _Kind.more:
        await _loadMore(n);
      case _Kind.file:
        final o = n.object!;
        final s = await _storage(n);
        if (!mounted) return;
        if (cloudTextExtensions.contains(o.extension)) {
          await cloudOpenInEditor(context, n.account, s, o);
        } else {
          await cloudProperties(context, s, o);
        }
      default:
        _toggle(n);
    }
  }

  Future<void> _withStorage(_Node n, Future<bool?> Function(CloudStorage s) action, {_Node? refresh}) async {
    CloudStorage? s;
    final ok = await guarded(context, () async => s = await _storage(n));
    if (!ok || !mounted) return;
    final changed = await action(s!);
    if (changed == true && mounted) await _refresh(refresh ?? n);
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    AppScope.of(context);
    final store = _store!;
    final roots = _rootNodes();
    final visible = _flatten(roots);
    final selected = visible.indexWhere((v) => v.node == _selected);
    return Column(
      children: [
        SectionLabel(
          'Storage',
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 2),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ToolButton(icon: AppIcons.add, tooltip: 'Nuovo account storage', onPressed: _newAccount),
              ToolButton(
                icon: AppIcons.collapseAll,
                tooltip: 'Comprimi tutto',
                onPressed: () => setState(() {
                  void collapse(_Node n) {
                    n.expanded = false;
                    for (final c in n.children ?? const <_Node>[]) {
                      collapse(c);
                    }
                  }

                  roots.forEach(collapse);
                }),
              ),
              ToolButton(
                icon: AppIcons.refresh,
                tooltip: 'Aggiorna (F5)',
                onPressed: _selected == null ? null : () => _refresh(_selected),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, 2, Gap.sm, Gap.sm),
          child: SearchField(controller: _filter, hint: 'Filtra bucket e file', onChanged: (_) => setState(() {})),
        ),
        Expanded(
          child: !store.isLoaded
              ? const SizedBox.shrink()
              : roots.isEmpty
              ? EmptyState(
                  icon: AppIcons.cloud,
                  title: 'Nessun account storage',
                  message:
                      'Aggiungi un account Amazon S3 (o compatibile, come MinIO), Azure Blob Storage (anche '
                      'l\'emulatore Azurite) o Google Cloud Storage per sfogliare bucket e container come '
                      'cartelle, caricare e scaricare file.',
                  action: PushButton.primary(label: 'Nuovo account…', onPressed: _newAccount),
                )
              : CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.f5): () => _refresh(_selected)},
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onSecondaryTapDown: (d) => _emptyMenu(d.globalPosition),
                    child: SourceList(
                      focusNode: _focus,
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, Gap.md),
                      itemCount: visible.length,
                      selectedIndex: selected < 0 ? null : selected,
                      onSelect: (i) => setState(() => _selected = visible[i].node),
                      onExpand: (i, expand) {
                        final n = visible[i].node;
                        expand ? _expand(n) : setState(() => n.expanded = false);
                      },
                      onActivate: (i) => _open(visible[i].node),
                      itemBuilder: (context, i) => _row(context, visible[i]),
                    ),
                  ),
                ),
        ),
        const CloudTransfersView(),
      ],
    );
  }

  IconData _icon(_Node n) => switch (n.kind) {
    _Kind.account => cloudProviderIcon(n.account.provider),
    _Kind.bucket => AppIcons.archive,
    _Kind.folder => n.expanded ? AppIcons.folderOpen : AppIcons.folder,
    _Kind.more => AppIcons.more,
    _Kind.file => cloudFileIcon(n.object!.extension),
  };

  Widget _row(BuildContext context, _VisibleNode v) {
    final c = DbColors.of(context);
    final n = v.node;
    final detail = switch (n.kind) {
      _Kind.account => n.account.subtitle,
      _Kind.bucket => n.region ?? '',
      _Kind.file => n.object!.size >= 0 ? formatBytes(n.object!.size) : '',
      _ => '',
    };
    return OutlineRow(
      title: n.label,
      icon: _icon(n),
      iconColor: switch (n.kind) {
        _Kind.account => cloudProviderColor(n.account.provider),
        _Kind.bucket || _Kind.folder => c.textSecondary,
        _ => c.textTertiary,
      },
      depth: v.depth,
      expanded: n.expandable ? n.expanded : null,
      onExpand: (_) => _toggle(n),
      busy: n.loading,
      reserveDisclosure: true,
      detail: detail.isEmpty ? null : detail,
      titleColor: n.error != null ? c.danger : (n.kind == _Kind.more ? c.accent : null),
      accessories: [
        if (n.error != null)
          Builder(
            builder: (context) => Icon(
              AppIcons.warning,
              size: 14,
              color: RowTint.emphasizedOf(context) ? c.onSelectionEmphasized : c.danger,
            ),
          ),
      ],
      selected: n == _selected,
      tooltip: n.error ?? (n.kind == _Kind.file ? n.object!.key : n.label),
      onTap: () => n.kind == _Kind.more ? _loadMore(n) : setState(() => _selected = n),
      onDoubleTap: () => _open(n),
      onMenu: (pos) {
        setState(() => _selected = n);
        _contextMenu(n, pos);
      },
    );
  }

  // -------------------------------------------------------------------------
  // Context menus
  // -------------------------------------------------------------------------

  static const _divider = MenuEntry<void>.divider();
  static const _f5 = SingleActivator(LogicalKeyboardKey.f5);

  MenuEntry<void> _item(String label, VoidCallback? action, {SingleActivator? shortcut}) =>
      MenuEntry<void>(label, onSelected: action, enabled: action != null, shortcut: shortcut);

  Future<void> _showMenu(Offset pos, List<MenuEntry<void>> items) =>
      showMacMenu<void>(context, position: pos, entries: items);

  void _emptyMenu(Offset pos) {
    if (_selected != null) return;
    _showMenu(pos, [_item('Nuovo account…', _newAccount)]);
  }

  Future<void> _contextMenu(_Node n, Offset pos) async {
    final items = <MenuEntry<void>>[];
    final app = AppScope.read(context);
    switch (n.kind) {
      case _Kind.account:
        items.addAll([
          _item('Aggiorna', () => _refresh(n), shortcut: _f5),
          _divider,
          _item('Modifica…', () => _editAccount(n)),
          _item('Elimina', () => _deleteAccount(n)),
          _divider,
          _item('Nuovo account…', _newAccount),
        ]);
      case _Kind.bucket:
      case _Kind.folder:
        final o = n.asObject;
        items.addAll([
          _item('Apri nel browser', () => _openBrowser(n)),
          _divider,
          _item('Nuova cartella…', () => _withStorage(n, (s) => cloudNewFolder(context, s, n.bucket!, n.prefix))),
          _item('Carica file…', () => _withStorage(n, (s) => cloudUploadFiles(context, s, n.bucket!, n.prefix))),
          _item(
            'Scarica…',
            () => _withStorage(n, (s) async {
              await cloudDownloadFolder(context, s, n.bucket!, n.prefix);
              return false;
            }),
          ),
          _divider,
          _item(
            'Copia URI',
            () => _withStorage(n, (s) async {
              await cloudCopyUri(context, s, n.bucket!, n.prefix);
              return false;
            }),
          ),
          if (n.kind == _Kind.folder) ...[
            _item('Rinomina…', () => _withStorage(n, (s) => cloudRename(context, s, o), refresh: n.parent)),
            _item('Elimina…', () => _withStorage(n, (s) => cloudDelete(context, s, [o]), refresh: n.parent)),
          ],
          if (n.kind == _Kind.bucket) _item('Proprietà', () => _bucketProperties(n)),
          _item('Aggiorna', () => _refresh(n), shortcut: _f5),
        ]);
      case _Kind.file:
        final o = n.object!;
        final ext = o.extension;
        final local = cloudLocalCopy(app, n.account, o.bucket, o.key);
        final hasLocal = local.existsSync();
        items.addAll([
          if (cloudTextExtensions.contains(ext))
            _item(
              'Apri nell\'editor SQL',
              () => _withStorage(n, (s) async {
                await cloudOpenInEditor(context, n.account, s, o);
                return false;
              }),
            ),
          if (hasLocal)
            _item(
              'Salva nello storage la copia locale',
              () => _withStorage(n, (s) => cloudSaveLocalCopy(context, n.account, s, o), refresh: n.parent),
            ),
          if (cloudCsvExtensions.contains(ext))
            _item(
              'Importa in tabella…',
              () => _withStorage(n, (s) async {
                await cloudImportCsv(context, s, o);
                return false;
              }),
            ),
          if (cloudTextExtensions.contains(ext) || cloudCsvExtensions.contains(ext) || hasLocal) _divider,
          _item(
            'Scarica…',
            () => _withStorage(n, (s) async {
              await cloudDownload(context, s, o);
              return false;
            }),
          ),
          _item(
            'Copia link di condivisione…',
            () => _withStorage(n, (s) async {
              await cloudShareLink(context, s, o);
              return false;
            }),
          ),
          _item(
            'Copia URI',
            () => _withStorage(n, (s) async {
              await cloudCopyUri(context, s, o.bucket, o.key);
              return false;
            }),
          ),
          _divider,
          _item('Rinomina…', () => _withStorage(n, (s) => cloudRename(context, s, o), refresh: n.parent)),
          _item('Elimina…', () => _withStorage(n, (s) => cloudDelete(context, s, [o]), refresh: n.parent)),
          _divider,
          _item(
            'Proprietà',
            () => _withStorage(n, (s) async {
              await cloudProperties(context, s, o);
              return false;
            }),
          ),
        ]);
      case _Kind.more:
        items.add(_item('Carica altri', () => _loadMore(n)));
    }
    await _showMenu(pos, items);
  }

  Future<void> _bucketProperties(_Node n) async {
    final s = await _storage(n);
    if (!mounted) return;
    await showSheet<void>(
      context,
      builder: (ctx) => SheetScaffold(
        title: n.bucket!,
        onSubmit: () => Navigator.pop(ctx),
        body: PropertyTable(
          entries: [
            ('Account', n.account.name),
            ('Servizio', n.account.provider.storageLabel),
            (n.account.provider.bucketTerm, n.bucket!),
            ('Regione', n.region ?? ''),
            ('URI', s.uri(n.bucket!, '')),
          ],
        ),
        actions: [PushButton.primary(label: 'Fine', onPressed: () => Navigator.pop(ctx))],
      ),
    );
  }
}

IconData cloudFileIcon(String ext) => switch (ext) {
  'sql' || 'ddl' || 'pgsql' || 'psql' => AppIcons.document,
  'csv' || 'tsv' || 'xlsx' || 'parquet' || 'avro' => AppIcons.table,
  'json' || 'jsonl' || 'ndjson' || 'xml' || 'yaml' || 'yml' => AppIcons.json,
  'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' => AppIcons.image,
  'zip' || 'gz' || 'tar' || 'bz2' => AppIcons.zip,
  'txt' || 'md' || 'log' => AppIcons.article,
  _ => AppIcons.file,
};
