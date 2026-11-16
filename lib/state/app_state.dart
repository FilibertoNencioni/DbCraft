import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../features/design/table_design.dart';
import '../model/connection_config.dart';
import '../model/connection_folders.dart';
import '../model/db_objects.dart';
import '../services/script_library.dart';
import '../services/script_session.dart';
import '../services/sql_variables.dart';
import '../services/storage.dart';
import '../services/vault.dart';
import 'db_connection.dart';
import 'editor_tabs.dart';
import 'editor_zoom.dart';

/// Global application state (connections, editors, settings, history).
class AppState extends ChangeNotifier {
  AppState(
    this.workspace,
    this.vault,
    this.settings,
    List<ConnectionConfig> configs,
    this.history, {
    required this.scriptSession,
  }) : library = ScriptLibrary(root: workspace.scriptsDir, stateDir: workspace.stateDir) {
    for (final c in configs) {
      _injectSecrets(c);
      connections.add(_newConnection(c));
    }
  }

  /// Opens workspace and vault; with a master password the vault must be
  /// unlocked before calling [loadWith].
  static Future<(Workspace, Vault)> openStorage({Directory? workspaceDir}) async {
    final ws = await Workspace.open(override: workspaceDir);
    final vault = await Vault.open(ws.root);
    return (ws, vault);
  }

  static Future<AppState> load({Directory? workspaceDir}) async {
    final (ws, vault) = await openStorage(workspaceDir: workspaceDir);
    return loadWith(ws, vault);
  }

  static Future<AppState> loadWith(Workspace ws, Vault vault) async {
    final settings = await ws.loadSettings();
    final configs = await ws.loadConnections();
    final history = await ws.loadHistory();
    final session = await ScriptSession.load(ws.stateDir);
    final state = AppState(ws, vault, settings, configs, history, scriptSession: session);
    // Passwords saved in clear text by older versions, or written in a
    // connection string, move to the vault.
    final inStrings = configs.where((c) => c.movePasswordToVault()).length;
    if (inStrings > 0 || configs.any((c) => c.password.isNotEmpty) && await ws.connectionsContainPasswords()) {
      await state._saveConnections();
    }
    await state._restoreScripts();
    return state;
  }

  final Workspace workspace;

  /// Saved scripts (the `scripts` folder) and their trash.
  final ScriptLibrary library;

  /// Drafts, open editors and other local state of the scripts.
  final ScriptSession scriptSession;

  /// Encrypted credential store (passwords, secrets, API keys).
  final Vault vault;
  AppSettings settings;
  final List<DbConnection> connections = [];
  final List<HistoryEntry> history;
  final List<EditorTab> tabs = [];
  int activeTab = -1;

  /// Text zoom of the SQL editors (session only).
  final sqlZoom = EditorZoom();

  /// The window is locked behind the master password (manual or idle lock).
  bool locked = false;

  void lockUi() {
    if (!vault.usesMasterPassword) return;
    locked = true;
    notifyListeners();
  }

  Future<bool> unlockUi(String password) async {
    if (!await vault.checkPassword(password)) return false;
    locked = false;
    notifyListeners();
    return true;
  }

  /// Connection selected in the navigator (target of toolbar actions).
  DbConnection? selectedConnection;
  Timer? _historySave;

  EditorTab? get currentTab => activeTab >= 0 && activeTab < tabs.length ? tabs[activeTab] : null;

  /// The connection that toolbar actions apply to.
  DbConnection? get activeConnection => currentTab?.connection ?? selectedConnection;

  DbConnection? byId(String id) {
    for (final c in connections) {
      if (c.config.id == id) return c;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Connections
  // -------------------------------------------------------------------------

  String _secretPrefix(ConnectionConfig c) => 'conn:${c.id}:';

  void _injectSecrets(ConnectionConfig c) {
    if (vault.isLocked) return;
    final pwd = vault.get('${_secretPrefix(c)}password');
    if (pwd != null) c.password = pwd;
    final secrets = vault.withPrefix('${_secretPrefix(c)}secret:');
    if (secrets.isNotEmpty) c.secretParams = {...c.secretParams, ...secrets};
  }

  Future<void> _saveConnections() async {
    for (final dc in connections) {
      final c = dc.config;
      c.movePasswordToVault();
      await vault.set('${_secretPrefix(c)}password', c.savePassword ? c.password : null);
      await vault.setAll('${_secretPrefix(c)}secret:', c.secretParams);
    }
    await workspace.saveConnections(connections.map((e) => e.config).toList());
  }

  /// Reloads what changed on disk after a Git pull: connections (matched by
  /// id, secrets re-injected), settings, history and unmodified editors.
  Future<void> reloadWorkspace(List<String> changed) async {
    bool touched(String name) => changed.isEmpty || changed.any((f) => f == name || f.endsWith('/$name'));
    if (touched('connections.json')) {
      final configs = await workspace.loadConnections();
      final ids = configs.map((c) => c.id).toSet();
      for (final dc in connections.where((d) => !ids.contains(d.config.id)).toList()) {
        await deleteConnection(dc);
      }
      for (final c in configs) {
        _injectSecrets(c);
        final existing = byId(c.id);
        if (existing != null) {
          existing.config = c;
        } else {
          connections.add(_newConnection(c));
        }
      }
      connections.sort((a, b) => configs.indexWhere((c) => c.id == a.config.id).compareTo(
            configs.indexWhere((c) => c.id == b.config.id),
          ));
    }
    if (touched('settings.json')) settings = await workspace.loadSettings();
    if (touched('history.json')) {
      final h = await workspace.loadHistory();
      history
        ..clear()
        ..addAll(h);
    }
    for (final t in tabs.whereType<SqlEditorTab>()) {
      final f = t.file;
      if (f == null || t.isDirty || !await f.exists()) continue;
      final text = await f.readAsString();
      if (text != t.controller.text) t.reloadFrom(text);
    }
    scriptsRevision++;
    notifyListeners();
  }

  /// Saves the connections (after editing shared properties).
  Future<void> saveConnections() async {
    await _saveConnections();
    notifyListeners();
  }

  Future<DbConnection> addConnection(ConnectionConfig c) async {
    final dc = _newConnection(c);
    connections.add(dc);
    selectedConnection = dc;
    await _saveConnections();
    notifyListeners();
    return dc;
  }

  Future<void> updateConnection(DbConnection dc, ConnectionConfig c) async {
    dc.config = c;
    await _saveConnections();
    notifyListeners();
  }

  Future<void> deleteConnection(DbConnection dc) async {
    for (final t in tabs.where((t) => t.connection == dc).toList()) {
      // SQL editors keep their text, without a connection.
      if (t is SqlEditorTab) {
        t.connection = null;
      } else {
        closeTab(t);
      }
    }
    await dc.disconnect();
    connections.remove(dc);
    dc.removeListener(notifyListeners);
    await vault.removePrefix(_secretPrefix(dc.config));
    if (selectedConnection == dc) selectedConnection = null;
    await _saveConnections();
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Connection folders (see connection_folders.dart)
  // -------------------------------------------------------------------------

  /// Folder of [dc] ("" at the top level).
  static String folderOf(DbConnection dc) => normalizeFolder(dc.config.folder);

  /// All the connection folders, in navigator order.
  List<String> get folders => orderedFolders(allFolders(connections.map(folderOf)), settings.folderOrder);

  /// Swaps [dc] with the previous (delta < 0) or next connection of its
  /// folder.
  Future<void> moveConnection(DbConnection dc, int delta) async {
    final i = connections.indexOf(dc);
    final folder = folderOf(dc);
    var j = i + delta.sign;
    while (j >= 0 && j < connections.length && folderOf(connections[j]) != folder) {
      j += delta.sign;
    }
    if (i < 0 || j < 0 || j >= connections.length) return;
    connections[i] = connections[j];
    connections[j] = dc;
    await _saveConnections();
    notifyListeners();
  }

  /// Moves [dc] into [folder], before [before] or after [after] (connections
  /// of that folder), at the end of the folder otherwise.
  Future<void> moveConnectionTo(DbConnection dc, String folder, {DbConnection? before, DbConnection? after}) async {
    if (identical(before, dc) || identical(after, dc)) return;
    folder = normalizeFolder(folder);
    connections.remove(dc);
    dc.config.folder = folder;
    final anchor = before ?? after;
    final at = anchor != null
        ? connections.indexOf(anchor)
        : connections.lastIndexWhere((c) => folderOf(c) == folder);
    // Unknown anchor or empty folder: at the end.
    final i = at < 0 ? connections.length : (before != null ? at : at + 1);
    connections.insert(i, dc);
    await _saveConnections();
    notifyListeners();
  }

  /// Moves the folder [path] into [parent] before its subfolder [before]
  /// (last when null). Returns the new path of each moved folder, null when
  /// the move is not possible (into itself).
  Future<Map<String, String>?> moveFolderTo(String path, String parent, {String? before}) =>
      _applyFolderMove(
        moveFolder(allFolders(connections.map(folderOf)), settings.folderOrder, path, parent: normalizeFolder(parent), before: before),
      );

  /// Renames the folder [path], keeping its place.
  Future<Map<String, String>?> renameFolder(String path, String name) {
    final all = allFolders(connections.map(folderOf));
    final siblings = subfolders(orderedFolders(all, settings.folderOrder), folderParent(path));
    final i = siblings.indexOf(path);
    return _applyFolderMove(
      moveFolder(
        all,
        settings.folderOrder,
        path,
        parent: folderParent(path),
        name: name,
        before: i >= 0 && i + 1 < siblings.length ? siblings[i + 1] : null,
      ),
    );
  }

  /// Swaps the folder [path] with its previous (delta < 0) or next sibling.
  Future<void> shiftFolderBy(String path, int delta) async {
    final order = shiftFolder(allFolders(connections.map(folderOf)), settings.folderOrder, path, delta);
    if (order == null) return;
    settings.folderOrder = order;
    await saveSettings();
  }

  Future<Map<String, String>?> _applyFolderMove(FolderMove? move) async {
    if (move == null) return null;
    for (final dc in connections) {
      final to = move.renames[folderOf(dc)];
      if (to != null) dc.config.folder = to;
    }
    // Without the folders left empty.
    settings.folderOrder = orderedFolders(allFolders(connections.map(folderOf)), move.order);
    await _saveConnections();
    await saveSettings();
    return move.renames;
  }

  Future<void> connect(DbConnection dc, {String? password}) =>
      dc.connect(libPath: settings.libPathOrNull, password: password);

  Future<void> disconnectAll() async {
    await Future.wait(connections.where((c) => c.isConnected).map((c) => c.disconnect()));
  }

  void select(DbConnection? dc) {
    selectedConnection = dc;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Settings / history
  // -------------------------------------------------------------------------

  Future<void> saveSettings() async {
    await workspace.saveSettings(settings);
    notifyListeners();
  }

  DbConnection _newConnection(ConnectionConfig c) => DbConnection(c)
    ..onHistory = addHistory
    ..onHistoryRolledBack = markHistoryRolledBack
    ..addListener(notifyListeners);

  /// Marks [entries] as failed with [reason] (their transaction was rolled
  /// back by the server).
  void markHistoryRolledBack(List<HistoryEntry> entries, String reason) {
    var changed = false;
    for (final e in entries) {
      final i = history.indexWhere((h) => identical(h, e));
      if (i < 0) continue;
      history[i] = HistoryEntry(
        sql: e.sql,
        connectionId: e.connectionId,
        connectionName: e.connectionName,
        time: e.time,
        durationMs: e.durationMs,
        rows: e.rows,
        error: reason,
      );
      changed = true;
    }
    if (!changed) return;
    _historySave?.cancel();
    _historySave = Timer(const Duration(seconds: 1), () => workspace.saveHistory(history));
    notifyListeners();
  }

  void addHistory(HistoryEntry e) {
    history.insert(0, e);
    if (history.length > settings.maxHistory) {
      history.removeRange(settings.maxHistory, history.length);
    }
    _historySave?.cancel();
    _historySave = Timer(const Duration(seconds: 1), () => workspace.saveHistory(history));
    notifyListeners();
  }

  Future<void> clearHistory() async {
    history.clear();
    await workspace.saveHistory(history);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Editors
  // -------------------------------------------------------------------------

  void _open(EditorTab t) {
    tabs.add(t);
    t.addListener(notifyListeners);
    activeTab = tabs.length - 1;
    _sessionChanged();
    notifyListeners();
  }

  void activate(EditorTab t) {
    final i = tabs.indexOf(t);
    if (i >= 0) {
      activeTab = i;
      if (t.connection != null) selectedConnection = t.connection;
      _sessionChanged();
      notifyListeners();
    }
  }

  /// Closes [t]. The text of a SQL editor not written to its file (a draft
  /// with some text, unsaved changes of a script) goes to "Chiuse di
  /// recente" unless [keepText] is false.
  void closeTab(EditorTab t, {bool keepText = true}) {
    final i = tabs.indexOf(t);
    if (i < 0) return;
    if (t is SqlEditorTab) _releaseSql(t, keep: keepText);
    tabs.removeAt(i);
    t.removeListener(notifyListeners);
    t.dispose();
    if (activeTab >= tabs.length) activeTab = tabs.length - 1;
    if (activeTab > i) activeTab--;
    _sessionChanged();
    notifyListeners();
  }

  void closeOtherTabs(EditorTab keep) {
    for (final t in tabs.where((e) => e != keep).toList()) {
      closeTab(t);
    }
    activate(keep);
  }

  void moveTab(int from, int to) {
    if (from == to) return;
    final t = tabs.removeAt(from);
    tabs.insert(to.clamp(0, tabs.length), t);
    activeTab = tabs.indexOf(t);
    _sessionChanged();
    notifyListeners();
  }

  /// Opens a new SQL editor: a draft (no file until the user saves it),
  /// proposed in the library [folder] when saved. With [file] it opens that
  /// script instead (see [openScript]).
  Future<SqlEditorTab> openSqlEditor(
    DbConnection? c, {
    String initialSql = '',
    File? file,
    String? catalog,
    String? folder,
  }) async {
    if (file != null) return openScript(file, connection: c, catalog: catalog);
    final tab = SqlEditorTab(
      settings: settings,
      connection: c,
      catalog: catalog,
      initialText: initialSql,
      draftName: scriptSession.newDraftName(),
      suggestedFolder: folder,
    );
    _attachSql(tab);
    _open(tab);
    if (initialSql.isNotEmpty) await _writeBuffer(tab);
    return tab;
  }

  /// Opens the script [file], or activates its editor. Without [connection]
  /// it uses the connection and database last used with the script, the
  /// active connection otherwise.
  Future<SqlEditorTab> openScript(File file, {DbConnection? connection, String? catalog}) async {
    final open = sqlTabOf(file);
    if (open != null) {
      activate(open);
      return open;
    }
    final text = await file.exists() ? await file.readAsString() : '';
    final key = scriptKey(file);
    var c = connection;
    var cat = catalog;
    final b = scriptSession.bindings[key];
    if (c == null) {
      final bound = b?.connection == null ? null : byId(b!.connection!);
      if (bound != null) {
        c = bound;
        cat = b!.catalog;
      } else {
        c = activeConnection;
      }
    }
    final tab = SqlEditorTab(
      settings: settings,
      connection: c,
      catalog: cat,
      file: file,
      initialText: text,
      variables: [...?b?.variables.map((v) => v.copy())],
    );
    _attachSql(tab);
    scriptSession.touchRecent(key);
    _open(tab);
    return tab;
  }

  /// Opens a SQL editor bound to [c] and [catalog] (re-uses the most recent
  /// one when [reuse] is true) and appends [sql].
  Future<SqlEditorTab> sqlEditorWith(DbConnection c, String sql, {bool reuse = false, String? catalog}) async {
    if (reuse) {
      for (final t in tabs.reversed) {
        if (t is SqlEditorTab && t.connection == c && (catalog == null || t.catalog == catalog)) {
          final cur = t.controller.text;
          t.controller.text = cur.trim().isEmpty ? sql : '$cur\n\n$sql';
          activate(t);
          return t;
        }
      }
    }
    return openSqlEditor(c, initialSql: sql, catalog: catalog);
  }

  void openTable(DbConnection c, DbTable table, {int page = 0}) {
    for (final t in tabs) {
      if (t is TableEditorTab && t.connection == c && t.table == table) {
        t.initialPage = page;
        activate(t);
        t.refresh();
        return;
      }
    }
    _open(TableEditorTab(c, table, initialPage: page));
  }

  /// Opens the designer of a new table in [catalog].[schema].
  void openNewTable(DbConnection c, {String? catalog, String? schema, TableDesign? template}) =>
      _open(TableEditorTab.create(c, catalog: catalog, schema: schema, template: template));

  /// Opens the editor of a new view (from [definition] when given).
  void openNewView(DbConnection c, {String? catalog, String? schema, String? definition}) =>
      _open(TableEditorTab.createView(c, catalog: catalog, schema: schema, definition: definition));

  void openProcedure(DbConnection c, DbProcedure p) {
    for (final t in tabs) {
      if (t is ProcedureEditorTab && t.connection == c && t.procedure.key == p.key) {
        activate(t);
        return;
      }
    }
    _open(ProcedureEditorTab(c, p));
  }

  void openErDiagram(DbConnection c, String? catalog, String? schema, {DbTable? focus}) {
    _open(ErDiagramTab(c, catalog, schema, focus: focus));
  }

  /// Opens a feature editor, or activates an existing one matching [match].
  T openFeatureTab<T extends FeatureTab>(T tab, {bool Function(T existing)? match}) {
    if (match != null) {
      for (final t in tabs) {
        if (t is T && match(t)) {
          tab.dispose();
          activate(t);
          return t;
        }
      }
    }
    _open(tab);
    return tab;
  }

  void openConnectionInfo(DbConnection c) {
    for (final t in tabs) {
      if (t is ConnectionInfoTab && t.connection == c) {
        activate(t);
        return;
      }
    }
    _open(ConnectionInfoTab(c));
  }

  // -------------------------------------------------------------------------
  // Scripts: drafts, buffers, session (see script_session.dart)
  // -------------------------------------------------------------------------

  /// Bumped when scripts may have changed on disk (refreshes the panel).
  int scriptsRevision = 0;

  /// Key of [file] in the script session: its library path, or its
  /// absolute path outside the library.
  String scriptKey(File file) => library.relOf(file.path) ?? p.normalize(p.absolute(file.path));

  /// The file of a session key.
  File scriptFile(String key) => p.isAbsolute(key) ? File(key) : library.fileOf(key);

  /// The editor of [file], if open.
  SqlEditorTab? sqlTabOf(File file) {
    final path = p.normalize(p.absolute(file.path));
    for (final t in tabs) {
      if (t is SqlEditorTab && t.file != null && p.normalize(p.absolute(t.file!.path)) == path) return t;
    }
    return null;
  }

  void _attachSql(SqlEditorTab t) {
    t
      ..onBuffer = _writeBuffer
      ..onSaved = _scriptSaved
      ..onBindingChanged = _bindingChanged;
    final meta = scriptSession.buffers.putIfAbsent(t.bufferId, () => BufferMeta(id: t.bufferId));
    meta
      ..name = t.draftName
      ..file = t.file?.path
      ..folder = t.suggestedFolder
      ..closedAt = null;
  }

  /// Autosave: the unsaved text goes to the buffer (never to the file).
  Future<void> _writeBuffer(SqlEditorTab t) async {
    final text = t.controller.text;
    final keep = t.isDraft ? text.isNotEmpty : t.hasUnsavedChanges;
    try {
      if (keep) {
        await scriptSession.writeBuffer(t.bufferId, text);
      } else {
        await scriptSession.deleteBuffer(t.bufferId);
      }
      t.markBuffered(text);
    } catch (_) {
      // Retried at the next change or at shutdown.
    }
  }

  void _scriptSaved(SqlEditorTab t) {
    final f = t.file;
    if (f == null) return;
    t.markBuffered(t.controller.text);
    scriptSession.deleteBufferSync(t.bufferId);
    final key = scriptKey(f);
    scriptSession.touchRecent(key);
    _bindingChanged(t);
    scriptsRevision++;
    notifyListeners();
  }

  /// The panel variables worth keeping (with a value or a type).
  static List<ScriptVariable> _variablesOf(SqlEditorTab t) => [
    for (final v in t.variables)
      if (v.value != null || v.isNull || v.type != VarType.auto || v.sqlType.isNotEmpty) v.copy(),
  ];

  void _bindingChanged(SqlEditorTab t) {
    final f = t.file;
    if (f != null) {
      scriptSession.bindings[scriptKey(f)] = ScriptBinding(
        connection: t.connection?.config.id,
        catalog: t.explicitCatalog,
        variables: _variablesOf(t),
      );
    }
    _sessionChanged();
  }

  /// A SQL editor is closing: keep its unsaved text as a closed buffer, or
  /// drop it.
  void _releaseSql(SqlEditorTab t, {required bool keep}) {
    final text = t.controller.text;
    final worth = t.isDraft ? text.trim().isNotEmpty : t.hasUnsavedChanges;
    final meta = scriptSession.buffers[t.bufferId];
    if (keep && worth && meta != null) {
      meta
        ..name = t.draftName
        ..file = t.file?.path
        ..folder = t.suggestedFolder
        ..connection = t.connection?.config.id
        ..catalog = t.explicitCatalog
        ..variables = _variablesOf(t)
        ..closedAt = DateTime.now();
      try {
        scriptSession.writeBufferSync(t.bufferId, text);
      } catch (_) {}
    } else {
      scriptSession.buffers.remove(t.bufferId);
      scriptSession.deleteBufferSync(t.bufferId);
    }
    scriptsRevision++;
  }

  /// Closed editors whose text was kept ("Chiuse di recente").
  List<BufferMeta> get closedDrafts => scriptSession.closed;

  /// Reopens a closed editor with its text.
  Future<SqlEditorTab?> reopenClosed(String id) async {
    final meta = scriptSession.buffers[id];
    if (meta == null || meta.closedAt == null) return null;
    final text = await scriptSession.readBuffer(id) ?? '';
    final f = meta.file == null ? null : File(meta.file!);
    if (f != null) {
      final open = sqlTabOf(f);
      if (open != null) {
        // The script is open again: its old changes come back as a draft.
        meta
          ..file = null
          ..name = '${meta.label} (modifiche)';
      }
    }
    final file = meta.file == null ? null : File(meta.file!);
    final saved = file != null && await file.exists() ? await file.readAsString() : '';
    final c = meta.connection == null ? null : byId(meta.connection!);
    final tab = SqlEditorTab(
      settings: settings,
      connection: c,
      catalog: c == null ? null : meta.catalog,
      file: file,
      initialText: text,
      savedText: file == null ? null : saved,
      bufferId: id,
      draftName: file == null ? meta.name : null,
      suggestedFolder: meta.folder,
      variables: [...meta.variables.map((v) => v.copy())],
    );
    _attachSql(tab);
    scriptsRevision++;
    _open(tab);
    return tab;
  }

  /// Reopens the editor closed last (⌘⇧T).
  Future<SqlEditorTab?> reopenLastClosed() async {
    final c = closedDrafts;
    return c.isEmpty ? null : reopenClosed(c.first.id);
  }

  /// Forgets a closed editor and its text.
  Future<void> discardClosed(String id) async {
    scriptSession.buffers.remove(id);
    await scriptSession.deleteBuffer(id);
    scriptsRevision++;
    _sessionChanged();
    notifyListeners();
  }

  /// Text of a closed editor (preview).
  Future<String?> closedText(String id) => scriptSession.readBuffer(id);

  /// The library script or folder [from] is now [to]: the editors, the
  /// buffers and the session follow it.
  void scriptsMoved(String from, String to) {
    for (final t in tabs.whereType<SqlEditorTab>()) {
      final r = t.file == null ? null : library.relOf(t.file!.path);
      if (r != null && isInFolder(r, from)) {
        t.file = library.fileOf(rebaseFolder(r, from, to));
        scriptSession.buffers[t.bufferId]?.file = t.file!.path;
        t.refresh();
      }
    }
    for (final b in scriptSession.buffers.values) {
      final r = b.file == null ? null : library.relOf(b.file!);
      if (r != null && isInFolder(r, from)) b.file = library.abs(rebaseFolder(r, from, to));
    }
    scriptSession.moved(from, to);
    scriptsRevision++;
    _sessionChanged();
    notifyListeners();
  }

  /// The library script or folder [path] was deleted: its editors close
  /// (without keeping their text) and the session forgets it.
  void scriptsRemoved(String path) {
    for (final t in tabs.whereType<SqlEditorTab>().toList()) {
      final r = t.file == null ? null : library.relOf(t.file!.path);
      if (r != null && isInFolder(r, path)) closeTab(t, keepText: false);
    }
    scriptSession.buffers.removeWhere((_, b) {
      final r = b.file == null ? null : library.relOf(b.file!);
      return b.closedAt != null && r != null && isInFolder(r, path);
    });
    scriptSession.removed(path);
    scriptsRevision++;
    _sessionChanged();
    notifyListeners();
  }

  /// Library changed (new script, folder, restore…): refresh the panel.
  void scriptsChanged() {
    scriptsRevision++;
    _sessionChanged();
    notifyListeners();
  }

  void toggleFavorite(String key) {
    scriptSession.toggleFavorite(key);
    _sessionChanged();
    notifyListeners();
  }

  void setScriptSort(ScriptSort s) {
    scriptSession.sort = s;
    _sessionChanged();
    notifyListeners();
  }

  /// Expands or collapses a library folder in the panel.
  void setScriptFolderExpanded(String path, bool expanded) {
    if (expanded) {
      scriptSession.expanded.add(path);
    } else {
      scriptSession.expanded.remove(path);
    }
    _sessionChanged();
    notifyListeners();
  }

  Future<void>? _sessionWrite;
  bool _sessionPending = false;

  /// Saves the session soon (writes are serialized and coalesced).
  void _sessionChanged() {
    _sessionPending = true;
    _sessionWrite ??= _flushSession();
  }

  Future<void> _flushSession() async {
    try {
      while (_sessionPending) {
        _sessionPending = false;
        _captureSession();
        await scriptSession.save();
      }
    } catch (_) {
      // Saved again at the next change or at shutdown.
    } finally {
      _sessionWrite = null;
    }
  }

  /// Copies the open SQL editors into the session.
  void _captureSession() {
    final open = <String>[];
    for (final t in tabs.whereType<SqlEditorTab>()) {
      final meta = scriptSession.buffers.putIfAbsent(t.bufferId, () => BufferMeta(id: t.bufferId));
      meta
        ..name = t.draftName
        ..file = t.file?.path
        ..folder = t.suggestedFolder
        ..connection = t.connection?.config.id
        ..catalog = t.explicitCatalog
        ..variables = _variablesOf(t)
        ..closedAt = null;
      open.add(t.bufferId);
    }
    scriptSession.open = open;
    final cur = currentTab;
    if (cur is SqlEditorTab) scriptSession.active = cur.bufferId;
    if (!open.contains(scriptSession.active)) scriptSession.active = null;
  }

  /// At startup: purges trash and old closed editors, then reopens the SQL
  /// editors of the last session (or, with "rememberTabs" off, moves their
  /// text to "Chiuse di recente").
  Future<void> _restoreScripts() async {
    final s = scriptSession;
    try {
      await library.purgeTrash();
    } catch (_) {}
    if (!settings.rememberTabs) {
      for (final id in s.open) {
        final text = await s.readBuffer(id);
        if (text != null && text.trim().isNotEmpty) s.buffers[id]?.closedAt ??= DateTime.now();
      }
      s.open = [];
    }
    try {
      await s.purge();
    } catch (_) {}
    for (final id in List.of(s.open)) {
      final meta = s.buffers[id];
      if (meta == null) continue;
      final buffer = await s.readBuffer(id);
      final file = meta.file == null ? null : File(meta.file!);
      String? saved;
      if (file != null && await file.exists()) {
        try {
          saved = await file.readAsString();
        } catch (_) {}
      }
      // A clean script deleted meanwhile: nothing to reopen.
      if (file != null && saved == null && buffer == null) {
        s.buffers.remove(id);
        continue;
      }
      if (file != null && sqlTabOf(file) != null) continue;
      final c = meta.connection == null ? null : byId(meta.connection!);
      final tab = SqlEditorTab(
        settings: settings,
        connection: c,
        catalog: c == null ? null : meta.catalog,
        file: file,
        initialText: buffer ?? saved ?? '',
        savedText: file == null ? null : (saved ?? ''),
        bufferId: id,
        draftName: file == null ? (meta.name ?? s.newDraftName()) : null,
        suggestedFolder: meta.folder,
        variables: [...meta.variables.map((v) => v.copy())],
      );
      _attachSql(tab);
      tabs.add(tab);
      tab.addListener(notifyListeners);
    }
    final i = tabs.indexWhere((t) => t is SqlEditorTab && t.bufferId == s.active);
    activeTab = i >= 0 ? i : tabs.length - 1;
    _captureSession();
    try {
      await s.save();
    } catch (_) {}
  }

  Future<void> shutdown() async {
    // The open editors come back at the next start (see _restoreScripts):
    // their unsaved text goes to the buffers, the files are left alone.
    for (final t in tabs.whereType<SqlEditorTab>()) {
      if (t.needsBuffer) await _writeBuffer(t);
    }
    _captureSession();
    await _sessionWrite;
    await scriptSession.save();
    await workspace.saveHistory(history);
    await disconnectAll();
  }
}

/// Makes [AppState] available to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
}
