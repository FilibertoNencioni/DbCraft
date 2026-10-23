import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/gestures.dart' show kDoubleTapSlop, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../cloud/ui/cloud_account_dialog.dart';
import '../cloud/ui/cloud_explorer_panel.dart';
import '../features/ai/ai.dart';
import '../features/data_compare/data_compare_tab.dart';
import '../features/design/capabilities.dart';
import '../features/design/ui/object_actions.dart' as objects;
import '../features/design/ui/security_tab.dart';
import 'navigator/nav_nodes.dart' show hasSecurity;
import '../features/design/ui/table_designer.dart';
import '../features/design/ui/view_editor.dart';
import '../features/git/git.dart';
import '../features/performance/perf_dashboard.dart';
import '../features/query_builder/query_builder_tab.dart';
import '../features/schema/schema_compare_view.dart';
import '../model/connection_config.dart';
import '../state/app_state.dart';
import '../state/db_connection.dart';
import '../state/editor_tabs.dart';
import 'actions.dart';
import 'dev/control_gallery.dart';
import 'dialogs/app_dialogs.dart';
import 'editors/misc_views.dart';
import 'editors/sql_editor_view.dart';
import 'editors/table_editor_view.dart';
import 'navigator/navigator_panel.dart';
import 'platform/window_bridge.dart';
import 'widgets/common.dart';
import 'widgets/split_view.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _leftTab = 0;
  bool _showSidebar = true;
  Duration _sidebarSlide = Duration.zero;

  bool get _mac => Platform.isMacOS;

  SingleActivator _a(LogicalKeyboardKey k, {bool shift = false, bool alt = false}) =>
      SingleActivator(k, control: !_mac, meta: _mac, shift: shift, alt: alt);

  SqlEditorTab? _sqlTab(AppState app) => app.currentTab is SqlEditorTab ? app.currentTab as SqlEditorTab : null;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = DbColors.of(context);
    final body = CallbackShortcuts(
      bindings: {
        _a(LogicalKeyboardKey.keyN): () => openSqlEditor(context),
        _a(LogicalKeyboardKey.bracketRight): () => openSqlEditor(context),
        _a(LogicalKeyboardKey.keyN, shift: true): () => newConnection(context),
        _a(LogicalKeyboardKey.keyO): () => openScriptFile(context),
        _a(LogicalKeyboardKey.keyW): () {
          final t = app.currentTab;
          if (t != null) _closeTab(t);
        },
        _a(LogicalKeyboardKey.digit0): _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () => _cycleTab(app, 1),
        const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => _cycleTab(app, -1),
        _a(LogicalKeyboardKey.keyH, shift: true): () => showHistoryDialog(context),
        _a(LogicalKeyboardKey.comma): () => showSettingsDialog(context),
        const SingleActivator(LogicalKeyboardKey.f4): () {
          final dc = app.selectedConnection;
          if (dc != null) editConnection(context, dc);
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: c.content,
          body: Column(children: [
            if (!_mac) _windowsMenuBar(app),
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: WindowBridge.instance.fullScreen,
                builder: (context, fullScreen, _) => _shell(app, trafficLightInset(fullScreen)),
              ),
            ),
          ]),
        ),
      ),
    );
    return _mac ? PlatformMenuBar(menus: _macMenus(app), child: body) : body;
  }

  /// Height of the title-bar bands (the sidebar's and the content toolbar).
  double get _barHeight => _mac ? BarHeight.toolbar : 44;

  /// Full-height sidebar beside the content column (toolbar, tabs, editor,
  /// status bar). The sidebar toggle stays put right of the traffic lights,
  /// over the sidebar band or, with the sidebar hidden, over the toolbar,
  /// which then makes room for both.
  Widget _shell(AppState app, double inset) {
    final toggleLeft = inset + Gap.sm;
    return Stack(children: [
      SplitView(
        initialFraction: 0.21,
        minFirst: 220,
        minSecond: 480,
        collapsedFirst: !_showSidebar,
        collapseDuration: _sidebarSlide,
        first: _sidebar(app),
        second: Column(children: [
          _AppToolbar(
            height: _barHeight,
            leadingInset: _showSidebar ? Gap.sm : toggleLeft + ControlSize.toolbar + Gap.md,
            slide: _sidebarSlide,
            onToggleAutoCommit: _toggleAutoCommit,
          ),
          Expanded(child: _editorArea(app)),
          _statusBar(app),
        ]),
      ),
      Positioned(
        left: toggleLeft,
        top: 0,
        height: _barHeight,
        child: Center(
          child: ToolButton(
            icon: AppIcons.sidebar,
            tooltip: '${_showSidebar ? 'Nascondi' : 'Mostra'} barra laterale '
                '(${shortcutLabel(_a(LogicalKeyboardKey.digit0))})',
            extent: ControlSize.toolbar,
            onPressed: () => _toggleSidebar(animate: true),
          ),
        ),
      ),
    ]);
  }

  /// Pointer toggles slide the sidebar; keyboard and menu toggles cut instantly.
  void _toggleSidebar({bool animate = false}) => setState(() {
        _showSidebar = !_showSidebar;
        _sidebarSlide = animate ? const Duration(milliseconds: 200) : Duration.zero;
      });

  void _cycleTab(AppState app, int delta) {
    if (app.tabs.isEmpty) return;
    final n = app.tabs.length;
    app.activate(app.tabs[(app.activeTab + delta + n) % n]);
  }

  // -------------------------------------------------------------------------
  // Menus: native on macOS, in-window bar on Windows / Linux
  // -------------------------------------------------------------------------

  List<_MenuSpec> _menuSpecs(AppState app) {
    final dc = app.activeConnection;
    final connected = dc?.isConnected ?? false;
    final sql = _sqlTab(app);
    final table = app.currentTab is TableEditorTab ? app.currentTab as TableEditorTab : null;
    VoidCallback? sqlCmd(SqlCommand cmd) => sql == null ? null : () => SqlEditorView.dispatch(sql, cmd);
    return [
      _MenuSpec('File', [
        _MenuAction('Nuovo editor SQL', () => openSqlEditor(context), _a(LogicalKeyboardKey.keyN)),
        _MenuAction('Nuova connessione…', () => newConnection(context), _a(LogicalKeyboardKey.keyN, shift: true)),
        _MenuAction('Apri script SQL…', () => openScriptFile(context), _a(LogicalKeyboardKey.keyO)),
        const _MenuDivider(),
        _MenuAction(
          table == null
              ? 'Salva script'
              : table.designDirty
              ? 'Salva struttura della tabella'
              : 'Salva modifiche ai dati',
          table != null
              ? (table.designDirty
                    ? () => table.viewDesign != null ? saveViewDesign(context, table) : saveTableDesign(context, table)
                    : (table.dataDirty ? () => _saveTableData(table) : null))
              : (sql == null ? null : () => sql.save()),
          _a(LogicalKeyboardKey.keyS),
        ),
        _MenuAction('Salva script come…', sqlCmd(SqlCommand.saveAs), _a(LogicalKeyboardKey.keyS, shift: true)),
        const _MenuDivider(),
        _MenuAction('Chiudi scheda', app.currentTab == null ? null : () => _closeTab(app.currentTab!),
            _a(LogicalKeyboardKey.keyW)),
        if (app.vault.usesMasterPassword) ...[
          const _MenuDivider(),
          _MenuAction('Blocca DbCraft', app.lockUi, _a(LogicalKeyboardKey.keyL, shift: true)),
        ],
        if (!_mac) ...[
          const _MenuDivider(),
          _MenuAction('Preferenze…', () => showSettingsDialog(context), _a(LogicalKeyboardKey.comma)),
          const _MenuDivider(),
          _MenuAction('Esci', () => SystemNavigator.pop(), null),
        ],
      ]),
      _MenuSpec('Database', [
        _MenuAction(
          connected ? 'Disconnetti' : 'Connetti',
          dc == null ? null : () => connected ? disconnectWithCheck(context, dc) : ensureConnected(context, dc),
          null,
        ),
        _MenuAction('Riconnetti', !connected ? null : () => guarded(context, () => dc!.reconnect(libPath: app.settings.libPathOrNull)), null),
        _MenuAction('Disconnetti tutto', app.connections.any((e) => e.isConnected) ? () => app.disconnectAll() : null, null),
        const _MenuDivider(),
        _MenuAction('Modifica connessione…', dc == null ? null : () => editConnection(context, dc), const SingleActivator(LogicalKeyboardKey.f4)),
        _MenuAction('Informazioni connessione', !connected ? null : () => app.openConnectionInfo(dc!), null),
        const _MenuDivider(),
        _MenuAction('Commit', !connected || dc!.autoCommit ? null : () => guarded(context, dc.commit), null),
        _MenuAction('Rollback', !connected || dc!.autoCommit ? null : () => guarded(context, dc.rollback), null),
        _MenuAction((dc?.autoCommit ?? true) ? 'Passa a commit manuale' : 'Passa ad auto-commit',
            !connected ? null : () => _toggleAutoCommit(dc!), null),
        const _MenuDivider(),
        _MenuAction('Driver ODBC installati…', () => showDriverManagerDialog(context), null),
        _MenuAction('Account cloud…', () {
          setState(() {
            _showSidebar = true;
            _leftTab = 2;
          });
          showCloudAccountDialog(context);
        }, null),
        const _MenuDivider(),
        _MenuAction(
          'Nuovo database…',
          !connected ||
                  !dc!.dialect.isSql ||
                  dc.config.readOnly ||
                  app.settings.simpleMode ||
                  !DesignCapabilities.of(dc.dialect).has(DesignFeature.createDatabase)
              ? null
              : () => objects.createDatabase(context, dc),
          null,
        ),
        _MenuAction(
          'Nuova tabella…',
          !connected || !dc!.dialect.isSql || dc.config.readOnly || app.settings.simpleMode
              ? null
              : () => app.openNewTable(dc, catalog: dc.defaultCatalog),
          null,
        ),
        _MenuAction(
          'Utenti e ruoli…',
          !connected || app.settings.simpleMode || !hasSecurity(dc!) ? null : () => openSecurity(context, dc),
          null,
        ),
        const _MenuDivider(),
        _MenuAction('Confronto schemi…', () => app.openFeatureTab(SchemaCompareTab(source: dc)), null),
        _MenuAction('Confronto dati…', () => app.openFeatureTab(DataCompareTab(source: dc)), null),
        _MenuAction(
          'Dashboard prestazioni',
          dc == null ? null : () => _openPerformance(app, dc),
          null,
        ),
      ]),
      _MenuSpec('SQL', [
        _MenuAction(
          'Query builder visuale…',
          dc == null || (connected && !dc.dialect.isSql) ? null : () => app.openFeatureTab(QueryBuilderTab(dc)),
          null,
        ),
        const _MenuDivider(),
        _MenuAction('Esegui', sqlCmd(SqlCommand.execute), _a(LogicalKeyboardKey.enter)),
        _MenuAction('Esegui istruzione corrente', sqlCmd(SqlCommand.executeCurrent), _a(LogicalKeyboardKey.enter, shift: true)),
        _MenuAction('Esegui in nuova scheda', sqlCmd(SqlCommand.executeNewTab), _a(LogicalKeyboardKey.backslash)),
        _MenuAction('Piano di esecuzione', sqlCmd(SqlCommand.explain), _a(LogicalKeyboardKey.keyE, shift: true)),
        _MenuAction('Piano visuale', sqlCmd(SqlCommand.visualPlan), _a(LogicalKeyboardKey.keyE, alt: true)),
        _MenuAction('Interrompi esecuzione', sql != null && sql.running ? () => sql.cancel() : null, _a(LogicalKeyboardKey.period)),
        const _MenuDivider(),
        _MenuAction(
          'Crea vista dalla query…',
          sql == null ||
                  sql.connection == null ||
                  !sql.connection!.dialect.isSql ||
                  sql.connection!.config.readOnly ||
                  app.settings.simpleMode
              ? null
              : () {
                  final st = sql.currentStatement();
                  if (st == null) return;
                  app.openNewView(sql.connection!, catalog: sql.catalog, definition: st.text);
                },
          null,
        ),
        const _MenuDivider(),
        _MenuAction('Formatta SQL', sqlCmd(SqlCommand.format), _a(LogicalKeyboardKey.keyF, shift: true)),
        _MenuAction('Trova e sostituisci…', sqlCmd(SqlCommand.find), _a(LogicalKeyboardKey.keyF)),
        const _MenuDivider(),
        _MenuAction('Mostra/nascondi risultati', sqlCmd(SqlCommand.toggleResults), _a(LogicalKeyboardKey.keyR, shift: true)),
        if (app.settings.aiEnabled) ...[
          const _MenuDivider(),
          _MenuAction('Spiega la query con AI', sqlCmd(SqlCommand.aiExplain), null),
          _MenuAction('Correggi con AI', sqlCmd(SqlCommand.aiFix), _a(LogicalKeyboardKey.keyJ, shift: true)),
          _MenuAction('Genera SQL con AI…', sqlCmd(SqlCommand.aiGenerate), _a(LogicalKeyboardKey.keyG, shift: true)),
          _MenuAction('Chat con l\'assistente AI', () => _openAiChat(app), null),
        ],
      ]),
      _MenuSpec('Vista', [
        _MenuAction(_showSidebar ? 'Nascondi barra laterale' : 'Mostra barra laterale', _toggleSidebar, _a(LogicalKeyboardKey.digit0)),
        _MenuAction('Query Manager', () => showHistoryDialog(context), _a(LogicalKeyboardKey.keyH, shift: true)),
        _MenuAction(
          app.settings.simpleMode ? 'Vista completa (sviluppatore)' : 'Vista semplificata (analisti)',
          () {
            app.settings.simpleMode = !app.settings.simpleMode;
            app.saveSettings();
          },
          null,
        ),
        const _MenuDivider(),
        _MenuAction('Aspetto: sistema', () => _setTheme(app, ThemeMode.system), null),
        _MenuAction('Aspetto: chiaro', () => _setTheme(app, ThemeMode.light), null),
        _MenuAction('Aspetto: scuro', () => _setTheme(app, ThemeMode.dark), null),
        if (_mac) ...[
          const _MenuDivider(),
          const _MenuProvided(PlatformProvidedMenuItemType.toggleFullScreen),
        ],
      ]),
      _MenuSpec('Finestra', [
        if (_mac) ...[
          const _MenuProvided(PlatformProvidedMenuItemType.minimizeWindow),
          const _MenuProvided(PlatformProvidedMenuItemType.zoomWindow),
          const _MenuDivider(),
        ],
        _MenuAction('Scheda successiva', app.tabs.length < 2 ? null : () => _cycleTab(app, 1),
            const SingleActivator(LogicalKeyboardKey.tab, control: true)),
        _MenuAction('Scheda precedente', app.tabs.length < 2 ? null : () => _cycleTab(app, -1),
            const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true)),
        _MenuAction('Chiudi tutte le schede', app.tabs.isEmpty ? null : () => _closeAll(app), null),
        if (_mac) ...[
          const _MenuDivider(),
          const _MenuProvided(PlatformProvidedMenuItemType.arrangeWindowsInFront),
        ],
      ]),
      _MenuSpec('Aiuto', [
        _MenuAction('Scorciatoie da tastiera', _shortcutsHelp, null),
        if (!_mac) _MenuAction('Informazioni su DbCraft', _about, null),
        if (kDebugMode) ...[
          const _MenuDivider(),
          _MenuAction('Galleria controlli', () => showControlGallery(context), null),
        ],
      ]),
    ];
  }

  List<PlatformMenuItem> _macMenus(AppState app) {
    PlatformMenu toPlatform(_MenuSpec spec) {
      final groups = <List<PlatformMenuItem>>[[]];
      for (final e in spec.entries) {
        switch (e) {
          case _MenuDivider():
            groups.add([]);
          case _MenuAction a:
            groups.last.add(PlatformMenuItem(label: a.label, shortcut: a.shortcut, onSelected: a.onSelected));
          case _MenuProvided pr:
            if (PlatformProvidedMenuItem.hasMenu(pr.type)) groups.last.add(PlatformProvidedMenuItem(type: pr.type));
        }
      }
      return PlatformMenu(label: spec.label, menus: [
        for (final g in groups.where((g) => g.isNotEmpty)) PlatformMenuItemGroup(members: g),
      ]);
    }

    // Null when the platform provides none of [types] (e.g. a non-macOS target
    // in tests on a Mac host): like toPlatform, never emit an empty group.
    PlatformMenuItemGroup? provided(List<PlatformProvidedMenuItemType> types) {
      final members = [
        for (final t in types)
          if (PlatformProvidedMenuItem.hasMenu(t)) PlatformProvidedMenuItem(type: t),
      ];
      return members.isEmpty ? null : PlatformMenuItemGroup(members: members);
    }

    return [
      PlatformMenu(label: 'DbCraft', menus: [
        ?provided([PlatformProvidedMenuItemType.about]),
        PlatformMenuItemGroup(members: [
          PlatformMenuItem(
            label: 'Impostazioni…',
            shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
            onSelected: () => showSettingsDialog(context),
          ),
        ]),
        ?provided([PlatformProvidedMenuItemType.servicesSubmenu]),
        ?provided([
          PlatformProvidedMenuItemType.hide,
          PlatformProvidedMenuItemType.hideOtherApplications,
          PlatformProvidedMenuItemType.showAllApplications,
        ]),
        ?provided([PlatformProvidedMenuItemType.quit]),
      ]),
      ..._menuSpecs(app).map(toPlatform),
    ];
  }

  Widget _windowsMenuBar(AppState app) {
    final c = DbColors.of(context);
    Widget toWidget(_MenuSpec spec) => SubmenuButton(
          menuChildren: [
            for (final e in spec.entries)
              switch (e) {
                _MenuDivider() => const Divider(height: 11, indent: 5, endIndent: 5),
                _MenuAction a => MenuItemButton(onPressed: a.onSelected, shortcut: a.shortcut, child: Text(a.label)),
                _MenuProvided() => const SizedBox.shrink(),
              },
          ],
          child: Text(spec.label),
        );
    // In-window menu bar (Windows, Linux): 24pt on chrome, same tokens as MacMenu.
    return Container(
      height: 24,
      decoration: BoxDecoration(color: c.chrome, border: Border(bottom: BorderSide(color: c.separator))),
      child: Row(children: [Expanded(child: MenuBar(children: _menuSpecs(app).map(toWidget).toList()))]),
    );
  }

  Future<void> _openPerformance(AppState app, DbConnection dc) async {
    if (await ensureConnected(context, dc)) {
      app.openFeatureTab<PerformanceDashboardTab>(PerformanceDashboardTab(dc), match: (t) => t.dc == dc);
    }
  }

  Future<void> _openAiChat(AppState app) async {
    if (await ensureAiReady(context)) app.openFeatureTab(AiChatTab(app.activeConnection));
  }

  Future<void> _setTheme(AppState app, ThemeMode mode) async {
    app.settings.themeMode = mode;
    await app.saveSettings();
  }

  Future<void> _saveTableData(TableEditorTab t) async {
    final m = t.data;
    if (m == null) return;
    final ok = await guarded(context, () => m.saveChanges(), title: 'Salvataggio non riuscito');
    if (ok && mounted) showToast(context, 'Modifiche salvate');
  }

  Future<void> _toggleAutoCommit(DbConnection c) async {
    if (!c.autoCommit && c.pendingStatements > 0) {
      final ok = await confirmDialog(
        context,
        'Transazione aperta',
        'Passando ad auto-commit le ${c.pendingStatements} istruzioni in sospeso verranno confermate. Continuare?',
        ok: 'Continua',
      );
      if (!ok) return;
    }
    if (mounted) await guarded(context, () => c.setAutoCommit(!c.autoCommit));
  }

  // -------------------------------------------------------------------------
  // Sidebar
  // -------------------------------------------------------------------------

  Widget _sidebar(AppState app) {
    final c = DbColors.of(context);
    return Material(
      color: c.sidebar,
      child: Column(children: [
        // Title-bar band of the sidebar: traffic lights and the toggle sit over it.
        _TitleBarGestures(child: SizedBox(height: _barHeight, width: double.infinity)),
        SidebarTabs<int>(
          value: _leftTab,
          items: const [
            SidebarTab(0, 'Database', AppIcons.database, selectedIcon: AppIcons.databaseFill),
            SidebarTab(1, 'Script', AppIcons.document, selectedIcon: AppIcons.documentFill),
            SidebarTab(2, 'Cloud', AppIcons.cloud, selectedIcon: AppIcons.cloudFill),
            SidebarTab(3, 'Git', AppIcons.git, selectedIcon: AppIcons.gitFill),
          ],
          onChanged: (v) => setState(() => _leftTab = v),
        ),
        Expanded(
          child: IndexedStack(index: _leftTab, children: [
            const NavigatorPanel(),
            _ScriptsPanel(revision: '${app.tabs.length}:${app.scriptsRevision}'),
            const CloudExplorerPanel(),
            GitPanel(onWorkspaceChanged: app.reloadWorkspace),
          ]),
        ),
      ]),
    );
  }

  // -------------------------------------------------------------------------
  // Editors
  // -------------------------------------------------------------------------

  Future<void> _closeTab(EditorTab t) async {
    final app = AppScope.read(context);
    if (t is TableEditorTab && t.isDirty) {
      final what = t.isNew
          ? 'La tabella "${t.title}" non è ancora stata creata'
          : t.designDirty
          ? 'La struttura di "${t.title}" contiene modifiche non salvate'
          : 'I dati di "${t.title}" contengono modifiche non salvate';
      final ok = await confirmDialog(context, 'Modifiche non salvate', '$what. Chiudere comunque?',
          ok: 'Chiudi', destructive: true);
      if (!ok) return;
    }
    if (!mounted) return;
    if (t is FeatureTab && !await t.canClose(context)) return;
    if (t is SqlEditorTab && t.running) t.cancel();
    if (t is SqlEditorTab && t.isDirty) await t.save();
    app.closeTab(t);
  }

  Future<void> _closeAll(AppState app) async {
    for (final t in List.of(app.tabs)) {
      await _closeTab(t);
    }
  }

  void _tabMenu(AppState app, EditorTab t, Offset pos) => showMacMenu<void>(
        context,
        position: pos,
        entries: [
          MenuEntry('Chiudi', onSelected: () => _closeTab(t), shortcut: _a(LogicalKeyboardKey.keyW)),
          MenuEntry('Chiudi le altre', onSelected: () => app.closeOtherTabs(t), enabled: app.tabs.length > 1),
          MenuEntry('Chiudi tutte', onSelected: () => _closeAll(app)),
        ],
      );

  Widget _editorArea(AppState app) {
    if (app.tabs.isEmpty) return _Welcome(onOpenScript: () => openScriptFile(context));
    final active = app.activeTab.clamp(0, app.tabs.length - 1);
    return Column(children: [
      WindowTabBar(
        itemCount: app.tabs.length,
        itemKey: (i) => ValueKey(app.tabs[i].id),
        onReorder: app.moveTab,
        itemBuilder: (context, i) {
          final t = app.tabs[i];
          final cfg = t.connection?.config;
          return WindowTab(
            title: t.title.replaceAll(RegExp(r' <.*>$'), ''),
            active: i == active,
            icon: t.icon,
            dirty: t.isDirty,
            busy: t is SqlEditorTab && t.running,
            accessory: cfg == null || cfg.type == ConnectionType.development
                ? null
                : EnvDot(cfg.type.colorOf(DbColors.of(context)), show: true, size: 6, tooltip: '${cfg.name} · ${cfg.type.label}'),
            tooltip: t.tooltip,
            onSelect: () => app.activate(t),
            onClose: () => _closeTab(t),
            onMenu: (pos) => _tabMenu(app, t, pos),
          );
        },
        trailing: ToolButton(
          icon: AppIcons.add,
          tooltip: 'Nuovo editor SQL (${shortcutLabel(_a(LogicalKeyboardKey.keyN))})',
          onPressed: () => openSqlEditor(context),
        ),
      ),
      Expanded(
        child: IndexedStack(
          index: active,
          children: [
            for (final (i, t) in app.tabs.indexed)
              KeyedSubtree(key: ValueKey(t.id), child: HoldLayout(hold: i != active, child: _editorFor(t))),
          ],
        ),
      ),
    ]);
  }

  Widget _editorFor(EditorTab t) => switch (t) {
        SqlEditorTab s => SqlEditorView(tab: s),
        TableEditorTab s => TableEditorView(tab: s),
        ProcedureEditorTab s => ProcedureView(tab: s),
        ErDiagramTab s => ErDiagramTabView(tab: s),
        ConnectionInfoTab s => ConnectionInfoView(tab: s),
        FeatureTab f => Builder(builder: f.buildView),
        _ => const SizedBox(),
      };

  Widget _statusBar(AppState app) {
    final c = DbColors.of(context);
    final dc = app.activeConnection;
    final connectedCount = app.connections.where((e) => e.isConnected).length;
    return StatusBar(children: [
      if (dc != null) ...[
        StatusDot(dc.isConnected ? c.success : c.textTertiary, size: 7, ring: !dc.isConnected),
        const SizedBox(width: 6),
        Text(dc.config.name, style: uiText(TypeSize.caption, color: c.text, weight: FontWeight.w500)),
        const SizedBox(width: Gap.sm),
        if (dc.isConnected)
          Flexible(
            child: Text('${dc.config.type.label} · ${dc.autoCommit ? 'auto-commit' : 'commit manuale'}'
                '${dc.config.readOnly ? ' · sola lettura' : ''}'),
          ),
        if (dc.status == ConnectionStatus.connecting) const Text('Connessione in corso…'),
        if (dc.status == ConnectionStatus.error)
          Flexible(
            child: Text('Errore: ${dc.error?.split('\n').first ?? ''}',
                style: uiText(TypeSize.caption, color: c.danger)),
          ),
      ] else
        const Text('Nessuna connessione selezionata'),
      const Spacer(),
      Text('$connectedCount di ${app.connections.length} connessioni attive'),
    ]);
  }

  void _about() => showAboutPanel(
        context,
        name: 'DbCraft',
        version: '1.0.0',
        description: 'Client database universale in Flutter. La connettività è basata su ODBC '
            '(unixODBC / iODBC / Windows ODBC) tramite dart:ffi.',
      );

  void _shortcutsHelp() {
    const h = ShortcutHelp.new;
    showShortcutsSheet(context, [
      ('Generale', [
        h('Nuovo editor SQL', [_a(LogicalKeyboardKey.keyN)]),
        h('Nuova connessione', [_a(LogicalKeyboardKey.keyN, shift: true)]),
        h('Apri script', [_a(LogicalKeyboardKey.keyO)]),
        h('Chiudi scheda', [_a(LogicalKeyboardKey.keyW)]),
        h('Mostra/nascondi barra laterale', [_a(LogicalKeyboardKey.digit0)]),
        h('Query Manager', [_a(LogicalKeyboardKey.keyH, shift: true)]),
        h('Modifica connessione', [const SingleActivator(LogicalKeyboardKey.f4)]),
      ]),
      ('Editor SQL', [
        h('Esegui istruzione o selezione', [_a(LogicalKeyboardKey.enter)]),
        h('Esegui in una nuova scheda', [_a(LogicalKeyboardKey.backslash)]),
        h('Esegui script', [
          const SingleActivator(LogicalKeyboardKey.keyX, alt: true),
          const SingleActivator(LogicalKeyboardKey.f5),
        ]),
        h('Piano di esecuzione', [_a(LogicalKeyboardKey.keyE, shift: true)]),
        h('Interrompi esecuzione', [_a(LogicalKeyboardKey.period)]),
        h('Formatta SQL', [_a(LogicalKeyboardKey.keyF, shift: true)]),
        h('Commenta righe', [_a(LogicalKeyboardKey.slash)]),
        h('Trova e sostituisci', [_a(LogicalKeyboardKey.keyF)]),
      ]),
      ('Griglia dati', [
        h('Modifica cella', [
          const SingleActivator(LogicalKeyboardKey.enter),
          const SingleActivator(LogicalKeyboardKey.f2),
        ]),
        h('Editor del valore', [const SingleActivator(LogicalKeyboardKey.enter, shift: true)]),
        h('Aggiungi riga', [const SingleActivator(LogicalKeyboardKey.insert)]),
        h('Elimina riga', [const SingleActivator(LogicalKeyboardKey.delete)]),
        h('Copia', [_a(LogicalKeyboardKey.keyC)]),
        h('Copia con intestazioni', [_a(LogicalKeyboardKey.keyC, shift: true)]),
        h('Salva modifiche', [_a(LogicalKeyboardKey.keyS)]),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Menu model shared by the native and in-window menu bars
// ---------------------------------------------------------------------------

class _MenuSpec {
  const _MenuSpec(this.label, this.entries);
  final String label;
  final List<_MenuEntry> entries;
}

sealed class _MenuEntry {
  const _MenuEntry();
}

class _MenuAction extends _MenuEntry {
  const _MenuAction(this.label, this.onSelected, this.shortcut);
  final String label;
  final VoidCallback? onSelected;
  final SingleActivator? shortcut;
}

class _MenuDivider extends _MenuEntry {
  const _MenuDivider();
}

class _MenuProvided extends _MenuEntry {
  const _MenuProvided(this.type);
  final PlatformProvidedMenuItemType type;
}

// ---------------------------------------------------------------------------
// Unified toolbar (lives in the title bar on macOS)
// ---------------------------------------------------------------------------

/// Title-bar gestures: dragging moves the window, double-clicking zooms it.
///
/// The double click is detected by timing plain taps rather than with
/// `onDoubleTap`, whose recognizer holds every click for 300ms waiting for a
/// second one, delaying every toolbar button. Taps on buttons never reach here.
class _TitleBarGestures extends StatefulWidget {
  const _TitleBarGestures({required this.child});

  final Widget child;

  @override
  State<_TitleBarGestures> createState() => _TitleBarGesturesState();
}

class _TitleBarGesturesState extends State<_TitleBarGestures> {
  DateTime? _lastTap;
  Offset? _lastPos;

  void _onTapUp(TapUpDetails d) {
    final now = DateTime.now();
    final last = _lastTap;
    final isDouble = last != null &&
        now.difference(last) <= kDoubleTapTimeout &&
        (d.globalPosition - _lastPos!).distance <= kDoubleTapSlop;
    _lastTap = isDouble ? null : now;
    _lastPos = d.globalPosition;
    if (isDouble) WindowBridge.instance.titleBarDoubleClick();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => WindowBridge.instance.startDrag(),
        onTapUp: _onTapUp,
        child: widget.child,
      );
}

/// The window toolbar over the content column: creation actions on the left,
/// the active connection in the middle, transaction and history on the right.
class _AppToolbar extends StatelessWidget {
  const _AppToolbar({
    required this.height,
    required this.leadingInset,
    required this.slide,
    required this.onToggleAutoCommit,
  });

  final double height;

  /// Room on the left: the toggle and the traffic lights while the sidebar is hidden.
  final double leadingInset;

  /// Matches the sidebar slide, so the toolbar content moves with it.
  final Duration slide;
  final void Function(DbConnection) onToggleAutoCommit;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = DbColors.of(context);
    final dc = app.activeConnection;
    final connected = dc?.isConnected ?? false;
    final mac = Platform.isMacOS;
    String keys(LogicalKeyboardKey k, {bool shift = false}) =>
        shortcutLabel(SingleActivator(k, meta: mac, control: !mac, shift: shift));
    return _TitleBarGestures(
      child: AnimatedContainer(
        duration: Motion.of(context, slide),
        curve: Curves.easeOutCubic,
        height: height,
        padding: EdgeInsets.only(left: leadingInset, right: Gap.md),
        decoration: BoxDecoration(
          color: c.chrome,
          border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
        ),
        child: Row(children: [
          ToolButton(
            icon: AppIcons.addLink,
            tooltip: 'Nuova connessione (${keys(LogicalKeyboardKey.keyN, shift: true)})',
            extent: ControlSize.toolbar,
            onPressed: () => newConnection(context),
          ),
          ToolButton(
            icon: AppIcons.script,
            tooltip: 'Nuovo editor SQL (${keys(LogicalKeyboardKey.keyN)})',
            extent: ControlSize.toolbar,
            onPressed: () => openSqlEditor(context),
          ),
          // Centered between the side groups; the activity view gives way first.
          Expanded(
            child: Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: _ActiveConnection(dc: dc)),
                if (dc != null) ...[
                  const SizedBox(width: Gap.xs),
                  ToolButton(
                    icon: connected ? AppIcons.power : AppIcons.connect,
                    tooltip: connected ? 'Disconnetti' : 'Connetti',
                    color: connected ? c.success : null,
                    extent: ControlSize.toolbar,
                    onPressed: () => connected ? disconnectWithCheck(context, dc) : ensureConnected(context, dc),
                  ),
                ],
              ]),
            ),
          ),
          if (connected) ...[
            _TransactionControl(dc: dc!, onToggle: () => onToggleAutoCommit(dc)),
            const SizedBox(width: Gap.sm),
          ],
          ToolButton(
            icon: AppIcons.history,
            tooltip: 'Query Manager (${keys(LogicalKeyboardKey.keyH, shift: true)})',
            extent: ControlSize.toolbar,
            onPressed: () => showHistoryDialog(context),
          ),
          if (!mac)
            ToolButton(
              icon: AppIcons.settings,
              tooltip: 'Preferenze',
              extent: ControlSize.toolbar,
              onPressed: () => showSettingsDialog(context),
            ),
        ]),
      ),
    );
  }
}

/// The active connection as an Xcode activity view; it opens the connection
/// menu (status dot, name, environment).
class _ActiveConnection extends StatelessWidget {
  const _ActiveConnection({required this.dc});
  final DbConnection? dc;

  Future<void> _menu(BuildContext context) async {
    final app = AppScope.read(context);
    final c = DbColors.of(context);
    final x = await showMacMenu<DbConnection>(
      context,
      anchor: anchorRect(context),
      minWidth: 320,
      alignInitial: false,
      initial: dc,
      entries: [
        if (app.connections.isEmpty) const MenuEntry('Nessuna connessione configurata', enabled: false),
        for (final x in app.connections)
          MenuEntry.connection(
            name: x.config.name,
            status: x.isConnected ? c.success : c.textTertiary,
            environment: x.config.type == ConnectionType.development ? null : x.config.type.label,
            environmentColor: x.config.type.colorOf(c),
            value: x,
            checked: x == dc,
          ),
        const MenuEntry.divider(),
        MenuEntry('Nuova connessione…', onSelected: () => newConnection(context)),
      ],
    );
    if (x == null || !context.mounted) return;
    final tab = app.currentTab;
    if (tab is SqlEditorTab && !tab.running) tab.connection = x;
    app.select(x);
    await ensureConnected(context, x);
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final d = dc;
    if (d == null) {
      return ActivityView(
        title: 'Scegli una connessione',
        tooltip: 'Connessione attiva',
        minWidth: 200,
        onPressed: () => _menu(context),
      );
    }
    final (status, color) = switch (d.status) {
      ConnectionStatus.connected => (d.serverLabel.isEmpty ? 'Connesso' : d.serverLabel, null),
      ConnectionStatus.connecting => ('Connessione in corso…', null),
      ConnectionStatus.error => ('Errore di connessione', c.danger),
      ConnectionStatus.disconnected => ('Non connesso', null),
    };
    final env = d.config.type;
    return ActivityView(
      title: d.config.name,
      status: status,
      statusColor: color,
      dot: d.isConnected ? c.success : c.textTertiary,
      busy: d.status == ConnectionStatus.connecting,
      environment: env == ConnectionType.development ? null : env.label,
      environmentColor: env.colorOf(c),
      tooltip: d.config.subtitle,
      minWidth: 200,
      onPressed: () => _menu(context),
    );
  }
}

/// Auto / manual commit, then Commit and Rollback while a transaction is open.
class _TransactionControl extends StatelessWidget {
  const _TransactionControl({required this.dc, required this.onToggle});
  final DbConnection dc;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final manual = !dc.autoCommit;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Tooltip(
        message: manual
            ? 'Commit manuale: le modifiche vanno confermate con Commit'
            : 'Auto-commit: ogni istruzione è confermata subito',
        child: Segmented<bool>(
          value: manual,
          small: true,
          items: const [(false, 'Auto', null), (true, 'Manuale', null)],
          onChanged: (v) {
            if (v != manual) onToggle();
          },
        ),
      ),
      if (manual) ...[
        const SizedBox(width: Gap.sm),
        PushButton(
          label: dc.pendingStatements > 0 ? 'Commit (${dc.pendingStatements})' : 'Commit',
          size: ControlScale.small,
          tooltip: 'Conferma la transazione',
          onPressed: () => guarded(context, dc.commit),
        ),
        const SizedBox(width: 2),
        ToolButton(
          icon: AppIcons.undo,
          tooltip: 'Rollback',
          color: c.danger,
          onPressed: () => guarded(context, dc.rollback),
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Welcome
// ---------------------------------------------------------------------------

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onOpenScript});
  final VoidCallback onOpenScript;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = DbColors.of(context);
    final mac = Platform.isMacOS;
    SingleActivator key(LogicalKeyboardKey k, {bool shift = false}) =>
        SingleActivator(k, meta: mac, control: !mac, shift: shift);
    return ColoredBox(
      color: c.content,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Gap.xxl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const AppMark(),
                    const SizedBox(height: Gap.lg),
                    Text('DbCraft', style: uiText(TypeSize.display, weight: FontWeight.w700, color: c.text)),
                    const SizedBox(height: 2),
                    Text('Scegli da cosa partire',
                        style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary)),
                    const SizedBox(height: Gap.xl),
                    _WelcomeAction(
                      icon: AppIcons.addLink,
                      title: 'Nuova connessione',
                      detail: 'Driver ODBC, DSN o stringa di connessione',
                      shortcut: key(LogicalKeyboardKey.keyN, shift: true),
                      onTap: () => newConnection(context),
                    ),
                    _WelcomeAction(
                      icon: AppIcons.script,
                      title: 'Nuovo editor SQL',
                      detail: 'Scrivi ed esegui query sulla connessione attiva',
                      shortcut: key(LogicalKeyboardKey.keyN),
                      onTap: () => openSqlEditor(context),
                    ),
                    _WelcomeAction(
                      icon: AppIcons.folderOpen,
                      title: 'Apri script',
                      detail: 'Riprendi un file .sql salvato',
                      shortcut: key(LogicalKeyboardKey.keyO),
                      onTap: onOpenScript,
                    ),
                  ]),
                ),
                Container(width: 1, margin: const EdgeInsets.symmetric(horizontal: Gap.xl), color: c.separator),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const SectionLabel('Connessioni', padding: EdgeInsets.only(bottom: Gap.sm, left: Gap.sm)),
                    if (app.connections.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(Gap.sm),
                        child: Text(
                          'Le connessioni che crei compariranno qui. Servono un Driver Manager ODBC '
                          '(unixODBC su macOS e Linux) e il driver del tuo database.',
                          style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary, height: 1.45),
                        ),
                      )
                    else
                      for (final dc in app.connections.take(8)) _RecentConnection(dc: dc),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _WelcomeAction extends StatelessWidget {
  const _WelcomeAction({required this.icon, required this.title, required this.detail, required this.onTap, this.shortcut});
  final IconData icon;
  final String title;
  final String detail;
  final SingleActivator? shortcut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListRow(
        icon: icon,
        title: title,
        subtitle: detail,
        trailing: shortcut == null ? null : ShortcutText(shortcut!, size: TypeSize.small),
        onTap: onTap,
      );
}

class _RecentConnection extends StatelessWidget {
  const _RecentConnection({required this.dc});
  final DbConnection dc;

  Future<void> _open(BuildContext context) async {
    final app = AppScope.read(context);
    app.select(dc);
    if (await ensureConnected(context, dc)) {
      await app.openSqlEditor(dc);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = dc.config;
    return ListRow(
      icon: cfg.template.icon,
      title: cfg.name,
      subtitle: cfg.subtitle,
      trailing: EnvDot(cfg.type.colorOf(DbColors.of(context)), show: cfg.type != ConnectionType.development, tooltip: cfg.type.label),
      trailingOnHover: LinkButton(label: 'Apri', small: true, onPressed: () => _open(context)),
      onTap: () => _open(context),
    );
  }
}

// ---------------------------------------------------------------------------
// Scripts (workspace)
// ---------------------------------------------------------------------------

class _ScriptsPanel extends StatefulWidget {
  const _ScriptsPanel({required this.revision});

  /// Changes when scripts may have been saved, renamed or pulled: the list
  /// reloads, keeping the filter.
  final String revision;

  @override
  State<_ScriptsPanel> createState() => _ScriptsPanelState();
}

class _ScriptsPanelState extends State<_ScriptsPanel> {
  late Future<List<({File file, DateTime modified})>> _files = AppScope.read(context).workspace.listScripts();
  final _filter = TextEditingController();
  bool _collapsed = false;

  /// Row picked with the arrows; follows the active editor's file otherwise.
  String? _picked;
  String? _lastCurrent;

  /// Script being renamed in place.
  String? _renaming;

  @override
  void didUpdateWidget(_ScriptsPanel old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) _files = AppScope.read(context).workspace.listScripts();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _reload() => setState(() {
        _files = AppScope.read(context).workspace.listScripts();
      });

  Future<void> _newScript() async {
    await openSqlEditor(context);
    _reload();
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'adesso';
    if (d.inHours < 1) return '${d.inMinutes} min fa';
    if (d.inDays < 1) return '${d.inHours} h fa';
    if (d.inDays < 7) return '${d.inDays} g fa';
    return '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year}';
  }

  void _open(File f) {
    final app = AppScope.read(context);
    setState(() => _picked = null);
    for (final t in app.tabs) {
      if (t is SqlEditorTab && t.file?.path == f.path) {
        app.activate(t);
        return;
      }
    }
    app.openSqlEditor(app.activeConnection, file: f);
  }

  Future<void> _menu(File f, Offset pos) async {
    final app = AppScope.read(context);
    final v = await showMacMenu<int>(
      context,
      position: pos,
      entries: const [MenuEntry('Rinomina', value: 0), MenuEntry('Elimina', value: 1)],
    );
    if (v == null || !mounted) return;
    if (v == 0) {
      setState(() => _renaming = f.path);
      return;
    } else {
      final ok = await confirmDialog(context, 'Elimina script', 'Eliminare ${p.basename(f.path)}?',
          ok: 'Elimina', destructive: true);
      if (!ok) return;
      for (final t in List.of(app.tabs)) {
        if (t is SqlEditorTab && t.file?.path == f.path) app.closeTab(t);
      }
      if (await f.exists()) await f.delete();
    }
    _reload();
  }

  Future<void> _rename(File f, String input) async {
    final app = AppScope.read(context);
    final name = input.trim();
    setState(() => _renaming = null);
    if (name.isEmpty || name == p.basenameWithoutExtension(f.path)) return;
    final target = p.join(f.parent.path, '$name.sql');
    try {
      if (name.contains(RegExp(r'[/\\:]'))) {
        throw Exception('Il nome non può contenere / \\ o :');
      }
      // Case-only renames point at the same file on macOS and Windows.
      if (target.toLowerCase() != f.path.toLowerCase() && await File(target).exists()) {
        throw Exception('Esiste già uno script "$name"');
      }
      final renamed = await f.rename(target);
      for (final t in app.tabs) {
        if (t is SqlEditorTab && t.file?.path == f.path) {
          t.file = renamed;
          t.refresh();
        }
      }
      if (_picked == f.path) _picked = renamed.path;
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Impossibile rinominare lo script');
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final current = app.currentTab is SqlEditorTab ? (app.currentTab as SqlEditorTab).file?.path : null;
    if (current != _lastCurrent) {
      _lastCurrent = current;
      _picked = null;
    }
    return Column(children: [
      SectionLabel('Script nel workspace',
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 2),
          expanded: !_collapsed,
          onToggle: (v) => setState(() => _collapsed = !v),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            ToolButton(icon: AppIcons.add, tooltip: 'Nuovo script', onPressed: _newScript),
            ToolButton(icon: AppIcons.refresh, tooltip: 'Aggiorna', onPressed: _reload),
          ])),
      if (!_collapsed) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, 2, Gap.sm, Gap.sm),
          child: SearchField(controller: _filter, hint: 'Filtra script', onChanged: (_) => setState(() {})),
        ),
        Expanded(
          child: FutureBuilder<List<({File file, DateTime modified})>>(
            future: _files,
            builder: (context, snap) {
              final all = snap.data ?? const <({File file, DateTime modified})>[];
              if (all.isEmpty) {
                return snap.connectionState == ConnectionState.done
                    ? EmptyState(
                        icon: AppIcons.document,
                        title: 'Nessuno script',
                        message: 'Gli editor SQL vengono salvati qui automaticamente.',
                        action: PushButton(label: 'Nuovo script', onPressed: _newScript),
                      )
                    : const SizedBox.shrink();
              }
              final q = _filter.text.trim().toLowerCase();
              final files = q.isEmpty
                  ? all
                  : all.where((s) => p.basenameWithoutExtension(s.file.path).toLowerCase().contains(q)).toList();
              if (files.isEmpty) {
                return EmptyState(
                  icon: AppIcons.search,
                  title: 'Nessun risultato',
                  message: 'Nessuno script contiene "${_filter.text.trim()}".',
                );
              }
              final sel = files.indexWhere((s) => s.file.path == (_picked ?? current));
              return SourceList(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, Gap.md),
                itemCount: files.length,
                selectedIndex: sel < 0 ? null : sel,
                onSelect: (i) => setState(() => _picked = files[i].file.path),
                onActivate: (i) => _open(files[i].file),
                itemBuilder: (context, i) {
                  final f = files[i].file;
                  final open = app.tabs.any((t) => t is SqlEditorTab && t.file?.path == f.path);
                  final name = p.basename(f.path);
                  return OutlineRow(
                    icon: AppIcons.document,
                    strong: open,
                    title: p.basenameWithoutExtension(f.path),
                    titleEditor: _renaming == f.path
                        ? InlineRenameField(
                            initial: p.basenameWithoutExtension(f.path),
                            onSubmit: (v) => _rename(f, v),
                            onCancel: () => setState(() => _renaming = null),
                          )
                        : null,
                    detail: _ago(files[i].modified),
                    selected: i == sel,
                    tooltip: open ? '$name · aperto' : name,
                    onTap: () => _open(f),
                    onMenu: (pos) => _menu(f, pos),
                  );
                },
              );
            },
          ),
        ),
      ] else
        const Spacer(),
    ]);
  }
}
