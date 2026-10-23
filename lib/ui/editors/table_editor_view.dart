import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/query_builder/query_model.dart';
import '../../features/query_builder/visual_filter.dart';
import '../../features/design/capabilities.dart';
import '../../features/design/catalog/design_catalog.dart';
import '../../features/design/table_design.dart';
import '../../features/design/ui/constraints_page.dart';
import '../../features/design/ui/design_actions.dart';
import '../../features/design/ui/table_designer.dart';
import '../../features/schema/ddl_builder.dart';
import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../../state/editor_tabs.dart';
import '../../state/result_set_model.dart';
import '../actions.dart';
import '../dialogs/export_dialog.dart';
import '../dialogs/import_dialog.dart';
import '../results/results_viewer.dart';
import '../widgets/common.dart';
import 'er_diagram_view.dart';
import 'sql_code_editor.dart';

/// Data-tab UI state kept per editor tab (survives switching tabs).
class _DataUi {
  final VisualFilter filter = VisualFilter();
  bool visual = false;
}

final _dataUi = Expando<_DataUi>('tableDataUi');

/// Object editor for tables and views (DBeaver "entity editor").
class TableEditorView extends StatefulWidget {
  const TableEditorView({super.key, required this.tab});
  final TableEditorTab tab;

  @override
  State<TableEditorView> createState() => _TableEditorViewState();
}

class _TableEditorViewState extends State<TableEditorView> {
  late int _page = _effectivePage(widget.tab.initialPage);
  Future<TableDetails>? _details;
  late final _where = TextEditingController(text: tab.dataFilter);
  late final _order = TextEditingController(text: tab.dataOrder);
  bool _loadingData = false;
  Object? _dataError;
  int? _rowCount;
  int _lastInitialPage = -1;
  int _schemaGeneration = 0;
  String _tableKey = '';
  TableDesign? _attached;

  TableEditorTab get tab => widget.tab;
  DbTable get table => tab.table;
  TableDesign? get _design => tab.design;

  static const _pageData = 1;
  static const _pageChanges = 7;
  static const _pageNames = ['Proprietà', 'Dati', 'Colonne', 'Vincoli', 'Indici', 'DDL', 'Diagramma', 'Modifiche'];

  /// Pages of a table that does not exist yet.
  static const _newPages = [0, 2, 3, 4, 7];

  /// The structure can be edited here (the designer).
  bool get _designable {
    final c = tab.connection;
    return !table.isView &&
        c.dialect.isSql &&
        !c.config.readOnly &&
        !_simple &&
        DesignCapabilities.of(c.dialect).has(DesignFeature.createTable);
  }

  /// Columns of the table once the metadata is loaded (visual filter).
  List<DbColumn>? _columnsMeta;

  _DataUi get _ui => _dataUi[tab] ??= _DataUi();

  bool get _simple => AppScope.read(context).settings.simpleMode;

  /// In the simplified analyst view the editor opens on the data page.
  int _effectivePage(int page) {
    final app = context.getInheritedWidgetOfExactType<AppScope>()?.notifier;
    return (app?.settings.simpleMode ?? false) && page == 0 ? _pageData : page;
  }

  @override
  void initState() {
    super.initState();
    _lastInitialPage = tab.initialPage;
    tab.addListener(_onTab);
    _schemaGeneration = tab.connection.schemaGeneration;
    _tableKey = table.key;
    tab.connection.addListener(_onConnection);
    _attachDesign();
    _init();
  }

  /// Follows the design: tab title and dirty mark, toolbar, pages.
  void _attachDesign() {
    final d = _design;
    if (identical(d, _attached)) return;
    _attached?.removeListener(_onDesign);
    _attached = d;
    d?.addListener(_onDesign);
  }

  void _onDesign() {
    tab.refresh();
    if (mounted) setState(() {});
  }

  /// Reads the complete definition for the designer (or refreshes a design
  /// without pending changes).
  Future<void> _loadDesign() async {
    if (!_designable) return;
    final cat = DesignCatalog.of(tab.connection);
    if (cat == null) return;
    try {
      final def = await cat.loadTable(table);
      if (!mounted) return;
      final d = tab.design;
      if (d == null) {
        tab.design = TableDesign.existing(tab.connection.dialect, def);
        _attachDesign();
      } else if (!d.isDirty) {
        d.saved(def);
      }
      final incoming = await incomingForeignKeys(tab.connection, def);
      tab.design?.incoming = incoming;
      tab.design?.refresh();
    } catch (_) {
      // The pages stay read-only.
    }
    if (mounted) setState(() {});
  }

  void _setPage(int page) {
    if (page == _page) return;
    setState(() => _page = page);
    if (page == _pageData && tab.data == null && !_loadingData) _loadData();
  }

  void _onTab() {
    _attachDesign();
    // Created or renamed by the designer.
    if (table.key != _tableKey) {
      _tableKey = table.key;
      if (!tab.isNew) {
        setState(() {
          _details = tab.connection.metadata?.tableDetails(table);
        });
      }
    }
    if (tab.initialPage != _lastInitialPage) {
      _lastInitialPage = tab.initialPage;
      _setPage(_effectivePage(tab.initialPage));
    }
  }

  /// Reloads the structure after DDL touching this table.
  void _onConnection() {
    final c = tab.connection;
    if (c.schemaGeneration == _schemaGeneration) return;
    final changes = c.schemaChangesSince(_schemaGeneration);
    _schemaGeneration = c.schemaGeneration;
    if (!c.isConnected || c.metadata == null || _details == null) return;
    if (!changes.any((s) => s.coversObject(table.catalog, table.schema, table.name))) return;
    setState(() {
      _details = c.metadata!.tableDetails(table);
    });
    if (_design != null && !_design!.isDirty) _loadDesign();
  }

  Future<void> _init() async {
    if (tab.isNew) {
      if (_page != 0 && !_newPages.contains(_page)) _page = 0;
      return;
    }
    if (!await ensureConnected(context, tab.connection)) return;
    setState(() {
      _details = tab.connection.metadata!.tableDetails(table);
    });
    _details!.then((d) {
      if (mounted) setState(() => _columnsMeta = d.columns);
    }, onError: (_) {});
    if (_page == _pageData) _loadData();
    if (_design == null) _loadDesign();
  }

  @override
  void dispose() {
    _attached?.removeListener(_onDesign);
    tab.removeListener(_onTab);
    tab.connection.removeListener(_onConnection);
    _where.dispose();
    _order.dispose();
    super.dispose();
  }

  String get _dataSql {
    final d = tab.connection.dialect;
    final sb = StringBuffer('SELECT * FROM ${d.tableName(table)}');
    if (_where.text.trim().isNotEmpty) sb.write(' WHERE ${_where.text.trim()}');
    if (_order.text.trim().isNotEmpty) sb.write(' ORDER BY ${_order.text.trim()}');
    return sb.toString();
  }

  Future<void> _loadData() async {
    final c = tab.connection;
    if (!await ensureConnected(context, c)) return;
    if (tab.data?.isDirty ?? false) {
      if (!mounted) return;
      final ok = await confirmDialog(context, 'Modifiche non salvate', 'Scartare le modifiche ai dati?');
      if (!ok) return;
    }
    setState(() {
      _loadingData = true;
      _dataError = null;
    });
    tab.dataFilter = _where.text;
    tab.dataOrder = _order.text;
    final app = mounted ? AppScope.read(context) : null;
    try {
      await tab.data?.close();
      final page = await c.main!.execute(_dataSql, fetchSize: app?.settings.fetchSize ?? 200);
      final m = ResultSetModel(
        connection: c,
        first: page,
        sql: _dataSql,
        fetchSize: app?.settings.fetchSize ?? 200,
        table: table,
      );
      tab.data = m;
      await m.detectEditTarget();
      if (table.isView) m.keyColumns = [];
    } catch (e) {
      _dataError = e;
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  void _filterByValue(ColumnInfo col, Object? v, String op) {
    if (_visualActive) {
      final name = col.baseColumn ?? col.name;
      _ui.filter.conditions.add(
        FilterCondition(
          column: name,
          kind: valueKindOf(col.sqlType, col.typeName),
          op: v == null ? (op == '=' ? FilterOp.isNull : FilterOp.isNotNull) : (op == '=' ? FilterOp.eq : FilterOp.ne),
          value: v == null ? '' : formatValue(v),
        ),
      );
      _applyVisual();
      return;
    }
    final d = tab.connection.dialect;
    final name = d.quoteIdent(col.baseColumn ?? col.name);
    final cond = v == null ? '$name IS ${op == '=' ? '' : 'NOT '}NULL' : '$name $op ${d.literal(v)}';
    _where.text = _where.text.trim().isEmpty ? cond : '(${_where.text.trim()}) AND $cond';
    _loadData();
  }

  Future<void> _countRows() async {
    await guarded(context, () async {
      final r = await tab.connection.meta!.execute(tab.connection.dialect.countSql(table));
      setState(() => _rowCount = (r.rows.first.first as num?)?.toInt());
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _design;
    if (tab.isNew && d != null) {
      return Column(
        children: [
          _header(app),
          Expanded(
            child: IndexedStack(
              index: _page,
              children: [
                DesignPropertiesPage(design: d, connection: tab.connection),
                const SizedBox(),
                DesignColumnsPage(design: d, connection: tab.connection),
                ConstraintsPage(connection: tab.connection, table: table, design: d),
                IndexesPage(connection: tab.connection, table: table, design: d),
                const SizedBox(),
                const SizedBox(),
                DesignChangesPage(design: d, connection: tab.connection),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        _header(app),
        Expanded(
          child: _details == null
              ? const Center(child: Spinner(size: Spinner.large))
              : FutureBuilder<TableDetails>(
                  future: _details,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return EmptyState.error(snap.error!, title: 'Impossibile leggere la struttura della tabella');
                    }
                    final det = snap.data;
                    final design = _designable ? _design : null;
                    return IndexedStack(
                      index: _page,
                      children: [
                        det == null
                            ? const Center(child: Spinner(size: Spinner.large))
                            : design != null
                            ? DesignPropertiesPage(
                                design: design,
                                connection: tab.connection,
                                footer: _propertiesContent(det),
                              )
                            : _properties(det),
                        _dataPage(),
                        det == null
                            ? const SizedBox()
                            : design != null
                            ? DesignColumnsPage(design: design, connection: tab.connection)
                            : _columns(det),
                        det == null || table.isView
                            ? const SizedBox()
                            : ConstraintsPage(
                                key: ValueKey(design),
                                connection: tab.connection,
                                table: table,
                                editable: !_simple,
                                design: design,
                              ),
                        det == null || table.isView
                            ? const SizedBox()
                            : IndexesPage(
                                key: ValueKey(design),
                                connection: tab.connection,
                                table: table,
                                editable: !_simple,
                                design: design,
                              ),
                        det == null ? const SizedBox() : _ddl(det),
                        det == null || _page != 6
                            ? const SizedBox()
                            : ErDiagramView(
                                connection: tab.connection,
                                catalog: table.catalog,
                                schema: table.schema,
                                focus: table,
                                positions: {},
                              ),
                        design == null
                            ? const SizedBox()
                            : DesignChangesPage(design: design, connection: tab.connection),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _header(AppState app) {
    final c = DbColors.of(context);
    return Container(
      color: c.content,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.md),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: Tint.regular),
                    borderRadius: BorderRadius.circular(Radii.menu),
                  ),
                  child: Icon(tab.icon, size: 16, color: c.accent),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              tab.title,
                              overflow: TextOverflow.ellipsis,
                              style: uiText(TypeSize.title, weight: FontWeight.w600, color: c.text),
                            ),
                          ),
                          const SizedBox(width: Gap.sm),
                          Tag(tab.isNew ? 'nuova' : (table.isView ? 'vista' : table.type.toLowerCase())),
                          if (_design?.isDirty ?? false) ...[const SizedBox(width: Gap.xs), const DirtyDot()],
                        ],
                      ),
                      PathBar(
                        segments: [
                          PathSegment(tab.connection.config.name, icon: AppIcons.server),
                          if (table.catalog != null) PathSegment(table.catalog!, icon: AppIcons.database),
                          if (table.schema != null) PathSegment(table.schema!, icon: AppIcons.schema),
                          PathSegment(tab.title, icon: tab.icon),
                        ],
                      ),
                    ],
                  ),
                ),
                // Only on the structure pages: the data page has its own "Salva".
                if (_design != null && _designable && _newPages.contains(_page)) ..._designTools(),
                if (!app.settings.simpleMode && !tab.isNew)
                  ToolButton(
                    icon: AppIcons.script,
                    tooltip: 'Apri in un editor SQL',
                    onPressed: () =>
                        app.sqlEditorWith(tab.connection, 'SELECT * FROM ${tab.connection.dialect.tableName(table)}'),
                  ),
                if (!tab.isNew)
                  ToolButton(
                    icon: AppIcons.share,
                    tooltip: 'Esporta dati…',
                    onPressed: () => showTableExportDialog(context, tab.connection, table),
                  ),
                if (!table.isView && !tab.isNew)
                  ToolButton(
                    icon: AppIcons.download,
                    tooltip: 'Importa dati da CSV…',
                    onPressed: tab.connection.config.readOnly
                        ? null
                        : () => showImportDialog(context, tab.connection, table),
                  ),
                if (!tab.isNew)
                ToolButton(
                  icon: AppIcons.refresh,
                  tooltip: 'Ricarica metadati',
                  onPressed: () {
                    tab.connection.metadata?.clearCache();
                    setState(() {
                      _details = tab.connection.metadata?.tableDetails(table);
                    });
                  },
                ),
              ],
            ),
          ),
          app.settings.simpleMode
              ? _simplePages()
              : PageSwitcher<int>(
                  value: _page,
                  items: [
                    for (final (i, n) in _pageNames.indexed)
                      if (tab.isNew ? _newPages.contains(i) : (i != _pageChanges || (_design != null && _designable)))
                        (i, i == _pageChanges && (_design?.changes.isNotEmpty ?? false) ? '$n (${_design!.changes.length})' : n, null),
                  ],
                  onChanged: _setPage,
                ),
        ],
      ),
    );
  }

  /// Undo, redo, discard and save of the designer.
  List<Widget> _designTools() {
    final d = _design!;
    final mac = Theme.of(context).platform == TargetPlatform.macOS;
    final save = SingleActivator(LogicalKeyboardKey.keyS, meta: mac, control: !mac);
    return [
      ToolButton(icon: AppIcons.undo, tooltip: 'Annulla l\'ultima modifica alla struttura', onPressed: d.canUndo ? d.undo : null),
      ToolButton(icon: AppIcons.redo, tooltip: 'Ripeti', onPressed: d.canRedo ? d.redo : null),
      if (!d.isNew)
        ToolButton(
          icon: AppIcons.replay,
          tooltip: 'Scarta le modifiche alla struttura',
          onPressed: d.isDirty
              ? () async {
                  final ok = await confirmDialog(
                    context,
                    'Scartare le modifiche?',
                    'Le ${d.changes.length} modifiche alla struttura di ${table.name} non ancora salvate andranno perse.',
                    ok: 'Scarta',
                    destructive: true,
                  );
                  if (ok) d.discard();
                }
              : null,
        ),
      const SizedBox(width: Gap.xs),
      PushButton.primary(
        label: d.isNew ? 'Crea tabella' : 'Salva',
        icon: AppIcons.save,
        size: ControlScale.small,
        tooltip: d.errors.isNotEmpty ? d.errors.first : 'Mostra lo script ed esegue le modifiche (${shortcutLabel(save)})',
        onPressed: d.isDirty && d.errors.isEmpty ? () => saveTableDesign(context, tab) : null,
      ),
      const SizedBox(width: Gap.sm),
      ToolSeparator(),
    ];
  }

  /// Simplified analyst view: "Dati" first, developer pages under a
  /// "Dettagli" pull-down (DDL hidden).
  Widget _simplePages() {
    final cur = _page;
    return PageSwitcher<int>(
      value: cur,
      items: [(_pageData, 'Dati', AppIcons.rows), if (cur != _pageData) (cur, _pageNames[cur], null)],
      onChanged: _setPage,
      trailing: PulldownButton(
        icon: AppIcons.info,
        label: 'Dettagli',
        tooltip: 'Dettagli della tabella',
        entries: () => [
          for (final i in const [0, 2, 3, 4, 6])
            MenuEntry<Object?>(_pageNames[i], checked: cur == i, onSelected: () => _setPage(i)),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Visual filter
  // -------------------------------------------------------------------------

  bool get _visualActive => _simple || _ui.visual;

  List<FilterColumn> get _filterColumns {
    final meta = _columnsMeta;
    if (meta != null) {
      return [for (final c in meta) FilterColumn(c.name, valueKindOf(c.dataType, c.typeName), c.fullType)];
    }
    final m = tab.data;
    if (m == null) return const [];
    return [
      for (final c in m.columns)
        FilterColumn(c.baseColumn ?? c.name, valueKindOf(c.sqlType, c.typeName), c.displayType),
    ];
  }

  /// Regenerates WHERE / ORDER BY from the chips and reloads.
  void _applyVisual() {
    final d = tab.connection.dialect;
    _where.text = _ui.filter.whereSql(d);
    _order.text = _ui.filter.orderSql(d);
    setState(() {});
    _loadData();
  }

  void _setVisual(bool v) {
    final ui = _ui;
    if (v) {
      // Keep what was typed in the raw fields: WHERE as a free SQL chip.
      final d = tab.connection.dialect;
      if (_where.text.trim() != ui.filter.whereSql(d)) {
        ui.filter
          ..clear()
          ..customWhere = _where.text.trim();
      }
    }
    setState(() => ui.visual = v);
  }

  Widget _properties(TableDetails d) =>
      SingleChildScrollView(padding: const EdgeInsets.all(16), child: _propertiesContent(d));

  Widget _propertiesContent(TableDetails d) => Align(
    alignment: Alignment.topLeft,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PropertyTable(
          entries: [
            ('Nome', table.name),
            ('Tipo', table.type),
            ('Catalogo', table.catalog ?? ''),
            ('Schema', table.schema ?? ''),
            ('Nome qualificato', tab.connection.dialect.tableName(table)),
            ('Commento', table.remarks ?? ''),
            ('Colonne', '${d.columns.length}'),
            (
              'Chiave primaria',
              d.primaryKey == null ? '' : '${d.primaryKey!.name ?? ''} (${d.primaryKey!.columns.join(', ')})',
            ),
            ('Chiavi esterne', '${d.foreignKeys.length}'),
            ('Referenziata da', '${d.referencedBy.length}'),
            ('Indici', '${d.indexes.length}'),
            ('Numero righe', _rowCount == null ? '' : '$_rowCount'),
          ],
        ),
        const SizedBox(height: 12),
        PushButton(label: 'Calcola numero righe', icon: AppIcons.number, onPressed: _countRows),
      ],
    ),
  );

  Widget _dataPage() {
    final Widget filter = _visualActive
        ? VisualFilterBar(
            filter: _ui.filter,
            columns: _filterColumns,
            onChanged: _applyVisual,
            trailing: [
              if (!_simple)
                ToolButton(
                  icon: AppIcons.code,
                  tooltip: 'Torna a WHERE / ORDER BY in SQL',
                  onPressed: () => _setVisual(false),
                ),
              ToolButton(icon: AppIcons.refresh, tooltip: 'Ricarica i dati', onPressed: _loadData),
            ],
          )
        : PaneBar(
            children: [
              Expanded(
                flex: 3,
                child: MacTextField(
                  controller: _where,
                  small: true,
                  mono: true,
                  token: 'WHERE',
                  hint: "id > 10 AND nome LIKE 'A%'",
                  onSubmitted: (_) => _loadData(),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: MacTextField(
                  controller: _order,
                  small: true,
                  mono: true,
                  token: 'ORDER BY',
                  hint: 'colonna DESC',
                  onSubmitted: (_) => _loadData(),
                ),
              ),
              const SizedBox(width: Gap.sm),
              PushButton(label: 'Applica', size: ControlScale.small, onPressed: _loadData),
              const SizedBox(width: Gap.xs),
              ToolButton(icon: AppIcons.tune, tooltip: 'Filtro visuale', onPressed: () => _setVisual(true)),
              ToolButton(
                icon: AppIcons.filterOff,
                tooltip: 'Rimuovi filtro',
                onPressed: _where.text.isEmpty && _order.text.isEmpty
                    ? null
                    : () {
                        _where.clear();
                        _order.clear();
                        _loadData();
                      },
              ),
            ],
          );
    final m = tab.data;
    if (_loadingData && m == null) {
      return Column(
        children: [
          filter,
          const Expanded(
            child: Center(child: Spinner(size: Spinner.large)),
          ),
        ],
      );
    }
    if (_dataError != null) {
      return Column(
        children: [
          filter,
          Expanded(child: EmptyState.error(_dataError!)),
        ],
      );
    }
    if (m == null) {
      return Column(
        children: [
          filter,
          const Expanded(child: SizedBox()),
        ],
      );
    }
    return ResultsViewer(
      key: ObjectKey(m),
      model: m,
      filterBar: filter,
      onRefresh: _loadData,
      onFilterByValue: _filterByValue,
    );
  }

  Widget _columns(TableDetails d) => SimpleGrid(
    headers: const ['#', 'Nome', 'Tipo', 'Nullable', 'Default', 'Auto', 'Chiave', 'Commento'],
    rows: [
      for (final c in d.columns)
        [
          '${c.position}',
          c.name,
          c.fullType,
          c.nullable ? 'sì' : 'NOT NULL',
          c.defaultValue ?? '',
          c.autoIncrement ? 'sì' : '',
          d.primaryKey?.columns.contains(c.name) ?? false ? 'PK' : '',
          c.remarks ?? '',
        ],
    ],
  );

  Widget _ddl(TableDetails d) {
    final ddl = DdlBuilder(tab.connection.dialect).tableScript(d);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          title: 'DDL ricostruito dai metadati ODBC',
          actions: [
            ToolButton(
              icon: AppIcons.copy,
              label: 'Copia',
              tooltip: 'Copia il DDL',
              onPressed: () => Clipboard.setData(ClipboardData(text: ddl)),
            ),
            ToolButton(
              icon: AppIcons.openExternal,
              label: 'Apri in editor SQL',
              tooltip: 'Apri il DDL in un editor SQL',
              onPressed: () => AppScope.read(context).sqlEditorWith(tab.connection, ddl),
            ),
          ],
        ),
        Expanded(
          child: SqlCodeView(text: ddl),
        ),
      ],
    );
  }
}
