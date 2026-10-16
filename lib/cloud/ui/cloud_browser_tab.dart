// Full-size browser of one bucket / container (editor tab): breadcrumbs,
// table with name / size / modified / class, multi-selection and the same
// actions as the Cloud Explorer.
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
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
  IconData get icon => AppIcons.cloud;

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
  (int, DateTime)? _lastClick;
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

  /// Selects on the first click and opens on a second one within the
  /// double-tap timeout (onDoubleTap would delay every single click).
  void _click(int index, List<CloudObject> visible) {
    final now = DateTime.now();
    final last = _lastClick;
    final isDouble = last != null && last.$1 == index && now.difference(last.$2) <= kDoubleTapTimeout;
    _lastClick = isDouble ? null : (index, now);
    if (isDouble) {
      _openItem(visible[index]);
    } else {
      _tap(index, visible);
    }
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
          _header(),
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
          onPressed: t.prefix.isEmpty ? null : () => _go(CloudObject(bucket: t.bucket, key: t.prefix).parent),
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
          onPressed: () => _act((s) => cloudNewFolder(context, s, t.bucket, t.prefix)),
        ),
        ToolButton(
          icon: AppIcons.upload,
          tooltip: 'Carica file…',
          onPressed: () => _act((s) => cloudUploadFiles(context, s, t.bucket, t.prefix)),
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
                  await cloudShareLink(context, s, single);
                  return false;
                }),
        ),
        ToolButton(
          icon: AppIcons.delete,
          tooltip: 'Elimina…',
          onPressed: sel.isEmpty ? null : () => _act((s) => cloudDelete(context, s, sel)),
        ),
        const SizedBox(width: Gap.sm),
        SearchField(controller: _filter, hint: 'Filtra', width: 180, onChanged: (_) => setState(() {})),
      ],
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

  static const _wIcon = 30.0;
  static const _wSize = 110.0;
  static const _wDate = 150.0;
  static const _wClass = 120.0;

  Widget _header() {
    final c = DbColors.of(context);
    Widget h(String label, String key, {double? width, bool right = false, bool last = false}) {
      final child = TableHeaderCell(
        label: label,
        alignEnd: right,
        sorted: _sort == key ? _asc : null,
        separator: !last,
        onTap: () => setState(() {
          if (_sort == key) {
            _asc = !_asc;
          } else {
            _sort = key;
            _asc = true;
          }
        }),
      );
      return width == null ? Expanded(child: child) : SizedBox(width: width, child: child);
    }

    return Container(
      height: GridMetrics.header,
      padding: const EdgeInsets.only(left: _wIcon, right: Gap.sm),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Row(
        children: [
          h('Nome', 'name'),
          h('Dimensione', 'size', width: _wSize, right: true),
          h('Ultima modifica', 'modified', width: _wDate),
          h('Classe', 'class', width: _wClass, last: true),
        ],
      ),
    );
  }

  // Rows are drawn here rather than with MacTable, which selects one row
  // only: the browser needs ⇧/⌘ multi-selection and ⌘A.
  Widget _body(List<CloudObject> visible) {
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
    final more = t.continuation != null;
    final focused = _focus.hasFocus;
    return Focus(
      focusNode: _focus,
      onFocusChange: (_) => setState(() {}),
      onKeyEvent: (_, e) => _onKey(e, visible),
      child: ListView.builder(
        itemCount: visible.length + (more ? 1 : 0),
        itemExtent: GridMetrics.row,
        itemBuilder: (context, i) {
          if (i == visible.length) {
            return Center(
              child: _loading
                  ? const Spinner(size: Spinner.small)
                  : LinkButton(label: 'Carica altri elementi', small: true, onPressed: () => _reload(more: true)),
            );
          }
          final o = visible[i];
          final selected = t.selection.contains(o.key);
          final emphasized = selected && focused && c.windowActive;
          final Color bg = selected
              ? (focused ? c.selectionEmphasized : c.selectionMuted)
              : (i.isOdd ? c.zebra : c.content);
          final fg = emphasized ? c.onSelectionEmphasized : c.text;
          final fg2 = emphasized ? c.onSelectionEmphasized.withValues(alpha: 0.8) : c.textSecondary;
          final cellStyle = uiText(TypeSize.body, color: fg2, features: kTabular);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _click(i, visible),
            onSecondaryTapDown: (d) {
              if (!selected) _tap(i, visible);
              _menu(d.globalPosition);
            },
            child: Container(
              color: bg,
              padding: const EdgeInsets.only(right: Gap.sm),
              child: RowTint(
                background: bg,
                emphasized: emphasized,
                child: Row(
                  children: [
                    SizedBox(
                      width: _wIcon,
                      child: Icon(
                        o.isFolder ? AppIcons.folder : cloudFileIcon(o.extension),
                        size: 16,
                        color: emphasized ? fg : (o.isFolder ? c.accent : c.textSecondary),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: Gap.sm),
                        child: Text(
                          o.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: uiText(TypeSize.body, color: fg),
                        ),
                      ),
                    ),
                    _cell(_wSize, o.isFolder || o.size < 0 ? '' : formatBytes(o.size), cellStyle, right: true),
                    _cell(_wDate, _date(o.modified), cellStyle),
                    _cell(_wClass, o.storageClass ?? '', cellStyle.copyWith(fontSize: TypeSize.small)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static Widget _cell(double width, String text, TextStyle style, {bool right = false}) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: right ? TextAlign.right : null,
        style: style,
      ),
    ),
  );

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
    return StatusBar(
      children: [
        Text(
          '${visible.length} elementi · ${formatBytes(total)}${t.continuation != null ? ' (parziale)' : ''}'
          '${sel.isEmpty ? '' : ' · ${sel.length} selezionati (${formatBytes(selSize)})'}',
          style: const TextStyle(fontFeatures: kTabular),
        ),
        const Spacer(),
        ListenableBuilder(
          listenable: CloudTransfers.instance,
          builder: (context, _) {
            final running = CloudTransfers.instance.items.where((x) => x.state == TransferState.running).length;
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
        if (single != null && !single.isFolder && cloudTextExtensions.contains(ext))
          _item('Apri nell\'editor SQL', () => _openItem(single)),
        if (single != null && !single.isFolder && cloudCsvExtensions.contains(ext))
          _item(
            'Importa in tabella…',
            () => _act((s) async {
              await cloudImportCsv(context, s, single);
              return false;
            }),
          ),
        _item('Scarica…', () => _downloadSelection(sel)),
        if (single != null && !single.isFolder)
          _item(
            'Copia link di condivisione…',
            () => _act((s) async {
              await cloudShareLink(context, s, single);
              return false;
            }),
          ),
        if (single != null)
          _item(
            'Copia URI',
            () => _act((s) async {
              await cloudCopyUri(context, s, single.bucket, single.key);
              return false;
            }),
          ),
        const MenuEntry.divider(),
        if (single != null) _item('Rinomina…', () => _act((s) => cloudRename(context, s, single))),
        _item('Elimina…', () => _act((s) => cloudDelete(context, s, sel))),
        if (single != null && !single.isFolder) ...[
          const MenuEntry.divider(),
          _item(
            'Proprietà',
            () => _act((s) async {
              await cloudProperties(context, s, single);
              return false;
            }),
          ),
        ],
      ],
    );
  }
}
