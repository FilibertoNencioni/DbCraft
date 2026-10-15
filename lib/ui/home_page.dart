import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../cloud/ui/cloud_account_dialog.dart';
import '../cloud/ui/cloud_explorer_panel.dart';
import '../features/ai/ai.dart';
import '../features/data_compare/data_compare_tab.dart';
import '../features/git/git.dart';
import '../features/performance/perf_dashboard.dart';
import '../features/query_builder/query_builder_tab.dart';
import '../features/schema/schema_compare_view.dart';
import '../model/connection_config.dart';
import '../state/app_state.dart';
import '../state/db_connection.dart';
import '../state/editor_tabs.dart';
import 'actions.dart';
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
            _AppToolbar(
              showSidebar: _showSidebar,
              onToggleSidebar: () => _toggleSidebar(animate: true),
              onToggleAutoCommit: _toggleAutoCommit,
            ),
            Expanded(
              child: SplitView(
                initialFraction: 0.21,
                minFirst: 220,
                minSecond: 480,
                collapsedFirst: !_showSidebar,
                collapseDuration: _sidebarSlide,
                first: _sidebar(app),
                second: _editorArea(app),
              ),
            ),
            _statusBar(app),
          ]),
        ),
      ),
    );
    return _mac ? PlatformMenuBar(menus: _macMenus(app), child: body) : body;
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
          table != null ? 'Salva modifiche ai dati' : 'Salva script',
          table != null
              ? (table.isDirty ? () => _saveTableData(table) : null)
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
        _MenuAction('Esegui istruzione', sqlCmd(SqlCommand.execute), _a(LogicalKeyboardKey.enter)),
        _MenuAction('Esegui in nuova scheda', sqlCmd(SqlCommand.executeNewTab), _a(LogicalKeyboardKey.backslash)),
        _MenuAction('Esegui script', sqlCmd(SqlCommand.executeScript), const SingleActivator(LogicalKeyboardKey.keyX, alt: true)),
        _MenuAction('Piano di esecuzione', sqlCmd(SqlCommand.explain), _a(LogicalKeyboardKey.keyE, shift: true)),
        _MenuAction('Piano visuale', sqlCmd(SqlCommand.visualPlan), _a(LogicalKeyboardKey.keyE, alt: true)),
        _MenuAction('Interrompi esecuzione', sql != null && sql.running ? () => sql.cancel() : null, _a(LogicalKeyboardKey.period)),
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

    PlatformMenuItemGroup provided(List<PlatformProvidedMenuItemType> types) => PlatformMenuItemGroup(members: [
          for (final t in types)
            if (PlatformProvidedMenuItem.hasMenu(t)) PlatformProvidedMenuItem(type: t),
        ]);

    return [
      PlatformMenu(label: 'DbCraft', menus: [
        provided([PlatformProvidedMenuItemType.about]),
        PlatformMenuItemGroup(members: [
          PlatformMenuItem(
            label: 'Impostazioni…',
            shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
            onSelected: () => showSettingsDialog(context),
          ),
        ]),
        provided([PlatformProvidedMenuItemType.servicesSubmenu]),
        provided([
          PlatformProvidedMenuItemType.hide,
          PlatformProvidedMenuItemType.hideOtherApplications,
          PlatformProvidedMenuItemType.showAllApplications,
        ]),
        provided([PlatformProvidedMenuItemType.quit]),
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
                _MenuDivider() => const Divider(height: 9),
                _MenuAction a => MenuItemButton(onPressed: a.onSelected, shortcut: a.shortcut, child: Text(a.label)),
                _MenuProvided() => const SizedBox.shrink(),
              },
          ],
          child: Text(spec.label),
        );
    return Container(
      height: 28,
      decoration: BoxDecoration(color: c.chrome),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 2),
          child: Segmented<int>(
            value: _leftTab,
            expand: true,
            iconOnly: true,
            items: const [
              (0, 'Database', Icons.storage_rounded),
              (1, 'Script', Icons.description_outlined),
              (2, 'Cloud', Icons.cloud_outlined),
              (3, 'Git', Icons.cloud_sync_outlined),
            ],
            onChanged: (v) => setState(() => _leftTab = v),
          ),
        ),
        Expanded(
          child: IndexedStack(index: _leftTab, children: [
            const NavigatorPanel(),
            _ScriptsPanel(key: ValueKey('${app.tabs.length}:${app.scriptsRevision}')),
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
      final ok = await confirmDialog(context, 'Modifiche non salvate',
          'I dati di "${t.title}" contengono modifiche non salvate. Chiudere comunque?',
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

  Widget _editorArea(AppState app) {
    final c = DbColors.of(context);
    if (app.tabs.isEmpty) return _Welcome(onOpenScript: () => openScriptFile(context));
    return Column(children: [
      Container(
        height: 34,
        decoration: BoxDecoration(
          color: c.chrome,
          border: Border(bottom: BorderSide(color: c.separator)),
        ),
        child: Row(children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: app.tabs.length,
              onReorderItem: app.moveTab,
              proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
              itemBuilder: (context, i) => ReorderableDragStartListener(
                key: ValueKey(app.tabs[i].id),
                index: i,
                child: _EditorTabChip(
                  tab: app.tabs[i],
                  active: i == app.activeTab,
                  onSelect: () => app.activate(app.tabs[i]),
                  onClose: () => _closeTab(app.tabs[i]),
                  onCloseOthers: () => app.closeOtherTabs(app.tabs[i]),
                  onCloseAll: () => _closeAll(app),
                ),
              ),
            ),
          ),
          ToolButton(
            icon: Icons.add_rounded,
            tooltip: 'Nuovo editor SQL (${_mac ? '⌘N' : 'Ctrl+N'})',
            onPressed: () => openSqlEditor(context),
          ),
          const SizedBox(width: Gap.xs),
        ]),
      ),
      Expanded(
        child: IndexedStack(
          index: app.activeTab.clamp(0, app.tabs.length - 1),
          children: [for (final t in app.tabs) KeyedSubtree(key: ValueKey(t.id), child: _editorFor(t))],
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
    final style = TextStyle(fontSize: TypeSize.caption + 0.5, color: c.textSecondary);
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      decoration: BoxDecoration(color: c.chrome, border: Border(top: BorderSide(color: c.separator))),
      child: DefaultTextStyle(
        style: style,
        child: Row(children: [
          if (dc != null) ...[
            StatusDot(dc.isConnected ? c.success : c.textTertiary, size: 7, ring: !dc.isConnected),
            const SizedBox(width: 6),
            Text(dc.config.name, style: style.copyWith(color: c.text, fontWeight: FontWeight.w500)),
            const SizedBox(width: Gap.sm),
            if (dc.isConnected)
              Text('${dc.config.type.label} · ${dc.autoCommit ? 'auto-commit' : 'commit manuale'}'
                  '${dc.config.readOnly ? ' · sola lettura' : ''}'),
            if (dc.status == ConnectionStatus.connecting) const Text('Connessione in corso…'),
            if (dc.status == ConnectionStatus.error)
              Flexible(
                child: Text('Errore: ${dc.error?.split('\n').first ?? ''}',
                    overflow: TextOverflow.ellipsis, style: style.copyWith(color: c.danger)),
              ),
          ] else
            const Text('Nessuna connessione selezionata'),
          const Spacer(),
          Text('$connectedCount di ${app.connections.length} connessioni attive'),
        ]),
      ),
    );
  }

  void _about() => showAboutDialog(
        context: context,
        applicationName: 'DbCraft',
        applicationVersion: '1.0.0',
        applicationIcon: const _AppMark(size: 48),
        children: const [
          Text('Client database universale in Flutter. La connettività è basata su ODBC '
              '(unixODBC / iODBC / Windows ODBC) tramite dart:ffi.'),
        ],
      );

  void _shortcutsHelp() {
    final m = _mac ? '⌘' : 'Ctrl+';
    final groups = <(String, List<(String, String)>)>[
      ('Generale', [
        ('${m}N', 'Nuovo editor SQL'),
        ('$m⇧N', 'Nuova connessione'),
        ('${m}O', 'Apri script'),
        ('${m}W', 'Chiudi scheda'),
        ('${m}0', 'Mostra/nascondi barra laterale'),
        ('$m⇧H', 'Query Manager'),
        ('F4', 'Modifica connessione'),
      ]),
      ('Editor SQL', [
        ('${m}Invio', 'Esegui istruzione o selezione'),
        ('$m\\', 'Esegui in una nuova scheda'),
        ('⌥X / F5', 'Esegui script'),
        ('$m⇧E', 'Piano di esecuzione'),
        ('$m.', 'Interrompi esecuzione'),
        ('$m⇧F', 'Formatta SQL'),
        ('$m/', 'Commenta righe'),
        ('${m}F', 'Trova e sostituisci'),
      ]),
      ('Griglia dati', [
        ('Invio / F2', 'Modifica cella'),
        ('⇧Invio', 'Editor del valore'),
        ('Ins / Canc', 'Aggiungi / elimina riga'),
        ('${m}C · $m⇧C', 'Copia · con intestazioni'),
        ('${m}S', 'Salva modifiche'),
      ]),
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = DbColors.of(ctx);
        return AlertDialog(
          title: const Text('Scorciatoie da tastiera'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final (title, rows) in groups) ...[
                  SectionLabel(title, padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.xs)),
                  for (final (k, v) in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(children: [
                        Expanded(child: Text(v)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: c.chrome,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: c.separator),
                          ),
                          child: Text(k, style: monoStyle(ctx, size: 11.5, color: c.textSecondary)),
                        ),
                      ]),
                    ),
                ],
              ]),
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Chiudi'))],
        );
      },
    );
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

class _AppToolbar extends StatelessWidget {
  const _AppToolbar({required this.showSidebar, required this.onToggleSidebar, required this.onToggleAutoCommit});

  final bool showSidebar;
  final VoidCallback onToggleSidebar;
  final void Function(DbConnection) onToggleAutoCommit;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = DbColors.of(context);
    final dc = app.activeConnection;
    final connected = dc?.isConnected ?? false;
    final mac = Platform.isMacOS;
    return ValueListenableBuilder<bool>(
      valueListenable: WindowBridge.instance.fullScreen,
      builder: (context, fullScreen, _) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => WindowBridge.instance.startDrag(),
        onDoubleTap: WindowBridge.instance.titleBarDoubleClick,
        child: Container(
          height: mac ? kUnifiedToolbarHeight : 44,
          padding: EdgeInsets.only(left: trafficLightInset(fullScreen) + Gap.sm, right: Gap.md),
          decoration: BoxDecoration(color: c.chrome, border: Border(bottom: BorderSide(color: c.separator))),
          child: Row(children: [
            ToolButton(
              icon: Icons.view_sidebar_outlined,
              tooltip: '${showSidebar ? 'Nascondi' : 'Mostra'} barra laterale (${mac ? '⌘0' : 'Ctrl+0'})',
              size: 17,
              onPressed: onToggleSidebar,
            ),
            const SizedBox(width: Gap.md),
            ToolButton(
              icon: Icons.add_link_rounded,
              tooltip: 'Nuova connessione (${mac ? '⌘⇧N' : 'Ctrl+Shift+N'})',
              size: 17,
              onPressed: () => newConnection(context),
            ),
            ToolButton(
              icon: Icons.edit_note_rounded,
              tooltip: 'Nuovo editor SQL (${mac ? '⌘N' : 'Ctrl+N'})',
              size: 19,
              onPressed: () => openSqlEditor(context),
            ),
            const Spacer(),
            _ConnectionPill(dc: dc),
            const SizedBox(width: Gap.sm),
            if (dc != null)
              ToolButton(
                icon: connected ? Icons.power_settings_new_rounded : Icons.power_rounded,
                tooltip: connected ? 'Disconnetti' : 'Connetti',
                color: connected ? c.success : null,
                size: 17,
                onPressed: () => connected ? disconnectWithCheck(context, dc) : ensureConnected(context, dc),
              ),
            const Spacer(),
            if (connected) _TransactionControl(dc: dc!, onToggle: () => onToggleAutoCommit(dc)),
            const SizedBox(width: Gap.sm),
            ToolButton(
              icon: Icons.history_rounded,
              tooltip: 'Query Manager (${mac ? '⌘⇧H' : 'Ctrl+Shift+H'})',
              size: 17,
              onPressed: () => showHistoryDialog(context),
            ),
            if (!mac)
              ToolButton(
                icon: Icons.settings_outlined,
                tooltip: 'Preferenze',
                size: 17,
                onPressed: () => showSettingsDialog(context),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Xcode-like activity pill: active connection, environment and state.
class _ConnectionPill extends StatelessWidget {
  const _ConnectionPill({required this.dc});
  final DbConnection? dc;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = DbColors.of(context);
    final d = dc;
    String status;
    Color statusColor = c.textSecondary;
    if (d == null) {
      status = 'Scegli una connessione';
    } else {
      switch (d.status) {
        case ConnectionStatus.connected:
          status = d.serverLabel.isEmpty ? 'Connesso' : d.serverLabel;
        case ConnectionStatus.connecting:
          status = 'Connessione in corso…';
        case ConnectionStatus.error:
          status = 'Errore di connessione';
          statusColor = c.danger;
        case ConnectionStatus.disconnected:
          status = 'Non connesso';
      }
    }
    return PopupMenuButton<DbConnection>(
      tooltip: 'Connessione attiva',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      constraints: const BoxConstraints(minWidth: 320),
      onSelected: (x) async {
        final tab = app.currentTab;
        if (tab is SqlEditorTab && !tab.running) tab.connection = x;
        app.select(x);
        await ensureConnected(context, x);
      },
      itemBuilder: (_) => [
        if (app.connections.isEmpty)
          const PopupMenuItem(enabled: false, child: Text('Nessuna connessione configurata')),
        for (final x in app.connections)
          PopupMenuItem(
            value: x,
            height: 40,
            child: Row(children: [
              StatusDot(x.isConnected ? c.success : c.textTertiary, size: 8, ring: !x.isConnected),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Text(x.config.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                    if (x.config.type != ConnectionType.development) ...[
                      const SizedBox(width: 6),
                      Badge2(x.config.type.label, color: x.config.type.color),
                    ],
                  ]),
                  Text(x.config.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary)),
                ]),
              ),
            ]),
          ),
      ],
      child: Container(
        constraints: const BoxConstraints(minWidth: 260, maxWidth: 420),
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          color: c.hover,
          borderRadius: BorderRadius.circular(Radii.control + 1),
          border: Border.all(color: c.separator),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (d != null) ...[
            StatusDot(d.isConnected ? c.success : c.textTertiary, size: 8, ring: !d.isConnected),
            const SizedBox(width: Gap.sm),
            Flexible(
              child: Text(d.config.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.text)),
            ),
            if (d.config.type != ConnectionType.development) ...[
              const SizedBox(width: 6),
              Badge2(d.config.type.label, color: d.config.type.color),
            ],
            Text('  ·  ', style: TextStyle(color: c.textTertiary)),
          ],
          if (d?.status == ConnectionStatus.connecting) ...[
            const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(status,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: TypeSize.small, color: statusColor)),
          ),
          const SizedBox(width: 6),
          Icon(Icons.unfold_more_rounded, size: 14, color: c.textTertiary),
        ]),
      ),
    );
  }
}

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
          items: const [(false, 'Auto', null), (true, 'Manuale', null)],
          onChanged: (v) {
            if (v != manual) onToggle();
          },
        ),
      ),
      if (manual) ...[
        const SizedBox(width: Gap.xs),
        ToolButton(
          icon: Icons.check_rounded,
          tooltip: 'Commit',
          color: c.success,
          label: dc.pendingStatements > 0 ? 'Commit (${dc.pendingStatements})' : 'Commit',
          onPressed: () => guarded(context, dc.commit),
        ),
        ToolButton(
          icon: Icons.undo_rounded,
          tooltip: 'Rollback',
          color: c.danger,
          onPressed: () => guarded(context, dc.rollback),
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Editor tabs
// ---------------------------------------------------------------------------

class _EditorTabChip extends StatefulWidget {
  const _EditorTabChip({
    required this.tab,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onCloseOthers,
    required this.onCloseAll,
  });

  final EditorTab tab;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;
  final VoidCallback onCloseOthers;
  final VoidCallback onCloseAll;

  @override
  State<_EditorTabChip> createState() => _EditorTabChipState();
}

class _EditorTabChipState extends State<_EditorTabChip> {
  bool _hover = false;
  bool _closeHover = false;

  Future<void> _menu(Offset pos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final r = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(pos & const Size(1, 1), Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: 0, height: 28, child: Text('Chiudi')),
        PopupMenuItem(value: 1, height: 28, child: Text('Chiudi le altre')),
        PopupMenuItem(value: 2, height: 28, child: Text('Chiudi tutte')),
      ],
    );
    if (r == 0) widget.onClose();
    if (r == 1) widget.onCloseOthers();
    if (r == 2) widget.onCloseAll();
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final t = widget.tab;
    final env = t.connection?.config.type.color;
    final running = t is SqlEditorTab && t.running;
    Widget trailing;
    if (running) {
      trailing = const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5));
    } else if (_hover || widget.active || !t.isDirty) {
      trailing = MouseRegion(
        onEnter: (_) => setState(() => _closeHover = true),
        onExit: (_) => setState(() => _closeHover = false),
        child: GestureDetector(
          onTap: widget.onClose,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: _closeHover ? c.pressed : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              t.isDirty && !_hover ? Icons.circle : Icons.close_rounded,
              size: t.isDirty && !_hover ? 7 : 12,
              color: (_hover || widget.active) ? c.textSecondary : Colors.transparent,
            ),
          ),
        ),
      );
    } else {
      trailing = SizedBox(width: 16, child: Icon(Icons.circle, size: 7, color: c.textSecondary));
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        onTertiaryTapUp: (_) => widget.onClose(),
        onSecondaryTapDown: (d) => _menu(d.globalPosition),
        child: Tooltip(
          message: t.tooltip,
          waitDuration: const Duration(milliseconds: 900),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240, minWidth: 110),
            padding: const EdgeInsets.only(left: Gap.md, right: Gap.sm),
            decoration: BoxDecoration(
              color: widget.active ? c.content : (_hover ? c.hover : Colors.transparent),
              border: Border(
                right: BorderSide(color: c.separator),
                bottom: BorderSide(color: widget.active ? c.content : Colors.transparent, width: 1),
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(t.icon, size: 14, color: widget.active ? c.accent : c.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  t.title.replaceAll(RegExp(r' <.*>$'), ''),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TypeSize.small + 0.5,
                    fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
                    color: widget.active ? c.text : c.textSecondary,
                  ),
                ),
              ),
              if (env != null && t.connection!.config.type != ConnectionType.development) ...[
                const SizedBox(width: 6),
                EnvDot(env, show: true, size: 6, tooltip: '${t.connection!.config.name} · ${t.connection!.config.type.label}'),
              ],
              const SizedBox(width: 6),
              trailing,
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Welcome
// ---------------------------------------------------------------------------

class _AppMark extends StatelessWidget {
  const _AppMark({this.size = 64});
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.accent,
        borderRadius: BorderRadius.circular(size * 0.23),
        boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.35), blurRadius: size * 0.25, offset: Offset(0, size * 0.08))],
      ),
      child: Icon(Icons.storage_rounded, color: Colors.white, size: size * 0.52),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onOpenScript});
  final VoidCallback onOpenScript;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = DbColors.of(context);
    final mac = Platform.isMacOS;
    final m = mac ? '⌘' : 'Ctrl+';
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
                    const _AppMark(),
                    const SizedBox(height: Gap.lg),
                    Text('DbCraft', style: Theme.of(context).textTheme.displaySmall),
                    const SizedBox(height: 2),
                    Text('Client per qualsiasi database con driver ODBC',
                        style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary)),
                    const SizedBox(height: Gap.xl),
                    _WelcomeAction(
                      icon: Icons.add_link_rounded,
                      title: 'Nuova connessione',
                      detail: 'Driver ODBC, DSN o stringa di connessione',
                      shortcut: '$m⇧N',
                      onTap: () => newConnection(context),
                    ),
                    _WelcomeAction(
                      icon: Icons.edit_note_rounded,
                      title: 'Nuovo editor SQL',
                      detail: 'Scrivi ed esegui query sulla connessione attiva',
                      shortcut: '${m}N',
                      onTap: () => openSqlEditor(context),
                    ),
                    _WelcomeAction(
                      icon: Icons.folder_open_outlined,
                      title: 'Apri script',
                      detail: 'Riprendi un file .sql salvato',
                      shortcut: '${m}O',
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
                          style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary, height: 1.45),
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

class _WelcomeAction extends StatefulWidget {
  const _WelcomeAction({required this.icon, required this.title, required this.detail, required this.onTap, this.shortcut});
  final IconData icon;
  final String title;
  final String detail;
  final String? shortcut;
  final VoidCallback onTap;

  @override
  State<_WelcomeAction> createState() => _WelcomeActionState();
}

class _WelcomeActionState extends State<_WelcomeAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.sm),
          decoration: BoxDecoration(
            color: _hover ? c.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.panel),
          ),
          child: Row(children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: c.chrome, borderRadius: BorderRadius.circular(Radii.panel)),
              child: Icon(widget.icon, size: 18, color: c.accent),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title, style: const TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600)),
                Text(widget.detail, style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary)),
              ]),
            ),
            if (widget.shortcut != null)
              Text(widget.shortcut!, style: TextStyle(fontSize: TypeSize.small, color: c.textTertiary)),
          ]),
        ),
      ),
    );
  }
}

class _RecentConnection extends StatefulWidget {
  const _RecentConnection({required this.dc});
  final DbConnection dc;

  @override
  State<_RecentConnection> createState() => _RecentConnectionState();
}

class _RecentConnectionState extends State<_RecentConnection> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final cfg = widget.dc.config;
    final t = cfg.template;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () async {
          final app = AppScope.read(context);
          app.select(widget.dc);
          if (await ensureConnected(context, widget.dc)) {
            await app.openSqlEditor(widget.dc);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 7),
          decoration: BoxDecoration(
            color: _hover ? c.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.panel),
          ),
          child: Row(children: [
            Icon(t.icon, size: 18, color: c.textSecondary),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(cfg.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w500)),
                  ),
                  const SizedBox(width: 6),
                  EnvDot(cfg.type.color, show: cfg.type != ConnectionType.development, size: 6),
                ]),
                Text(cfg.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary)),
              ]),
            ),
            if (_hover) Text('Apri', style: TextStyle(fontSize: TypeSize.small, color: c.accent)),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scripts (workspace)
// ---------------------------------------------------------------------------

class _ScriptsPanel extends StatefulWidget {
  const _ScriptsPanel({super.key});
  @override
  State<_ScriptsPanel> createState() => _ScriptsPanelState();
}

class _ScriptsPanelState extends State<_ScriptsPanel> {
  late Future<List<File>> _files = AppScope.read(context).workspace.listScripts();

  void _reload() => setState(() {
        _files = AppScope.read(context).workspace.listScripts();
      });

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'adesso';
    if (d.inHours < 1) return '${d.inMinutes} min fa';
    if (d.inDays < 1) return '${d.inHours} h fa';
    if (d.inDays < 7) return '${d.inDays} g fa';
    return '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final c = DbColors.of(context);
    return Column(children: [
      SectionLabel('Script nel workspace',
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 2),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            ToolButton(
              icon: Icons.add_rounded,
              tooltip: 'Nuovo script',
              onPressed: () async {
                await openSqlEditor(context);
                _reload();
              },
            ),
            ToolButton(icon: Icons.refresh_rounded, tooltip: 'Aggiorna', onPressed: _reload),
          ])),
      Expanded(
        child: FutureBuilder<List<File>>(
          future: _files,
          builder: (context, snap) {
            final files = snap.data ?? const <File>[];
            if (files.isEmpty) {
              return const EmptyState(
                icon: Icons.description_outlined,
                title: 'Nessuno script',
                message: 'Gli editor SQL vengono salvati qui automaticamente.',
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
              itemCount: files.length,
              itemExtent: 40,
              itemBuilder: (context, i) {
                final f = files[i];
                final open = app.tabs.any((t) => t is SqlEditorTab && t.file?.path == f.path);
                return ListTile(
                  leading: Icon(Icons.description_outlined, size: 16, color: open ? c.accent : c.textSecondary),
                  minLeadingWidth: 16,
                  horizontalTitleGap: Gap.sm,
                  title: Text(p.basenameWithoutExtension(f.path), overflow: TextOverflow.ellipsis),
                  subtitle: Text(_ago(f.lastModifiedSync()), style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary)),
                  onTap: () {
                    for (final t in app.tabs) {
                      if (t is SqlEditorTab && t.file?.path == f.path) {
                        app.activate(t);
                        return;
                      }
                    }
                    app.openSqlEditor(app.activeConnection, file: f);
                  },
                  trailing: PopupMenuButton<int>(
                    iconSize: 16,
                    tooltip: 'Azioni',
                    icon: Icon(Icons.more_horiz_rounded, size: 16, color: c.textTertiary),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 0, height: 28, child: Text('Rinomina…')),
                      PopupMenuItem(value: 1, height: 28, child: Text('Elimina')),
                    ],
                    onSelected: (v) async {
                      if (v == 0) {
                        final name = await promptText(context, 'Rinomina script', initial: p.basenameWithoutExtension(f.path));
                        if (name == null || name.trim().isEmpty) return;
                        final renamed = await f.rename(p.join(f.parent.path, '${name.trim()}.sql'));
                        for (final t in app.tabs) {
                          if (t is SqlEditorTab && t.file?.path == f.path) {
                            t.file = renamed;
                            t.refresh();
                          }
                        }
                      } else {
                        if (!context.mounted) return;
                        final ok = await confirmDialog(context, 'Elimina script', 'Eliminare ${p.basename(f.path)}?',
                            ok: 'Elimina', destructive: true);
                        if (!ok) return;
                        for (final t in List.of(app.tabs)) {
                          if (t is SqlEditorTab && t.file?.path == f.path) app.closeTab(t);
                        }
                        if (await f.exists()) await f.delete();
                      }
                      _reload();
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    ]);
  }
}
