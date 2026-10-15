// Full-size browser of one bucket / container (editor tab): breadcrumbs,
// table with name / size / modified / class, multi-selection and the same
// actions as the Cloud Explorer.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/editor_tabs.dart';
import '../../state/db_connection.dart';
import '../../ui/widgets/common.dart';
import '../cloud_accounts.dart';
import '../cloud_common.dart';
import '../storage/cloud_storage.dart';
import 'cloud_actions.dart';
import 'cloud_explorer_panel.dart' show cloudFileIcon;
import 'cloud_transfers.dart';

class CloudBrowserTab extends FeatureTab {
  CloudBrowserTab({required this.store, required this.account, required this.bucket, String prefix = ''})
    : prefix = prefix,
      _startPrefix = prefix;

  final CloudAccountsStore store;
  final CloudAccount account;
  final String bucket;
  final String _startPrefix;

  /// Folder shown (with trailing `/`, empty at the root).
  String prefix;

  // Listing kept here so it survives tab switches.
  List<CloudObject> items = [];
  String? continuation;
  bool loaded = false;
  final Set<String> selection = {};

  @override
  String get title => _startPrefix.isEmpty ? bucket : '$bucket/${CloudObject(bucket: bucket, key: _startPrefix).name}';

  @override
  String get tooltip => '${account.name} · ${account.provider.storageLabel} · $bucket/$prefix';

  @override
  IconData get icon => Icons.cloud_outlined;

  @override
  DbConnection? get connection => null;

  @override
  Widget buildView(BuildContext context) => _CloudBrowserView(key: ValueKey(id), tab: this);
}

class _CloudBrowserView extends StatefulWidget {
  const _CloudBrowserView({super.key, required this.tab});
  final CloudBrowserTab tab;

  @override
  State<_CloudBrowserView> createState() => _CloudBrowserViewState();
}

class _CloudBrowserViewState extends State<_CloudBrowserView> {
  CloudBrowserTab get t => widget.tab;
  final _filter = TextEditingController();
  final _focus = FocusNode();
  bool _loading = false;
  String? _error;
  int? _anchor;
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
    _focus.dispose();
    super.dispose();
  }

  Future<CloudStorage> get _storage => t.store.storage(t.account);

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
    _anchor = null;
    _reload();
  }

  List<CloudObject> get _visible {
    final f = _filter.text.trim().toLowerCase();
    final list = t.items.where((o) => f.isEmpty || o.name.toLowerCase().contains(f)).toList();
    int cmp(CloudObject a, CloudObject b) {
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

  List<CloudObject> get _selected => t.items.where((o) => t.selection.contains(o.key)).toList();

  Future<void> _act(Future<bool?> Function(CloudStorage s) f) async {
    CloudStorage? s;
    if (!await guarded(context, () async => s = await _storage) || !mounted) return;
    if (await f(s!) == true && mounted) await _reload();
  }

  Future<void> _openItem(CloudObject o) async {
    if (o.isFolder) return _go(o.key);
    await _act((s) async {
      if (cloudTextExtensions.contains(o.extension)) {
        await cloudOpenInEditor(context, t.account, s, o);
      } else {
        await cloudDownload(context, s, o);
      }
      return false;
    });
  }

  void _tap(int index, List<CloudObject> visible) {
    _focus.requestFocus();
    final keys = HardwareKeyboard.instance;
    final o = visible[index];
    setState(() {
      if (keys.isShiftPressed && _anchor != null) {
        final a = _anchor!.clamp(0, visible.length - 1);
        final lo = a < index ? a : index;
        final hi = a < index ? index : a;
        t.selection
          ..clear()
          ..addAll(visible.sublist(lo, hi + 1).map((e) => e.key));
      } else if (keys.isMetaPressed || keys.isControlPressed) {
        if (!t.selection.remove(o.key)) t.selection.add(o.key);
        _anchor = index;
      } else {
        t.selection
          ..clear()
          ..add(o.key);
        _anchor = index;
      }
    });
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final visible = _visible;
    final sel = _selected;
    return Material(
      color: c.content,
      child: Column(
        children: [
          _toolbar(sel),
          Divider(height: 1, color: c.separator),
          _header(),
          Divider(height: 1, color: c.separator),
          Expanded(child: _body(visible)),
          _statusBar(visible, sel),
        ],
      ),
    );
  }

  Widget _toolbar(List<CloudObject> sel) {
    final c = DbColors.of(context);
    final parts = t.prefix.split('/').where((e) => e.isNotEmpty).toList();
    final single = sel.length == 1 ? sel.first : null;
    return Container(
      height: 40,
      color: c.chrome,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      child: Row(
        children: [
          ToolButton(
            icon: Icons.arrow_upward_rounded,
            tooltip: 'Cartella superiore',
            onPressed: t.prefix.isEmpty ? null : () => _go(CloudObject(bucket: t.bucket, key: t.prefix).parent),
          ),
          ToolButton(icon: Icons.refresh_rounded, tooltip: 'Aggiorna (F5)', onPressed: _loading ? null : _reload),
          const ToolSeparator(),
          // Breadcrumbs.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  _crumb(t.bucket, '', icon: Icons.inventory_2_outlined),
                  for (var i = 0; i < parts.length; i++) ...[
                    Icon(Icons.chevron_right_rounded, size: 14, color: c.textTertiary),
                    _crumb(parts[i], '${parts.sublist(0, i + 1).join('/')}/', current: i == parts.length - 1),
                  ],
                ],
              ),
            ),
          ),
          const ToolSeparator(),
          ToolButton(
            icon: Icons.create_new_folder_outlined,
            tooltip: 'Nuova cartella',
            onPressed: () => _act((s) => cloudNewFolder(context, s, t.bucket, t.prefix)),
          ),
          ToolButton(
            icon: Icons.upload_outlined,
            tooltip: 'Carica file…',
            onPressed: () => _act((s) => cloudUploadFiles(context, s, t.bucket, t.prefix)),
          ),
          ToolButton(
            icon: Icons.download_outlined,
            tooltip: 'Scarica…',
            onPressed: sel.isEmpty ? null : () => _downloadSelection(sel),
          ),
          ToolButton(
            icon: Icons.link_rounded,
            tooltip: 'Copia link di condivisione…',
            onPressed: single == null || single.isFolder
                ? null
                : () => _act((s) async {
                    await cloudShareLink(context, s, single);
                    return false;
                  }),
          ),
          ToolButton(
            icon: Icons.delete_outline_rounded,
            tooltip: 'Elimina…',
            onPressed: sel.isEmpty ? null : () => _act((s) => cloudDelete(context, s, sel)),
          ),
          const SizedBox(width: Gap.sm),
          SearchField(controller: _filter, hint: 'Filtra', width: 180, onChanged: (_) => setState(() {})),
        ],
      ),
    );
  }

  Future<void> _downloadSelection(List<CloudObject> sel) => _act((s) async {
    if (sel.length == 1 && !sel.first.isFolder) {
      await cloudDownload(context, s, sel.first);
    } else {
      for (final o in sel) {
        if (!mounted) break;
        if (o.isFolder) {
          await cloudDownloadFolder(context, s, o.bucket, o.key);
        } else {
          await cloudDownload(context, s, o);
        }
      }
    }
    return false;
  });

  Widget _crumb(String label, String prefix, {IconData? icon, bool current = false}) {
    final c = DbColors.of(context);
    final isCurrent = current || (prefix == t.prefix);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.control),
      onTap: isCurrent ? null : () => _go(prefix),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 14, color: c.accent), const SizedBox(width: 4)],
            Text(
              label,
              style: TextStyle(
                fontSize: TypeSize.body,
                fontWeight: isCurrent ? FontWeight.w600 : null,
                color: isCurrent ? c.text : c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _wSize = 110.0;
  static const _wDate = 150.0;
  static const _wClass = 120.0;

  Widget _header() {
    final c = DbColors.of(context);
    Widget h(String label, String key, {double? width, bool right = false}) {
      final active = _sort == key;
      final child = InkWell(
        onTap: () => setState(() {
          if (_sort == key) {
            _asc = !_asc;
          } else {
            _sort = key;
            _asc = true;
          }
        }),
        child: Container(
          height: 30,
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: TypeSize.small, fontWeight: FontWeight.w600, color: c.text),
              ),
              if (active) Icon(_asc ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 16, color: c.textSecondary),
            ],
          ),
        ),
      );
      return width == null ? Expanded(child: child) : SizedBox(width: width, child: child);
    }

    return Container(
      color: c.chrome,
      padding: const EdgeInsets.only(left: 30, right: Gap.sm),
      child: Row(
        children: [
          h('Nome', 'name'),
          h('Dimensione', 'size', width: _wSize, right: true),
          h('Ultima modifica', 'modified', width: _wDate),
          h('Classe', 'class', width: _wClass),
        ],
      ),
    );
  }

  Widget _body(List<CloudObject> visible) {
    final c = DbColors.of(context);
    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Impossibile elencare i file',
        message: _error,
        action: OutlinedButton(onPressed: _reload, child: const Text('Riprova')),
      );
    }
    if (_loading && t.items.isEmpty) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (visible.isEmpty) {
      return EmptyState(
        icon: Icons.folder_open_outlined,
        title: _filter.text.isEmpty ? 'Cartella vuota' : 'Nessun elemento corrispondente',
        message: _filter.text.isEmpty ? 'Usa "Carica file…" per aggiungere file qui.' : 'Modifica il filtro.',
      );
    }
    final more = t.continuation != null;
    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, e) => _onKey(e, visible),
      child: ListView.builder(
        itemCount: visible.length + (more ? 1 : 0),
        itemExtent: 26,
        itemBuilder: (context, i) {
          if (i == visible.length) {
            return Center(
              child: TextButton(
                onPressed: _loading ? null : () => _reload(more: true),
                child: Text(_loading ? 'Caricamento…' : 'Carica altri elementi'),
              ),
            );
          }
          final o = visible[i];
          final selected = t.selection.contains(o.key);
          final strong = selected && _focus.hasFocus;
          final fg = strong ? Colors.white : c.text;
          final fg2 = strong ? Colors.white.withValues(alpha: 0.85) : c.textSecondary;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _tap(i, visible),
            onDoubleTap: () => _openItem(o),
            onSecondaryTapDown: (d) {
              if (!selected) _tap(i, visible);
              _menu(d.globalPosition);
            },
            child: Container(
              color: selected ? (strong ? c.accent : c.selection) : (i.isOdd ? c.zebra : c.content),
              padding: const EdgeInsets.only(left: Gap.sm, right: Gap.sm),
              child: Row(
                children: [
                  Icon(
                    o.isFolder ? Icons.folder_outlined : cloudFileIcon(o.extension),
                    size: 15,
                    color: strong ? Colors.white : (o.isFolder ? c.accent : c.textSecondary),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      o.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: TypeSize.body, color: fg),
                    ),
                  ),
                  SizedBox(
                    width: _wSize,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      child: Text(
                        o.isFolder || o.size < 0 ? '' : formatBytes(o.size),
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: TypeSize.body, color: fg2, fontFeatures: kTabular),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _wDate,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      child: Text(
                        _date(o.modified),
                        style: TextStyle(fontSize: TypeSize.body, color: fg2, fontFeatures: kTabular),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _wClass,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      child: Text(
                        o.storageClass ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: TypeSize.small, color: fg2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _date(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  KeyEventResult _onKey(KeyEvent e, List<CloudObject> visible) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final idx = visible.indexWhere((o) => t.selection.contains(o.key));
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        if (idx + 1 < visible.length) _tap(idx + 1, visible);
      case LogicalKeyboardKey.arrowUp:
        if (idx > 0) _tap(idx - 1, visible);
      case LogicalKeyboardKey.enter:
        if (idx >= 0) _openItem(visible[idx]);
      case LogicalKeyboardKey.backspace when HardwareKeyboard.instance.isMetaPressed:
      case LogicalKeyboardKey.delete:
        final sel = _selected;
        if (sel.isNotEmpty) _act((s) => cloudDelete(context, s, sel));
      case LogicalKeyboardKey.f5:
        _reload();
      case LogicalKeyboardKey.keyA
          when HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed:
        setState(() => t.selection.addAll(visible.map((o) => o.key)));
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _statusBar(List<CloudObject> visible, List<CloudObject> sel) {
    final c = DbColors.of(context);
    final files = visible.where((o) => !o.isFolder).toList();
    final total = files.fold<int>(0, (a, o) => a + (o.size > 0 ? o.size : 0));
    final selSize = sel.where((o) => !o.isFolder).fold<int>(0, (a, o) => a + (o.size > 0 ? o.size : 0));
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(top: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          Text(
            '${visible.length} elementi · ${formatBytes(total)}${t.continuation != null ? ' (parziale)' : ''}'
            '${sel.isEmpty ? '' : ' · ${sel.length} selezionati (${formatBytes(selSize)})'}',
            style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary, fontFeatures: kTabular),
          ),
          const Spacer(),
          ListenableBuilder(
            listenable: CloudTransfers.instance,
            builder: (context, _) {
              final running = CloudTransfers.instance.items.where((x) => x.state == TransferState.running).length;
              if (running == 0) return const SizedBox.shrink();
              return Text(
                '$running trasferimenti in corso',
                style: TextStyle(fontSize: TypeSize.caption, color: c.accent, fontFeatures: kTabular),
              );
            },
          ),
          if (_loading) ...[
            const SizedBox(width: Gap.sm),
            const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
          ],
          const SizedBox(width: Gap.sm),
          Text(
            t.account.name,
            style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<VoidCallback> _item(String label, IconData icon, VoidCallback? action) => PopupMenuItem<VoidCallback>(
    value: action,
    enabled: action != null,
    height: 28,
    child: Row(
      children: [
        Icon(icon, size: 15, color: DbColors.of(context).textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: TypeSize.body)),
        ),
      ],
    ),
  );

  Future<void> _menu(Offset pos) async {
    final sel = _selected;
    if (sel.isEmpty) return;
    final single = sel.length == 1 ? sel.first : null;
    final ext = single?.extension ?? '';
    final items = <PopupMenuEntry<VoidCallback>>[
      if (single != null && single.isFolder) _item('Apri', Icons.folder_open_outlined, () => _go(single.key)),
      if (single != null && !single.isFolder && cloudTextExtensions.contains(ext))
        _item('Apri nell\'editor SQL', Icons.edit_note_rounded, () => _openItem(single)),
      if (single != null && !single.isFolder && cloudCsvExtensions.contains(ext))
        _item(
          'Importa in tabella…',
          Icons.table_chart_outlined,
          () => _act((s) async {
            await cloudImportCsv(context, s, single);
            return false;
          }),
        ),
      _item('Scarica…', Icons.download_outlined, () => _downloadSelection(sel)),
      if (single != null && !single.isFolder)
        _item(
          'Copia link di condivisione…',
          Icons.link_rounded,
          () => _act((s) async {
            await cloudShareLink(context, s, single);
            return false;
          }),
        ),
      if (single != null)
        _item(
          'Copia URI',
          Icons.content_copy,
          () => _act((s) async {
            await cloudCopyUri(context, s, single.bucket, single.key);
            return false;
          }),
        ),
      const PopupMenuDivider(height: 9),
      if (single != null)
        _item('Rinomina…', Icons.drive_file_rename_outline, () => _act((s) => cloudRename(context, s, single))),
      _item('Elimina…', Icons.delete_outline, () => _act((s) => cloudDelete(context, s, sel))),
      if (single != null && !single.isFolder) ...[
        const PopupMenuDivider(height: 9),
        _item(
          'Proprietà',
          Icons.info_outline,
          () => _act((s) async {
            await cloudProperties(context, s, single);
            return false;
          }),
        ),
      ],
    ];
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(pos & const Size(1, 1), Offset.zero & overlay.size),
      items: items,
    );
    action?.call();
  }
}
