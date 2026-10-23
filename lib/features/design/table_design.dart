// Editing session of one table in the table designer: the definition in the
// database ([TableDesign.original], null for a new table), the wanted one
// ([TableDesign.working]), undo / redo, validation and the DDL that applies
// the difference.

import 'package:flutter/foundation.dart';

import '../../services/sql_dialect.dart';
import '../schema/ddl_builder.dart';
import '../schema/schema_diff.dart';
import '../schema/schema_migration.dart';
import '../schema/schema_model.dart';
import '../schema/schema_snapshot.dart';

/// Name of a constraint or index.
String? constraintName(Object c) => switch (c) {
  PrimaryKeyDef p => p.name,
  UniqueDef u => u.name,
  CheckDef k => k.name,
  ForeignKeyDef f => f.name,
  IndexDef i => i.name,
  _ => null,
};

/// Same constraint or index: by name, or by structure when unnamed.
bool sameConstraint(Object a, Object b) {
  if (a.runtimeType != b.runtimeType) return false;
  final na = constraintName(a), nb = constraintName(b);
  if (na != null && nb != null) return na.toLowerCase() == nb.toLowerCase();
  return switch ((a, b)) {
    (UniqueDef x, UniqueDef y) => x.signature() == y.signature(),
    (CheckDef x, CheckDef y) => x.normalized == y.normalized,
    (ForeignKeyDef x, ForeignKeyDef y) => x.signature() == y.signature(),
    (PrimaryKeyDef _, PrimaryKeyDef _) => true,
    _ => false,
  };
}

/// [t] with [old] replaced by [now] (added when [old] is null, removed when
/// [now] is null).
TableDef replaceConstraint(TableDef t, Object? old, Object? now) {
  List<T> swap<T extends Object>(List<T> items) => [
    for (final x in items)
      if (old == null || !sameConstraint(x, old)) x else if (now != null) now as T,
    if (old == null && now is T) now,
  ];
  final kind = now ?? old!;
  return switch (kind) {
    PrimaryKeyDef _ => t.copyWith(primaryKey: now as PrimaryKeyDef?),
    UniqueDef _ => t.copyWith(uniques: swap(t.uniques)),
    CheckDef _ => t.copyWith(checks: swap(t.checks)),
    ForeignKeyDef _ => t.copyWith(foreignKeys: swap(t.foreignKeys)),
    IndexDef _ => t.copyWith(indexes: swap(t.indexes)),
    _ => t,
  };
}

/// [c] with the columns renamed by [rename] (old → new name) and the ones
/// in [removed] left out; null when no column is left.
Object? _withColumns(Object c, String Function(String) rename, Set<String> removed) {
  List<String> cols(List<String> l) => [
    for (final x in l)
      if (!removed.contains(x)) IndexDef.isExpression(x) ? x : rename(x),
  ];
  switch (c) {
    case PrimaryKeyDef p:
      final l = cols(p.columns);
      return l.isEmpty ? null : p.copyWith(columns: l);
    case UniqueDef u:
      final l = cols(u.columns);
      return l.isEmpty ? null : u.copyWith(columns: l);
    case ForeignKeyDef f:
      // A foreign key loses its meaning without all its columns.
      if (f.columns.any(removed.contains)) return null;
      return f.copyWith(columns: cols(f.columns));
    case IndexDef i:
      final l = cols(i.columns);
      if (l.isEmpty) return null;
      return i.copyWith(
        columns: l,
        descending: {
          for (final d in i.descending)
            if (!removed.contains(d)) rename(d),
        },
        include: cols(i.include),
      );
    default:
      return c;
  }
}

class TableDesign extends ChangeNotifier {
  TableDesign._(this.dialect, this.original, TableDef working) : _working = working {
    _recompute();
  }

  /// Designs the existing table [table] (as read from the database).
  factory TableDesign.existing(SqlDialect dialect, TableDef table) {
    final seeded = table.copyWith(
      originalName: table.name,
      columns: [for (final c in table.columns) c.copyWith(originalName: c.name)],
    );
    return TableDesign._(dialect, table, seeded);
  }

  /// Designs a new table in [catalog].[schema], with an identity "id" key.
  factory TableDesign.create(SqlDialect dialect, {String? catalog, String? schema, String name = ''}) {
    final type = commonTypes(dialect.family).first;
    final t = TableDef(
      catalog: catalog,
      schema: schema,
      name: name,
      columns: [ColumnDef(name: 'id', type: type, nullable: false, autoIncrement: true)],
    );
    final b = DdlBuilder(dialect);
    final pkName = dialect.family == DbFamily.mysql
        ? null
        : b.autoName(t.copyWith(name: name.isEmpty ? 'tabella' : name), ConstraintKind.primaryKey);
    return TableDesign._(
      dialect,
      null,
      t.copyWith(
        primaryKey: PrimaryKeyDef(name: pkName, columns: const ['id']),
      ),
    );
  }

  /// A new table with the structure of [source], named [name]. Constraint
  /// and index names that contain the source table name follow the new
  /// one; the others are generated again (index names are unique per schema
  /// in many DBMS).
  factory TableDesign.copyOf(SqlDialect dialect, TableDef source, String name) {
    final b = DdlBuilder(dialect);
    final base = TableDef(catalog: source.catalog, schema: source.schema, name: name, columns: const []);
    String? rename(String? n, ConstraintKind? kind, List<String> cols, {String? ref, int k = 1}) {
      if (n == null) return null;
      final i = n.toLowerCase().indexOf(source.name.toLowerCase());
      if (i >= 0) return n.replaceRange(i, i + source.name.length, name);
      return b.autoName(base, kind, columns: cols, refTable: ref, n: k);
    }

    final pk = source.primaryKey;
    final t = source.copyWith(
      name: name,
      originalName: null,
      columns: [for (final c in source.columns) c.copyWith(originalName: null, defaultName: null)],
      primaryKey: pk?.copyWith(
        name: dialect.family == DbFamily.mysql ? null : rename(pk.name, ConstraintKind.primaryKey, pk.columns),
      ),
      uniques: [for (final u in source.uniques) u.copyWith(name: rename(u.name, ConstraintKind.unique, u.columns))],
      checks: [
        for (final (i, c) in source.checks.indexed)
          c.copyWith(name: rename(c.name, ConstraintKind.check, const [], k: i + 1)),
      ],
      foreignKeys: [
        for (final f in source.foreignKeys)
          f.copyWith(name: rename(f.name, ConstraintKind.foreignKey, f.columns, ref: f.refTable)),
      ],
      indexes: [for (final x in source.indexes) x.copyWith(name: rename(x.name, null, x.columns))],
    );
    return TableDesign._(dialect, null, t);
  }

  final SqlDialect dialect;

  /// The table in the database; null while it does not exist.
  TableDef? original;

  TableDef _working;
  TableDef get working => _working;

  bool get isNew => original == null;

  /// Foreign keys of other tables referencing this one (dropped and added
  /// back when a referenced key changes). Set by the editor after loading.
  List<IncomingForeignKey> incoming = const [];

  /// Changes left out of the script (ids of [DiffChange]).
  final Set<String> excluded = {};

  final List<TableDef> _undo = [];
  final List<TableDef> _redo = [];
  String? _coalesce;

  SchemaDiff? _diff;
  List<String> _statements = const [];

  SchemaDiff? get diff => _diff;

  /// Changes found by the diff (empty for a new table).
  List<DiffChange> get changes => _diff?.changes ?? const [];

  /// DDL that applies the design (comment-only entries are notes).
  List<String> get statements => _statements;

  bool get isDirty => isNew || changes.isNotEmpty;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Replaces the working definition. Consecutive updates with the same
  /// [coalesce] key (typing in one field) make a single undo step.
  void update(TableDef next, {String? coalesce}) {
    if (coalesce == null || coalesce != _coalesce || _undo.isEmpty) _undo.add(_working);
    if (_undo.length > 200) _undo.removeAt(0);
    _coalesce = coalesce;
    _redo.clear();
    _working = next;
    _recompute();
    notifyListeners();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_working);
    _working = _undo.removeLast();
    _coalesce = null;
    _recompute();
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_working);
    _working = _redo.removeLast();
    _coalesce = null;
    _recompute();
    notifyListeners();
  }

  /// Drops every change.
  void discard() {
    final o = original;
    if (o == null) return;
    _undo.add(_working);
    _redo.clear();
    _working = TableDesign.existing(dialect, o).working;
    excluded.clear();
    _recompute();
    notifyListeners();
  }

  /// After the script ran: [table] (read again from the database) is the
  /// new original. With [keepPending] (some changes were left out of the
  /// script) the working definition stays: its columns already applied are
  /// matched by their new names.
  void saved(TableDef table, {bool keepPending = false}) {
    original = table;
    if (keepPending) {
      _working = _working.copyWith(
        originalName: table.name,
        columns: [
          for (final c in _working.columns) table.column(c.name) != null ? c.copyWith(originalName: c.name) : c,
        ],
      );
    } else {
      _working = TableDesign.existing(dialect, table).working;
      _undo.clear();
      _redo.clear();
    }
    excluded.clear();
    _recompute();
    notifyListeners();
  }

  void setExcluded(String id, bool value) {
    value ? excluded.add(id) : excluded.remove(id);
    _recompute();
    notifyListeners();
  }

  void _recompute() {
    final o = original;
    if (o == null) {
      _diff = null;
      _statements = DdlBuilder(dialect).createTable(_working, withForeignKeys: true);
      return;
    }
    final family = dialect.family;
    final d = SchemaDiff.compare(
      SchemaSnapshot(catalog: o.catalog, schema: o.schema, tables: [_working], family: family),
      SchemaSnapshot(catalog: o.catalog, schema: o.schema, tables: [o], family: family),
      options: const CompareOptions(ignoreCase: false, ignoreComments: false, compareConstraintNames: true),
    );
    _diff = d;
    _statements = SchemaMigration(dialect).generate(
      d,
      options: const MigrationOptions(dropExtra: true, relocate: false),
      excluded: excluded,
      incoming: incoming,
    );
  }

  /// Recomputes the script (after [incoming] changed).
  void refresh() {
    _recompute();
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Columns
  // -------------------------------------------------------------------------

  /// Replaces column [i]; a rename follows into keys, constraints and
  /// indexes.
  void setColumn(int i, ColumnDef c, {String? coalesce}) {
    final cols = List.of(_working.columns);
    final old = cols[i];
    cols[i] = c;
    var t = _working.copyWith(columns: cols);
    if (old.name != c.name) t = _renameInConstraints(t, old.name, c.name);
    update(t, coalesce: coalesce);
  }

  TableDef _renameInConstraints(TableDef t, String from, String to) {
    String r(String x) => x == from ? to : x;
    return _mapConstraints(t, (c) => _withColumns(c, r, const {}));
  }

  TableDef _mapConstraints(TableDef t, Object? Function(Object c) f) {
    final pk = t.primaryKey == null ? null : f(t.primaryKey!) as PrimaryKeyDef?;
    return t.copyWith(
      primaryKey: pk,
      uniques: [for (final u in t.uniques) ?f(u) as UniqueDef?],
      foreignKeys: [for (final x in t.foreignKeys) ?f(x) as ForeignKeyDef?],
      indexes: [for (final x in t.indexes) ?f(x) as IndexDef?],
    );
  }

  /// Name for a new column: "colonna", "colonna_2"…
  String _freeColumnName() {
    final taken = {for (final c in _working.columns) c.name.toLowerCase()};
    var n = 'colonna';
    for (var i = 2; taken.contains(n); i++) {
      n = 'colonna_$i';
    }
    return n;
  }

  /// Adds a column at the end (or after [after]); returns its index.
  int addColumn({ColumnDef? column, int? after}) {
    final c = column ?? ColumnDef(name: _freeColumnName(), type: _defaultType());
    final cols = List.of(_working.columns);
    final at = after == null ? cols.length : after + 1;
    cols.insert(at, c);
    update(_working.copyWith(columns: cols));
    return at;
  }

  String _defaultType() {
    final types = commonTypes(dialect.family);
    return types.firstWhere((t) => canonicalType(t) == 'varchar', orElse: () => types.first);
  }

  /// Removes column [i] and its traces in keys, constraints and indexes
  /// (a foreign key using it is dropped).
  void removeColumn(int i) {
    final name = _working.columns[i].name;
    final cols = List.of(_working.columns)..removeAt(i);
    update(_mapConstraints(_working.copyWith(columns: cols), (c) => _withColumns(c, (x) => x, {name})));
  }

  void moveColumn(int from, int to) {
    final cols = List.of(_working.columns);
    final c = cols.removeAt(from);
    cols.insert(to, c);
    update(_working.copyWith(columns: cols));
  }

  /// Columns of the database table removed in the design.
  List<ColumnDef> get removedColumns {
    final o = original;
    if (o == null) return const [];
    final kept = {for (final c in _working.columns) (c.originalName ?? '').toLowerCase()};
    return [
      for (final c in o.columns)
        if (!kept.contains(c.name.toLowerCase())) c,
    ];
  }

  /// Brings back the removed database column [c].
  void restoreColumn(ColumnDef c) {
    final cols = [..._working.columns, c.copyWith(originalName: c.name)];
    update(_working.copyWith(columns: cols));
  }

  /// Makes column [name] part of the primary key, or takes it out.
  void togglePrimaryKey(String name, bool on) {
    final pk = _working.primaryKey;
    final cols = [...?pk?.columns];
    if (on && !cols.contains(name)) cols.add(name);
    if (!on) cols.remove(name);
    final now = cols.isEmpty
        ? null
        : (pk ??
                  PrimaryKeyDef(
                    name: dialect.family == DbFamily.mysql
                        ? null
                        : DdlBuilder(dialect).autoName(_working, ConstraintKind.primaryKey),
                    columns: cols,
                  ))
              .copyWith(columns: cols);
    // Key columns are NOT NULL.
    final columns = [for (final c in _working.columns) on && c.name == name ? c.copyWith(nullable: false) : c];
    update(_working.copyWith(primaryKey: now, columns: columns));
  }

  /// Replaces a constraint or index (see [replaceConstraint]).
  void replace(Object? old, Object? now) => update(replaceConstraint(_working, old, now));

  /// Edit state of column [c] (of the working definition).
  ColumnMark columnMark(ColumnDef c) {
    if (isNew) return ColumnMark.none;
    final from = c.originalName;
    if (from == null) return ColumnMark.added;
    final td = _diff?.tables.firstOrNull;
    final diff = td?.columns.where((d) => d.source?.name == c.name).firstOrNull;
    return diff == null || diff.status == DiffStatus.identical ? ColumnMark.none : ColumnMark.changed;
  }

  /// Edit state of a constraint or index of the working definition.
  ColumnMark constraintMark(Object c) {
    final o = original;
    if (o == null) return ColumnMark.none;
    final before = switch (c) {
      PrimaryKeyDef _ => o.primaryKey,
      UniqueDef _ => o.uniques.where((x) => sameConstraint(x, c)).firstOrNull,
      CheckDef _ => o.checks.where((x) => sameConstraint(x, c)).firstOrNull,
      ForeignKeyDef _ => o.foreignKeys.where((x) => sameConstraint(x, c)).firstOrNull,
      IndexDef _ => o.indexes.where((x) => sameConstraint(x, c)).firstOrNull,
      _ => null,
    };
    if (before == null) return ColumnMark.added;
    final b = DdlBuilder(dialect);
    final t = TableDef(name: 'x', columns: const []);
    String sql(Object x) => (x is IndexDef ? b.createIndex(t, x) : b.addConstraint(t, x)).join('\n');
    final enabled = switch ((before, c)) {
      (IndexDef a, IndexDef z) => a.enabled == z.enabled,
      _ => true,
    };
    return sql(before) == sql(c) && enabled ? ColumnMark.none : ColumnMark.changed;
  }

  // -------------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------------

  /// Problems that prevent saving (empty when the design can be applied).
  List<String> get errors {
    final t = _working;
    final out = <String>[];
    if (t.name.trim().isEmpty) out.add('Inserisci il nome della tabella');
    if (t.columns.isEmpty) out.add('Aggiungi almeno una colonna');
    final seen = <String>{};
    for (final c in t.columns) {
      if (c.name.trim().isEmpty) {
        out.add('Ogni colonna deve avere un nome');
      } else if (!seen.add(c.name.toLowerCase())) {
        out.add('Colonna "${c.name}" duplicata');
      }
      if (c.type.trim().isEmpty && !(c.isComputed && dialect.family == DbFamily.sqlServer)) {
        out.add('Indica il tipo della colonna "${c.name}"');
      }
    }
    bool known(String c) => IndexDef.isExpression(c) || seen.contains(c.toLowerCase());
    for (final c in [
      ...?t.primaryKey?.columns,
      for (final u in t.uniques) ...u.columns,
      for (final f in t.foreignKeys) ...f.columns,
    ]) {
      if (!known(c)) out.add('Un vincolo usa la colonna "$c", che non esiste');
    }
    for (final i in t.indexes) {
      if (i.columns.any((c) => !known(c))) out.add('L\'indice ${i.name} usa una colonna che non esiste');
    }
    return out.toSet().toList();
  }
}

/// Edit state shown next to a column or constraint.
enum ColumnMark { none, added, changed }
