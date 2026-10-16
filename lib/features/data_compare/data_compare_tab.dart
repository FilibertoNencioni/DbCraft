import 'dart:math';

import 'package:flutter/material.dart';

import '../../drivers/db_session.dart';
import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../ui/actions.dart';
import '../../ui/widgets/common.dart';
import 'compare_engine.dart';
import 'sql_values.dart';
import 'sync_script_dialog.dart';

const _defaultRowCap = 100000;

/// One side (source or target) of the comparison.
class CompareSide {
  DbConnection? conn;
  List<String> catalogs = const [];
  List<String> schemas = const [];
  List<DbTable> tables = const [];
  String? catalog;
  String? schema;
  DbTable? table;
  List<DbColumn> columns = const [];
  DbPrimaryKey? primaryKey;
  List<DbIndex> indexes = const [];
  final where = TextEditingController();
  bool loading = false;
  String? error;

  DbColumn? column(String name) {
    final l = name.toLowerCase();
    for (final c in columns) {
      if (c.name.toLowerCase() == l) return c;
    }
    return null;
  }
}

/// Rows of a database query as a [RowSource] (dedicated read-only session).
class _DbRowSource implements RowSource {
  _DbRowSource(this.dc, this.sql);
  final DbConnection dc;
  final String sql;
  final int pageSize = 2000;
  DbSession? _s;
  List<List<Object?>>? _first;
  int? _cursor;
  bool _end = false;

  Future<List<ColumnInfo>> open() async {
    _s = await dc.openSession(readOnly: true);
    final p = await _s!.execute(sql, fetchSize: pageSize);
    _first = p.rows;
    _cursor = p.cursorId;
    _end = !p.hasMore || p.cursorId == null;
    return p.columns;
  }

  @override
  Future<List<List<Object?>>> nextPage() async {
    final f = _first;
    if (f != null) {
      _first = null;
      if (f.isNotEmpty) return f;
    }
    while (!_end && _cursor != null) {
      final p = await _s!.fetchMore(_cursor!, pageSize);
      if (!p.hasMore || p.cursorId == null) {
        _end = true;
        _cursor = null;
      }
      if (p.rows.isNotEmpty) return p.rows;
    }
    return const [];
  }

  void cancel() => _s?.cancel();

  @override
  Future<void> close() async {
    final s = _s;
    _s = null;
    if (s == null) return;
    try {
      if (_cursor != null && !_end) await s.closeCursor(_cursor!);
    } catch (_) {}
    await s.close();
  }
}

/// DBeaver PRO "Data compare": compares the rows of two tables (possibly on
/// different connections and DBMS) and generates a synchronization script.
class DataCompareTab extends FeatureTab {
  DataCompareTab({DbConnection? source, DbTable? sourceTable}) : initialTable = sourceTable {
    src.conn = source;
    tgt.conn = source;
  }

  final DbTable? initialTable;
  bool initialized = false;

  final src = CompareSide();
  final tgt = CompareSide();

  /// Source column names used as key (in order).
  List<String> keyColumns = [];

  /// Source column names compared (lowercase lookup through [CompareSide.column]).
  List<String> compareColumns = [];

  bool trimStrings = true;
  bool ignoreCase = false;
  bool nullEqualsEmpty = false;
  bool normalizeDates = true;
  bool orderIndependent = false;
  bool _orderTouched = false;
  final tolerance = TextEditingController(text: '0');
  final rowCap = TextEditingController(text: '$_defaultRowCap');

  bool running = false;
  bool _cancel = false;
  int readSource = 0;
  int readTarget = 0;
  String? note;
  Object? error;
  CompareResult? result;
  bool stale = false;
  List<String> resultTargetColumns = const [];
  List<int?> resultTargetTypes = const [];
  DbConnection? resultTarget;
  DbTable? resultTargetTable;
  Set<RowDiff> filter = {RowDiff.different, RowDiff.onlySource, RowDiff.onlyTarget};
  final List<_DbRowSource> _open = [];

  @override
  String get title => 'Confronto dati';

  @override
  String get tooltip {
    final a = src.table, b = tgt.table;
    if (a == null || b == null) return title;
    return 'Confronto dati: ${src.conn?.config.name}/${a.displayPath} → ${tgt.conn?.config.name}/${b.displayPath}';
  }

  @override
  IconData get icon => AppIcons.compare;

  @override
  DbConnection? get connection => src.conn;

  @override
  Widget buildView(BuildContext context) => _DataCompareView(tab: this);

  @override
  Future<bool> canClose(BuildContext context) async {
    if (!running) return true;
    final ok = await confirmDialog(
      context,
      'Confronto in corso',
      'Interrompere il confronto e chiudere la scheda?',
      ok: 'Interrompi',
    );
    if (ok) cancel();
    return ok;
  }

  @override
  void dispose() {
    cancel();
    src.where.dispose();
    tgt.where.dispose();
    tolerance.dispose();
    rowCap.dispose();
    super.dispose();
  }

  void cancel() {
    _cancel = true;
    for (final s in _open) {
      s.cancel();
    }
  }

  // -------------------------------------------------------------------------
  // Configuration
  // -------------------------------------------------------------------------

  static String? _pick(List<String> list, List<String?> preferred) {
    for (final p in preferred) {
      if (p == null) continue;
      for (final x in list) {
        if (x.toLowerCase() == p.toLowerCase()) return x;
      }
    }
    return list.isEmpty ? null : list.first;
  }

  void _updateOrderDefault() {
    if (!_orderTouched) orderIndependent = src.conn != null && tgt.conn != null && src.conn != tgt.conn;
  }

  void setOrderIndependent(bool v) {
    _orderTouched = true;
    orderIndependent = v;
    notifyListeners();
  }

  /// Selects the connection of [side] (already connected) and loads its
  /// catalogs, schemas and tables. [preferTable] is selected when present,
  /// otherwise a table with the same name as the other side.
  Future<void> setConnection(CompareSide side, DbConnection dc, {DbTable? preferTable}) async {
    side.conn = dc;
    side.loading = true;
    side.error = null;
    _updateOrderDefault();
    notifyListeners();
    try {
      final md = dc.metadata!;
      final other = identical(side, src) ? tgt : src;
      final ref = preferTable ?? other.table;
      side.catalogs = md.supportsCatalogs ? await md.catalogs() : const [];
      side.catalog = side.catalogs.isEmpty
          ? null
          : _pick(side.catalogs, [preferTable?.catalog, other.catalog, md.currentCatalog]);
      await _loadSchemas(side, ref);
      await _loadTables(side, ref?.name);
    } catch (e) {
      side.error = e.toString();
    } finally {
      side.loading = false;
      notifyListeners();
    }
  }

  Future<void> _loadSchemas(CompareSide side, DbTable? ref) async {
    final md = side.conn!.metadata!;
    final other = identical(side, src) ? tgt : src;
    side.schemas = md.supportsSchemas ? await md.schemas(side.catalog) : const [];
    side.schema = side.schemas.isEmpty
        ? null
        : _pick(side.schemas, [ref?.schema, other.schema, 'dbo', 'public', side.conn!.config.user]);
  }

  Future<void> _loadTables(CompareSide side, String? preferName) async {
    final md = side.conn!.metadata!;
    side.tables = await md.tables(side.catalog, side.schema);
    DbTable? t;
    if (preferName != null) {
      final l = preferName.toLowerCase();
      for (final x in side.tables) {
        if (x.name.toLowerCase() == l) {
          t = x;
          break;
        }
      }
    }
    await _setTable(side, t);
  }

  Future<void> setCatalog(CompareSide side, String? catalog) => _guard(side, () async {
    side.catalog = catalog;
    await _loadSchemas(side, side.table);
    await _loadTables(side, side.table?.name);
  });

  Future<void> setSchema(CompareSide side, String? schema) => _guard(side, () async {
    side.schema = schema;
    await _loadTables(side, side.table?.name);
  });

  Future<void> setTable(CompareSide side, DbTable? t) => _guard(side, () async {
    await _setTable(side, t);
    // Choosing the source table proposes the same table on the target.
    if (identical(side, src) && t != null && tgt.conn != null && tgt.tables.isNotEmpty) {
      final match = tgt.tables.where((x) => x.name.toLowerCase() == t.name.toLowerCase());
      if (match.isNotEmpty && tgt.table != match.first) await _setTable(tgt, match.first);
    }
  });

  Future<void> _guard(CompareSide side, Future<void> Function() f) async {
    side.loading = true;
    side.error = null;
    notifyListeners();
    try {
      await f();
    } catch (e) {
      side.error = e.toString();
    } finally {
      side.loading = false;
      notifyListeners();
    }
  }

  Future<void> _setTable(CompareSide side, DbTable? t) async {
    side.table = t;
    side.columns = const [];
    side.primaryKey = null;
    side.indexes = const [];
    if (t != null) {
      final md = side.conn!.metadata!;
      side.columns = await md.columns(t);
      side.primaryKey = await md.primaryKey(t);
      try {
        side.indexes = await md.indexes(t);
      } catch (_) {}
    }
    _defaultColumns();
  }

  /// Source columns that also exist in the target (case-insensitive).
  List<DbColumn> get commonColumns => [
    for (final c in src.columns)
      if (tgt.column(c.name) != null) c,
  ];

  List<String> get onlySourceColumns => [
    for (final c in src.columns)
      if (tgt.column(c.name) == null) c.name,
  ];

  List<String> get onlyTargetColumns => [
    for (final c in tgt.columns)
      if (src.column(c.name) == null) c.name,
  ];

  void _defaultColumns() {
    final common = commonColumns;
    final names = {for (final c in common) c.name.toLowerCase()};
    List<String>? keys;
    final pk = src.primaryKey?.columns ?? tgt.primaryKey?.columns;
    if (pk != null && pk.isNotEmpty && pk.every((k) => names.contains(k.toLowerCase()))) {
      keys = [for (final k in pk) src.column(k)?.name ?? k];
    } else {
      for (final ix in [...src.indexes, ...tgt.indexes]) {
        if (ix.unique && ix.columns.isNotEmpty && ix.columns.every((k) => names.contains(k.toLowerCase()))) {
          keys = [for (final k in ix.columns) src.column(k)?.name ?? k];
          break;
        }
      }
    }
    keyColumns = keys ?? [];
    final keySet = {for (final k in keyColumns) k.toLowerCase()};
    compareColumns = [
      for (final c in common)
        if (!keySet.contains(c.name.toLowerCase())) c.name,
    ];
  }

  void toggleKey(String name) {
    final l = name.toLowerCase();
    if (keyColumns.any((k) => k.toLowerCase() == l)) {
      keyColumns = keyColumns.where((k) => k.toLowerCase() != l).toList();
      if (!compareColumns.any((c) => c.toLowerCase() == l)) compareColumns = [...compareColumns, name];
    } else {
      keyColumns = [...keyColumns, name];
      compareColumns = compareColumns.where((c) => c.toLowerCase() != l).toList();
    }
    notifyListeners();
  }

  void toggleCompare(String name, bool on) {
    final l = name.toLowerCase();
    compareColumns = compareColumns.where((c) => c.toLowerCase() != l).toList();
    if (on) {
      // Keep the table order.
      final order = {for (final (i, c) in src.columns.indexed) c.name.toLowerCase(): i};
      compareColumns = [...compareColumns, name]
        ..sort((a, b) => order[a.toLowerCase()]!.compareTo(order[b.toLowerCase()]!));
    }
    notifyListeners();
  }

  void setAllCompared(bool on) {
    final keys = {for (final k in keyColumns) k.toLowerCase()};
    compareColumns = on
        ? [
            for (final c in commonColumns)
              if (!keys.contains(c.name.toLowerCase())) c.name,
          ]
        : [];
    notifyListeners();
  }

  void setOption(void Function() change) {
    change();
    notifyListeners();
  }

  int get rowCapValue => int.tryParse(rowCap.text.trim()) ?? _defaultRowCap;

  String? validate() {
    if (src.table == null) return 'Scegli la tabella di origine';
    if (tgt.table == null) return 'Scegli la tabella di destinazione';
    if (src.conn == tgt.conn && src.table == tgt.table && src.where.text.trim() == tgt.where.text.trim()) {
      return 'Origine e destinazione coincidono';
    }
    if (keyColumns.isEmpty) return 'Scegli le colonne chiave che identificano le righe';
    return null;
  }

  // -------------------------------------------------------------------------
  // Execution
  // -------------------------------------------------------------------------

  String _select(CompareSide side, List<String> cols, bool ordered) {
    final d = side.conn!.dialect;
    final w = side.where.text.trim();
    final keys = cols.take(keyColumns.length).map(d.quoteIdent).join(', ');
    return 'SELECT ${cols.map(d.quoteIdent).join(', ')} FROM ${d.tableName(side.table!)}'
        '${w.isEmpty ? '' : ' WHERE ($w)'}'
        '${ordered ? ' ORDER BY $keys' : ''}';
  }

  static ValueKind _kind(ColumnInfo? a, ColumnInfo? b) {
    bool any(bool Function(ColumnInfo) f) => (a != null && f(a)) || (b != null && f(b));
    if (any((c) => c.isBinary)) return ValueKind.binary;
    if (any((c) => temporalKindOf(c.sqlType) != null)) return ValueKind.temporal;
    if (any((c) => c.isNumeric)) return ValueKind.numeric;
    return ValueKind.text;
  }

  Future<void> run() async {
    if (running) return;
    final srcNames = [...keyColumns, ...compareColumns];
    final tgtNames = [for (final n in srcNames) tgt.column(n)?.name ?? n];
    running = true;
    _cancel = false;
    readSource = readTarget = 0;
    error = null;
    note = null;
    result = null;
    stale = false;
    notifyListeners();
    final options = CompareOptions(
      trimStrings: trimStrings,
      ignoreCase: ignoreCase,
      nullEqualsEmpty: nullEqualsEmpty,
      normalizeDates: normalizeDates,
      floatTolerance: double.tryParse(tolerance.text.trim().replaceAll(',', '.')) ?? 0,
    );
    var hash = orderIndependent;
    try {
      while (true) {
        final a = _DbRowSource(src.conn!, _select(src, srcNames, !hash));
        final b = _DbRowSource(tgt.conn!, _select(tgt, tgtNames, !hash));
        _open
          ..clear()
          ..addAll([a, b]);
        try {
          final infos = await Future.wait([a.open(), b.open()]);
          final ia = infos[0], ib = infos[1];
          final kinds = [
            for (var i = 0; i < srcNames.length; i++) _kind(i < ia.length ? ia[i] : null, i < ib.length ? ib[i] : null),
          ];
          final cmp = DataComparer(
            columns: srcNames,
            keyCount: keyColumns.length,
            kinds: kinds,
            options: options,
            rowCap: max(0, rowCapValue),
            isCancelled: () => _cancel,
            onProgress: (s, t) {
              readSource = s;
              readTarget = t;
              notifyListeners();
            },
          );
          final r = hash ? await cmp.hashJoin(a, b) : await cmp.mergeJoin(a, b);
          result = r;
          resultTargetColumns = tgtNames;
          resultTargetTypes = [for (var i = 0; i < tgtNames.length; i++) i < ib.length ? ib[i].sqlType : null];
          resultTarget = tgt.conn;
          resultTargetTable = tgt.table;
          break;
        } on CompareOrderException catch (e) {
          // Collations differ: repeat order independently.
          note = '$e Il confronto è stato ripetuto in memoria (ordinamento indipendente dal DB).';
          hash = true;
          readSource = readTarget = 0;
          notifyListeners();
        } finally {
          await Future.wait([a.close(), b.close()]);
          _open.clear();
        }
      }
    } on CompareCancelledException {
      error = null;
      note = 'Confronto interrotto.';
    } catch (e) {
      error = _cancel ? null : e;
      if (_cancel) note = 'Confronto interrotto.';
    } finally {
      running = false;
      notifyListeners();
    }
  }
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

class _DataCompareView extends StatefulWidget {
  const _DataCompareView({required this.tab});
  final DataCompareTab tab;

  @override
  State<_DataCompareView> createState() => _DataCompareViewState();
}

/// A display line of the results grid: a row, or one of the two lines
/// (source / target) of a differing row.
typedef _Line = ({int row, bool targetLine});

class _DataCompareViewState extends State<_DataCompareView> {
  DataCompareTab get tab => widget.tab;
  CompareResult? _linesFor;
  Set<RowDiff>? _linesFilter;
  List<_Line> _lines = const [];
  List<double> _widths = const [];
  List<bool> _numeric = const [];

  @override
  void initState() {
    super.initState();
    tab.addListener(_changed);
    if (!tab.initialized) {
      tab.initialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _init());
    }
  }

  @override
  void dispose() {
    tab.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    final dc = tab.src.conn;
    if (dc == null || !mounted) return;
    if (!await ensureConnected(context, dc)) return;
    await tab.setConnection(tab.src, dc, preferTable: tab.initialTable);
    await tab.setConnection(tab.tgt, dc, preferTable: tab.initialTable);
  }

  Future<void> _chooseConnection(CompareSide side, DbConnection? dc) async {
    if (dc == null) return;
    if (!await ensureConnected(context, dc)) return;
    if (!dc.dialect.isSql) {
      if (mounted) showToast(context, 'Il confronto dati richiede un database SQL', error: true);
      return;
    }
    await tab.setConnection(side, dc);
  }

  Future<void> _run() async {
    final err = tab.validate();
    if (err != null) {
      showToast(context, err, error: true);
      return;
    }
    for (final dc in [tab.src.conn!, tab.tgt.conn!]) {
      if (!await ensureConnected(context, dc)) return;
    }
    await tab.run();
  }

  void _sync() {
    final r = tab.result, t = tab.resultTarget, tt = tab.resultTargetTable;
    if (r == null || t == null || tt == null) return;
    showSyncScriptDialog(
      context,
      target: t,
      targetTable: tt,
      result: r,
      targetColumns: tab.resultTargetColumns,
      targetTypes: tab.resultTargetTypes,
      onExecuted: () => tab.setOption(() => tab.stale = true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(c),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Inspector-style configuration pane.
              Container(
                width: 320,
                decoration: BoxDecoration(
                  color: c.windowBackground,
                  border: Border(right: BorderSide(color: c.separator, width: 0.5)),
                ),
                child: AbsorbPointer(absorbing: tab.running, child: _config(c)),
              ),
              Expanded(child: _results(c)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolbar(DbColors c) {
    final r = tab.result;
    return PaneBar(
      loading: tab.running,
      children: [
        if (tab.running)
          PushButton(
            label: 'Interrompi',
            icon: AppIcons.stop,
            kind: PushButtonKind.destructive,
            size: ControlScale.small,
            onPressed: tab.cancel,
          )
        else
          PushButton.primary(
            label: 'Confronta',
            icon: AppIcons.compare,
            size: ControlScale.small,
            tooltip: 'Legge le due tabelle e confronta le righe per chiave',
            onPressed: _run,
          ),
        const SizedBox(width: Gap.xs),
        ToolButton(
          icon: AppIcons.sync,
          label: 'Script di sincronizzazione',
          tooltip: 'Genera INSERT / UPDATE / DELETE per allineare la destinazione all\'origine',
          onPressed: r == null || tab.running || r.inSync ? null : _sync,
        ),
        const ToolSeparator(),
        Expanded(
          child: Text(
            tab.running
                ? 'Lettura: ${_n(tab.readSource)} righe origine · ${_n(tab.readTarget)} righe destinazione…'
                : r == null
                ? ''
                : '${_n(r.sourceRows)} righe origine · ${_n(r.targetRows)} righe destinazione · '
                      '${(r.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s · '
                      '${r.hashJoin ? 'confronto in memoria' : 'merge ordinato'}',
            overflow: TextOverflow.ellipsis,
            style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular),
          ),
        ),
      ],
    );
  }

  static String _n(int v) {
    final s = v.toString();
    final sb = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) sb.write('.');
      sb.write(s[i]);
    }
    return sb.toString();
  }

  // -------------------------------------------------------------------------
  // Configuration panel
  // -------------------------------------------------------------------------

  Widget _dropdown<T>(T? value, List<T> items, String Function(T) label, ValueChanged<T?>? onChanged, {String? hint}) =>
      PopUpButton<T?>(
        value: items.contains(value) ? value : null,
        expand: true,
        placeholder: hint,
        items: [for (final x in items) (x, label(x), null)],
        onChanged: onChanged,
      );

  Widget _side(DbColors c, String title, CompareSide side) {
    final app = AppScope.of(context);
    final md = side.conn?.metadata;
    final enabled = !side.loading;
    return FormGroup(
      title: title,
      footer: side.error,
      children: [
        FormRow(
          label: 'Connessione',
          child: Row(
            children: [
              Expanded(
                child: _dropdown<DbConnection>(
                  side.conn,
                  app.connections,
                  (x) => x.config.name,
                  enabled ? (v) => _chooseConnection(side, v) : null,
                  hint: 'Scegli…',
                ),
              ),
              if (side.loading) ...[const SizedBox(width: Gap.sm), const Spinner(size: Spinner.small)],
            ],
          ),
        ),
        if (md != null && side.catalogs.isNotEmpty)
          FormRow(
            label: md.catalogTerm,
            child: _dropdown<String>(
              side.catalog,
              side.catalogs,
              (x) => x,
              enabled ? (v) => tab.setCatalog(side, v) : null,
            ),
          ),
        if (md != null && side.schemas.isNotEmpty)
          FormRow(
            label: md.schemaTerm,
            child: _dropdown<String>(
              side.schema,
              side.schemas,
              (x) => x,
              enabled ? (v) => tab.setSchema(side, v) : null,
            ),
          ),
        FormRow(
          label: 'Tabella',
          child: _dropdown<DbTable>(
            side.table,
            side.tables,
            (x) => x.isView ? '${x.name} (vista)' : x.name,
            enabled && side.conn != null ? (v) => tab.setTable(side, v) : null,
            hint: side.conn == null ? 'Scegli prima la connessione' : 'Scegli…',
          ),
        ),
        FormRow(
          label: 'Filtro',
          help: 'Condizione WHERE',
          child: MacTextField(controller: side.where, mono: true, hint: 'es. data >= \'2024-01-01\''),
        ),
      ],
    );
  }

  Widget _columnsGroup(DbColors c) {
    final common = tab.commonColumns;
    if (common.isEmpty) {
      return FormGroup(
        title: 'Colonne',
        children: [
          Text(
            tab.src.table == null || tab.tgt.table == null
                ? 'Scegli le due tabelle per vedere le colonne in comune.'
                : 'Le tabelle non hanno colonne con lo stesso nome.',
            style: uiText(TypeSize.small, color: c.textSecondary),
          ),
        ],
      );
    }
    final keys = {for (final k in tab.keyColumns) k.toLowerCase()};
    final cmp = {for (final k in tab.compareColumns) k.toLowerCase()};
    final onlyS = tab.onlySourceColumns, onlyT = tab.onlyTargetColumns;
    return FormGroup(
      title: 'Colonne',
      footer: [
        'Chiave: ${tab.keyColumns.isEmpty ? 'nessuna (scegline almeno una)' : tab.keyColumns.join(', ')}',
        if (onlyS.isNotEmpty) 'Solo in origine: ${onlyS.join(', ')}',
        if (onlyT.isNotEmpty) 'Solo in destinazione: ${onlyT.join(', ')}',
      ].join('\n'),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${cmp.length} di ${common.length - keys.length} confrontate',
                style: uiText(TypeSize.small, color: c.textSecondary),
              ),
            ),
            ToolButton(icon: AppIcons.doneAll, tooltip: 'Seleziona tutte', onPressed: () => tab.setAllCompared(true)),
            ToolButton(
              icon: AppIcons.deselectAll,
              tooltip: 'Deseleziona tutte',
              onPressed: () => tab.setAllCompared(false),
            ),
          ],
        ),
        for (final col in common)
          SizedBox(
            height: ControlSize.regular,
            child: Row(
              children: [
                MacCheckbox(
                  value: keys.contains(col.name.toLowerCase()) || cmp.contains(col.name.toLowerCase()),
                  semanticLabel: col.name,
                  onChanged: keys.contains(col.name.toLowerCase()) ? null : (v) => tab.toggleCompare(col.name, v),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    col.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(TypeSize.body, color: c.text),
                  ),
                ),
                const SizedBox(width: 6),
                TypeLabel(col.fullType.toLowerCase()),
                const Spacer(),
                ToolButton(
                  icon: AppIcons.key,
                  extent: 18,
                  active: keys.contains(col.name.toLowerCase()),
                  tooltip: keys.contains(col.name.toLowerCase()) ? 'Rimuovi dalla chiave' : 'Usa come colonna chiave',
                  onPressed: () => tab.toggleKey(col.name),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _checkRow(String label, bool value, ValueChanged<bool> onChanged, {String? help}) =>
      CheckboxRow(label: label, help: help, value: value, onChanged: (v) => tab.setOption(() => onChanged(v)));

  Widget _config(DbColors c) {
    final cap = tab.rowCapValue;
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        _side(c, 'Origine', tab.src),
        _side(c, 'Destinazione', tab.tgt),
        _columnsGroup(c),
        FormGroup(
          title: 'Opzioni',
          footer: cap <= 0 || cap > _defaultRowCap
              ? 'Oltre ${_n(_defaultRowCap)} righe per lato il confronto può richiedere molta memoria e tempo.'
              : null,
          children: [
            _checkRow('Ignora spazi iniziali e finali', tab.trimStrings, (v) => tab.trimStrings = v),
            _checkRow('Ignora maiuscole/minuscole', tab.ignoreCase, (v) => tab.ignoreCase = v),
            _checkRow('NULL uguale a stringa vuota', tab.nullEqualsEmpty, (v) => tab.nullEqualsEmpty = v),
            _checkRow(
              'Normalizza date e ore',
              tab.normalizeDates,
              (v) => tab.normalizeDates = v,
              help: '2024-01-02 00:00:00 = 2024-01-02',
            ),
            CheckboxRow(
              label: 'Ordinamento indipendente dal DB',
              help: 'Confronto in memoria: necessario con collation diverse',
              value: tab.orderIndependent,
              onChanged: tab.setOrderIndependent,
            ),
            FormRow(
              label: 'Tolleranza numerica',
              child: Align(
                alignment: Alignment.centerRight,
                child: NumberField(controller: tab.tolerance, min: 0, step: 0.01, decimals: 4),
              ),
            ),
            FormRow(
              label: 'Righe massime per lato',
              help: '0 = nessun limite',
              child: Align(
                alignment: Alignment.centerRight,
                child: NumberField(
                  controller: tab.rowCap,
                  min: 0,
                  step: 10000,
                  width: 100,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Results
  // -------------------------------------------------------------------------

  Color _kindColor(DbColors c, RowDiff k) => switch (k) {
    RowDiff.identical => c.textTertiary,
    RowDiff.different => c.warning,
    RowDiff.onlySource => c.success,
    RowDiff.onlyTarget => c.danger,
  };

  void _computeLines(CompareResult r) {
    if (identical(_linesFor, r) &&
        _linesFilter != null &&
        _linesFilter!.length == tab.filter.length &&
        _linesFilter!.containsAll(tab.filter)) {
      return;
    }
    _linesFor = r;
    _linesFilter = {...tab.filter};
    final out = <_Line>[];
    for (var i = 0; i < r.rows.length; i++) {
      final k = r.rows[i].kind;
      if (!tab.filter.contains(k)) continue;
      out.add((row: i, targetLine: false));
      if (k == RowDiff.different) out.add((row: i, targetLine: true));
    }
    _lines = out;
    // Column widths from the names and a sample of values.
    final widths = <double>[];
    for (var j = 0; j < r.columns.length; j++) {
      var w = r.columns[j].length * 7.5 + 28;
      for (var i = 0; i < min(200, r.rows.length); i++) {
        final v = formatValue(r.rows[i].values[j], nullText: 'NULL', maxLen: 40);
        w = max(w, v.length * 7.2 + 16);
      }
      widths.add(w.clamp(70, 280).toDouble());
    }
    _widths = widths;
    _numeric = [
      for (var j = 0; j < r.columns.length; j++)
        r.rows.take(200).map((x) => x.values[j]).firstWhere((v) => v != null, orElse: () => null) is num,
    ];
  }

  Widget _banner(NoticeKind kind, String text, {Widget? action}) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
    child: Notice(kind: kind, message: text, actions: [?action]),
  );

  Widget _results(DbColors c) {
    final r = tab.result;
    if (tab.error != null) {
      return EmptyState.error(
        tab.error!,
        title: 'Confronto non riuscito',
        action: PushButton(label: 'Riprova', onPressed: _run),
      );
    }
    if (r == null) {
      if (tab.running) {
        return EmptyState(
          icon: AppIcons.hourglass,
          title: 'Confronto in corso…',
          message:
              '${_n(tab.readSource)} righe lette dall\'origine, ${_n(tab.readTarget)} dalla destinazione.'
              '${tab.note == null ? '' : '\n${tab.note}'}',
        );
      }
      return EmptyState(
        icon: AppIcons.compare,
        title: tab.note ?? 'Confronta i dati di due tabelle',
        message:
            'Scegli origine e destinazione (anche su connessioni diverse), le colonne chiave e premi Confronta. '
            'Potrai poi generare lo script che allinea la destinazione.',
      );
    }
    _computeLines(r);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: ScopeBar<RowDiff>(
            items: [for (final k in RowDiff.values) ScopeItem(k, k.plural, dot: _kindColor(c, k), count: r.count(k))],
            selected: tab.filter,
            onChanged: (v) => tab.setOption(() => tab.filter = v),
          ),
        ),
        if (tab.stale)
          _banner(
            NoticeKind.info,
            'La destinazione è stata modificata: i risultati non sono aggiornati.',
            action: PushButton(
              label: 'Ricalcola',
              size: ControlScale.small,
              tooltip: 'Ripeti il confronto',
              onPressed: _run,
            ),
          ),
        if (r.truncated)
          _banner(
            NoticeKind.warning,
            'Raggiunto il limite di ${_n(tab.rowCapValue)} righe per lato: il confronto copre solo una parte dei dati.',
          ),
        if (tab.note != null) _banner(NoticeKind.info, tab.note!),
        Expanded(
          child: r.inSync && !tab.filter.contains(RowDiff.identical)
              ? const EmptyState(
                  icon: AppIcons.checkCircle,
                  title: 'Le tabelle sono allineate',
                  message: 'Tutte le righe confrontate sono identiche.',
                )
              : _lines.isEmpty
              ? const EmptyState(
                  icon: AppIcons.filterOff,
                  title: 'Nessuna riga con questi filtri',
                  message: 'Attiva le categorie da mostrare con i contatori qui sopra.',
                )
              : _grid(c, r),
        ),
      ],
    );
  }

  Widget _grid(DbColors c, CompareResult r) {
    final headers = ['Stato', ...r.columns];
    return MacTable(
      headers: headers,
      rowCount: _lines.length,
      resizable: true,
      zebra: false,
      // Both lines of a differing row share the zebra stripe.
      rowTint: (i) => _lines[i].row.isOdd ? c.zebra : c.content,
      rowStatus: (i) => _lines[i].targetLine ? null : _kindColor(c, r.rows[_lines[i].row].kind),
      types: (j) => j > 0 && j <= r.keyCount ? 'chiave' : null,
      width: (j) => j == 0 ? 150 : _widths[j - 1],
      numeric: (j) => j > 0 && _numeric[j - 1],
      cell: (i, j) => j == 0 ? _status(_lines[i], r) : _text(_values(_lines[i], r)[j - 1]),
      cellBuilder: (context, i, j) {
        final l = _lines[i];
        final row = r.rows[l.row];
        if (j == 0) {
          return Text(
            _status(l, r),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: uiText(
              TypeSize.small,
              color: row.kind == RowDiff.different && l.targetLine ? c.textSecondary : _kindColor(c, row.kind),
              weight: l.targetLine ? null : FontWeight.w500,
            ),
          );
        }
        final v = _values(l, r)[j - 1];
        final cell = _cell(c, v, dim: l.targetLine && j - 1 < r.keyCount);
        if (!row.diffColumns.contains(j - 1)) return cell;
        // Changed value: a diffChanged tint behind the text.
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: c.diffChanged.withValues(alpha: Tint.strong),
            borderRadius: BorderRadius.circular(Radii.small),
          ),
          child: cell,
        );
      },
    );
  }

  List<Object?> _values(_Line l, CompareResult r) {
    final row = r.rows[l.row];
    return l.targetLine ? row.target! : (row.source ?? row.target!);
  }

  String _status(_Line l, CompareResult r) {
    final k = r.rows[l.row].kind;
    if (k != RowDiff.different) return k.singular;
    return l.targetLine ? 'destinazione' : 'Diverso · origine';
  }

  static String _text(Object? v) => v == null ? 'NULL' : formatValue(v, maxLen: 200).replaceAll('\n', ' ');

  Widget _cell(DbColors c, Object? v, {bool dim = false}) {
    if (v == null) {
      return Text(
        'NULL',
        style: uiText(TypeSize.body, color: c.textTertiary).copyWith(fontStyle: FontStyle.italic),
      );
    }
    return Text(
      _text(v),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: uiText(TypeSize.body, color: dim ? c.textTertiary : c.text, features: kTabular),
    );
  }
}
