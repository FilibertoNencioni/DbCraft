import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../model/connection_folders.dart';
import '../../services/script_library.dart';
import '../../services/script_session.dart';
import '../../state/app_state.dart';
import '../../state/editor_tabs.dart';
import '../navigator/folder_prompt.dart';
import '../widgets/common.dart';
import 'script_actions.dart';

/// Kinds of row of the scripts panel.
enum _Kind { header, draft, closedGroup, closed, folder, script, shortcut, trashGroup, trashItem, match, hint }

/// A row of the panel. [key] identifies it across rebuilds (selection,
/// rename): `d:buffer`, `c:buffer`, `f:folder`, `s:script`, `fav:key`,
/// `rec:key`, `t:trashId`, `m:script`, `h:section`.
class _Row {
  _Row(
    this.kind,
    this.key, {
    this.title = '',
    this.depth = 0,
    this.tab,
    this.meta,
    this.node,
    this.scriptKey,
    this.trash,
    this.match,
    this.section,
  });

  final _Kind kind;
  final String key;
  final String title;
  final int depth;
  final SqlEditorTab? tab;
  final BufferMeta? meta;
  final ScriptNode? node;

  /// Session key of a favorite / recent row.
  final String? scriptKey;
  final TrashItem? trash;
  final ScriptMatch? match;
  final String? section;

  /// Library path of a script or folder row.
  String? get path => node?.path ?? match?.path;

  bool get selectable => kind != _Kind.header && kind != _Kind.hint;
}

/// The "Script" sidebar: open drafts and recently closed editors, the
/// library of saved scripts as a tree of folders (drag & drop, rename,
/// move, trash), favorites and recents, search by name and content.
class ScriptsPanel extends StatefulWidget {
  const ScriptsPanel({super.key, required this.revision});

  /// Changes when scripts may have changed on disk: the tree reloads.
  final int revision;

  @override
  State<ScriptsPanel> createState() => _ScriptsPanelState();
}

class _ScriptsPanelState extends State<ScriptsPanel> {
  final _filter = TextEditingController();
  final _scroll = ScrollController();
  ScriptNode? _tree;
  List<TrashItem> _trash = [];

  /// External favorites / recents that still exist.
  Set<String> _externalExisting = {};
  int _loadSeq = 0;

  List<ScriptMatch>? _matches;
  Timer? _searchTimer;
  int _searchSeq = 0;

  /// Row picked by the user; follows the active editor otherwise.
  String? _picked;
  Object? _lastCurrent;
  String? _renaming;
  final Set<String> _collapsed = {};
  bool _showClosed = false;
  bool _showTrash = false;

  // Drag and drop.
  String? _dragging;
  String? _dropFolder;
  EdgeDraggingAutoScroller? _autoScroller;

  AppState get _app => AppScope.read(context);
  ScriptLibrary get _lib => _app.library;
  String get _query => _filter.text.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ScriptsPanel old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) _load();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _filter.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    final app = _app;
    try {
      final tree = await _lib.tree();
      final trash = await _lib.listTrash();
      final external = <String>{};
      for (final k in {...app.scriptSession.favorites, ...app.scriptSession.recent}) {
        if (p.isAbsolute(k) && await File(k).exists()) external.add(k);
      }
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _tree = tree;
        _trash = trash;
        _externalExisting = external;
      });
      if (_query.isNotEmpty) _search();
    } catch (_) {
      // Library not readable right now: keep what is shown.
    }
  }

  void _onFilter(String _) {
    _searchTimer?.cancel();
    setState(() => _matches = null);
    if (_query.isEmpty) return;
    _searchTimer = Timer(const Duration(milliseconds: 200), _search);
  }

  Future<void> _search() async {
    final seq = ++_searchSeq;
    final q = _query;
    final r = await _lib.search(q, tree: _tree);
    if (!mounted || seq != _searchSeq || q != _query) return;
    setState(() => _matches = r);
  }

  // -------------------------------------------------------------------------
  // Rows
  // -------------------------------------------------------------------------

  List<ScriptNode> _sorted(List<ScriptNode> nodes, ScriptSort sort) {
    int cmp(ScriptNode a, ScriptNode b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      if (sort == ScriptSort.modified) {
        final c = b.lastModified.compareTo(a.lastModified);
        if (c != 0) return c;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }

    return [...nodes]..sort(cmp);
  }

  Set<String> get _libraryScripts => {for (final s in _tree?.scripts ?? const <ScriptNode>[]) s.path};

  bool _keyExists(String key, Set<String> library) =>
      p.isAbsolute(key) ? _externalExisting.contains(key) : library.contains(key);

  List<_Row> _rows(AppState app) {
    final rows = <_Row>[];
    final session = app.scriptSession;
    final drafts = app.tabs.whereType<SqlEditorTab>().where((t) => t.isDraft).toList();
    final closed = app.closedDrafts;
    final q = _query.toLowerCase();

    if (q.isNotEmpty) {
      final d = drafts.where((t) => t.name.toLowerCase().contains(q)).toList();
      final c = closed.where((b) => b.label.toLowerCase().contains(q)).toList();
      if (d.isNotEmpty || c.isNotEmpty) {
        rows.add(_Row(_Kind.header, 'h:drafts', title: 'Bozze'));
        rows.addAll(d.map((t) => _Row(_Kind.draft, 'd:${t.bufferId}', title: t.name, tab: t)));
        rows.addAll(c.map((b) => _Row(_Kind.closed, 'c:${b.id}', title: b.label, meta: b)));
      }
      rows.add(_Row(_Kind.header, 'h:lib', title: 'Libreria'));
      final m = _matches;
      if (m == null) {
        rows.add(_Row(_Kind.hint, 'hint', title: 'Ricerca…'));
      } else if (m.isEmpty) {
        rows.add(_Row(_Kind.hint, 'hint', title: 'Nessuno script contiene "$_query"'));
      } else {
        rows.addAll(m.map((x) => _Row(_Kind.match, 'm:${x.path}', title: p.basenameWithoutExtension(x.path), match: x)));
      }
      return rows;
    }

    final library = _libraryScripts;
    final favorites = session.favorites.where((k) => _keyExists(k, library)).toList();
    if (favorites.isNotEmpty) {
      rows.add(_Row(_Kind.header, 'h:fav', title: 'Preferiti', section: 'fav'));
      if (!_collapsed.contains('fav')) {
        rows.addAll(favorites.map((k) => _Row(_Kind.shortcut, 'fav:$k', title: _keyTitle(k), scriptKey: k)));
      }
    }
    final recent = session.recent.where((k) => !favorites.contains(k) && _keyExists(k, library)).take(5).toList();
    if (recent.isNotEmpty) {
      rows.add(_Row(_Kind.header, 'h:rec', title: 'Recenti', section: 'rec'));
      if (!_collapsed.contains('rec')) {
        rows.addAll(recent.map((k) => _Row(_Kind.shortcut, 'rec:$k', title: _keyTitle(k), scriptKey: k)));
      }
    }
    if (drafts.isNotEmpty || closed.isNotEmpty) {
      rows.add(_Row(_Kind.header, 'h:drafts', title: 'Bozze', section: 'drafts'));
      if (!_collapsed.contains('drafts')) {
        rows.addAll(drafts.map((t) => _Row(_Kind.draft, 'd:${t.bufferId}', title: t.name, tab: t)));
        if (closed.isNotEmpty) {
          rows.add(_Row(_Kind.closedGroup, 'cg', title: 'Chiuse di recente'));
          if (_showClosed) {
            rows.addAll(closed.map((b) => _Row(_Kind.closed, 'c:${b.id}', title: _closedTitle(b), meta: b, depth: 1)));
          }
        }
      }
    }
    rows.add(_Row(_Kind.header, 'h:lib', title: 'Libreria', section: 'lib'));
    if (!_collapsed.contains('lib')) {
      final tree = _tree;
      if (tree != null && tree.children.isEmpty) {
        rows.add(_Row(_Kind.hint, 'hint', title: 'Nessuno script salvato'));
      }
      void walk(ScriptNode n, int depth) {
        for (final c in _sorted(n.children, session.sort)) {
          if (c.isFolder) {
            rows.add(_Row(_Kind.folder, 'f:${c.path}', title: c.name, node: c, depth: depth));
            if (session.expanded.contains(c.path)) walk(c, depth + 1);
          } else {
            rows.add(_Row(_Kind.script, 's:${c.path}', title: c.title, node: c, depth: depth));
          }
        }
      }

      if (tree != null) walk(tree, 0);
    }
    if (_trash.isNotEmpty) {
      rows.add(_Row(_Kind.trashGroup, 'tg', title: 'Cestino'));
      if (_showTrash) {
        rows.addAll(_trash.map((t) => _Row(_Kind.trashItem, 't:${t.id}', title: _trashTitle(t), trash: t, depth: 1)));
      }
    }
    return rows;
  }

  String _keyTitle(String key) => p.basenameWithoutExtension(key);

  String _closedTitle(BufferMeta b) => b.isDraft ? b.label : '${b.label} (modifiche)';

  String _trashTitle(TrashItem t) => t.isFolder ? t.name : p.basenameWithoutExtension(t.name);

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'adesso';
    if (d.inHours < 1) return '${d.inMinutes} min fa';
    if (d.inDays < 1) return '${d.inHours} h fa';
    if (d.inDays < 7) return '${d.inDays} g fa';
    return '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year}';
  }

  /// Key of the row matching the active editor.
  String? _currentKey(AppState app) {
    final t = app.currentTab;
    if (t is! SqlEditorTab) return null;
    if (t.isDraft) return 'd:${t.bufferId}';
    final rel = _lib.relOf(t.file!.path);
    return rel == null ? null : 's:$rel';
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  /// The library folder new things go into: the selected folder, or the
  /// folder of the selected script.
  String _targetFolder(String? key) {
    if (key == null) return '';
    if (key.startsWith('f:')) return key.substring(2);
    if (key.startsWith('s:')) return folderParent(key.substring(2));
    return '';
  }

  Future<void> _newDraft({String? folder}) async {
    final app = _app;
    await app.openSqlEditor(app.activeConnection, folder: folder ?? _targetFolder(_picked));
  }

  Future<void> _newFolder({String? parent}) async {
    final where = parent ?? _targetFolder(_picked);
    final name = await promptText(context, where.isEmpty ? 'Nuova cartella' : 'Nuova cartella in "$where"',
        label: 'Nome della cartella');
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final rel = await _lib.createFolder(where, name);
      if (where.isNotEmpty) _app.setScriptFolderExpanded(where, true);
      _picked = 'f:$rel';
      _app.scriptsChanged();
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Impossibile creare la cartella');
    }
  }

  Future<void> _openPath(String rel) async {
    setState(() => _picked = null);
    await openLibraryScript(context, _lib.fileOf(rel));
  }

  Future<void> _openKey(String key) async {
    setState(() => _picked = null);
    await openLibraryScript(context, _app.scriptFile(key));
  }

  void _toggleFolder(String rel) {
    final app = _app;
    app.setScriptFolderExpanded(rel, !app.scriptSession.expanded.contains(rel));
  }

  void _activate(_Row r) {
    final app = _app;
    switch (r.kind) {
      case _Kind.header:
        if (r.section != null) _toggleSection(r.section!);
      case _Kind.draft:
        setState(() => _picked = null);
        app.activate(r.tab!);
      case _Kind.closedGroup:
        setState(() => _showClosed = !_showClosed);
      case _Kind.closed:
        setState(() => _picked = null);
        app.reopenClosed(r.meta!.id);
      case _Kind.folder:
        _toggleFolder(r.node!.path);
      case _Kind.script || _Kind.match:
        _openPath(r.path!);
      case _Kind.shortcut:
        _openKey(r.scriptKey!);
      case _Kind.trashGroup:
        setState(() => _showTrash = !_showTrash);
      case _Kind.trashItem || _Kind.hint:
        break;
    }
  }

  void _toggleSection(String s) => setState(() {
    if (!_collapsed.remove(s)) _collapsed.add(s);
  });

  void _expand(_Row r, bool expand) {
    switch (r.kind) {
      case _Kind.folder:
        _app.setScriptFolderExpanded(r.node!.path, expand);
      case _Kind.closedGroup:
        setState(() => _showClosed = expand);
      case _Kind.trashGroup:
        setState(() => _showTrash = expand);
      case _Kind.header when r.section != null:
        setState(() => expand ? _collapsed.remove(r.section) : _collapsed.add(r.section!));
      default:
        break;
    }
  }

  Future<void> _rename(_Row r, String input) async {
    setState(() => _renaming = null);
    final name = input.trim();
    if (name.isEmpty || name == r.title) return;
    final app = _app;
    if (r.kind == _Kind.draft) {
      r.tab!.draftName = name;
      r.tab!.refresh();
      app.scriptsChanged();
      return;
    }
    final from = r.node!.path;
    try {
      final to = await _lib.rename(from, name);
      if (_picked == r.key) _picked = '${r.key.substring(0, 2)}$to';
      app.scriptsMoved(from, to);
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Impossibile rinominare');
    }
  }

  Future<void> _move(String from, String folder) async {
    final app = _app;
    try {
      final isFolder = await FileSystemEntity.isDirectory(_lib.abs(from));
      final to = await _lib.move(from, folder);
      if (to == from) return;
      if (folder.isNotEmpty) app.setScriptFolderExpanded(folder, true);
      _picked = '${isFolder ? 'f:' : 's:'}$to';
      app.scriptsMoved(from, to);
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Impossibile spostare');
    }
  }

  Future<void> _promptMove(String rel) async {
    final isFolder = await FileSystemEntity.isDirectory(_lib.abs(rel));
    final folders = (await _lib.folderPaths()).where((f) => !isFolder || !isInFolder(f, rel)).toList();
    if (!mounted) return;
    final to = await promptFolder(
      context,
      'Sposta "${isFolder ? folderName(rel) : p.basenameWithoutExtension(rel)}" in',
      folders: folders,
      initial: folderParent(rel),
      message: 'Scegli una cartella della libreria o scrivine una nuova (es. Report/Vendite). Vuoto: livello principale.',
    );
    if (to == null || !mounted) return;
    try {
      for (final part in to.split('/').where((s) => s.isNotEmpty)) {
        ScriptLibrary.checkName(part);
      }
    } catch (e) {
      showErrorDialog(context, e, title: 'Nome di cartella non valido');
      return;
    }
    await _move(rel, to);
  }

  Future<void> _duplicate(String rel) async {
    try {
      final copy = await _lib.duplicate(rel);
      _picked = 's:$copy';
      _app.scriptsChanged();
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Impossibile duplicare lo script');
    }
  }

  Future<void> _trashPath(String rel) async {
    final app = _app;
    final isFolder = await FileSystemEntity.isDirectory(_lib.abs(rel));
    final unsaved = app.tabs.whereType<SqlEditorTab>().where((t) {
      final r = t.file == null ? null : _lib.relOf(t.file!.path);
      return r != null && isInFolder(r, rel) && t.hasUnsavedChanges;
    }).toList();
    if (unsaved.isNotEmpty && mounted) {
      final ok = await confirmDialog(
        context,
        'Modifiche non salvate',
        '${unsaved.map((t) => t.name).join(', ')} contiene modifiche non salvate, che andranno perse.',
        ok: 'Sposta nel cestino',
        destructive: true,
      );
      if (!ok) return;
    }
    try {
      await _lib.trash(rel);
      app.scriptsRemoved(rel);
      if (mounted) {
        showToast(
          context,
          '${isFolder ? 'Cartella "${folderName(rel)}"' : '"${p.basenameWithoutExtension(rel)}"'} spostato nel cestino',
        );
      }
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Impossibile eliminare');
    }
  }

  Future<void> _deleteDraft(SqlEditorTab t) async {
    if (t.isDirty) {
      final ok = await confirmDialog(
        context,
        'Eliminare "${t.name}"?',
        'La bozza non è salvata: il testo non sarà recuperabile.',
        ok: 'Elimina',
        destructive: true,
      );
      if (!ok) return;
    }
    _app.closeTab(t, keepText: false);
  }

  Future<void> _deleteClosed(BufferMeta b) async {
    final ok = await confirmDialog(
      context,
      'Eliminare "${_closedTitle(b)}"?',
      'Il testo non sarà recuperabile.',
      ok: 'Elimina',
      destructive: true,
    );
    if (ok) await _app.discardClosed(b.id);
  }

  Future<void> _restore(TrashItem t) async {
    try {
      final rel = await _lib.restore(t);
      final parent = folderParent(rel);
      if (parent.isNotEmpty) _app.setScriptFolderExpanded(parent, true);
      _picked = '${t.isFolder ? 'f:' : 's:'}$rel';
      _app.scriptsChanged();
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Impossibile ripristinare');
    }
  }

  Future<void> _deleteForever(TrashItem t) async {
    final ok = await confirmDialog(
      context,
      'Eliminare definitivamente "${_trashTitle(t)}"?',
      'Non potrà essere ripristinato.',
      ok: 'Elimina',
      destructive: true,
    );
    if (!ok) return;
    await _lib.deleteForever(t);
    _app.scriptsChanged();
  }

  Future<void> _emptyTrash() async {
    final ok = await confirmDialog(
      context,
      'Svuotare il cestino?',
      '${_trash.length} elementi verranno eliminati definitivamente.',
      ok: 'Svuota',
      destructive: true,
    );
    if (!ok) return;
    await _lib.emptyTrash();
    _app.scriptsChanged();
  }

  Future<void> _saveDraftIn(SqlEditorTab t, String folder) async {
    t.suggestedFolder = folder;
    _app.activate(t);
    await saveSqlTabAs(context, t);
  }

  void _copyPath(String path) {
    Clipboard.setData(ClipboardData(text: path));
    showToast(context, 'Percorso copiato');
  }

  // -------------------------------------------------------------------------
  // Context menus
  // -------------------------------------------------------------------------

  List<MenuEntry<void>> _scriptMenu(String rel, {required bool inTree}) {
    final app = _app;
    final fav = app.scriptSession.isFavorite(rel);
    return [
      MenuEntry('Apri', onSelected: () => _openPath(rel)),
      const MenuEntry.divider(),
      if (inTree) MenuEntry('Rinomina', onSelected: () => setState(() => _renaming = 's:$rel')),
      MenuEntry('Duplica', onSelected: () => _duplicate(rel)),
      MenuEntry('Sposta in…', onSelected: () => _promptMove(rel)),
      MenuEntry(fav ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti', onSelected: () => app.toggleFavorite(rel)),
      const MenuEntry.divider(),
      MenuEntry('Mostra in $fileManagerName', onSelected: () => revealInFileManager(_lib.abs(rel))),
      MenuEntry('Copia percorso', onSelected: () => _copyPath(_lib.abs(rel))),
      const MenuEntry.divider(),
      MenuEntry('Sposta nel cestino', destructive: true, onSelected: () => _trashPath(rel)),
    ];
  }

  List<MenuEntry<void>> _menu(_Row r) {
    final app = _app;
    switch (r.kind) {
      case _Kind.script:
        return _scriptMenu(r.node!.path, inTree: true);
      case _Kind.match:
        return _scriptMenu(r.match!.path, inTree: false);
      case _Kind.shortcut:
        final k = r.scriptKey!;
        final path = app.scriptFile(k).path;
        return [
          MenuEntry('Apri', onSelected: () => _openKey(k)),
          MenuEntry(
            app.scriptSession.isFavorite(k) ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti',
            onSelected: () => app.toggleFavorite(k),
          ),
          const MenuEntry.divider(),
          MenuEntry('Mostra in $fileManagerName', onSelected: () => revealInFileManager(path)),
          MenuEntry('Copia percorso', onSelected: () => _copyPath(path)),
        ];
      case _Kind.folder:
        final rel = r.node!.path;
        return [
          MenuEntry('Nuovo script qui', onSelected: () => _newDraft(folder: rel)),
          MenuEntry('Nuova cartella', onSelected: () => _newFolder(parent: rel)),
          const MenuEntry.divider(),
          MenuEntry('Rinomina', onSelected: () => setState(() => _renaming = r.key)),
          MenuEntry('Sposta in…', onSelected: () => _promptMove(rel)),
          const MenuEntry.divider(),
          MenuEntry('Mostra in $fileManagerName', onSelected: () => revealInFileManager(_lib.abs(rel))),
          MenuEntry('Copia percorso', onSelected: () => _copyPath(_lib.abs(rel))),
          const MenuEntry.divider(),
          MenuEntry('Sposta nel cestino', destructive: true, onSelected: () => _trashPath(rel)),
        ];
      case _Kind.draft:
        final t = r.tab!;
        return [
          MenuEntry('Apri', onSelected: () => app.activate(t)),
          MenuEntry('Salva come script…', onSelected: () {
            app.activate(t);
            saveSqlTabAs(context, t);
          }),
          MenuEntry('Rinomina', onSelected: () => setState(() => _renaming = r.key)),
          const MenuEntry.divider(),
          MenuEntry('Elimina bozza', destructive: true, onSelected: () => _deleteDraft(t)),
        ];
      case _Kind.closed:
        final b = r.meta!;
        return [
          MenuEntry('Riapri', onSelected: () => app.reopenClosed(b.id)),
          const MenuEntry.divider(),
          MenuEntry('Elimina', destructive: true, onSelected: () => _deleteClosed(b)),
        ];
      case _Kind.closedGroup:
        return [
          MenuEntry('Riapri l\'ultima', onSelected: () => app.reopenLastClosed()),
          MenuEntry('Elimina tutte', destructive: true, onSelected: _deleteAllClosed),
        ];
      case _Kind.trashGroup:
        return [MenuEntry('Svuota cestino', destructive: true, onSelected: _emptyTrash)];
      case _Kind.trashItem:
        final t = r.trash!;
        return [
          MenuEntry('Ripristina', onSelected: () => _restore(t)),
          const MenuEntry.divider(),
          MenuEntry('Elimina definitivamente', destructive: true, onSelected: () => _deleteForever(t)),
        ];
      case _Kind.header when r.section == 'lib':
        return [
          MenuEntry('Nuovo script', onSelected: () => _newDraft(folder: '')),
          MenuEntry('Nuova cartella', onSelected: () => _newFolder(parent: '')),
          const MenuEntry.divider(),
          MenuEntry('Mostra in $fileManagerName', onSelected: () => revealInFileManager(_lib.root.path)),
        ];
      default:
        return const [];
    }
  }

  Future<void> _deleteAllClosed() async {
    final app = _app;
    final all = app.closedDrafts;
    final ok = await confirmDialog(
      context,
      'Eliminare le chiuse di recente?',
      'Il testo di ${all.length} editor chiusi non sarà recuperabile.',
      ok: 'Elimina',
      destructive: true,
    );
    if (!ok) return;
    for (final b in all) {
      await app.discardClosed(b.id);
    }
  }

  void _showMenu(_Row r, Offset pos) {
    final entries = _menu(r);
    if (entries.isEmpty) return;
    setState(() => _picked = r.key);
    showMacMenu<void>(context, position: pos, entries: entries);
  }

  // -------------------------------------------------------------------------
  // Drag and drop: scripts and folders into folders or the library root;
  // drafts onto a folder to save them there.
  // -------------------------------------------------------------------------

  /// Whether [data] (a row key) can go into [folder].
  bool _canDrop(String data, String folder) {
    if (data.startsWith('d:')) return true;
    final rel = data.substring(2);
    if (data.startsWith('f:') && isInFolder(folder, rel)) return false;
    return folderParent(rel) != folder;
  }

  void _drop(String data, String folder) {
    if (data.startsWith('d:')) {
      final id = data.substring(2);
      final t = _app.tabs.whereType<SqlEditorTab>().where((t) => t.bufferId == id).firstOrNull;
      if (t != null) _saveDraftIn(t, folder);
      return;
    }
    _move(data.substring(2), folder);
  }

  void _startDrag(String key, BuildContext rowContext) {
    _autoScroller?.stopAutoScroll();
    _autoScroller = EdgeDraggingAutoScroller(Scrollable.of(rowContext), velocityScalar: 20);
    setState(() {
      _dragging = key;
      _picked = key;
    });
  }

  void _endDrag() {
    if (_dragging == null) return;
    _autoScroller?.stopAutoScroll();
    _autoScroller = null;
    setState(() {
      _dragging = null;
      _dropFolder = null;
    });
  }

  Widget _dropTarget(String folder, Widget child) {
    final c = DbColors.of(context);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) {
        final ok = _canDrop(d.data, folder);
        if (ok && _dropFolder != folder) setState(() => _dropFolder = folder);
        return ok;
      },
      onLeave: (_) {
        if (_dropFolder == folder) setState(() => _dropFolder = null);
      },
      onAcceptWithDetails: (d) {
        setState(() => _dropFolder = null);
        _drop(d.data, folder);
      },
      builder: (context, _, _) => Stack(
        children: [
          child,
          if (_dragging != null && _dropFolder == folder)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: c.accent, width: 2),
                    borderRadius: BorderRadius.circular(Radii.control),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _draggable(String key, IconData icon, String label, Widget child) {
    final c = DbColors.of(context);
    return Builder(
      builder: (rowContext) => Draggable<String>(
        data: key,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () => _startDrag(key, rowContext),
        onDragEnd: (_) => _endDrag(),
        onDraggableCanceled: (_, _) => _endDrag(),
        feedback: Transform.translate(
          offset: const Offset(10, -12),
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              height: kDenseRowHeight,
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
              decoration: BoxDecoration(
                color: c.menuBackground,
                borderRadius: BorderRadius.circular(Radii.control),
                border: Border.all(color: c.separator),
                boxShadow: Elevation.menu(Theme.of(context).brightness),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: c.textSecondary),
                  const SizedBox(width: 6),
                  Text(label, style: uiText(TypeSize.body, color: c.text)),
                ],
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: child),
        child: child,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  Widget _rowWidget(AppState app, _Row r, bool selected) {
    final c = DbColors.of(context);
    final session = app.scriptSession;
    void onMenu(Offset pos) => _showMenu(r, pos);

    switch (r.kind) {
      case _Kind.header:
        final label = SectionLabel(
          r.title,
          padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.md, Gap.xs, Gap.xs),
          expanded: r.section == null || !_collapsed.contains(r.section),
          onToggle: r.section == null ? null : (_) => _toggleSection(r.section!),
        );
        final withMenu = r.section == 'lib'
            ? GestureDetector(
                behavior: HitTestBehavior.translucent,
                onSecondaryTapUp: (d) => _showMenu(r, d.globalPosition),
                child: label,
              )
            : label;
        return r.section == 'lib' ? _dropTarget('', withMenu) : withMenu;
      case _Kind.hint:
        return OutlineRow(title: r.title, muted: true, reserveDisclosure: true);
      case _Kind.draft:
        final t = r.tab!;
        final row = OutlineRow(
          icon: AppIcons.edit,
          title: r.title,
          titleEditor: _renaming == r.key ? _renameField(r) : null,
          strong: true,
          reserveDisclosure: true,
          detail: t.connection?.config.name,
          accessories: [if (t.isDirty) const DirtyDot()],
          selected: selected,
          tooltip: '${t.name} · bozza non salvata',
          onTap: () => _activate(r),
          onMenu: onMenu,
        );
        return _draggable(r.key, AppIcons.edit, r.title, row);
      case _Kind.closedGroup:
        return OutlineRow(
          icon: AppIcons.history,
          title: r.title,
          expanded: _showClosed,
          onExpand: (v) => setState(() => _showClosed = v),
          accessories: [CountBadge(app.closedDrafts.length)],
          selected: selected,
          tooltip: 'Editor chiusi senza salvare: restano qui per 30 giorni',
          onTap: () => setState(() {
            _picked = r.key;
            _showClosed = !_showClosed;
          }),
          onMenu: onMenu,
        );
      case _Kind.closed:
        final b = r.meta!;
        return OutlineRow(
          icon: b.isDraft ? AppIcons.edit : AppIcons.document,
          iconColor: c.textTertiary,
          title: r.title,
          depth: r.depth,
          reserveDisclosure: true,
          muted: true,
          detail: _ago(b.closedAt!),
          selected: selected,
          tooltip: 'Chiuso ${_ago(b.closedAt!)} · clic per riaprire',
          onTap: () => _activate(r),
          onMenu: onMenu,
        );
      case _Kind.folder:
        final n = r.node!;
        final open = session.expanded.contains(n.path);
        final row = OutlineRow(
          icon: open ? AppIcons.folderOpen : AppIcons.folder,
          title: r.title,
          titleEditor: _renaming == r.key ? _renameField(r) : null,
          depth: r.depth,
          expanded: open,
          onExpand: (v) => app.setScriptFolderExpanded(n.path, v),
          selected: selected,
          tooltip: n.path,
          onTap: () {
            setState(() => _picked = r.key);
            _toggleFolder(n.path);
          },
          onDoubleTap: () {},
          onMenu: onMenu,
        );
        return _dropTarget(n.path, _draggable(r.key, AppIcons.folder, r.title, row));
      case _Kind.script:
        final n = r.node!;
        final file = _lib.fileOf(n.path);
        final tab = app.sqlTabOf(file);
        final row = OutlineRow(
          icon: AppIcons.document,
          title: r.title,
          titleEditor: _renaming == r.key ? _renameField(r) : null,
          depth: r.depth,
          reserveDisclosure: true,
          strong: tab != null,
          detail: _ago(n.modified),
          accessories: [
            if (tab != null && tab.isDirty) const DirtyDot(),
            if (session.isFavorite(n.path)) Icon(AppIcons.starFill, size: 11, color: c.textTertiary),
          ],
          selected: selected,
          tooltip: tab != null ? '${n.path} · aperto' : n.path,
          onTap: () => _activate(r),
          onMenu: onMenu,
        );
        return _draggable(r.key, AppIcons.document, r.title, row);
      case _Kind.shortcut:
        final k = r.scriptKey!;
        final tab = app.sqlTabOf(app.scriptFile(k));
        final folder = p.isAbsolute(k) ? p.dirname(k) : folderParent(k);
        return OutlineRow(
          icon: r.key.startsWith('fav:') ? AppIcons.starFill : AppIcons.document,
          iconColor: r.key.startsWith('fav:') ? c.accent : null,
          title: r.title,
          reserveDisclosure: true,
          strong: tab != null,
          detail: folder.isEmpty ? null : folderName(folder),
          accessories: [if (tab != null && tab.isDirty) const DirtyDot()],
          selected: selected,
          tooltip: p.isAbsolute(k) ? k : 'Libreria/$k',
          onTap: () => _activate(r),
          onMenu: onMenu,
        );
      case _Kind.trashGroup:
        return OutlineRow(
          icon: AppIcons.delete,
          title: r.title,
          expanded: _showTrash,
          onExpand: (v) => setState(() => _showTrash = v),
          accessories: [CountBadge(_trash.length)],
          selected: selected,
          tooltip: 'Script e cartelle eliminati: restano qui per 30 giorni',
          onTap: () => setState(() {
            _picked = r.key;
            _showTrash = !_showTrash;
          }),
          onMenu: onMenu,
        );
      case _Kind.trashItem:
        final t = r.trash!;
        return OutlineRow(
          icon: t.isFolder ? AppIcons.folder : AppIcons.document,
          iconColor: c.textTertiary,
          title: r.title,
          depth: r.depth,
          reserveDisclosure: true,
          muted: true,
          detail: _ago(t.deletedAt),
          selected: selected,
          tooltip: 'Era in: Libreria/${t.path}',
          onTap: () => setState(() => _picked = r.key),
          onMenu: onMenu,
        );
      case _Kind.match:
        final m = r.match!;
        final file = _lib.fileOf(m.path);
        final tab = app.sqlTabOf(file);
        final folder = folderParent(m.path);
        return OutlineRow(
          icon: AppIcons.document,
          title: r.title,
          reserveDisclosure: true,
          strong: tab != null,
          detail: m.lineNumber != null ? 'riga ${m.lineNumber}' : (folder.isEmpty ? null : folderName(folder)),
          selected: selected,
          tooltip: m.line != null ? '${m.path}\n${m.lineNumber}: ${m.line}' : m.path,
          onTap: () => _activate(r),
          onMenu: onMenu,
        );
    }
  }

  Widget _renameField(_Row r) => InlineRenameField(
    initial: r.title,
    onSubmit: (v) => _rename(r, v),
    onCancel: () => setState(() => _renaming = null),
  );

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final current = _currentKey(app);
    if (current != _lastCurrent) {
      _lastCurrent = current;
      _picked = null;
    }
    final rows = _rows(app);
    final selKey = _picked ?? current;
    final sel = rows.indexWhere((r) => r.key == selKey);
    return Column(
      children: [
        SectionLabel(
          'Script',
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 2),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ToolButton(icon: AppIcons.add, tooltip: 'Nuovo script (bozza)', onPressed: () => _newDraft()),
              ToolButton(icon: AppIcons.newFolder, tooltip: 'Nuova cartella', onPressed: () => _newFolder()),
              PulldownButton(
                icon: AppIcons.sort,
                tooltip: 'Ordina la libreria',
                commandIcons: false,
                entries: () => [
                  MenuEntry(
                    'Per nome',
                    checked: app.scriptSession.sort == ScriptSort.name,
                    onSelected: () => app.setScriptSort(ScriptSort.name),
                  ),
                  MenuEntry(
                    'Per data di modifica',
                    checked: app.scriptSession.sort == ScriptSort.modified,
                    onSelected: () => app.setScriptSort(ScriptSort.modified),
                  ),
                ],
              ),
              ToolButton(icon: AppIcons.refresh, tooltip: 'Aggiorna', onPressed: _load),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, 2, Gap.sm, Gap.sm),
          child: SearchField(controller: _filter, hint: 'Cerca nei nomi e nel contenuto', onChanged: _onFilter),
        ),
        Expanded(
          child: Listener(
            onPointerMove: (e) {
              if (_dragging == null) return;
              _autoScroller?.startAutoScrollIfNecessary(
                Rect.fromCenter(center: e.position, width: 1, height: kSidebarRowHeight * 2),
              );
            },
            onPointerUp: (_) => _endDrag(),
            onPointerCancel: (_) => _endDrag(),
            child: SourceList(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(10, 0, 10, Gap.md),
              itemCount: rows.length,
              selectedIndex: sel < 0 ? null : sel,
              selectable: (i) => rows[i].selectable,
              onSelect: (i) => setState(() => _picked = rows[i].key),
              onActivate: (i) => _activate(rows[i]),
              onExpand: (i, v) => _expand(rows[i], v),
              itemBuilder: (context, i) => _rowWidget(app, rows[i], i == sel),
            ),
          ),
        ),
      ],
    );
  }
}
