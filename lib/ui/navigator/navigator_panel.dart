import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/ai/ai.dart';
import '../../features/data_compare/data_compare_tab.dart';
import '../../features/debugger/pg_debugger_tab.dart';
import '../../features/schema/schema_compare_view.dart';
import '../../features/mock_data/mock_data_dialog.dart';
import '../../features/performance/perf_dashboard.dart';
import '../../features/query_builder/query_builder_tab.dart';
import '../../model/connection_config.dart';
import '../../model/db_objects.dart';
import '../../services/sql_dialect.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../actions.dart';
import '../dialogs/export_dialog.dart';
import '../dialogs/import_dialog.dart';
import '../widgets/common.dart';
import 'nav_nodes.dart';

class _VisibleNode {
  _VisibleNode(this.node, this.depth);
  final NavNode node;
  final int depth;
}

/// DBeaver-like "Database Navigator".
class NavigatorPanel extends StatefulWidget {
  const NavigatorPanel({super.key});

  @override
  State<NavigatorPanel> createState() => _NavigatorPanelState();
}

class _NavigatorPanelState extends State<NavigatorPanel> {
  final Map<String, NavNode> _cache = {};
  final _filter = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  NavNode? _selected;
  final Map<DbConnection, ConnectionStatus> _lastStatus = {};
  NavNode? _lastTapNode;
  DateTime? _lastTapAt;

  @override
  void dispose() {
    _filter.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _syncConnectionStates(AppState app) {
    for (final c in app.connections) {
      final prev = _lastStatus[c];
      if (prev != c.status) {
        _lastStatus[c] = c.status;
        final node = _cache['conn:${c.config.id}'];
        if (node != null && c.status != ConnectionStatus.connected) {
          node.reset();
        }
        if (node != null && c.status == ConnectionStatus.connected && prev == ConnectionStatus.connecting) {
          // Auto expand after connect.
          _expand(node);
        }
      }
    }
  }

  /// Expands at once when the children are cached; otherwise the chevron
  /// becomes a spinner while connecting and loading, and the node ignores
  /// further toggles until it is done.
  Future<void> _expand(NavNode n) async {
    if (!n.expandable || _busy(n)) return;
    if (n.children != null && (n is! ConnectionNode || n.dc.isConnected)) {
      setState(() => n.expanded = true);
      return;
    }
    setState(() {
      n.loading = true;
      n.error = null;
    });
    try {
      if (n is ConnectionNode && !n.dc.isConnected && !await ensureConnected(context, n.dc)) return;
      n.children = await n.load();
      n.expanded = true;
    } catch (e) {
      n.error = e.toString();
      n.children = null;
    } finally {
      n.loading = false;
      if (mounted) setState(() {});
    }
  }

  /// Loading its children, or a connection still connecting.
  bool _busy(NavNode n) => n.loading || (n is ConnectionNode && n.dc.status == ConnectionStatus.connecting);

  void _collapse(NavNode n) {
    if (_busy(n)) return;
    setState(() => n.expanded = false);
  }

  void _toggle(NavNode n) => n.expanded ? _collapse(n) : _expand(n);

  /// Selects at once; a second click on the same row within the double-tap
  /// timeout opens it. `onDoubleTap` would instead hold every click on the
  /// row, chevron included, for 300ms waiting for a second one.
  void _onRowTap(NavNode n) {
    final now = DateTime.now();
    final last = _lastTapAt;
    final isDouble = n == _lastTapNode && last != null && now.difference(last) <= kDoubleTapTimeout;
    _lastTapNode = isDouble ? null : n;
    _lastTapAt = now;
    _focus.requestFocus();
    setState(() => _selected = n);
    if (n.connection != null) AppScope.read(context).select(n.connection);
    if (isDouble) _open(n);
  }

  Future<void> _refresh(NavNode n) async {
    if (_busy(n)) return;
    final c = n.connection;
    if (c != null && c.metadata != null) {
      // Coarse but safe: drop all cached metadata of the connection.
      c.metadata!.clearCache();
    }
    void resetTree(NavNode x) {
      for (final ch in x.children ?? const <NavNode>[]) {
        resetTree(ch);
      }
      x.children = null;
    }

    final wasExpanded = n.expanded;
    resetTree(n);
    n.expanded = false;
    if (wasExpanded) await _expand(n);
    setState(() {});
  }

  List<_VisibleNode> _flatten(List<NavNode> roots) {
    final out = <_VisibleNode>[];
    final f = _filter.text.trim().toLowerCase();
    // Simplified view for analysts: only tables and views, no table parts.
    final simple = AppScope.read(context).settings.simpleMode;
    void walk(NavNode n, int depth) {
      if (f.isNotEmpty && n.filterable && !n.label.toLowerCase().contains(f)) return;
      if (simple && n is ObjectFolderNode && (n.kind == ObjectKind.system || n.kind == ObjectKind.procedures)) return;
      out.add(_VisibleNode(n, depth));
      if (simple && n is TableNode) return;
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

  void _open(NavNode n) {
    final app = AppScope.read(context);
    setState(() => _selected = n);
    if (n.connection != null) app.select(n.connection);
    switch (n) {
      case TableNode t:
        app.openTable(t.connection!, t.table);
      case ProcedureNode p:
        app.openProcedure(p.connection!, p.procedure);
      default:
        _toggle(n);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    _syncConnectionStates(app);
    final roots = buildRoots(app.connections, _cache);
    final visible = _flatten(roots);

    return Column(
      children: [
        SectionLabel(
          'Connessioni',
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 2),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ToolButton(
                icon: AppIcons.add,
                tooltip: 'Nuova connessione',
                onPressed: () => newConnection(context),
              ),
              ToolButton(
                icon: AppIcons.collapseAll,
                tooltip: 'Comprimi tutto',
                onPressed: () => setState(() {
                  for (final n in _cache.values) {
                    n.expanded = false;
                  }
                }),
              ),
              ToolButton(
                icon: AppIcons.refresh,
                tooltip: 'Aggiorna (F5)',
                onPressed: _selected == null ? null : () => _refresh(_selected!),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, 2, Gap.sm, Gap.sm),
          child: SearchField(
            controller: _filter,
            hint: 'Filtra tabelle e procedure',
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: app.connections.isEmpty
              ? _empty()
              : Focus(
                  focusNode: _focus,
                  onFocusChange: (_) => setState(() {}),
                  onKeyEvent: (node, e) => _onKey(e, visible),
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: Gap.md),
                    itemCount: visible.length,
                    itemExtent: kSidebarRowHeight,
                    itemBuilder: (context, i) => _row(context, visible[i]),
                  ),
                ),
        ),
      ],
    );
  }

  KeyEventResult _onKey(KeyEvent e, List<_VisibleNode> visible) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final idx = visible.indexWhere((v) => v.node == _selected);
    void sel(int i) {
      if (i < 0 || i >= visible.length) return;
      setState(() => _selected = visible[i].node);
    }

    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        sel(idx + 1);
      case LogicalKeyboardKey.arrowUp:
        sel(idx - 1);
      case LogicalKeyboardKey.arrowRight:
        if (_selected != null) _expand(_selected!);
      case LogicalKeyboardKey.arrowLeft:
        if (_selected != null) _collapse(_selected!);
      case LogicalKeyboardKey.enter:
        if (_selected != null) _open(_selected!);
      case LogicalKeyboardKey.f5:
        if (_selected != null) _refresh(_selected!);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _empty() => EmptyState(
    icon: AppIcons.database,
    title: 'Nessuna connessione',
    message: 'Aggiungi un database tramite driver ODBC, DSN o stringa di connessione.',
    action: PrimaryButton(label: 'Nuova connessione', onPressed: () => newConnection(context)),
  );

  Color _iconColor(NavNode n, DbColors c) => switch (n) {
    ConnectionNode x => x.dc.config.template.color,
    TableNode _ || ProcedureNode _ => c.accent,
    LeafNode l when l.color == const Color(0xFFFFB300) => const Color(0xFFE8A200),
    LeafNode _ => c.textTertiary,
    _ => c.textSecondary,
  };

  Widget _row(BuildContext context, _VisibleNode v) {
    final c = DbColors.of(context);
    final n = v.node;
    final selected = n == _selected;
    final strong = selected && _focus.hasFocus;
    final dc = n is ConnectionNode ? n.dc : null;
    final fg = strong ? Colors.white : c.text;
    final fgSecondary = strong ? Colors.white.withValues(alpha: 0.8) : c.textTertiary;
    Widget leading = Icon(n.icon, size: 16, color: strong ? Colors.white : _iconColor(n, c));
    if (dc != null && (dc.isConnected || dc.status == ConnectionStatus.error)) {
      leading = Stack(
        clipBehavior: Clip.none,
        children: [
          leading,
          Positioned(
            right: -3,
            bottom: -2,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dc.isConnected ? c.success : c.danger,
                shape: BoxShape.circle,
                border: Border.all(color: strong ? c.accent : c.sidebar, width: 1.5),
              ),
            ),
          ),
        ],
      );
    }
    final isCount = n is ObjectFolderNode;
    return GestureDetector(
      onSecondaryTapDown: (d) {
        setState(() => _selected = n);
        _contextMenu(context, n, d.globalPosition);
      },
      onTap: () => _onRowTap(n),
      child: Tooltip(
        message: n.error ?? (dc?.config.subtitle ?? n.label),
        waitDuration: const Duration(milliseconds: 1000),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 1),
          decoration: BoxDecoration(
            color: selected ? (strong ? c.accent : c.selectionMuted) : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.control - 1),
          ),
          padding: EdgeInsets.only(left: 2.0 + v.depth * 14, right: Gap.sm),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: n.expandable && !(n is TableNode && AppScope.read(context).settings.simpleMode)
                    ? _busy(n)
                          ? const Padding(
                              padding: EdgeInsets.all(4),
                              child: CircularProgressIndicator(strokeWidth: 1.5),
                            )
                          : GestureDetector(
                              onTap: () => _toggle(n),
                              child: AnimatedRotation(
                                turns: n.expanded ? 0.25 : 0,
                                duration: const Duration(milliseconds: 120),
                                curve: Curves.easeOut,
                                child: Icon(AppIcons.chevronRight, size: 15, color: fgSecondary),
                              ),
                            )
                    : null,
              ),
              leading,
              const SizedBox(width: 7),
              // Label and detail take all free space so trailing marks sit flush right
              // and names only truncate when the row is actually full.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        n.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: TypeSize.body,
                          fontWeight:
                              (n is CatalogNode && n.current) || (dc?.isConnected ?? false) ? FontWeight.w600 : null,
                          color: n.error != null && !strong ? c.danger : fg,
                        ),
                      ),
                    ),
                    if (n.detail != null && !isCount && dc == null) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          n.detail!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: TypeSize.small - 0.5, color: fgSecondary),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (isCount && n.detail != null) ...[
                const SizedBox(width: 6),
                Text(
                  n.detail!,
                  style: TextStyle(fontSize: TypeSize.small - 0.5, color: fgSecondary, fontFeatures: kTabular),
                ),
              ],
              if (dc != null && dc.config.type != ConnectionType.development) ...[
                const SizedBox(width: 6),
                EnvDot(dc.config.type.color, show: true, tooltip: dc.config.type.label),
              ],
              if (n.error != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(AppIcons.warning, size: 14, color: strong ? Colors.white : c.danger),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Context menus
  // -------------------------------------------------------------------------

  PopupMenuItem<VoidCallback> _item(String label, IconData icon, VoidCallback? action, {String? shortcut}) =>
      PopupMenuItem<VoidCallback>(
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
            if (shortcut != null)
              Text(
                shortcut,
                style: TextStyle(fontSize: TypeSize.caption, color: DbColors.of(context).textTertiary),
              ),
          ],
        ),
      );

  Future<void> _contextMenu(BuildContext context, NavNode n, Offset pos) async {
    final app = AppScope.read(context);
    final items = <PopupMenuEntry<VoidCallback>>[];
    final dc = n.connection;
    void sqlWith(String sql) => app.sqlEditorWith(dc!, sql);

    final simple = app.settings.simpleMode;
    switch (n) {
      case ConnectionNode c:
        final d = c.dc;
        items.addAll([
          if (!d.isConnected) _item('Connetti', AppIcons.connect, () => ensureConnected(context, d)),
          if (d.isConnected) _item('Disconnetti', AppIcons.disconnect, () => disconnectWithCheck(context, d)),
          if (d.isConnected)
            _item(
              'Riconnetti',
              AppIcons.sync,
              () => guarded(context, () => d.reconnect(libPath: app.settings.libPathOrNull)),
            ),
          const PopupMenuDivider(height: 9),
          _item('Nuovo editor SQL', AppIcons.newScript, () => openSqlEditor(context, dc: d), shortcut: 'Ctrl+]'),
          if (d.isConnected && d.dialect.isSql)
            _item('Query builder…', AppIcons.join, () => app.openFeatureTab(QueryBuilderTab(d))),
          if (d.isConnected && !simple)
            _item(
              'Prestazioni…',
              AppIcons.performance,
              () => app.openFeatureTab<PerformanceDashboardTab>(PerformanceDashboardTab(d), match: (t) => t.dc == d),
            ),
          _item('Informazioni connessione', AppIcons.info, d.isConnected ? () => app.openConnectionInfo(d) : null),
          const PopupMenuDivider(height: 9),
          _item('Modifica connessione…', AppIcons.edit, () => editConnection(context, d), shortcut: 'F4'),
          _item('Duplica', AppIcons.copy, () => duplicateConnection(context, d)),
          _item('Sposta su', AppIcons.arrowUp, () => app.moveConnection(d, -1)),
          _item('Sposta giù', AppIcons.arrowDown, () => app.moveConnection(d, 1)),
          _item('Elimina', AppIcons.delete, () => deleteConnection(context, d)),
          const PopupMenuDivider(height: 9),
          _item('Aggiorna', AppIcons.refresh, d.isConnected ? () => _refresh(n) : null, shortcut: 'F5'),
        ]);
      case CatalogNode c:
        items.addAll([
          _item(
            'Nuovo editor SQL',
            AppIcons.newScript,
            () => app.openSqlEditor(dc, catalog: c.catalog),
          ),
          _item('Imposta come predefinito', AppIcons.check, () async {
            await guarded(context, () async {
              await dc!.useCatalog(c.catalog);
              dc.defaultCatalog = c.catalog;
              dc.touch();
              if (mounted) showToast(this.context, 'Catalogo attivo: ${c.catalog}');
            });
          }),
          _item('Diagramma ER', AppIcons.tree, () => app.openErDiagram(dc!, c.catalog, null)),
          if (dc!.dialect.isSql)
            _item(
              'Query builder…',
              AppIcons.join,
              () => app.openFeatureTab(QueryBuilderTab(dc, catalog: c.catalog)),
            ),
          if (dc.dialect.isSql && !simple)
            _item(
              'Confronta schema…',
              AppIcons.diff,
              () => app.openFeatureTab(SchemaCompareTab(source: dc, sourceCatalog: c.catalog)),
            ),
          _item('Copia nome', AppIcons.copy, () => Clipboard.setData(ClipboardData(text: c.catalog))),
          _item('Aggiorna', AppIcons.refresh, () => _refresh(n), shortcut: 'F5'),
        ]);
      case SchemaNode s:
        items.addAll([
          _item('Nuovo editor SQL', AppIcons.newScript, () => app.openSqlEditor(dc, catalog: s.catalog)),
          _item('Diagramma ER', AppIcons.tree, () => app.openErDiagram(dc!, s.catalog, s.schema)),
          if (dc!.dialect.isSql)
            _item(
              'Query builder…',
              AppIcons.join,
              () => app.openFeatureTab(QueryBuilderTab(dc, catalog: s.catalog, schema: s.schema)),
            ),
          if (dc.dialect.isSql && !simple)
            _item(
              'Confronta schema…',
              AppIcons.diff,
              () => app.openFeatureTab(SchemaCompareTab(source: dc, sourceCatalog: s.catalog, sourceSchema: s.schema)),
            ),
          _item('Copia nome', AppIcons.copy, () => Clipboard.setData(ClipboardData(text: s.schema))),
          _item('Aggiorna', AppIcons.refresh, () => _refresh(n), shortcut: 'F5'),
        ]);
      case TableNode t:
        final tb = t.table;
        final d = dc!.dialect;
        Future<void> gen(String Function(TableDetails) f) async {
          await guarded(context, () async {
            final det = await dc.metadata!.tableDetails(tb);
            sqlWith(f(det));
          });
        }

        items.addAll([
          _item('Apri', AppIcons.openExternal, () => app.openTable(dc, tb), shortcut: 'Invio'),
          _item('Visualizza dati', AppIcons.grid, () => app.openTable(dc, tb, page: 1)),
          if (d.isSql)
            _item(
              'Query builder…',
              AppIcons.join,
              () => app.openFeatureTab(QueryBuilderTab(dc, catalog: tb.catalog, schema: tb.schema, initialTable: tb)),
            ),
          _item('Leggi in editor SQL', AppIcons.runOutline, () => sqlWith('SELECT * FROM ${d.tableName(tb)}')),
          if (d.isSql && !simple) ...[
            const PopupMenuDivider(height: 9),
            _item('Genera SELECT', AppIcons.code, () => gen((x) => '${d.selectSql(tb, x.columns)};')),
            _item('Genera INSERT', AppIcons.code, () => gen((x) => '${d.insertSql(tb, x.columns)};')),
            _item(
              'Genera UPDATE',
              AppIcons.code,
              () => gen((x) => '${d.updateSql(tb, x.columns, x.primaryKey?.columns ?? [])};'),
            ),
            _item(
              'Genera DELETE',
              AppIcons.code,
              () => gen((x) => '${d.deleteSql(tb, x.columns, x.primaryKey?.columns ?? [])};'),
            ),
            _item('Genera DDL', AppIcons.document, () => gen(d.ddl)),
          ],
          const PopupMenuDivider(height: 9),
          _item('Esporta dati…', AppIcons.upload, () => showTableExportDialog(context, dc, tb)),
          if (!tb.isView)
            _item(
              'Importa dati (CSV)…',
              AppIcons.download,
              dc.config.readOnly ? null : () => showImportDialog(context, dc, tb),
            ),
          _item(
            'Diagramma ER',
            AppIcons.tree,
            () => app.openErDiagram(dc, tb.catalog, tb.schema, focus: tb),
          ),
          if (!tb.isView && d.isSql && !simple)
            _item(
              'Genera dati di test…',
              AppIcons.random,
              dc.config.readOnly ? null : () => showMockDataDialog(context, dc, tb),
            ),
          if (!simple)
            _item(
              'Confronta dati…',
              AppIcons.compare,
              () => app.openFeatureTab(DataCompareTab(source: dc, sourceTable: tb)),
            ),
          _item('Conta righe', AppIcons.number, () => _countRows(dc, tb)),
          if (app.settings.aiEnabled)
            _item('Spiega con AI', AppIcons.ai, () async {
              if (await ensureAiReady(context) && mounted) await showAiExplainObject(this.context, dc, tb);
            }),
          _item(
            'Copia nome qualificato',
            AppIcons.copy,
            () => Clipboard.setData(ClipboardData(text: d.tableName(tb))),
          ),
          const PopupMenuDivider(height: 9),
          if (!tb.isView)
            _item(
              'Svuota (TRUNCATE)…',
              AppIcons.clearAll,
              dc.config.readOnly ? null : () => _dangerous(dc, d.truncateSql(tb), n),
            ),
          _item(
            'Elimina (DROP)…',
            AppIcons.delete,
            dc.config.readOnly ? null : () => _dangerous(dc, d.dropSql(tb), n),
          ),
          _item('Aggiorna', AppIcons.refresh, () => _refresh(n), shortcut: 'F5'),
        ]);
      case ProcedureNode p:
        items.addAll([
          _item('Apri', AppIcons.openExternal, () => app.openProcedure(dc!, p.procedure)),
          if (app.settings.aiEnabled)
            _item('Spiega con AI', AppIcons.ai, () async {
              if (await ensureAiReady(context) && mounted) await showAiExplainProcedure(this.context, dc!, p.procedure);
            }),
          if (dc!.dialect.family == DbFamily.postgres)
            _item('Debug…', AppIcons.debug, () => PgDebuggerTab.open(context, dc, p.procedure)),
          _item('Genera chiamata', AppIcons.code, () async {
            final params = await dc.metadata!.procedureParams(p.procedure);
            sqlWith(dc.dialect.procedureCall(p.procedure, params));
          }),
          _item('Copia nome', AppIcons.copy, () => Clipboard.setData(ClipboardData(text: p.procedure.cleanName))),
        ]);
      case ObjectFolderNode _:
      case TablePartNode _:
        items.add(_item('Aggiorna', AppIcons.refresh, () => _refresh(n), shortcut: 'F5'));
      case LeafNode l:
        items.add(_item('Copia nome', AppIcons.copy, () => Clipboard.setData(ClipboardData(text: l.name))));
      default:
        break;
    }
    if (items.isEmpty) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(pos & const Size(1, 1), Offset.zero & overlay.size),
      items: items,
    );
    action?.call();
  }

  Future<void> _countRows(DbConnection dc, DbTable t) async {
    await guarded(context, () async {
      final r = await dc.meta!.execute(dc.dialect.countSql(t));
      if (!mounted) return;
      showToast(context, '${t.name}: ${r.rows.first.first} righe');
    });
  }

  Future<void> _dangerous(DbConnection dc, String sql, NavNode node) async {
    final ok = await confirmDialog(
      context,
      'Conferma',
      'Eseguire la seguente istruzione?\n\n$sql',
      ok: 'Esegui',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await guarded(context, () async {
      await dc.main!.execute(sql);
      dc.statementExecuted();
      if (!mounted) return;
      showToast(context, 'Eseguito: $sql');
      // Refresh the parent folder.
      for (final n in _cache.values) {
        if (n.children?.contains(node) ?? false) {
          await _refresh(n);
          break;
        }
      }
      setState(() {});
    });
  }
}
