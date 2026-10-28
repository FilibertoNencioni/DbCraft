import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../features/design/table_design.dart';
import '../model/connection_config.dart';
import '../model/db_objects.dart';
import '../services/storage.dart';
import '../services/vault.dart';
import 'db_connection.dart';
import 'editor_tabs.dart';

/// Global application state (connections, editors, settings, history).
class AppState extends ChangeNotifier {
  AppState(this.workspace, this.vault, this.settings, List<ConnectionConfig> configs, this.history) {
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
    final state = AppState(ws, vault, settings, configs, history);
    // Passwords saved in clear text by older versions, or written in a
    // connection string, move to the vault.
    final inStrings = configs.where((c) => c.movePasswordToVault()).length;
    if (inStrings > 0 || configs.any((c) => c.password.isNotEmpty) && await ws.connectionsContainPasswords()) {
      await state._saveConnections();
    }
    return state;
  }

  final Workspace workspace;

  /// Encrypted credential store (passwords, secrets, API keys).
  final Vault vault;
  AppSettings settings;
  final List<DbConnection> connections = [];
  final List<HistoryEntry> history;
  final List<EditorTab> tabs = [];
  int activeTab = -1;

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
      if (text != t.controller.text) {
        t.controller.text = text;
        await t.save();
      }
    }
    scriptsRevision++;
    notifyListeners();
  }

  /// Bumped when scripts may have changed on disk (refreshes the panel).
  int scriptsRevision = 0;

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
      closeTab(t);
    }
    await dc.disconnect();
    connections.remove(dc);
    dc.removeListener(notifyListeners);
    await vault.removePrefix(_secretPrefix(dc.config));
    if (selectedConnection == dc) selectedConnection = null;
    await _saveConnections();
    notifyListeners();
  }

  Future<void> moveConnection(DbConnection dc, int delta) async {
    final i = connections.indexOf(dc);
    final j = (i + delta).clamp(0, connections.length - 1);
    if (i == j) return;
    connections.removeAt(i);
    connections.insert(j, dc);
    await _saveConnections();
    notifyListeners();
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
    ..addListener(notifyListeners);

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
    notifyListeners();
  }

  void activate(EditorTab t) {
    final i = tabs.indexOf(t);
    if (i >= 0) {
      activeTab = i;
      if (t.connection != null) selectedConnection = t.connection;
      notifyListeners();
    }
  }

  void closeTab(EditorTab t) {
    final i = tabs.indexOf(t);
    if (i < 0) return;
    tabs.removeAt(i);
    t.removeListener(notifyListeners);
    t.dispose();
    if (activeTab >= tabs.length) activeTab = tabs.length - 1;
    if (activeTab > i) activeTab--;
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
    notifyListeners();
  }

  Future<SqlEditorTab> openSqlEditor(DbConnection? c, {String initialSql = '', File? file, String? catalog}) async {
    final f = file ?? await workspace.newScriptFile();
    var text = initialSql;
    if (file != null && await file.exists()) text = await file.readAsString();
    if (file == null && initialSql.isNotEmpty) await f.writeAsString(initialSql);
    final tab = SqlEditorTab(
      settings: settings,
      connection: c,
      catalog: catalog,
      file: f,
      initialText: text,
    );
    _open(tab);
    return tab;
  }

  /// Opens a SQL editor bound to [c] (re-uses the most recent one when
  /// [reuse] is true) and appends [sql].
  Future<SqlEditorTab> sqlEditorWith(DbConnection c, String sql, {bool reuse = false}) async {
    if (reuse) {
      for (final t in tabs.reversed) {
        if (t is SqlEditorTab && t.connection == c) {
          final cur = t.controller.text;
          t.controller.text = cur.trim().isEmpty ? sql : '$cur\n\n$sql';
          activate(t);
          return t;
        }
      }
    }
    return openSqlEditor(c, initialSql: sql);
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

  Future<void> shutdown() async {
    for (final t in List.of(tabs)) {
      if (t is SqlEditorTab) await t.save();
    }
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
