import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/ai/ai.dart';
import '../../features/data_compare/data_compare_tab.dart';
import '../../features/debugger/pg_debugger_tab.dart';
import '../../features/design/ddl_script.dart';
import '../../features/design/capabilities.dart';
import '../../features/design/catalog/design_catalog.dart';
import '../../features/design/ddl/code_ddl.dart';
import '../../features/design/ddl/object_ddl.dart';
import '../../features/design/model/object_defs.dart';
import '../../features/design/table_design.dart';
import '../../features/design/ui/constraint_dialogs.dart';
import '../../features/design/ui/design_actions.dart' as design;
import '../../features/design/ui/design_menu.dart';
import '../../features/design/ui/object_actions.dart' as objects;
import '../../features/design/ui/view_editor.dart';
import '../../features/schema/ddl_builder.dart';
import '../../features/schema/ddl_execution.dart';
import '../../features/schema/schema_model.dart';
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
  // Shown in the context menu; the bindings live in the shell and below.
  static const _refreshKey = SingleActivator(LogicalKeyboardKey.f5);
  static const _editKey = SingleActivator(LogicalKeyboardKey.f4);
  static final _newEditorKey =
      SingleActivator(LogicalKeyboardKey.bracketRight, meta: Platform.isMacOS, control: !Platform.isMacOS);
  final Map<String, NavNode> _cache = {};
  final _filter = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  NavNode? _selected;
  final Map<DbConnection, ConnectionStatus> _lastStatus = {};
  final Map<DbConnection, int> _lastGeneration = {};
  bool _collapsed = false;

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

  /// Reloads the loaded parts of the tree touched by the DDL run since the
  /// last build (see [DbConnection.schemaChanged]).
  void _syncSchemaChanges(AppState app) {
    for (final c in app.connections) {
      final seen = _lastGeneration[c];
      _lastGeneration[c] = c.schemaGeneration;
      if (seen == null || seen == c.schemaGeneration) continue;
      final root = _cache['conn:${c.config.id}'];
      if (root == null || root.children == null) continue;
      final targets = nodesForSchemaChanges(root, c.schemaChangesSince(seen));
      if (targets.isEmpty) continue;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        for (final t in targets) {
          if (mounted) await _reload(t);
        }
      });
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

  void _select(NavNode n) {
    setState(() => _selected = n);
    if (n.connection != null) AppScope.read(context).select(n.connection);
  }

  /// F5: re-reads the metadata of the connection and reloads [n].
  Future<void> _refresh(NavNode n) async {
    if (_busy(n)) return;
    // Coarse but safe: drop all cached metadata of the connection.
    n.connection?.metadata?.clearCache();
    await _reload(n);
  }

  /// Reloads the children of [n], re-expanding the nodes that were open and
  /// keeping the selection when the selected node still exists.
  Future<void> _reload(NavNode n) async {
    if (_busy(n)) return;
    final open = <String>{};
    void reset(NavNode x) {
      for (final ch in x.children ?? const <NavNode>[]) {
        if (ch.expanded) open.add(ch.key);
        reset(ch);
      }
      x.children = null;
    }

    final selected = _selected?.key;
    final wasExpanded = n.expanded;
    reset(n);
    n.expanded = false;
    if (wasExpanded) {
      await _expand(n);
      Future<void> reopen(NavNode x) async {
        for (final ch in List.of(x.children ?? const <NavNode>[])) {
          if (!open.contains(ch.key)) continue;
          await _expand(ch);
          await reopen(ch);
        }
      }

      await reopen(n);
    }
    if (!mounted) return;
    setState(() {
      if (selected != null && _selected != null && !_contains(n, _selected!)) {
        _selected = _find(n, selected) ?? (n.key == selected ? n : _selected);
      }
    });
  }

  static bool _contains(NavNode root, NavNode n) {
    for (final ch in root.children ?? const <NavNode>[]) {
      if (identical(ch, n) || _contains(ch, n)) return true;
    }
    return false;
  }

  static NavNode? _find(NavNode root, String key) {
    for (final ch in root.children ?? const <NavNode>[]) {
      if (ch.key == key) return ch;
      final f = _find(ch, key);
      if (f != null) return f;
    }
    return null;
  }

  List<_VisibleNode> _flatten(List<NavNode> roots) {
    final out = <_VisibleNode>[];
    final f = _filter.text.trim().toLowerCase();
    // Simplified view for analysts: only tables and views, no table parts.
    final simple = AppScope.read(context).settings.simpleMode;
    void walk(NavNode n, int depth) {
      if (f.isNotEmpty && n.filterable && !n.label.toLowerCase().contains(f)) return;
      if (simple &&
          n is ObjectFolderNode &&
          (n.kind == ObjectKind.system || n.kind == ObjectKind.procedures || n.kind == ObjectKind.sequences)) {
        return;
      }
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
      case ConstraintNode c when !app.settings.simpleMode && !c.connection!.config.readOnly:
        design.editConstraint(context, c.connection!, c.table, c.definition);
      case SequenceNode q when !app.settings.simpleMode:
        objects.editSequence(context, q.connection!, q.sequence);
      case TriggerNode t when !app.settings.simpleMode:
        objects.editTrigger(context, t.connection!, t.table, t.trigger);
      default:
        _toggle(n);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    _syncConnectionStates(app);
    _syncSchemaChanges(app);
    final roots = buildRoots(app.connections, _cache);
    final visible = _flatten(roots);

    final sel = visible.indexWhere((v) => v.node == _selected);
    return Column(
      children: [
        SectionLabel(
          'Connessioni',
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 2),
          expanded: !_collapsed,
          onToggle: (v) => setState(() => _collapsed = !v),
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
                tooltip: 'Aggiorna (${shortcutLabel(_refreshKey)})',
                onPressed: _selected == null ? null : () => _refresh(_selected!),
              ),
            ],
          ),
        ),
        if (!_collapsed) ...[
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
                : CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.f5): () {
                        if (_selected != null) _refresh(_selected!);
                      },
                    },
                    child: SourceList(
                      focusNode: _focus,
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, Gap.md),
                      itemCount: visible.length,
                      selectedIndex: sel < 0 ? null : sel,
                      onSelect: (i) => setState(() => _selected = visible[i].node),
                      onExpand: (i, expand) => expand ? _expand(visible[i].node) : _collapse(visible[i].node),
                      onActivate: (i) => _open(visible[i].node),
                      itemBuilder: (context, i) => _row(context, visible[i]),
                    ),
                  ),
          ),
        ] else
          const Spacer(),
      ],
    );
  }

  Widget _empty() => EmptyState(
    icon: AppIcons.database,
    title: 'Nessuna connessione',
    message: 'Aggiungi un database tramite driver ODBC, DSN o stringa di connessione.',
    action: PushButton.primary(label: 'Nuova connessione', onPressed: () => newConnection(context)),
  );

  Color _iconColor(NavNode n, DbColors c) => switch (n) {
    ConnectionNode x => x.dc.config.template.color,
    TableNode _ || ProcedureNode _ => c.accent,
    LeafNode l when l.isKey => c.keyIcon,
    ConstraintNode k when !k.enabled => c.textTertiary,
    ConstraintNode k when k.isKey => c.keyIcon,
    ConstraintNode k when k.definition is ForeignKeyDef => c.foreignKeyIcon,
    ConstraintNode _ => c.textSecondary,
    TriggerNode t when !t.trigger.enabled => c.textTertiary,
    SequenceNode _ || TriggerNode _ => c.accent,
    LeafNode _ => c.textTertiary,
    _ => c.textSecondary,
  };

  Widget _row(BuildContext context, _VisibleNode v) {
    final c = DbColors.of(context);
    final n = v.node;
    final dc = n is ConnectionNode ? n.dc : null;
    final expandable = n.expandable && !(n is TableNode && AppScope.read(context).settings.simpleMode);
    return OutlineRow(
      title: n.label,
      icon: n.icon,
      iconColor: _iconColor(n, c),
      iconBadge: dc == null
          ? null
          : dc.isConnected
          ? c.success
          : (dc.status == ConnectionStatus.error ? c.danger : null),
      depth: v.depth,
      expanded: expandable ? n.expanded : null,
      onExpand: (_) => _toggle(n),
      busy: expandable && _busy(n),
      reserveDisclosure: true,
      detail: dc == null ? n.detail : null,
      strong: (n is CatalogNode && n.current) || (dc?.isConnected ?? false),
      titleColor: n.error != null ? c.danger : null,
      accessories: [
        if (dc != null && dc.config.type != ConnectionType.development)
          EnvDot(dc.config.type.colorOf(c), show: true, tooltip: dc.config.type.label),
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
      tooltip: n.error ?? (dc?.config.subtitle ?? n.label),
      onTap: () => _select(n),
      onDoubleTap: () => _open(n),
      onMenu: (pos) {
        setState(() => _selected = n);
        _contextMenu(context, n, pos);
      },
    );
  }

  // -------------------------------------------------------------------------
  // Context menus
  // -------------------------------------------------------------------------

  MenuEntry<void> _item(String label, VoidCallback? action, {SingleActivator? shortcut}) =>
      MenuEntry(label, onSelected: action, enabled: action != null, shortcut: shortcut);

  Future<void> _contextMenu(BuildContext context, NavNode n, Offset pos) async {
    final app = AppScope.read(context);
    final items = <MenuEntry<void>>[];
    final dc = n.connection;
    void sqlWith(String sql) => app.sqlEditorWith(dc!, sql);

    final simple = app.settings.simpleMode;
    switch (n) {
      case ConnectionNode c:
        final d = c.dc;
        items.addAll([
          if (!d.isConnected) _item('Connetti', () => ensureConnected(context, d)),
          if (d.isConnected) _item('Disconnetti', () => disconnectWithCheck(context, d)),
          if (d.isConnected)
            _item(
              'Riconnetti',
              () => guarded(context, () => d.reconnect(libPath: app.settings.libPathOrNull)),
            ),
          const MenuEntry.divider(),
          _item('Nuovo editor SQL', () => openSqlEditor(context, dc: d), shortcut: _newEditorKey),
          if (d.isConnected && d.dialect.isSql)
            _item('Query builder…', () => app.openFeatureTab(QueryBuilderTab(d))),
          if (d.isConnected && !simple)
            _item(
              'Prestazioni…',
              () => app.openFeatureTab<PerformanceDashboardTab>(PerformanceDashboardTab(d), match: (t) => t.dc == d),
            ),
          _item('Informazioni connessione', d.isConnected ? () => app.openConnectionInfo(d) : null),
          if (designAvailable(d) && !simple) ...[
            const MenuEntry.divider(),
            ...connectionDesignMenu(
              context,
              d,
              schemasAtRoot: c.children?.any((x) => x is SchemaNode) ?? false,
            ),
          ],
          const MenuEntry.divider(),
          _item('Modifica connessione…', () => editConnection(context, d), shortcut: _editKey),
          _item('Duplica', () => duplicateConnection(context, d)),
          _item('Sposta su', () => app.moveConnection(d, -1)),
          _item('Sposta giù', () => app.moveConnection(d, 1)),
          _item('Elimina', () => deleteConnection(context, d)),
          const MenuEntry.divider(),
          _item('Aggiorna', d.isConnected ? () => _refresh(n) : null, shortcut: _refreshKey),
        ]);
      case CatalogNode c:
        items.addAll([
          _item(
            'Nuovo editor SQL',
            () => app.openSqlEditor(dc, catalog: c.catalog),
          ),
          _item('Imposta come predefinito', () async {
            await guarded(context, () async {
              await dc!.useCatalog(c.catalog);
              dc.defaultCatalog = c.catalog;
              dc.touch();
              if (mounted) showToast(this.context, 'Catalogo attivo: ${c.catalog}');
            });
          }),
          if (designAvailable(dc!) && !simple)
            _item(
              'Nuova tabella…',
              dc.config.readOnly ? null : () => app.openNewTable(dc, catalog: c.catalog),
            ),
          _item('Diagramma ER', () => app.openErDiagram(dc, c.catalog, null)),
          if (dc.dialect.isSql)
            _item(
              'Query builder…',
              () => app.openFeatureTab(QueryBuilderTab(dc, catalog: c.catalog)),
            ),
          if (dc.dialect.isSql && !simple)
            _item(
              'Confronta schema…',
              () => app.openFeatureTab(SchemaCompareTab(source: dc, sourceCatalog: c.catalog)),
            ),
          if (designAvailable(dc) && !simple) ...[const MenuEntry.divider(), ...databaseMenu(context, dc, c.catalog)],
          const MenuEntry.divider(),
          _item('Copia nome', () => Clipboard.setData(ClipboardData(text: c.catalog))),
          _item('Aggiorna', () => _refresh(n), shortcut: _refreshKey),
        ]);
      case SchemaNode s:
        items.addAll([
          _item('Nuovo editor SQL', () => app.openSqlEditor(dc, catalog: s.catalog)),
          if (designAvailable(dc!) && !simple)
            _item(
              'Nuova tabella…',
              dc.config.readOnly ? null : () => app.openNewTable(dc, catalog: s.catalog, schema: s.schema),
            ),
          _item('Diagramma ER', () => app.openErDiagram(dc, s.catalog, s.schema)),
          if (dc.dialect.isSql)
            _item(
              'Query builder…',
              () => app.openFeatureTab(QueryBuilderTab(dc, catalog: s.catalog, schema: s.schema)),
            ),
          if (dc.dialect.isSql && !simple)
            _item(
              'Confronta schema…',
              () => app.openFeatureTab(SchemaCompareTab(source: dc, sourceCatalog: s.catalog, sourceSchema: s.schema)),
            ),
          if (designAvailable(dc) && !simple) ...[
            const MenuEntry.divider(),
            ...schemaMenu(context, dc, s.catalog, s.schema),
          ],
          const MenuEntry.divider(),
          _item('Copia nome', () => Clipboard.setData(ClipboardData(text: s.schema))),
          _item('Aggiorna', () => _refresh(n), shortcut: _refreshKey),
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
          _item('Apri', () => app.openTable(dc, tb), shortcut: const SingleActivator(LogicalKeyboardKey.enter)),
          _item('Visualizza dati', () => app.openTable(dc, tb, page: 1)),
          if (d.isSql)
            _item(
              'Query builder…',
              () => app.openFeatureTab(QueryBuilderTab(dc, catalog: tb.catalog, schema: tb.schema, initialTable: tb)),
            ),
          _item('Leggi in editor SQL', () => sqlWith('SELECT * FROM ${d.tableName(tb)}')),
          if (d.isSql && !simple) ...[
            const MenuEntry.divider(),
            _item('Genera SELECT', () => gen((x) => '${d.selectSql(tb, x.columns)};')),
            _item('Genera INSERT', () => gen((x) => '${d.insertSql(tb, x.columns)};')),
            _item(
              'Genera UPDATE',
              () => gen((x) => '${d.updateSql(tb, x.columns, x.primaryKey?.columns ?? [])};'),
            ),
            _item(
              'Genera DELETE',
              () => gen((x) => '${d.deleteSql(tb, x.columns, x.primaryKey?.columns ?? [])};'),
            ),
            _item(
              'Genera DDL',
              tb.isView
                  ? () => guarded(context, () async {
                      final v = await DesignCatalog.of(dc)?.viewDef(tb);
                      sqlWith(v == null ? DdlBuilder(d).tableScript(await dc.metadata!.tableDetails(tb)) : viewScript(d, v));
                    })
                  : () => gen(DdlBuilder(d).tableScript),
            ),
          ],
          if (tb.isView && d.isSql && !simple) ...[
            const MenuEntry.divider(),
            _item('Modifica definizione', dc.config.readOnly ? null : () => app.openTable(dc, tb, page: 8)),
            if (_materialized(tb) && DesignCapabilities.of(d).has(DesignFeature.materializedViews))
              _item('Aggiorna i dati della vista', dc.config.readOnly ? null : () => _refreshMaterialized(dc, tb)),
          ],
          if (!tb.isView && d.isSql && !simple) ...[
            const MenuEntry.divider(),
            _item('Modifica struttura', dc.config.readOnly ? null : () => app.openTable(dc, tb, page: 2)),
            createConstraintMenu(context, dc, tb),
            _item('Duplica struttura…', dc.config.readOnly ? null : () => _duplicate(dc, tb)),
          ],
          const MenuEntry.divider(),
          _item('Esporta dati…', () => showTableExportDialog(context, dc, tb)),
          if (!tb.isView)
            _item(
              'Importa dati (CSV)…',
              dc.config.readOnly ? null : () => showImportDialog(context, dc, tb),
            ),
          _item(
            'Diagramma ER',
            () => app.openErDiagram(dc, tb.catalog, tb.schema, focus: tb),
          ),
          if (!tb.isView && d.isSql && !simple)
            _item(
              'Genera dati di test…',
              dc.config.readOnly ? null : () => showMockDataDialog(context, dc, tb),
            ),
          if (!simple)
            _item(
              'Confronta dati…',
              () => app.openFeatureTab(DataCompareTab(source: dc, sourceTable: tb)),
            ),
          _item('Conta righe', () => _countRows(dc, tb)),
          if (app.settings.aiEnabled)
            _item('Spiega con AI', () async {
              if (await ensureAiReady(context) && mounted) await showAiExplainObject(this.context, dc, tb);
            }),
          _item(
            'Copia nome qualificato',
            () => Clipboard.setData(ClipboardData(text: d.tableName(tb))),
          ),
          const MenuEntry.divider(),
          if (!tb.isView)
            _item(
              'Svuota (TRUNCATE)…',
              dc.config.readOnly
                  ? null
                  : () => _dangerous(
                      dc,
                      d.truncateSql(tb),
                      'Svuota ${tb.name}',
                      SchemaScope.object(tb.catalog, tb.schema, tb.name),
                    ),
            ),
          _item(
            'Elimina (DROP)…',
            dc.config.readOnly
                ? null
                : () => tb.isView
                      ? _dropView(dc, tb)
                      : _dangerous(dc, d.dropSql(tb), 'Elimina ${tb.name}', SchemaScope.schema(tb.catalog, tb.schema)),
          ),
          _item('Aggiorna', () => _refresh(n), shortcut: _refreshKey),
        ]);
      case SequenceNode q:
        final ro = dc!.config.readOnly || simple;
        items.addAll([
          _item('Modifica…', ro ? null : () => objects.editSequence(context, dc, q.sequence)),
          _item('Imposta valore…', ro ? null : () => objects.restartSequence(context, dc, q.sequence)),
          _item('Rinomina…', ro ? null : () => objects.renameSequence(context, dc, q.sequence)),
          _item('Copia nome', () => Clipboard.setData(ClipboardData(text: q.sequence.name))),
          const MenuEntry.divider(),
          MenuEntry('Elimina…', onSelected: ro ? null : () => objects.dropSequence(context, dc, q.sequence), enabled: !ro, destructive: true),
        ]);
      case TriggerNode t:
        final ro = dc!.config.readOnly || simple;
        final codes = CodeDdl(dc.dialect);
        items.addAll([
          _item('Modifica sorgente', simple ? null : () => objects.editTrigger(context, dc, t.table, t.trigger)),
          if (codes.canDisableTriggers)
            _item(
              t.trigger.enabled ? 'Disabilita' : 'Abilita',
              ro ? null : () => objects.setTriggerEnabled(context, dc, t.trigger, !t.trigger.enabled),
            ),
          _item('Copia nome', () => Clipboard.setData(ClipboardData(text: t.trigger.name))),
          const MenuEntry.divider(),
          MenuEntry('Elimina…', onSelected: ro ? null : () => objects.dropTrigger(context, dc, t.trigger), enabled: !ro, destructive: true),
        ]);
      case ProcedureNode p:
        items.addAll([
          _item('Apri', () => app.openProcedure(dc!, p.procedure)),
          if (designAvailable(dc!) && !simple) ...[
            _item('Modifica sorgente', () => objects.editRoutine(context, dc, p.procedure)),
            MenuEntry(
              'Elimina…',
              onSelected: dc.config.readOnly ? null : () => objects.dropRoutine(context, dc, p.procedure),
              enabled: !dc.config.readOnly,
              destructive: true,
            ),
          ],
          if (app.settings.aiEnabled)
            _item('Spiega con AI', () async {
              if (await ensureAiReady(context) && mounted) await showAiExplainProcedure(this.context, dc, p.procedure);
            }),
          if (dc.dialect.family == DbFamily.postgres)
            _item('Debug…', () => PgDebuggerTab.open(context, dc, p.procedure)),
          _item('Genera chiamata', () async {
            final params = await dc.metadata!.procedureParams(p.procedure);
            sqlWith(dc.dialect.procedureCall(p.procedure, params));
          }),
          _item('Copia nome', () => Clipboard.setData(ClipboardData(text: p.procedure.cleanName))),
        ]);
      case TablePartNode p:
        if (p.part == TablePart.triggers && designAvailable(dc!) && !simple) {
          items.addAll([
            _item('Nuovo trigger…', dc.config.readOnly ? null : () => objects.newTrigger(context, dc, p.table)),
            const MenuEntry.divider(),
          ]);
        }
        if (designAvailable(dc!) && !simple && partKinds(p.part).isNotEmpty) {
          items.addAll([createConstraintMenu(context, dc, p.table, only: partKinds(p.part)), const MenuEntry.divider()]);
        }
        items.add(_item('Aggiorna', () => _refresh(n), shortcut: _refreshKey));
      case ConstraintNode k:
        if (simple || !designAvailable(dc!)) {
          if (k.name != null) items.add(_item('Copia nome', () => Clipboard.setData(ClipboardData(text: k.name!))));
        } else {
          items.addAll(constraintMenu(context, k, refresh: () => _refreshParent(k)));
        }
      case ObjectFolderNode f:
        if (f.kind == ObjectKind.sequences && designAvailable(dc!) && !simple) {
          items.addAll([
            _item(
              'Nuova sequenza…',
              dc.config.readOnly ? null : () => objects.createSequence(context, dc, f.catalog, f.schema),
            ),
            const MenuEntry.divider(),
          ]);
        }
        if (f.kind == ObjectKind.procedures && designAvailable(dc!) && !simple && DesignCapabilities.of(dc.dialect).has(DesignFeature.routines)) {
          items.addAll([
            _item(
              'Nuova procedura…',
              dc.config.readOnly ? null : () => objects.newRoutine(context, dc, f.catalog, f.schema, RoutineKind.procedure),
            ),
            _item(
              'Nuova funzione…',
              dc.config.readOnly ? null : () => objects.newRoutine(context, dc, f.catalog, f.schema, RoutineKind.function),
            ),
            const MenuEntry.divider(),
          ]);
        }
        if (f.kind == ObjectKind.views && designAvailable(dc!) && !simple) {
          items.addAll([
            _item(
              'Nuova vista…',
              dc.config.readOnly ? null : () => app.openNewView(dc, catalog: f.catalog, schema: f.schema),
            ),
            const MenuEntry.divider(),
          ]);
        }
        if (f.kind == ObjectKind.tables && designAvailable(dc!) && !simple) {
          items.addAll([
            _item(
              'Nuova tabella…',
              dc.config.readOnly ? null : () => app.openNewTable(dc, catalog: f.catalog, schema: f.schema),
            ),
            const MenuEntry.divider(),
          ]);
        }
        items.add(_item('Aggiorna', () => _refresh(n), shortcut: _refreshKey));
      case LeafNode l:
        items.add(_item('Copia nome', () => Clipboard.setData(ClipboardData(text: l.name))));
      default:
        break;
    }
    if (items.isEmpty) return;
    await showMacMenu<void>(context, position: pos, entries: items);
  }

  Future<void> _countRows(DbConnection dc, DbTable t) async {
    await guarded(context, () async {
      final r = await dc.meta!.execute(dc.dialect.countSql(t));
      if (!mounted) return;
      showToast(context, '${t.name}: ${r.rows.first.first} righe');
    });
  }

  static bool _materialized(DbTable t) {
    final type = t.type.toUpperCase();
    return type.contains('MATERIALIZED') || type.contains('MATVIEW');
  }

  /// DROP of a view as its kind needs (DROP MATERIALIZED VIEW…).
  Future<void> _dropView(DbConnection dc, DbTable t) async {
    final v = await loadViewDef(dc, t);
    if (!mounted) return;
    final sql = v == null ? [dc.dialect.dropSql(t)] : ObjectDdl(dc.dialect).dropView(v);
    await showDdlScriptDialog(
      context,
      dc: dc,
      title: 'Elimina ${t.name}',
      script: DdlScript(
        sql,
        scope: SchemaScope.schema(t.catalog, t.schema),
        catalog: ObjectDdl(dc.dialect).scriptCatalog(t.catalog),
      ),
    );
  }

  Future<void> _refreshMaterialized(DbConnection dc, DbTable t) async {
    final v = await loadViewDef(dc, t);
    if (!mounted) return;
    await showDdlScriptDialog(
      context,
      dc: dc,
      title: 'Aggiorna ${t.name}',
      script: DdlScript(
        ObjectDdl(dc.dialect).refreshMaterializedView(v ?? ViewDef(catalog: t.catalog, schema: t.schema, name: t.name, definition: '', materialized: true)),
        scope: SchemaScope.object(t.catalog, t.schema, t.name),
      ),
    );
  }

  /// New table with the structure of [t].
  Future<void> _duplicate(DbConnection dc, DbTable t) async {
    final name = await promptText(context, 'Duplica struttura di ${t.name}', label: 'Nome della nuova tabella', initial: '${t.name}_copia');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final def = await loadDesignTable(dc, t);
    if (def == null || !mounted) return;
    AppScope.read(context).openNewTable(
      dc,
      catalog: t.catalog,
      schema: t.schema,
      template: TableDesign.copyOf(dc.dialect, def, name.trim()),
    );
  }

  /// Refreshes the node listing [n].
  Future<void> _refreshParent(NavNode n) async {
    for (final root in _cache.values) {
      final p = _parentIn(root, n);
      if (p != null) return _refresh(p);
    }
  }

  static NavNode? _parentIn(NavNode root, NavNode n) {
    for (final ch in root.children ?? const <NavNode>[]) {
      if (identical(ch, n)) return root;
      final p = _parentIn(ch, n);
      if (p != null) return p;
    }
    return null;
  }

  /// Destructive single statement: script preview, confirmation, refresh.
  Future<void> _dangerous(DbConnection dc, String sql, String title, SchemaScope scope) =>
      showDdlScriptDialog(context, dc: dc, script: DdlScript([sql], scope: scope), title: title);
}
