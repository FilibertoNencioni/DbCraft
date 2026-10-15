import 'package:flutter/foundation.dart';

import '../model/db_objects.dart';
import '../odbc/odbc_types.dart';
import 'db_connection.dart';

/// A row of the result set with its editing state.
class ResultRow {
  ResultRow(this.values, {this.inserted = false});
  List<Object?> values;

  /// Original values before editing (null if unchanged).
  List<Object?>? original;
  bool inserted;
  bool deleted = false;
  final Set<int> changedCells = {};

  bool get isDirty => inserted || deleted || changedCells.isNotEmpty;
}

/// Data behind a results grid: paging, client side sort/filter and editing
/// (UPDATE / INSERT / DELETE generated from the key columns).
class ResultSetModel extends ChangeNotifier {
  ResultSetModel({
    required this.connection,
    required ResultPage first,
    required this.sql,
    this.fetchSize = 200,
    this.table,
    this.params = const [],
  }) : columns = first.columns,
       _cursorId = first.cursorId,
       hasMore = first.hasMore,
       elapsedMs = first.elapsedMs,
       hasNextResultSet = first.hasNextResultSet {
    rows.addAll(first.rows.map(ResultRow.new));
    _rebuildView();
  }

  final DbConnection connection;
  final String sql;
  final List<Object?> params;
  final int fetchSize;
  final List<ColumnInfo> columns;
  final List<ResultRow> rows = [];
  int? _cursorId;
  bool hasMore;
  bool hasNextResultSet;
  int elapsedMs;
  bool loading = false;
  String? error;

  /// Source table (for editing). Detected from the query or provided by the
  /// table data editor.
  DbTable? table;
  List<String> keyColumns = [];
  bool keyIsVirtual = false;

  // View state
  int? sortColumn;
  bool sortAscending = true;
  String quickFilter = '';
  List<int> view = [];

  int? get cursorId => _cursorId;

  bool get isEditable => table != null && keyColumns.isNotEmpty && !connection.config.readOnly;

  bool get isDirty => rows.any((r) => r.isDirty);

  int get changeCount => rows.where((r) => r.isDirty).length;

  // -------------------------------------------------------------------------
  // Paging
  // -------------------------------------------------------------------------

  Future<void> fetchNext({int? count}) async {
    final id = _cursorId;
    final s = connection.main;
    if (id == null || !hasMore || loading || s == null) return;
    loading = true;
    notifyListeners();
    try {
      final p = await s.fetchMore(id, count ?? fetchSize);
      rows.addAll(p.rows.map(ResultRow.new));
      hasMore = p.hasMore;
      hasNextResultSet = p.hasNextResultSet;
      if (p.cursorId == null) _cursorId = null;
      _rebuildView();
    } catch (e) {
      error = e.toString();
      hasMore = false;
      _cursorId = null;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> fetchAll() => fetchNext(count: 0);

  /// Returns the next result set produced by the same statement.
  Future<ResultPage?> nextResultSet() async {
    final id = _cursorId;
    final s = connection.main;
    if (id == null || s == null) return null;
    _cursorId = null;
    hasNextResultSet = false;
    notifyListeners();
    return s.nextResultSet(id, fetchSize);
  }

  Future<void> close() async {
    final id = _cursorId;
    _cursorId = null;
    if (id != null) {
      try {
        await connection.main?.closeCursor(id);
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------------
  // View (sort + filter)
  // -------------------------------------------------------------------------

  void setSort(int column) {
    if (sortColumn == column) {
      if (sortAscending) {
        sortAscending = false;
      } else {
        sortColumn = null;
        sortAscending = true;
      }
    } else {
      sortColumn = column;
      sortAscending = true;
    }
    _rebuildView();
    notifyListeners();
  }

  void sortBy(int? column, {bool ascending = true}) {
    sortColumn = column;
    sortAscending = ascending;
    _rebuildView();
    notifyListeners();
  }

  void setQuickFilter(String f) {
    quickFilter = f;
    _rebuildView();
    notifyListeners();
  }

  static int compareValues(Object? a, Object? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    if (a is num && b is num) return a.compareTo(b);
    if (a is Uint8List && b is Uint8List) return a.length.compareTo(b.length);
    final na = num.tryParse(a.toString()), nb = num.tryParse(b.toString());
    if (na != null && nb != null) return na.compareTo(nb);
    return a.toString().toLowerCase().compareTo(b.toString().toLowerCase());
  }

  void _rebuildView() {
    final f = quickFilter.trim().toLowerCase();
    final idx = <int>[];
    for (var i = 0; i < rows.length; i++) {
      if (f.isEmpty || rows[i].values.any((v) => v != null && v.toString().toLowerCase().contains(f))) {
        idx.add(i);
      }
    }
    final sc = sortColumn;
    if (sc != null) {
      idx.sort((a, b) {
        final r = compareValues(rows[a].values[sc], rows[b].values[sc]);
        return sortAscending ? r : -r;
      });
    }
    view = idx;
  }

  ResultRow rowAt(int viewIndex) => rows[view[viewIndex]];

  // -------------------------------------------------------------------------
  // Editing
  // -------------------------------------------------------------------------

  /// Resolves the source table and the key columns used for editing.
  Future<void> detectEditTarget() async {
    final md = connection.metadata;
    if (md == null) return;
    if (table == null) {
      // Editable only when every column comes from the same base table
      // (no expressions, aggregates or joins).
      if (columns.any((c) => c.baseTable == null)) return;
      final names = columns.map((c) => c.baseTable!.toLowerCase()).toSet();
      if (names.length != 1) return;
      if (RegExp(r'\b(group\s+by|distinct|union)\b', caseSensitive: false).hasMatch(sql)) return;
      final c0 = columns.firstWhere((c) => c.baseTable != null);
      table =
          await md.findTable(c0.catalog, c0.schema, c0.baseTable!) ??
          await md.findTable(null, null, c0.baseTable!);
      if (table == null) return;
    }
    final pk = await md.primaryKey(table!);
    final names = columns.map((c) => (c.baseColumn ?? c.name).toLowerCase()).toSet();
    if (pk != null && pk.columns.every((k) => names.contains(k.toLowerCase()))) {
      keyColumns = pk.columns;
      keyIsVirtual = false;
    } else {
      // No primary key: use every non-LOB column (DBeaver "virtual key").
      keyColumns = columns.where((c) => !c.isLob).map((c) => c.baseColumn ?? c.name).toList();
      keyIsVirtual = true;
    }
    notifyListeners();
  }

  void setValue(int viewIndex, int col, Object? value) {
    final r = rowAt(viewIndex);
    if (!r.inserted) {
      r.original ??= List.of(r.values);
      if (_eq(r.original![col], value)) {
        r.changedCells.remove(col);
      } else {
        r.changedCells.add(col);
      }
    } else {
      r.changedCells.add(col);
    }
    r.values[col] = value;
    notifyListeners();
  }

  static bool _eq(Object? a, Object? b) {
    if (a is Uint8List && b is Uint8List) return listEquals(a, b);
    return a == b;
  }

  /// Adds a new empty row after [afterViewIndex] (or at the end).
  int addRow({int? afterViewIndex, List<Object?>? values}) {
    final r = ResultRow(values ?? List<Object?>.filled(columns.length, null), inserted: true);
    final at = afterViewIndex == null ? rows.length : view[afterViewIndex] + 1;
    rows.insert(at, r);
    _rebuildView();
    notifyListeners();
    return view.indexOf(at);
  }

  void duplicateRow(int viewIndex) {
    addRow(afterViewIndex: viewIndex, values: List.of(rowAt(viewIndex).values));
  }

  void toggleDelete(Iterable<int> viewIndexes) {
    final toRemove = <ResultRow>[];
    for (final v in viewIndexes) {
      final r = rowAt(v);
      if (r.inserted) {
        toRemove.add(r);
      } else {
        r.deleted = !r.deleted;
      }
    }
    rows.removeWhere(toRemove.contains);
    _rebuildView();
    notifyListeners();
  }

  void cancelChanges() {
    rows.removeWhere((r) => r.inserted);
    for (final r in rows) {
      if (r.original != null) r.values = List.of(r.original!);
      r.original = null;
      r.changedCells.clear();
      r.deleted = false;
    }
    _rebuildView();
    notifyListeners();
  }

  String _colName(int i) => columns[i].baseColumn ?? columns[i].name;

  int _colIndex(String name) =>
      columns.indexWhere((c) => (c.baseColumn ?? c.name).toLowerCase() == name.toLowerCase());

  /// Builds the DML statements (with parameters) for the pending changes.
  List<(String, List<Object?>)> buildChanges() {
    final t = table;
    if (t == null) return [];
    final d = connection.dialect;
    final tn = d.tableName(t);
    final out = <(String, List<Object?>)>[];
    (String, List<Object?>) where(List<Object?> values) {
      final parts = <String>[];
      final params = <Object?>[];
      for (final k in keyColumns) {
        final i = _colIndex(k);
        if (i < 0) continue;
        final v = values[i];
        if (v == null) {
          parts.add('${d.quoteIdent(k)} IS NULL');
        } else {
          parts.add('${d.quoteIdent(k)} = ?');
          params.add(v);
        }
      }
      return (parts.join(' AND '), params);
    }

    for (final r in rows) {
      if (r.deleted && !r.inserted) {
        final (w, p) = where(r.original ?? r.values);
        out.add(('DELETE FROM $tn WHERE $w', p));
      } else if (r.inserted) {
        final cols = <int>[];
        for (var i = 0; i < columns.length; i++) {
          if (r.values[i] != null || r.changedCells.contains(i)) {
            if (columns[i].autoIncrement && r.values[i] == null) continue;
            cols.add(i);
          }
        }
        if (cols.isEmpty) {
          out.add(('INSERT INTO $tn DEFAULT VALUES', []));
        } else {
          out.add((
            'INSERT INTO $tn (${cols.map((i) => d.quoteIdent(_colName(i))).join(', ')}) '
                'VALUES (${cols.map((_) => '?').join(', ')})',
            cols.map((i) => r.values[i]).toList(),
          ));
        }
      } else if (r.changedCells.isNotEmpty) {
        final cols = r.changedCells.toList()..sort();
        final (w, p) = where(r.original ?? r.values);
        out.add((
          'UPDATE $tn SET ${cols.map((i) => '${d.quoteIdent(_colName(i))} = ?').join(', ')} WHERE $w',
          [...cols.map((i) => r.values[i]), ...p],
        ));
      }
    }
    return out;
  }

  /// Persists the pending changes. In auto-commit mode the changes are
  /// applied in a single transaction.
  Future<int> saveChanges() async {
    final s = connection.main;
    if (s == null) throw StateError('Connessione non attiva');
    final changes = buildChanges();
    if (changes.isEmpty) return 0;
    final wasAuto = connection.autoCommit;
    var total = 0;
    try {
      if (wasAuto) await s.setAutoCommit(false);
      for (final (sql, p) in changes) {
        final r = await s.execute(sql, params: p);
        if (keyIsVirtual && r.rowsAffected > 1) {
          throw StateError(
            'L\'istruzione modificherebbe ${r.rowsAffected} righe (nessuna chiave univoca):\n$sql',
          );
        }
        total += r.rowsAffected < 0 ? 0 : r.rowsAffected;
      }
      if (wasAuto) {
        await s.commit();
      } else {
        connection.pendingStatements += changes.length;
        connection.touch();
      }
    } catch (e) {
      if (wasAuto) {
        try {
          await s.rollback();
        } catch (_) {}
      }
      rethrow;
    } finally {
      if (wasAuto) await s.setAutoCommit(true);
    }
    // Accept the new state.
    rows.removeWhere((r) => r.deleted);
    for (final r in rows) {
      r.inserted = false;
      r.original = null;
      r.changedCells.clear();
    }
    _rebuildView();
    notifyListeners();
    return total;
  }
}
