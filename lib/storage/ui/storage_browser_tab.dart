// Full-size browser of one bucket / container (editor tab): breadcrumbs,
// table with name / size / modified / class, multi-selection and the same
// actions as the Storage panel.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cloud/cloud_common.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../ui/widgets/common.dart';
import '../backends/object_storage.dart';
import '../storage_accounts.dart';
import 'storage_actions.dart';
import 'storage_panel.dart' show storageFileIcon;
import 'storage_transfers.dart';

class StorageBrowserTab extends FeatureTab {
  StorageBrowserTab({required this.store, required this.account, required this.bucket, String prefix = ''})
    : prefix = prefix,
      _startPrefix = prefix;

  final StorageAccountsStore store;
  final StorageAccount account;
  final String bucket;
  final String _startPrefix;

  /// Folder shown (with trailing `/`, empty at the root).
  String prefix;

  // Listing kept here so it survives tab switches.
  List<StorageObject> items = [];
  String? continuation;
  bool loaded = false;
  final Set<String> selection = {};

  @override
  String get title => _startPrefix.isEmpty ? bucket : '$bucket/${StorageObject(bucket: bucket, key: _startPrefix).name}';

  @override
  String get tooltip => '${account.name} · ${account.provider.storageLabel} · $bucket/$prefix';

  @override
  IconData get icon => AppIcons.storage;

  @override
  DbConnection? get connection => null;

  @override
  Widget buildView(BuildContext context) => _StorageBrowserView(key: ValueKey(id), tab: this);
}

class _StorageBrowserView extends StatefulWidget {
  const _StorageBrowserView({super.key, required this.tab});
  final StorageBrowserTab tab;

  @override
  State<_StorageBrowserView> createState() => _StorageBrowserViewState();
}

class _StorageBrowserViewState extends State<_StorageBrowserView> {
  StorageBrowserTab get t => widget.tab;
  final _filter = TextEditingController();
  bool _loading = false;
  String? _error;
  String _sort = 'name';
  bool _asc = true;

  @override
  void initState() {
    super.initState();
    if (!t.loaded) _reload();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<ObjectStorage> get _storage => t.store.storage(t.account);

  Future<void> _reload({bool more = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await _storage;
      final page = await s.list(t.bucket, prefix: t.prefix, continuation: more ? t.continuation : null);
      final list = [...page.folders, ...page.files];
      t.items = more ? [...t.items, ...list] : list;
      t.continuation = page.continuation;
      t.loaded = true;
      if (!more) t.selection.clear();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  void _go(String prefix) {
    t.prefix = prefix;
    t.items = [];
    t.continuation = null;
    t.selection.clear();
    _reload();
  }

  List<StorageObject> get _visible {
    final f = _filter.text.trim().toLowerCase();
    final list = t.items.where((o) => f.isEmpty || o.name.toLowerCase().contains(f)).toList();
    int cmp(StorageObject a, StorageObject b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      final r = switch (_sort) {
        'size' => a.size.compareTo(b.size),
        'modified' => (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0)),
        'class' => (a.storageClass ?? '').compareTo(b.storageClass ?? ''),
        _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      return _asc ? r : -r;
    }

    return list..sort(cmp);
  }

  List<StorageObject> get _selected => t.items.where((o) => t.selection.contains(o.key)).toList();

  Future<void> _act(Future<bool?> Function(ObjectStorage s) f) async {
    ObjectStorage? s;
    if (!await guarded(context, () async => s = await _storage) || !mounted) return;
    if (await f(s!) == true && mounted) await _reload();
  }

  Future<void> _openItem(StorageObject o) async {
    if (o.isFolder) return _go(o.key);
    await _act((s) async {
      if (storageTextExtensions.contains(o.extension)) {
        await storageOpenInEditor(context, t.account, s, o);
      } else {
        await storageDownload(context, s, o);
      }
      return false;
    });
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final visible = _visible;
    final sel = _selected;
    return ColoredBox(
      color: c.content,
      child: Column(
        children: [
          _toolbar(sel),
          Expanded(child: _body(visible)),
          _statusBar(visible, sel),
        ],
      ),
    );
  }

  Widget _toolbar(List<StorageObject> sel) {
    final c = DbColors.of(context);
    final parts = t.prefix.split('/').where((e) => e.isNotEmpty).toList();
    final single = sel.length == 1 ? sel.first : null;
    PathSegment crumb(String label, String prefix, {IconData? icon}) => PathSegment(
      label,
      icon: icon,
      iconColor: icon == null ? null : c.accent,
      onTap: prefix == t.prefix ? null : () => _go(prefix),
    );
    return PaneBar(
      loading: _loading && t.items.isNotEmpty,
      children: [
        ToolButton(
          icon: AppIcons.arrowUp,
          tooltip: 'Cartella superiore',
          onPressed: t.prefix.isEmpty ? null : () => _go(StorageObject(bucket: t.bucket, key: t.prefix).parent),
        ),
        ToolButton(icon: AppIcons.refresh, tooltip: 'Aggiorna (F5)', onPressed: _loading ? null : _reload),
        const ToolSeparator(),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: PathBar(
              segments: [
                crumb(t.bucket, '', icon: AppIcons.archive),
                for (var i = 0; i < parts.length; i++) crumb(parts[i], '${parts.sublist(0, i + 1).join('/')}/'),
              ],
            ),
          ),
        ),
        const ToolSeparator(),
        ToolButton(
          icon: AppIcons.newFolder,
          tooltip: 'Nuova cartella',
          onPressed: () => _act((s) => storageNewFolder(context, s, t.bucket, t.prefix)),
        ),
        ToolButton(
          icon: AppIcons.upload,
          tooltip: 'Carica file…',
          onPressed: () => _act((s) => storageUploadFiles(context, s, t.bucket, t.prefix)),
        ),
        ToolButton(
          icon: AppIcons.download,
          tooltip: 'Scarica…',
          onPressed: sel.isEmpty ? null : () => _downloadSelection(sel),
        ),
        ToolButton(
          icon: AppIcons.link,
          tooltip: 'Copia link di condivisione…',
          onPressed: single == null || single.isFolder
              ? null
              : () => _act((s) async {
                  await storageShareLink(context, s, single);
                  return false;
                }),
        ),
        ToolButton(
          icon: AppIcons.delete,
          tooltip: 'Elimina…',
          onPressed: sel.isEmpty ? null : () => _act((s) => storageDelete(context, s, sel)),
        ),
        const SizedBox(width: Gap.sm),
        SearchField(controller: _filter, hint: 'Filtra', width: 180, onChanged: (_) => setState(() {})),
      ],
    );
  }

  Future<void> _downloadSelection(List<StorageObject> sel) => _act((s) async {
    if (sel.length == 1 && !sel.first.isFolder) {
      await storageDownload(context, s, sel.first);
    } else {
      for (final o in sel) {
        if (!mounted) break;
        if (o.isFolder) {
          await storageDownloadFolder(context, s, o.bucket, o.key);
        } else {
          await storageDownload(context, s, o);
        }
      }
    }
    return false;
  });

  static const _columns = ['name', 'size', 'modified', 'class'];

  Widget _body(List<StorageObject> visible) {
    final c = DbColors.of(context);
    if (_error != null) {
      return EmptyState.error(
        _error!,
        title: 'Impossibile elencare i file',
        action: PushButton(label: 'Riprova', onPressed: _reload),
      );
    }
    if (_loading && t.items.isEmpty) return const Center(child: Spinner(size: Spinner.large));
    if (visible.isEmpty) {
      return EmptyState(
        icon: AppIcons.folderOpen,
        title: _filter.text.isEmpty ? 'Cartella vuota' : 'Nessun elemento corrispondente',
        message: _filter.text.isEmpty ? 'Usa "Carica file…" per aggiungere file qui.' : 'Modifica il filtro.',
      );
    }
    String text(StorageObject o, int col) => switch (col) {
      0 => o.name,
      1 => o.isFolder || o.size < 0 ? '' : formatBytes(o.size),
      2 => _date(o.modified),
      _ => o.storageClass ?? '',
    };
    // Del, ⌘⌫ and F5 reach this Focus when the table leaves them.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) => _onKey(e),
      child: MacTable(
        headers: const ['Nome', 'Dimensione', 'Ultima modifica', 'Classe'],
        rowCount: visible.length,
        cell: (r, col) => text(visible[r], col),
        flex: (col) => col == 0 ? 1 : null,
        width: (col) => const [200.0, 110.0, 150.0, 120.0][col],
        numeric: (col) => col == 1,
        resizable: false,
        emphasizeSelection: true,
        selection: {
          for (var i = 0; i < visible.length; i++)
            if (t.selection.contains(visible[i].key)) i,
        },
        onSelectionChanged: (rows) => setState(
          () => t.selection
            ..clear()
            ..addAll(rows.map((i) => visible[i].key)),
        ),
        onDoubleTap: (r) => _openItem(visible[r]),
        onContextMenu: (_, _, pos) => _menu(pos),
        sortColumn: _columns.indexOf(_sort),
        sortAscending: _asc,
        onSort: (col) => setState(() {
          if (_sort == _columns[col]) {
            _asc = !_asc;
          } else {
            _sort = _columns[col];
            _asc = true;
          }
        }),
        leading: (r) {
          final o = visible[r];
          return Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: Icon(
                o.isFolder ? AppIcons.folder : storageFileIcon(o.extension),
                size: 16,
                color: RowTint.emphasizedOf(context)
                    ? c.onSelectionEmphasized
                    : (o.isFolder ? c.accent : c.textSecondary),
              ),
            ),
          );
        },
        // Size, date and class in secondary, as in Finder.
        cellBuilder: (context, r, col) {
          if (col == 0) return null;
          final on = RowTint.emphasizedOf(context);
          return Text(
            text(visible[r], col),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: col == 1 ? TextAlign.right : null,
            style: uiText(
              col == 3 ? TypeSize.small : TypeSize.body,
              color: on ? c.onSelectionEmphasized.withValues(alpha: 0.8) : c.textSecondary,
              features: kTabular,
            ),
          );
        },
        footer: t.continuation == null
            ? null
            : Center(
                child: _loading
                    ? const Spinner(size: Spinner.small)
                    : LinkButton(label: 'Carica altri elementi', small: true, onPressed: () => _reload(more: true)),
              ),
      ),
    );
  }

  static String _date(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.backspace when HardwareKeyboard.instance.isMetaPressed:
      case LogicalKeyboardKey.delete:
        final sel = _selected;
        if (sel.isNotEmpty) _act((s) => storageDelete(context, s, sel));
      case LogicalKeyboardKey.f5:
        _reload();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _statusBar(List<StorageObject> visible, List<StorageObject> sel) {
    final c = DbColors.of(context);
    final files = visible.where((o) => !o.isFolder).toList();
    final total = files.fold<int>(0, (a, o) => a + (o.size > 0 ? o.size : 0));
    final selSize = sel.where((o) => !o.isFolder).fold<int>(0, (a, o) => a + (o.size > 0 ? o.size : 0));
    return StatusBar(
      children: [
        Text(
          '${visible.length} elementi · ${formatBytes(total)}${t.continuation != null ? ' (parziale)' : ''}'
          '${sel.isEmpty ? '' : ' · ${sel.length} selezionati (${formatBytes(selSize)})'}',
          style: const TextStyle(fontFeatures: kTabular),
        ),
        const Spacer(),
        ListenableBuilder(
          listenable: StorageTransfers.instance,
          builder: (context, _) {
            final running = StorageTransfers.instance.items.where((x) => x.state == TransferState.running).length;
            if (running == 0) return const SizedBox.shrink();
            return Text(
              '$running trasferimenti in corso',
              style: TextStyle(color: c.accent, fontFeatures: kTabular),
            );
          },
        ),
        if (_loading) ...[const SizedBox(width: Gap.sm), const Spinner(size: Spinner.small)],
        const SizedBox(width: Gap.sm),
        Text(t.account.name, style: TextStyle(color: c.textTertiary)),
      ],
    );
  }

  MenuEntry<void> _item(String label, VoidCallback action) => MenuEntry<void>(label, onSelected: action);

  Future<void> _menu(Offset pos) async {
    final sel = _selected;
    if (sel.isEmpty) return;
    final single = sel.length == 1 ? sel.first : null;
    final ext = single?.extension ?? '';
    await showMacMenu<void>(
      context,
      position: pos,
      entries: [
        if (single != null && single.isFolder) _item('Apri', () => _go(single.key)),
        if (single != null && !single.isFolder && storageTextExtensions.contains(ext))
          _item('Apri nell\'editor SQL', () => _openItem(single)),
        if (single != null && !single.isFolder && storageCsvExtensions.contains(ext))
          _item(
            'Importa in tabella…',
            () => _act((s) async {
              await storageImportCsv(context, s, single);
              return false;
            }),
          ),
        _item('Scarica…', () => _downloadSelection(sel)),
        if (single != null && !single.isFolder)
          _item(
            'Copia link di condivisione…',
            () => _act((s) async {
              await storageShareLink(context, s, single);
              return false;
            }),
          ),
        if (single != null)
          _item(
            'Copia URI',
            () => _act((s) async {
              await storageCopyUri(context, s, single.bucket, single.key);
              return false;
            }),
          ),
        const MenuEntry.divider(),
        if (single != null) _item('Rinomina…', () => _act((s) => storageRename(context, s, single))),
        _item('Elimina…', () => _act((s) => storageDelete(context, s, sel))),
        if (single != null && !single.isFolder) ...[
          const MenuEntry.divider(),
          _item(
            'Proprietà',
            () => _act((s) async {
              await storageProperties(context, s, single);
              return false;
            }),
          ),
        ],
      ],
    );
  }
}
