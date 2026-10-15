import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../services/storage.dart';
import '../../state/app_state.dart';
import '../../state/result_set_model.dart';
import '../../ui/actions.dart';
import '../../ui/results/results_viewer.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/split_view.dart';
import 'query_builder_tab.dart';
import 'query_model.dart';

// Box geometry (canvas coordinates).
const double _headerH = 28;
const double _rowH = 20;

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
    final sw = Stopwatch()..start();
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
      app.addHistory(
        HistoryEntry(
          sql: sql,
          connectionId: c.config.id,
          connectionName: c.config.name,
          time: DateTime.now(),
          durationMs: sw.elapsedMilliseconds,
          rows: page.isResultSet ? page.rows.length : page.rowsAffected,
        ),
      );
    } catch (e) {
      tab.error = e is OdbcException ? e.message : e.toString();
      app.addHistory(
        HistoryEntry(
          sql: sql,
          connectionId: c.config.id,
          connectionName: c.config.name,
          time: DateTime.now(),
          durationMs: sw.elapsedMilliseconds,
          error: tab.error,
        ),
      );
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
        icon: Icons.join_inner_rounded,
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
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl+';
    final hasSql = _sql.isNotEmpty;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          PrimaryButton(
            label: 'Esegui',
            icon: Icons.play_arrow_rounded,
            tooltip: 'Esegui la query (${mod}Invio)',
            onPressed: hasSql && !tab.running ? _run : null,
          ),
          const SizedBox(width: Gap.sm),
          ToolButton(
            icon: Icons.edit_note_rounded,
            size: 18,
            tooltip: 'Apri nell\'editor SQL',
            onPressed: hasSql ? _openInEditor : null,
          ),
          ToolButton(icon: Icons.content_copy_rounded, tooltip: 'Copia SQL', onPressed: hasSql ? _copySql : null),
          ToolButton(icon: Icons.delete_sweep_outlined, tooltip: 'Cancella tutto', onPressed: _clearAll),
          const ToolSeparator(),
          Text(
            'Distinct',
            style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary),
          ),
          const SizedBox(width: 6),
          DbSwitch(
            value: model.distinct,
            onChanged: (v) {
              model.distinct = v;
              _changed();
            },
          ),
          const SizedBox(width: Gap.md),
          Text(
            'Limite',
            style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 72,
            height: 26,
            child: TextField(
              controller: _limit,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: TypeSize.body, fontFeatures: kTabular),
              decoration: const InputDecoration(
                hintText: 'nessuno',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              onChanged: (v) {
                model.limit = int.tryParse(v);
                _changed();
              },
            ),
          ),
          const ToolSeparator(),
          ToolButton(icon: Icons.zoom_in_rounded, tooltip: 'Zoom +', onPressed: () => _zoom(1.2)),
          ToolButton(icon: Icons.zoom_out_rounded, tooltip: 'Zoom -', onPressed: () => _zoom(1 / 1.2)),
          ToolButton(
            icon: Icons.fit_screen_outlined,
            tooltip: 'Zoom 100%',
            onPressed: () => _transform.value = Matrix4.identity(),
          ),
          const Spacer(),
          if (tab.running)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Gap.sm),
              child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
            ),
          Flexible(
            child: Text(
              '${tab.dc.config.name}${tab.schema != null
                  ? ' · ${tab.schema}'
                  : tab.catalog != null
                  ? ' · ${tab.catalog}'
                  : ''}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  void _zoom(double f) {
    _transform.value = _transform.value.clone()..scaleByDouble(f, f, 1, 1);
  }

  // -------------------------------------------------------------------------
  // Table list
  // -------------------------------------------------------------------------

  Widget _selector(DbColors c, String hint, String? value, List<String> items, ValueChanged<String?> onChanged) =>
      SizedBox(
        child: DropdownButtonFormField<String>(
          key: ValueKey('$hint:$value:${items.length}'),
          initialValue: items.contains(value) ? value : null,
          isExpanded: true,
          isDense: true,
          hint: Text(
            hint,
            style: TextStyle(fontSize: TypeSize.body, color: c.textTertiary),
          ),
          style: TextStyle(fontSize: TypeSize.body, color: c.text),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          ),
          items: [
            for (final i in items)
              DropdownMenuItem(
                value: i,
                child: Text(i, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ),
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
                  _selector(c, md.catalogTerm, tab.catalog, _catalogs, _changeCatalog),
                  const SizedBox(height: 6),
                ],
                if (md != null && md.supportsSchemas && _schemas.isNotEmpty) ...[
                  _selector(c, md.schemaTerm, tab.schema, _schemas, (s) {
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
              icon: Icons.refresh_rounded,
              size: 14,
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
              child: Text(
                _loadError!,
                style: TextStyle(fontSize: TypeSize.small, color: c.danger),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              itemCount: list.length,
              itemExtent: 26,
              itemBuilder: (context, i) => _tableItem(c, list[i]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: Text(
              'Trascina una tabella nell\'area di lavoro o fai doppio clic per aggiungerla.',
              style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableItem(DbColors c, DbTable t) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Row(
        children: [
          Icon(t.isView ? Icons.view_quilt_outlined : Icons.table_chart_outlined, size: 15, color: c.textSecondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              t.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: TypeSize.body, color: c.text),
            ),
          ),
        ],
      ),
    );
    return Draggable<DbTable>(
      data: t,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.raised,
            borderRadius: BorderRadius.circular(Radii.control),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.table_chart_outlined, size: 14, color: c.accent),
              const SizedBox(width: 6),
              Text(
                t.name,
                style: TextStyle(fontSize: TypeSize.body, color: c.text, decoration: TextDecoration.none),
              ),
            ],
          ),
        ),
      ),
      child: _Hover(
        onDoubleTap: () => _addTable(t),
        child: Tooltip(
          message: '${t.displayPath}${t.remarks != null && t.remarks!.isNotEmpty ? '\n${t.remarks}' : ''}',
          waitDuration: const Duration(milliseconds: 800),
          child: row,
        ),
      ),
    );
  }

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
          border: candidates.isNotEmpty ? Border.all(color: c.accent.withValues(alpha: 0.6), width: 2) : null,
        ),
        child: model.tables.isEmpty
            ? const EmptyState(
                icon: Icons.join_inner_rounded,
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

  Widget _box(DbColors c, QbTable t) {
    final r = _boxRect(t);
    final selected = _selectedBox == t.id;
    return Positioned(
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      child: Container(
        decoration: BoxDecoration(
          color: c.raised,
          border: Border.all(color: selected ? c.accent : c.separator, width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(Radii.panel),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 6, offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: () => setState(() => _selectedBox = t.id),
              onDoubleTap: () => _renameAlias(t),
              onPanStart: (_) => setState(() => _selectedBox = t.id),
              onPanUpdate: (d) => setState(() {
                t.x = math.max(0, t.x + d.delta.dx / _scale);
                t.y = math.max(0, t.y + d.delta.dy / _scale);
              }),
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Container(
                  height: _headerH - 1,
                  padding: const EdgeInsets.only(left: Gap.sm, right: 2),
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: selected ? 0.16 : 0.09),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.panel - 1)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        t.table.isView ? Icons.view_quilt_outlined : Icons.table_chart_outlined,
                        size: 14,
                        color: c.accent,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Tooltip(
                          message: '${t.table.displayPath}\nDoppio clic per cambiare l\'alias',
                          waitDuration: const Duration(milliseconds: 700),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: t.table.name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: TypeSize.small + 0.5,
                                    color: c.text,
                                  ),
                                ),
                                TextSpan(
                                  text: '  ${t.alias}',
                                  style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
                                ),
                              ],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      ToolButton(
                        icon: Icons.select_all_rounded,
                        size: 13,
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
                        icon: Icons.close_rounded,
                        size: 13,
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
    );
  }

  Widget _columnRow(DbColors c, QbTable t, QbColumn col) {
    final selected = model.isSelected(t.id, col.name);
    final ref = _ColumnRef(t.id, col.name);
    final row = SizedBox(
      height: _rowH,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Transform.scale(
              scale: 0.75,
              child: Checkbox(
                value: selected,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onChanged: (_) {
                  model.toggleColumn(t.id, col.name);
                  _changed();
                },
              ),
            ),
          ),
          SizedBox(
            width: 14,
            child: col.isKey ? const Icon(Icons.key_rounded, size: 11, color: Color(0xFFE8A200)) : null,
          ),
          Expanded(
            child: Text(
              col.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: TypeSize.small, color: c.text, fontWeight: col.isKey ? FontWeight.w600 : null),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: Text(
              col.typeName.toLowerCase(),
              style: TextStyle(fontSize: TypeSize.caption - 0.5, color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
    return DragTarget<_ColumnRef>(
      onWillAcceptWithDetails: (d) => d.data.tableId != t.id,
      onAcceptWithDetails: (d) => _addJoin(d.data, t, col.name),
      builder: (context, cand, _) => Container(
        color: cand.isNotEmpty ? c.accent.withValues(alpha: 0.18) : null,
        child: Draggable<_ColumnRef>(
          data: ref,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(Radii.control)),
              child: Text(
                '${t.alias}.${col.name}',
                style: TextStyle(fontSize: TypeSize.small, color: c.onAccent, decoration: TextDecoration.none),
              ),
            ),
          ),
          child: Tooltip(
            message: 'Trascina su una colonna di un\'altra tabella per creare un join',
            waitDuration: const Duration(milliseconds: 1200),
            child: GestureDetector(
              onDoubleTap: () {
                model.toggleColumn(t.id, col.name);
                _changed();
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
      child: Builder(
        builder: (ctx) => GestureDetector(
          onTap: () => _joinMenu(ctx, j),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message: '${a.alias}.${j.leftColumn} ${j.op} ${b.alias}.${j.rightColumn}\nClic per modificare il join',
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.raised,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.accent.withValues(alpha: 0.6)),
                ),
                child: Text(
                  text,
                  style: TextStyle(fontSize: TypeSize.caption, color: c.accent, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _joinMenu(BuildContext ctx, QbJoin j) async {
    final box = ctx.findRenderObject() as RenderBox;
    final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(0, box.size.height), ancestor: overlay);
    PopupMenuItem<VoidCallback> item(String label, bool checked, VoidCallback f, {Color? color}) => PopupMenuItem(
      height: 28,
      value: f,
      child: Row(
        children: [
          SizedBox(width: 20, child: checked ? const Icon(Icons.check_rounded, size: 15) : null),
          Text(
            label,
            style: TextStyle(fontSize: TypeSize.body, color: color),
          ),
        ],
      ),
    );
    final c = DbColors.of(context);
    final f = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(pos & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        for (final t in JoinType.values) item(t.sql, j.type == t, () => j.type = t),
        const PopupMenuDivider(height: 9),
        for (final op in QbJoin.operators) item('Operatore $op', j.op == op, () => j.op = op),
        const PopupMenuDivider(height: 9),
        item('Elimina join', false, () => model.joins.remove(j), color: c.danger),
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
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          decoration: BoxDecoration(
            color: c.chrome,
            border: Border(
              top: BorderSide(color: c.separator),
              bottom: BorderSide(color: c.separator),
            ),
          ),
          child: Row(
            children: [
              Segmented<QueryBuilderPane>(
                value: tab.pane,
                items: const [
                  (QueryBuilderPane.columns, 'Colonne', Icons.view_column_outlined),
                  (QueryBuilderPane.results, 'Risultati', Icons.table_rows_outlined),
                ],
                onChanged: (v) => setState(() => tab.pane = v),
              ),
              const SizedBox(width: Gap.sm),
              if (tab.pane == QueryBuilderPane.columns) ...[
                ToolButton(
                  icon: Icons.functions_rounded,
                  tooltip: 'Aggiungi un\'espressione calcolata',
                  label: 'Espressione',
                  onPressed: () {
                    model.fields.add(QbField(expression: ''));
                    _changed();
                  },
                ),
                ToolButton(
                  icon: Icons.numbers_rounded,
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
                Text(
                  'Raggruppamento automatico sulle colonne non aggregate',
                  style: TextStyle(fontSize: TypeSize.caption + 0.5, color: c.textTertiary),
                ),
            ],
          ),
        ),
        Expanded(
          child: tab.pane == QueryBuilderPane.columns
              ? SplitView(initialFraction: 0.64, minFirst: 300, minSecond: 200, first: _grid(c), second: _sqlPreview(c))
              : tab.running && r == null
              ? const EmptyState(icon: Icons.hourglass_empty_rounded, title: 'Esecuzione in corso…')
              : tab.error != null
              ? Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: SingleChildScrollView(
                    child: SelectableText(tab.error!, style: monoStyle(context, size: 12.5, color: c.danger)),
                  ),
                )
              : r != null
              ? ResultsViewer(key: ObjectKey(r), model: r, onRefresh: _run)
              : EmptyState(
                  icon: Icons.play_circle_outline_rounded,
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
          SectionLabel('SQL generato', padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 2)),
          Expanded(
            child: sql.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Text(
                      'La query apparirà qui.',
                      style: TextStyle(fontSize: TypeSize.small, color: c.textTertiary),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.md),
                    child: SelectableText(sql, style: monoStyle(context, size: 12.5)),
                  ),
          ),
        ],
      ),
    );
  }

  static const _gridCols = <(String, double)>[
    ('Espressione', 210),
    ('Alias', 120),
    ('Output', 52),
    ('Aggregazione', 136),
    ('Ordinamento', 106),
    ('N.', 44),
    ('Filtro', 120),
    ('Valore', 150),
    ('Valore 2', 110),
    ('', 32),
  ];

  Widget _grid(DbColors c) {
    final width = _gridCols.fold<double>(Gap.sm * 2, (t, e) => t + e.$2);
    if (model.fields.isEmpty) {
      return const EmptyState(
        icon: Icons.view_column_outlined,
        title: 'Nessuna colonna',
        message: 'Spunta le colonne nelle tabelle o aggiungi un\'espressione: senza colonne la query restituisce *.',
      );
    }
    final header = Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          for (final (h, w) in _gridCols)
            SizedBox(
              width: w,
              child: Text(
                h,
                style: TextStyle(fontSize: TypeSize.small, fontWeight: FontWeight.w600, color: c.textSecondary),
              ),
            ),
        ],
      ),
    );
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(
            children: [
              header,
              Expanded(
                child: ListView.builder(
                  itemCount: model.fields.length,
                  itemBuilder: (context, i) => _FieldRow(
                    key: ObjectKey(model.fields[i]),
                    field: model.fields[i],
                    model: model,
                    index: i,
                    widths: [for (final e in _gridCols) e.$2],
                    label: _fieldLabel(model.fields[i]),
                    onChanged: _changed,
                    onRemove: () {
                      model.fields.removeAt(i);
                      _changed();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fieldLabel(QbField f) {
    if (f.isCustom) return '';
    final t = model.byId(f.tableId);
    return '${t?.alias ?? '?'}.${f.column}';
  }
}

/// One row of the "Colonne" grid (owns its text controllers).
class _FieldRow extends StatefulWidget {
  const _FieldRow({
    super.key,
    required this.field,
    required this.model,
    required this.index,
    required this.widths,
    required this.label,
    required this.onChanged,
    required this.onRemove,
  });

  final QbField field;
  final QueryModel model;
  final int index;
  final List<double> widths;
  final String label;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<_FieldRow> {
  QbField get f => widget.field;
  late final _expr = TextEditingController(text: f.expression);
  late final _alias = TextEditingController(text: f.alias);
  late final _order = TextEditingController(text: f.sortOrder == 0 ? '' : '${f.sortOrder}');
  late final _v1 = TextEditingController(text: f.value);
  late final _v2 = TextEditingController(text: f.value2);

  @override
  void dispose() {
    for (final ctrl in [_expr, _alias, _order, _v1, _v2]) {
      ctrl.dispose();
    }
    super.dispose();
  }

  Widget _cell(int i, Widget child) => SizedBox(
    width: widget.widths[i],
    child: Padding(padding: const EdgeInsets.only(right: 6), child: child),
  );

  Widget _text(TextEditingController ctrl, String hint, ValueChanged<String> onChanged, {bool mono = false}) =>
      SizedBox(
        height: 24,
        child: TextField(
          controller: ctrl,
          style: mono
              ? monoStyle(context, size: 12)
              : const TextStyle(fontSize: TypeSize.small + 0.5, fontFeatures: kTabular),
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          ),
          onChanged: (v) {
            onChanged(v);
            widget.onChanged();
          },
        ),
      );

  Widget _menu<T>(T value, List<(T, String)> items, ValueChanged<T> onChanged) {
    final c = DbColors.of(context);
    final label = items.firstWhere((e) => e.$1 == value, orElse: () => items.first).$2;
    return PopupMenuButton<T>(
      tooltip: '',
      position: PopupMenuPosition.under,
      onSelected: (v) {
        onChanged(v);
        widget.onChanged();
      },
      itemBuilder: (_) => [for (final (v, l) in items) PopupMenuItem<T>(height: 28, value: v, child: Text(l))],
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(color: c.hover, borderRadius: BorderRadius.circular(Radii.control)),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: TypeSize.small + 0.5,
                  color: value == items.first.$1 ? c.textTertiary : c.text,
                ),
              ),
            ),
            Icon(Icons.expand_more_rounded, size: 14, color: c.textTertiary),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final kind = f.isCustom
        ? ValueKind.text
        : widget.model.byId(f.tableId)?.column(f.column ?? '')?.kind ?? ValueKind.text;
    final ops = f.aggregate == Aggregate.none ? FilterOp.forKind(kind) : FilterOp.values;
    final arity = f.filterOp?.arity ?? 0;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      color: widget.index.isOdd ? c.zebra : null,
      child: Row(
        children: [
          _cell(
            0,
            f.isCustom
                ? _text(_expr, 'espressione SQL, es. prezzo * qta', (v) => f.expression = v, mono: true)
                : Text(widget.label, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12)),
          ),
          _cell(1, _text(_alias, 'alias', (v) => f.alias = v)),
          _cell(
            2,
            Align(
              alignment: Alignment.centerLeft,
              child: Checkbox(
                value: f.output,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) {
                  setState(() => f.output = v ?? true);
                  widget.onChanged();
                },
              ),
            ),
          ),
          _cell(
            3,
            _menu<Aggregate>(f.aggregate, [for (final a in Aggregate.values) (a, a.label)], (v) => f.aggregate = v),
          ),
          _cell(
            4,
            _menu<SortDir>(f.sort, const [
              (SortDir.none, 'Nessuno'),
              (SortDir.asc, 'Crescente'),
              (SortDir.desc, 'Decrescente'),
            ], (v) => f.sort = v),
          ),
          _cell(
            5,
            f.sort == SortDir.none ? const SizedBox() : _text(_order, '#', (v) => f.sortOrder = int.tryParse(v) ?? 0),
          ),
          _cell(
            6,
            _menu<FilterOp?>(f.filterOp, [(null, 'Nessuno'), for (final o in ops) (o, o.sql)], (v) => f.filterOp = v),
          ),
          _cell(
            7,
            arity == 0
                ? const SizedBox()
                : _text(
                    _v1,
                    f.filterOp == FilterOp.inList
                        ? 'a, b, c'
                        : kind == ValueKind.date
                        ? 'aaaa-mm-gg'
                        : 'valore',
                    (v) => f.value = v,
                  ),
          ),
          _cell(8, arity == 2 ? _text(_v2, 'e', (v) => f.value2 = v) : const SizedBox()),
          SizedBox(
            width: widget.widths[9],
            child: ToolButton(
              icon: Icons.remove_circle_outline_rounded,
              size: 14,
              tooltip: 'Rimuovi riga',
              onPressed: widget.onRemove,
            ),
          ),
        ],
      ),
    );
  }
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
      final hl = selected != null && j.involves(selected!);
      final paint = Paint()
        ..color = hl ? color : color.withValues(alpha: 0.55)
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

/// Row with hover tint and double tap (table list).
class _Hover extends StatefulWidget {
  const _Hover({required this.child, required this.onDoubleTap});
  final Widget child;
  final VoidCallback onDoubleTap;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: widget.onDoubleTap,
      child: ColoredBox(color: _hover ? DbColors.of(context).hover : Colors.transparent, child: widget.child),
    ),
  );
}
