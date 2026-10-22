import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../../state/result_set_model.dart';
import '../../ui/actions.dart';
import '../../ui/results/results_viewer.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/split_view.dart';
import 'query_builder_tab.dart';
import 'query_model.dart';

// Box geometry (canvas coordinates).
const double _headerH = 24;
const double _rowH = 18;

double _boxWidth(QbTable t) {
  final longest = t.columns.fold<int>(
    t.table.name.length + t.alias.length + 2,
    (m, c) => math.max(m, c.name.length + (c.typeName.length * 0.8).ceil() + 2),
  );
  return (longest * 6.6 + 64).clamp(190.0, 320.0);
}

Rect _boxRect(QbTable t) => Rect.fromLTWH(t.x, t.y, _boxWidth(t), _headerH + t.columns.length * _rowH + 6);

double _rowY(QbTable t, String column) {
  final i = t.columns.indexWhere((c) => c.name == column);
  return t.y + (i < 0 ? _headerH / 2 : _headerH + i * _rowH + _rowH / 2);
}

/// Column being dragged to create a join.
class _ColumnRef {
  const _ColumnRef(this.tableId, this.column);
  final String tableId;
  final String column;
}

/// Visual Query Builder: table list, canvas with boxes and joins, column
/// grid, live SQL preview and embedded results.
class QueryBuilderView extends StatefulWidget {
  const QueryBuilderView({super.key, required this.tab});
  final QueryBuilderTab tab;

  @override
  State<QueryBuilderView> createState() => _QueryBuilderViewState();
}

class _QueryBuilderViewState extends State<QueryBuilderView> {
  late final _transform = TransformationController(widget.tab.viewTransform);
  final _canvasKey = GlobalKey();
  late final _search = TextEditingController(text: widget.tab.tableSearch);
  late final _limit = TextEditingController(text: widget.tab.model.limit?.toString() ?? '');

  List<String> _catalogs = [];
  List<String> _schemas = [];
  List<DbTable> _tables = [];
  bool _loadingTables = false;
  String? _loadError;
  String? _selectedBox;

  QueryBuilderTab get tab => widget.tab;
  QueryModel get model => tab.model;

  @override
  void initState() {
    super.initState();
    _transform.addListener(() => tab.viewTransform = _transform.value.clone());
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _transform.dispose();
    _search.dispose();
    _limit.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (!tab.dc.dialect.isSql && tab.dc.isConnected) return;
    if (!await ensureConnected(context, tab.dc)) return;
    final md = tab.dc.metadata;
    if (md == null || !mounted) return;
    try {
      if (md.supportsCatalogs) {
        _catalogs = await md.catalogs();
        tab.catalog ??= tab.initialTable?.catalog ?? md.currentCatalog ?? _catalogs.firstOrNull;
      }
      if (md.supportsSchemas) {
        _schemas = await md.schemas(tab.catalog);
        tab.schema ??= tab.initialTable?.schema;
      }
    } catch (e) {
      _loadError = e.toString();
    }
    await _loadTables();
    final t = tab.initialTable;
    if (t != null && !tab.initialTableAdded) {
      tab.initialTableAdded = true;
      await _addTable(t);
    }
  }

  Future<void> _loadTables() async {
    final md = tab.dc.metadata;
    if (md == null) return;
    setState(() {
      _loadingTables = true;
      _loadError = null;
    });
    try {
      _tables = await md.tables(tab.catalog, tab.schema);
    } catch (e) {
      _loadError = e is OdbcException ? e.message : e.toString();
      _tables = [];
    }
    if (mounted) setState(() => _loadingTables = false);
  }

  Future<void> _changeCatalog(String? c) async {
    final md = tab.dc.metadata;
    if (md == null) return;
    tab.catalog = c;
    tab.schema = null;
    try {
      _schemas = md.supportsSchemas ? await md.schemas(c) : [];
    } catch (_) {
      _schemas = [];
    }
    await _loadTables();
  }

  // -------------------------------------------------------------------------
  // Model edits
  // -------------------------------------------------------------------------

  void _changed() {
    if (mounted) setState(() {});
    tab.refresh();
  }

  Offset _freeSpot() {
    if (model.tables.isEmpty) return const Offset(40, 40);
    final right = model.tables.map((t) => _boxRect(t).right).reduce(math.max);
    final top = model.tables.map((t) => t.y).reduce(math.min);
    return Offset(right + 80, top);
  }

  Future<void> _addTable(DbTable t, {Offset? at}) async {
    final md = tab.dc.metadata;
    if (md == null) return;
    await guarded(context, () async {
      final cols = await md.columns(t);
      final pk = await md.primaryKey(t);
      List<DbForeignKey> fks = const [];
      try {
        fks = await md.foreignKeys(t);
      } catch (_) {}
      final keys = pk?.columns.map((e) => e.toLowerCase()).toSet() ?? {};
      final pos = at ?? _freeSpot();
      final box = model.addTable(
        t,
        [for (final c in cols) QbColumn.fromDb(c, isKey: keys.contains(c.name.toLowerCase()))],
        foreignKeys: fks,
        x: math.max(0, pos.dx),
        y: math.max(0, pos.dy),
      );
      _selectedBox = box.id;
      _changed();
    }, title: 'Impossibile aggiungere la tabella');
  }

  Future<void> _renameAlias(QbTable t) async {
    final v = await promptText(context, 'Alias di ${t.table.name}', initial: t.alias, label: 'alias');
    final a = v?.trim();
    if (a == null || a.isEmpty) return;
    if (model.tables.any((o) => o != t && o.alias.toLowerCase() == a.toLowerCase())) {
      if (mounted) showToast(context, 'L\'alias "$a" è già usato', error: true);
      return;
    }
    t.alias = a;
    _changed();
  }

  void _addJoin(_ColumnRef from, QbTable to, String column) {
    if (from.tableId == to.id) return;
    if (model.joins.any(
      (j) =>
          (j.leftId == from.tableId && j.leftColumn == from.column && j.rightId == to.id && j.rightColumn == column) ||
          (j.rightId == from.tableId && j.rightColumn == from.column && j.leftId == to.id && j.leftColumn == column),
    )) {
      return;
    }
    model.joins.add(QbJoin(leftId: from.tableId, leftColumn: from.column, rightId: to.id, rightColumn: column));
    _changed();
  }

  Future<void> _clearAll() async {
    if (model.tables.isEmpty && model.fields.isEmpty) return;
    final ok = await confirmDialog(
      context,
      'Cancellare la query?',
      'Tabelle, join e colonne verranno rimosse.',
      ok: 'Cancella',
      destructive: true,
    );
    if (!ok) return;
    model.clear();
    _limit.clear();
    _changed();
  }

  // -------------------------------------------------------------------------
  // SQL
  // -------------------------------------------------------------------------

  String get _sql => QuerySqlGenerator(tab.dc.dialect).generate(model);

  String get _formattedSql => QuerySqlGenerator(tab.dc.dialect).generate(model, pretty: true);

  Future<void> _run() async {
    final sql = _formattedSql;
    if (sql.isEmpty || tab.running) return;
    final c = tab.dc;
    if (!await ensureConnected(context, c)) return;
    final s = c.main;
    if (s == null || !mounted) return;
    final app = AppScope.read(context);
    final fetch = app.settings.fetchSize;
    setState(() {
      tab.running = true;
      tab.error = null;
      tab.message = null;
      tab.pane = QueryBuilderPane.results;
    });
    try {
      await tab.result?.close();
      tab.result = null;
      final page = await s.execute(sql, fetchSize: fetch, queryTimeoutSec: c.config.queryTimeout);
      if (page.isResultSet) {
        final m = ResultSetModel(connection: c, first: page, sql: sql, fetchSize: fetch);
        tab.result = m;
        unawaited(m.detectEditTarget());
      } else {
        tab.message = 'Istruzione eseguita';
      }
    } catch (e) {
      tab.error = e is OdbcException ? e.message : e.toString();
    } finally {
      tab.running = false;
      _changed();
    }
  }

  void _openInEditor() {
    final sql = _formattedSql;
    if (sql.isEmpty) return;
    AppScope.read(context).openSqlEditor(tab.dc, initialSql: sql);
  }

  void _copySql() {
    final sql = _formattedSql;
    if (sql.isEmpty) return;
    Clipboard.setData(ClipboardData(text: sql));
    showToast(context, 'SQL copiato negli appunti');
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    if (tab.dc.isConnected && !tab.dc.dialect.isSql) {
      return const EmptyState(
        icon: AppIcons.join,
        title: 'Query builder non disponibile',
        message: 'Il query builder visuale genera SQL: questa connessione usa un linguaggio di interrogazione diverso.',
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _run,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _run,
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: c.content,
          child: Column(
            children: [
              _toolbar(c),
              Expanded(
                child: SplitView(
                  axis: Axis.vertical,
                  initialFraction: 0.56,
                  minFirst: 160,
                  minSecond: 140,
                  first: SplitView(
                    initialFraction: 0.2,
                    minFirst: 180,
                    minSecond: 300,
                    first: _tableList(c),
                    second: _canvas(c),
                  ),
                  second: _bottom(c),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar(DbColors c) {
    final hasSql = _sql.isNotEmpty;
    return PaneBar(
      loading: tab.running,
      children: [
        PushButton.primary(
          label: 'Esegui',
          icon: AppIcons.run,
          size: ControlScale.small,
          tooltip: 'Esegui la query (${shortcutLabel(const SingleActivator(LogicalKeyboardKey.enter, meta: true))})',
          onPressed: hasSql && !tab.running ? _run : null,
        ),
        const SizedBox(width: Gap.sm),
        ToolButton(icon: AppIcons.script, tooltip: 'Apri nell\'editor SQL', onPressed: hasSql ? _openInEditor : null),
        ToolButton(icon: AppIcons.copy, tooltip: 'Copia SQL', onPressed: hasSql ? _copySql : null),
        ToolButton(icon: AppIcons.clearAll, tooltip: 'Cancella tutto', onPressed: _clearAll),
        const ToolSeparator(),
        CheckboxRow(
          label: 'Distinct',
          small: true,
          value: model.distinct,
          onChanged: (v) {
            model.distinct = v;
            _changed();
          },
        ),
        const SizedBox(width: Gap.md),
        Text('Limite', style: uiText(TypeSize.caption, color: c.textSecondary)),
        const SizedBox(width: 6),
        NumberField(
          controller: _limit,
          min: 1,
          hint: 'nessuno',
          small: true,
          width: 64,
          onChanged: (v) {
            model.limit = int.tryParse(v);
            _changed();
          },
        ),
        const ToolSeparator(),
        ToolButton(icon: AppIcons.zoomIn, tooltip: 'Zoom +', onPressed: () => _zoom(1.2)),
        ToolButton(icon: AppIcons.zoomOut, tooltip: 'Zoom -', onPressed: () => _zoom(1 / 1.2)),
        ToolButton(
          icon: AppIcons.fitScreen,
          tooltip: 'Zoom 100%',
          onPressed: () => _transform.value = Matrix4.identity(),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            '${tab.dc.config.name}${tab.schema != null
                ? ' · ${tab.schema}'
                : tab.catalog != null
                ? ' · ${tab.catalog}'
                : ''}',
            overflow: TextOverflow.ellipsis,
            style: uiText(TypeSize.small, color: c.textSecondary),
          ),
        ),
      ],
    );
  }

  void _zoom(double f) {
    _transform.value = _transform.value.clone()..scaleByDouble(f, f, 1, 1);
  }

  // -------------------------------------------------------------------------
  // Table list
  // -------------------------------------------------------------------------

  Widget _selector(String hint, String? value, List<String> items, ValueChanged<String?> onChanged) =>
      PopUpButton<String?>(
        value: items.contains(value) ? value : null,
        items: [for (final i in items) (i, i, null)],
        placeholder: hint,
        expand: true,
        onChanged: onChanged,
      );

  Widget _tableList(DbColors c) {
    final md = tab.dc.metadata;
    final q = _search.text.trim().toLowerCase();
    final list = q.isEmpty ? _tables : _tables.where((t) => t.name.toLowerCase().contains(q)).toList();
    return Container(
      color: c.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
            child: Column(
              children: [
                if (md != null && md.supportsCatalogs && _catalogs.isNotEmpty) ...[
                  _selector(md.catalogTerm, tab.catalog, _catalogs, _changeCatalog),
                  const SizedBox(height: 6),
                ],
                if (md != null && md.supportsSchemas && _schemas.isNotEmpty) ...[
                  _selector(md.schemaTerm, tab.schema, _schemas, (s) {
                    tab.schema = s;
                    _loadTables();
                  }),
                  const SizedBox(height: 6),
                ],
                SearchField(
                  controller: _search,
                  hint: 'Cerca tabelle',
                  onChanged: (v) => setState(() => tab.tableSearch = v),
                ),
              ],
            ),
          ),
          SectionLabel(
            _loadingTables ? 'Caricamento…' : '${list.length} ${list.length == 1 ? 'oggetto' : 'oggetti'}',
            trailing: ToolButton(
              icon: AppIcons.refresh,
              extent: 18,
              tooltip: 'Ricarica elenco',
              onPressed: () {
                tab.dc.metadata?.clearCache('tables:');
                _loadTables();
              },
            ),
          ),
          if (_loadError != null)
            Padding(
              padding: const EdgeInsets.all(Gap.sm),
              child: StatusLine(_loadError!, kind: StatusKind.danger, selectable: true, maxLines: 4),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(Gap.xs, 0, Gap.xs, Gap.sm),
              itemCount: list.length,
              itemExtent: ListRow.height,
              itemBuilder: (context, i) => _tableItem(list[i]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: Text(
              'Trascina una tabella nell\'area di lavoro o fai doppio clic per aggiungerla.',
              style: uiText(TypeSize.caption, color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableItem(DbTable t) => Draggable<DbTable>(
    data: t,
    dragAnchorStrategy: pointerDragAnchorStrategy,
    feedback: DragChip(label: t.name, icon: t.isView ? AppIcons.erDiagram : AppIcons.table),
    child: ListRow(
      title: t.name,
      icon: t.isView ? AppIcons.erDiagram : AppIcons.table,
      tooltip: '${t.displayPath}${t.remarks != null && t.remarks!.isNotEmpty ? '\n${t.remarks}' : ''}',
      onDoubleTap: () => _addTable(t),
    ),
  );

  // -------------------------------------------------------------------------
  // Canvas
  // -------------------------------------------------------------------------

  Widget _canvas(DbColors c) {
    var w = 1400.0, h = 900.0;
    for (final t in model.tables) {
      final r = _boxRect(t);
      w = math.max(w, r.right + 300);
      h = math.max(h, r.bottom + 300);
    }
    final content = SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _selectedBox = null),
              child: CustomPaint(
                painter: _JoinPainter(model: model, color: c.accent, muted: c.textTertiary, selected: _selectedBox),
              ),
            ),
          ),
          for (final t in model.tables) _box(c, t),
          for (final j in model.joins) _joinLabel(c, j),
        ],
      ),
    );
    return DragTarget<DbTable>(
      onAcceptWithDetails: (d) {
        final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(d.offset);
        _addTable(d.data, at: _transform.toScene(local) - const Offset(20, 10));
      },
      builder: (context, candidates, _) => Container(
        key: _canvasKey,
        decoration: BoxDecoration(
          color: c.content,
          border: candidates.isNotEmpty ? Border.all(color: c.focusRing, width: 2) : null,
        ),
        child: model.tables.isEmpty
            ? const EmptyState(
                icon: AppIcons.join,
                title: 'Costruisci una query senza scrivere SQL',
                message:
                    'Trascina qui le tabelle dall\'elenco: i join seguono le chiavi esterne. '
                    'Spunta le colonne da estrarre e completa filtri e ordinamenti nella griglia sotto.',
              )
            : ClipRect(
                child: InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  minScale: 0.3,
                  maxScale: 2.5,
                  boundaryMargin: const EdgeInsets.all(400),
                  child: content,
                ),
              ),
      ),
    );
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  // Manual double click (onDoubleTap would delay the single click).
  String? _lastTapId;
  DateTime? _lastTapAt;

  bool _isDoubleTap(String id) {
    final now = DateTime.now();
    final last = _lastTapAt;
    final dbl = _lastTapId == id && last != null && now.difference(last) <= kDoubleTapTimeout;
    _lastTapId = id;
    _lastTapAt = dbl ? null : now;
    return dbl;
  }

  Widget _box(DbColors c, QbTable t) {
    final r = _boxRect(t);
    final selected = _selectedBox == t.id;
    return Positioned(
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      child: FocusRing(
        visible: selected,
        radius: Radii.menu,
        child: Container(
          decoration: BoxDecoration(
            color: c.raised,
            borderRadius: BorderRadius.circular(Radii.menu),
            boxShadow: Elevation.node(Theme.of(context).brightness),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                supportedDevices: kCanvasDragDevices,
                onTap: () {
                  setState(() => _selectedBox = t.id);
                  if (_isDoubleTap('box:${t.id}')) _renameAlias(t);
                },
                onPanStart: (_) => setState(() => _selectedBox = t.id),
                onPanUpdate: (d) => setState(() {
                  t.x = math.max(0, t.x + d.delta.dx / _scale);
                  t.y = math.max(0, t.y + d.delta.dy / _scale);
                }),
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: Container(
                    height: _headerH,
                    padding: const EdgeInsets.only(left: Gap.sm, right: 2),
                    color: c.accent.withValues(alpha: selected ? Tint.regular : Tint.subtle),
                    child: Row(
                      children: [
                        Icon(t.table.isView ? AppIcons.erDiagram : AppIcons.table, size: 14, color: c.accent),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Tooltip(
                            message: '${t.table.displayPath}\nDoppio clic per cambiare l\'alias',
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: t.table.name,
                                    style: uiText(TypeSize.small, weight: FontWeight.w600, color: c.text),
                                  ),
                                  TextSpan(
                                    text: '  ${t.alias}',
                                    style: uiText(TypeSize.small, color: c.textSecondary),
                                  ),
                                ],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        ToolButton(
                          icon: AppIcons.selectAll,
                          extent: 18,
                          tooltip: 'Seleziona / deseleziona tutte le colonne',
                          onPressed: () {
                            final all = t.columns.every((col) => model.isSelected(t.id, col.name));
                            for (final col in t.columns) {
                              if (model.isSelected(t.id, col.name) == all) model.toggleColumn(t.id, col.name);
                            }
                            _changed();
                          },
                        ),
                        ToolButton(
                          icon: AppIcons.close,
                          extent: 18,
                          tooltip: 'Rimuovi dalla query',
                          onPressed: () {
                            model.removeTable(t.id);
                            _changed();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              for (final col in t.columns) _columnRow(c, t, col),
            ],
          ),
        ),
      ),
    );
  }

  Widget _columnRow(DbColors c, QbTable t, QbColumn col) {
    final selected = model.isSelected(t.id, col.name);
    final ref = _ColumnRef(t.id, col.name);
    final name = col.name.toLowerCase();
    final isFk = t.foreignKeys.any((fk) => fk.columns.any((x) => x.toLowerCase() == name));
    void toggle() {
      model.toggleColumn(t.id, col.name);
      _changed();
    }

    final row = SizedBox(
      height: _rowH,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Center(child: MacCheckbox(value: selected, onChanged: (_) => toggle())),
          ),
          SizedBox(
            width: 14,
            child: col.isKey
                ? Icon(AppIcons.key, size: 11, color: c.keyIcon)
                : (isFk ? Icon(AppIcons.link, size: 11, color: c.foreignKeyIcon) : null),
          ),
          Expanded(
            child: Text(
              col.name,
              overflow: TextOverflow.ellipsis,
              style: uiText(TypeSize.small, color: c.text, weight: col.isKey ? FontWeight.w600 : null),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: TypeLabel(col.typeName.toLowerCase()),
          ),
        ],
      ),
    );
    return DragTarget<_ColumnRef>(
      onWillAcceptWithDetails: (d) => d.data.tableId != t.id,
      onAcceptWithDetails: (d) => _addJoin(d.data, t, col.name),
      builder: (context, cand, _) => Container(
        color: cand.isNotEmpty ? c.accent.withValues(alpha: Tint.strong) : null,
        child: Draggable<_ColumnRef>(
          data: ref,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: DragChip(label: '${t.alias}.${col.name}', icon: AppIcons.link),
          child: Tooltip(
            message: 'Trascina su una colonna di un\'altra tabella per creare un join',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_isDoubleTap('col:${t.id}.${col.name}')) toggle();
              },
              child: row,
            ),
          ),
        ),
      ),
    );
  }

  /// Clickable label in the middle of a join line.
  Widget _joinLabel(DbColors c, QbJoin j) {
    final a = model.byId(j.leftId), b = model.byId(j.rightId);
    if (a == null || b == null) return const SizedBox.shrink();
    final (p1, p2) = _JoinPainter.endpoints(a, j.leftColumn, b, j.rightColumn);
    final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    final text = '${j.type.label.split(' ').first.toLowerCase()}${j.op == '=' ? '' : ' ${j.op}'}';
    return Positioned(
      left: mid.dx - 34,
      top: mid.dy - 10,
      width: 68,
      height: 20,
      child: Center(
        child: Builder(
          builder: (ctx) => GestureDetector(
            onTap: () => _joinMenu(ctx, j),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Tooltip(
                message: '${a.alias}.${j.leftColumn} ${j.op} ${b.alias}.${j.rightColumn}\nClic per modificare il join',
                child: Capsule(
                  bordered: true,
                  elevated: true,
                  child: Text(text, style: uiText(TypeSize.caption, weight: FontWeight.w600, color: c.accent)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _joinMenu(BuildContext ctx, QbJoin j) async {
    final f = await showMacMenu<VoidCallback>(
      ctx,
      anchor: anchorRect(ctx),
      entries: [
        for (final t in JoinType.values) MenuEntry(t.sql, value: () => j.type = t, checked: j.type == t),
        const MenuEntry.divider(),
        for (final op in QbJoin.operators) MenuEntry('Operatore $op', value: () => j.op = op, checked: j.op == op),
        const MenuEntry.divider(),
        MenuEntry('Elimina join', value: () => model.joins.remove(j), destructive: true),
      ],
    );
    if (f == null) return;
    f();
    _changed();
  }

  // -------------------------------------------------------------------------
  // Bottom pane: columns grid + SQL preview / results
  // -------------------------------------------------------------------------

  Widget _bottom(DbColors c) {
    final r = tab.result;
    return Column(
      children: [
        PaneBar(
          children: [
            Segmented<QueryBuilderPane>(
              value: tab.pane,
              items: const [
                (QueryBuilderPane.columns, 'Colonne', AppIcons.column),
                (QueryBuilderPane.results, 'Risultati', AppIcons.rows),
              ],
              onChanged: (v) => setState(() => tab.pane = v),
            ),
            const SizedBox(width: Gap.sm),
            if (tab.pane == QueryBuilderPane.columns) ...[
              ToolButton(
                icon: AppIcons.function,
                tooltip: 'Aggiungi un\'espressione calcolata',
                label: 'Espressione',
                onPressed: () {
                  model.fields.add(QbField(expression: ''));
                  _changed();
                },
              ),
              ToolButton(
                icon: AppIcons.number,
                tooltip: 'Aggiungi COUNT(*)',
                label: 'Conteggio',
                onPressed: () {
                  model.fields.add(QbField(expression: '*', aggregate: Aggregate.count, alias: 'conteggio'));
                  _changed();
                },
              ),
            ],
            const Spacer(),
            if (tab.pane == QueryBuilderPane.columns && model.fields.any((f) => f.aggregate != Aggregate.none))
              Flexible(
                child: Text(
                  'Raggruppamento automatico sulle colonne non aggregate',
                  overflow: TextOverflow.ellipsis,
                  style: uiText(TypeSize.caption, color: c.textTertiary),
                ),
              ),
          ],
        ),
        Expanded(
          child: tab.pane == QueryBuilderPane.columns
              ? SplitView(initialFraction: 0.64, minFirst: 300, minSecond: 200, first: _grid(c), second: _sqlPreview(c))
              : tab.running && r == null
              ? const EmptyState(icon: AppIcons.hourglass, title: 'Esecuzione in corso…')
              : tab.error != null
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Notice(
                    kind: NoticeKind.danger,
                    title: 'La query non è stata eseguita',
                    child: CodeBox(tab.error!, wrap: true, color: c.danger),
                  ),
                )
              : r != null
              ? ResultsViewer(key: ObjectKey(r), model: r, onRefresh: _run)
              : EmptyState(
                  icon: AppIcons.runCircle,
                  title: tab.message ?? 'Nessun risultato',
                  message: tab.message == null ? 'Premi Esegui per eseguire la query costruita.' : null,
                ),
        ),
      ],
    );
  }

  Widget _sqlPreview(DbColors c) {
    final sql = _formattedSql;
    return Container(
      color: c.codeBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(
            title: 'SQL generato',
            actions: [
              ToolButton(icon: AppIcons.copy, extent: 18, tooltip: 'Copia SQL', onPressed: sql.isEmpty ? null : _copySql),
            ],
          ),
          Expanded(
            child: sql.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Text(
                      'La query apparirà qui.',
                      style: uiText(TypeSize.small, color: c.textTertiary),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(Gap.md),
                    child: SelectableText(sql, style: monoStyle(context, size: TypeSize.mono)),
                  ),
          ),
        ],
      ),
    );
  }

  static const _gridCols = <(String, double)>[
    ('Espressione', 210),
    ('Alias', 120),
    ('Output', 60),
    ('Aggregazione', 136),
    ('Ordinamento', 116),
    ('N.', 52),
    ('Filtro', 120),
    ('Valore', 150),
    ('Valore 2', 110),
    ('', 34),
  ];

  Widget _grid(DbColors c) {
    if (model.fields.isEmpty) {
      return const EmptyState(
        icon: AppIcons.column,
        title: 'Nessuna colonna',
        message: 'Spunta le colonne nelle tabelle o aggiungi un\'espressione: senza colonne la query restituisce *.',
      );
    }
    return MacTable(
      headers: [for (final (h, _) in _gridCols) h],
      rowCount: model.fields.length,
      width: (col) => _gridCols[col].$2,
      mono: (col) => col == 0,
      resizable: false,
      cell: (r, col) => col == 0 ? _fieldLabel(model.fields[r]) : '',
      cellBuilder: _gridCell,
    );
  }

  /// Inline editor of a "Colonne" grid cell; null shows the label text.
  Widget? _gridCell(BuildContext context, int r, int col) {
    final f = model.fields[r];
    void edit(VoidCallback change) {
      change();
      _changed();
    }

    Widget text(String initial, String hint, ValueChanged<String> onChanged, {bool mono = false}) =>
        _GridText(key: ObjectKey(f), initial: initial, hint: hint, mono: mono, onChanged: (v) => edit(() => onChanged(v)));

    Widget popUp<T>(T value, List<(T, String)> items, ValueChanged<T> onChanged) => PopUpButton<T>(
      value: value,
      items: [for (final (v, l) in items) (v, l, null)],
      style: PopUpStyle.inline,
      small: true,
      expand: true,
      onChanged: (v) => edit(() => onChanged(v)),
    );

    final kind = f.isCustom ? ValueKind.text : model.byId(f.tableId)?.column(f.column ?? '')?.kind ?? ValueKind.text;
    final ops = f.aggregate == Aggregate.none ? FilterOp.forKind(kind) : FilterOp.values;
    final arity = f.filterOp?.arity ?? 0;
    return switch (col) {
      0 when f.isCustom => text(f.expression, 'espressione SQL, es. prezzo * qta', (v) => f.expression = v, mono: true),
      0 => null,
      1 => text(f.alias, 'alias', (v) => f.alias = v),
      2 => Align(
        alignment: Alignment.centerLeft,
        child: MacCheckbox(value: f.output, onChanged: (v) => edit(() => f.output = v)),
      ),
      3 => popUp<Aggregate>(f.aggregate, [for (final a in Aggregate.values) (a, a.label)], (v) => f.aggregate = v),
      4 => popUp<SortDir>(f.sort, const [
        (SortDir.none, 'Nessuno'),
        (SortDir.asc, 'Crescente'),
        (SortDir.desc, 'Decrescente'),
      ], (v) => f.sort = v),
      5 when f.sort == SortDir.none => const SizedBox.shrink(),
      5 => text(f.sortOrder == 0 ? '' : '${f.sortOrder}', '#', (v) => f.sortOrder = int.tryParse(v) ?? 0),
      // Indices, not the operators: a menu cannot return null for "Nessuno".
      6 => popUp<int>(
        f.filterOp == null ? -1 : ops.indexOf(f.filterOp!),
        [(-1, 'Nessuno'), for (final (i, o) in ops.indexed) (i, o.sql)],
        (i) => f.filterOp = i < 0 ? null : ops[i],
      ),
      7 when arity == 0 => const SizedBox.shrink(),
      7 => text(
        f.value,
        f.filterOp == FilterOp.inList
            ? 'a, b, c'
            : kind == ValueKind.date
            ? 'aaaa-mm-gg'
            : 'valore',
        (v) => f.value = v,
      ),
      8 when arity == 2 => text(f.value2, 'e', (v) => f.value2 = v),
      8 => const SizedBox.shrink(),
      _ => ToolButton(
        icon: AppIcons.removeCircle,
        extent: 18,
        tooltip: 'Rimuovi riga',
        onPressed: () {
          model.fields.removeAt(r);
          _changed();
        },
      ),
    };
  }

  String _fieldLabel(QbField f) {
    if (f.isCustom) return '';
    final t = model.byId(f.tableId);
    return '${t?.alias ?? '?'}.${f.column}';
  }
}

/// Small text field in a grid cell; owns its controller, so key it by the
/// row's field to keep the text with its row.
class _GridText extends StatefulWidget {
  const _GridText({super.key, required this.initial, required this.hint, required this.onChanged, this.mono = false});

  final String initial;
  final String hint;
  final ValueChanged<String> onChanged;
  final bool mono;

  @override
  State<_GridText> createState() => _GridTextState();
}

class _GridTextState extends State<_GridText> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      MacTextField(controller: _ctrl, hint: widget.hint, small: true, mono: widget.mono, onChanged: widget.onChanged);
}

/// Join lines between column rows.
class _JoinPainter extends CustomPainter {
  _JoinPainter({required this.model, required this.color, required this.muted, required this.selected});

  final QueryModel model;
  final Color color;
  final Color muted;
  final String? selected;

  /// Line endpoints on the facing sides of the two boxes.
  static (Offset, Offset) endpoints(QbTable a, String colA, QbTable b, String colB) {
    final ra = _boxRect(a), rb = _boxRect(b);
    final ya = _rowY(a, colA), yb = _rowY(b, colB);
    if (ra.center.dx <= rb.center.dx) return (Offset(ra.right, ya), Offset(rb.left, yb));
    return (Offset(ra.left, ya), Offset(rb.right, yb));
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final j in model.joins) {
      final a = model.byId(j.leftId), b = model.byId(j.rightId);
      if (a == null || b == null) continue;
      // Neutral lines; the joins of the selected box take the accent.
      final hl = selected != null && j.involves(selected!);
      final paint = Paint()
        ..color = hl ? color : muted
        ..strokeWidth = hl ? 2 : 1.4
        ..style = PaintingStyle.stroke;
      final (p1, p2) = endpoints(a, j.leftColumn, b, j.rightColumn);
      final dir = p1.dx <= p2.dx ? 1.0 : -1.0;
      final bend = math.max(40.0, (p2.dx - p1.dx).abs() / 2);
      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..cubicTo(p1.dx + dir * bend, p1.dy, p2.dx - dir * bend, p2.dy, p2.dx, p2.dy);
      canvas.drawPath(path, paint);
      final dot = Paint()..color = paint.color;
      canvas.drawCircle(p1, 3, dot);
      canvas.drawCircle(p2, 3, dot);
      // Outer joins: hollow marker on the optional side.
      if (j.type == JoinType.left || j.type == JoinType.full) {
        canvas.drawCircle(p2, 5, paint..strokeWidth = 1.2);
      }
      if (j.type == JoinType.right || j.type == JoinType.full) {
        canvas.drawCircle(p1, 5, paint..strokeWidth = 1.2);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
