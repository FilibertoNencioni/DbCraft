import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/query_builder/query_model.dart';
import '../../features/query_builder/visual_filter.dart';
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
  late int _schemaGeneration = tab.connection.schemaGeneration;

  TableEditorTab get tab => widget.tab;
  DbTable get table => tab.table;

  static const _pageData = 1;
  static const _pageNames = ['Proprietà', 'Dati', 'Colonne', 'Chiavi', 'Indici', 'DDL', 'Diagramma'];

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
    tab.connection.addListener(_onConnection);
    _init();
  }

  void _setPage(int page) {
    if (page == _page) return;
    setState(() => _page = page);
    if (page == _pageData && tab.data == null && !_loadingData) _loadData();
  }

  void _onTab() {
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
    setState(() => _details = c.metadata!.tableDetails(table));
  }

  Future<void> _init() async {
    if (!await ensureConnected(context, tab.connection)) return;
    setState(() {
      _details = tab.connection.metadata!.tableDetails(table);
    });
    _details!.then((d) {
      if (mounted) setState(() => _columnsMeta = d.columns);
    }, onError: (_) {});
    if (_page == _pageData) _loadData();
  }

  @override
  void dispose() {
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
                    final d = snap.data;
                    return IndexedStack(
                      index: _page,
                      children: [
                        d == null ? const Center(child: Spinner(size: Spinner.large)) : _properties(d),
                        _dataPage(),
                        d == null ? const SizedBox() : _columns(d),
                        d == null ? const SizedBox() : _constraints(d),
                        d == null ? const SizedBox() : _indexes(d),
                        d == null ? const SizedBox() : _ddl(d),
                        d == null || _page != 6
                            ? const SizedBox()
                            : ErDiagramView(
                                connection: tab.connection,
                                catalog: table.catalog,
                                schema: table.schema,
                                focus: table,
                                positions: {},
                              ),
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
                              table.name,
                              overflow: TextOverflow.ellipsis,
                              style: uiText(TypeSize.title, weight: FontWeight.w600, color: c.text),
                            ),
                          ),
                          const SizedBox(width: Gap.sm),
                          Tag(table.isView ? 'vista' : table.type.toLowerCase()),
                        ],
                      ),
                      PathBar(
                        segments: [
                          PathSegment(tab.connection.config.name, icon: AppIcons.server),
                          if (table.catalog != null) PathSegment(table.catalog!, icon: AppIcons.database),
                          if (table.schema != null) PathSegment(table.schema!, icon: AppIcons.schema),
                          PathSegment(table.name, icon: tab.icon),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!app.settings.simpleMode)
                  ToolButton(
                    icon: AppIcons.script,
                    tooltip: 'Apri in un editor SQL',
                    onPressed: () =>
                        app.sqlEditorWith(tab.connection, 'SELECT * FROM ${tab.connection.dialect.tableName(table)}'),
                  ),
                ToolButton(
                  icon: AppIcons.share,
                  tooltip: 'Esporta dati…',
                  onPressed: () => showTableExportDialog(context, tab.connection, table),
                ),
                if (!table.isView)
                  ToolButton(
                    icon: AppIcons.download,
                    tooltip: 'Importa dati da CSV…',
                    onPressed: tab.connection.config.readOnly
                        ? null
                        : () => showImportDialog(context, tab.connection, table),
                  ),
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
                  items: [for (final (i, n) in _pageNames.indexed) (i, n, null)],
                  onChanged: _setPage,
                ),
        ],
      ),
    );
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

  Widget _properties(TableDetails d) => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
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

  Widget _constraints(TableDetails d) {
    final c = DbColors.of(context);
    Widget section(String title, Widget child) => Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: FormGroup(title: title, children: [child]),
      ),
    );
    final app = AppScope.read(context);
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        section(
          'Chiave primaria',
          d.primaryKey == null
              ? const Text('Nessuna chiave primaria')
              : SelectableText('${d.primaryKey!.name ?? 'PRIMARY KEY'}  (${d.primaryKey!.columns.join(', ')})'),
        ),
        section(
          'Vincoli UNIQUE',
          Text(
            d.indexes.where((i) => i.unique).map((i) => '${i.name} (${i.columns.join(', ')})').join('\n').isEmpty
                ? 'Nessuno'
                : d.indexes.where((i) => i.unique).map((i) => '${i.name} (${i.columns.join(', ')})').join('\n'),
          ),
        ),
        section(
          'Chiavi esterne',
          d.foreignKeys.isEmpty
              ? const Text('Nessuna')
              : Column(
                  children: [
                    for (final f in d.foreignKeys)
                      ListRow(
                        icon: AppIcons.link,
                        iconColor: c.foreignKeyIcon,
                        title: f.name ?? '(senza nome)',
                        subtitle:
                            '(${f.columns.join(', ')}) → ${f.pkTable} (${f.refColumns.join(', ')})'
                            '${DbForeignKey.ruleName(f.deleteRule).isEmpty ? '' : '  ON DELETE ${DbForeignKey.ruleName(f.deleteRule)}'}',
                        trailing: LinkButton(
                          label: 'Apri',
                          onPressed: () => app.openTable(
                            tab.connection,
                            DbTable(catalog: f.pkCatalog, schema: f.pkSchema, name: f.pkTable, type: 'TABLE'),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        section(
          'Referenziata da',
          d.referencedBy.isEmpty
              ? const Text('Nessuna tabella')
              : Column(
                  children: [
                    for (final f in d.referencedBy)
                      ListRow(
                        icon: AppIcons.incoming,
                        title: f.fkTable,
                        subtitle: '${f.name ?? ''}  (${f.columns.join(', ')}) → (${f.refColumns.join(', ')})',
                        trailing: LinkButton(
                          label: 'Apri',
                          onPressed: () => app.openTable(
                            tab.connection,
                            DbTable(catalog: f.fkCatalog, schema: f.fkSchema, name: f.fkTable, type: 'TABLE'),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _indexes(TableDetails d) => SimpleGrid(
    headers: const ['Nome', 'Univoco', 'Tipo', 'Colonne'],
    rows: [
      for (final i in d.indexes) [i.name, i.unique ? 'sì' : 'no', i.typeName, i.columns.join(', ')],
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
