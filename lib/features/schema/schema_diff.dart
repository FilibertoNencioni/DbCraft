import 'schema_model.dart';
import 'schema_snapshot.dart';

enum DiffStatus {
  onlyInSource('Solo in origine'),
  onlyInTarget('Solo in destinazione'),
  different('Differenti'),
  identical('Identici');

  const DiffStatus(this.label);
  final String label;
}

class CompareOptions {
  const CompareOptions({
    this.ignoreCase = true,
    this.ignoreColumnOrder = true,
    this.ignoreComments = true,
    this.ignoreDefaults = false,
    this.compareIndexes = true,
    this.compareForeignKeys = true,
  });

  /// Match table, column and constraint names case-insensitively.
  final bool ignoreCase;
  final bool ignoreColumnOrder;
  final bool ignoreComments;
  final bool ignoreDefaults;
  final bool compareIndexes;
  final bool compareForeignKeys;

  CompareOptions copyWith({
    bool? ignoreCase,
    bool? ignoreColumnOrder,
    bool? ignoreComments,
    bool? ignoreDefaults,
    bool? compareIndexes,
    bool? compareForeignKeys,
  }) => CompareOptions(
    ignoreCase: ignoreCase ?? this.ignoreCase,
    ignoreColumnOrder: ignoreColumnOrder ?? this.ignoreColumnOrder,
    ignoreComments: ignoreComments ?? this.ignoreComments,
    ignoreDefaults: ignoreDefaults ?? this.ignoreDefaults,
    compareIndexes: compareIndexes ?? this.compareIndexes,
    compareForeignKeys: compareForeignKeys ?? this.compareForeignKeys,
  );
}

/// What differs between two matched columns.
enum ColumnAspect {
  name('nome'),
  type('tipo'),
  nullable('null'),
  defaultValue('default'),
  autoIncrement('auto-incremento'),
  comment('commento'),
  position('posizione');

  const ColumnAspect(this.label);
  final String label;
}

class ColumnDiff {
  ColumnDiff(this.status, this.source, this.target, [this.aspects = const {}]);
  final DiffStatus status;
  final ColumnDef? source;
  final ColumnDef? target;
  final Set<ColumnAspect> aspects;

  String get name => (source ?? target)!.name;
}

/// Difference of a key, foreign key or index.
class ItemDiff<T> {
  ItemDiff(this.status, this.source, this.target);
  final DiffStatus status;
  final T? source;
  final T? target;
}

/// One selectable change of the migration.
class DiffChange {
  const DiffChange(this.id, this.label, {this.destructive = false});
  final String id;
  final String label;

  /// Drops something that exists only in the target (needs the "drop extra
  /// objects" option in schema compare).
  final bool destructive;
}

class TableDiff {
  TableDiff({
    required this.status,
    this.source,
    this.target,
    this.columns = const [],
    this.primaryKey,
    this.foreignKeys = const [],
    this.indexes = const [],
    this.commentChanged = false,
    this.renamed = false,
  });

  final DiffStatus status;
  final TableDef? source;
  final TableDef? target;
  final List<ColumnDiff> columns;
  final ItemDiff<PrimaryKeyDef>? primaryKey;
  final List<ItemDiff<ForeignKeyDef>> foreignKeys;
  final List<ItemDiff<IndexDef>> indexes;
  final bool commentChanged;

  /// The source table was renamed from the target one (editor only).
  final bool renamed;

  String get name => source?.name ?? target!.name;

  /// Stable identifier of the table in change selections.
  String get id => 't:$name';

  String columnId(String column) => '$id/c:$column';
  String get pkId => '$id/pk';
  String get renameId => '$id/rename';
  String get commentId => '$id/comment';
  String fkId(ItemDiff<ForeignKeyDef> f) => '$id/fk:${(f.source ?? f.target)!.signature()}';
  String indexId(ItemDiff<IndexDef> i) => '$id/ix:${(i.source ?? i.target)!.name.toLowerCase()}';

  /// Selectable changes of this table.
  List<DiffChange> get changes {
    switch (status) {
      case DiffStatus.identical:
        return const [];
      case DiffStatus.onlyInSource:
        return [DiffChange(id, 'Crea la tabella $name')];
      case DiffStatus.onlyInTarget:
        return [DiffChange(id, 'Elimina la tabella $name', destructive: true)];
      case DiffStatus.different:
        break;
    }
    String fkName(ForeignKeyDef f) => f.name ?? '(${f.columns.join(', ')}) → ${f.refTable}';
    return [
      if (renamed) DiffChange(renameId, 'Rinomina la tabella ${target!.name} in ${source!.name}'),
      for (final c in columns)
        if (c.status == DiffStatus.onlyInSource)
          DiffChange(columnId(c.name), 'Aggiungi la colonna ${c.name}')
        else if (c.status == DiffStatus.onlyInTarget)
          DiffChange(columnId(c.name), 'Elimina la colonna ${c.name}', destructive: true)
        else if (c.status == DiffStatus.different)
          DiffChange(
            columnId(c.name),
            c.aspects.length == 1 && c.aspects.contains(ColumnAspect.name)
                ? 'Rinomina la colonna ${c.target!.name} in ${c.name}'
                : 'Modifica la colonna ${c.name} (${c.aspects.map((a) => a.label).join(', ')})',
          ),
      if (primaryKey != null && primaryKey!.status != DiffStatus.identical)
        DiffChange(pkId, switch (primaryKey!.status) {
          DiffStatus.onlyInSource => 'Aggiungi la chiave primaria',
          DiffStatus.onlyInTarget => 'Elimina la chiave primaria',
          _ => 'Modifica la chiave primaria',
        }, destructive: primaryKey!.status == DiffStatus.onlyInTarget),
      for (final f in foreignKeys)
        if (f.status != DiffStatus.identical)
          DiffChange(fkId(f), switch (f.status) {
            DiffStatus.onlyInSource => 'Aggiungi la chiave esterna ${fkName(f.source!)}',
            DiffStatus.onlyInTarget => 'Elimina la chiave esterna ${fkName(f.target!)}',
            _ => 'Modifica la chiave esterna ${fkName(f.source!)}',
          }, destructive: f.status == DiffStatus.onlyInTarget),
      for (final i in indexes)
        if (i.status != DiffStatus.identical)
          DiffChange(indexId(i), switch (i.status) {
            DiffStatus.onlyInSource => 'Crea l\'indice ${i.source!.name}',
            DiffStatus.onlyInTarget => 'Elimina l\'indice ${i.target!.name}',
            _ => 'Modifica l\'indice ${i.source!.name}',
          }, destructive: i.status == DiffStatus.onlyInTarget),
      if (commentChanged) DiffChange(commentId, 'Modifica il commento della tabella'),
    ];
  }

  /// Changes counted for the UI ([includeDestructive] false hides drops of
  /// extra objects).
  int changeCount({bool includeDestructive = true}) =>
      changes.where((c) => includeDestructive || !c.destructive).length;
}

/// Comparison of two schemas: [source] is the wanted state, [target] the
/// database to migrate.
class SchemaDiff {
  SchemaDiff({required this.source, required this.target, required this.options, required this.tables});

  final SchemaSnapshot source;
  final SchemaSnapshot target;
  final CompareOptions options;
  final List<TableDiff> tables;

  Iterable<TableDiff> withStatus(DiffStatus s) => tables.where((t) => t.status == s);

  List<DiffChange> get changes => [for (final t in tables) ...t.changes];

  int changeCount({bool includeDestructive = true}) =>
      tables.fold(0, (n, t) => n + t.changeCount(includeDestructive: includeDestructive));

  static SchemaDiff compare(
    SchemaSnapshot source,
    SchemaSnapshot target, {
    CompareOptions options = const CompareOptions(),
  }) => _Comparer(options).run(source, target);
}

class _Comparer {
  _Comparer(this.o);
  final CompareOptions o;

  String k(String s) => o.ignoreCase ? s.toLowerCase() : s;

  /// target table key → source table name (renames made in an editor).
  final Map<String, String> _tableRenames = {};

  /// target table key → (target column key → source column name).
  final Map<String, Map<String, String>> _columnRenames = {};

  SchemaDiff run(SchemaSnapshot source, SchemaSnapshot target) {
    for (final s in source.tables) {
      final from = s.originalName ?? s.name;
      if (from != s.name) _tableRenames[k(from)] = s.name;
      final cols = <String, String>{};
      for (final c in s.columns) {
        if (c.originalName != null && c.originalName != c.name) cols[k(c.originalName!)] = c.name;
      }
      if (cols.isNotEmpty) _columnRenames[k(from)] = cols;
    }
    final targets = <String, TableDef>{for (final t in target.tables) k(t.name): t};
    final out = <TableDiff>[];
    for (final s in source.tables) {
      final t = targets.remove(k(s.originalName ?? s.name));
      out.add(t == null ? TableDiff(status: DiffStatus.onlyInSource, source: s) : _table(s, t));
    }
    for (final t in targets.values) {
      out.add(TableDiff(status: DiffStatus.onlyInTarget, target: t));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return SchemaDiff(source: source, target: target, options: o, tables: out);
  }

  /// Name in the source naming of target column [col] of target table [table].
  String _col(String table, String col) => _columnRenames[k(table)]?[k(col)] ?? col;

  String _tbl(String table) => _tableRenames[k(table)] ?? table;

  TableDiff _table(TableDef s, TableDef t) {
    // Columns
    final tCols = <String, (int, ColumnDef)>{for (final (i, c) in t.columns.indexed) k(c.name): (i, c)};
    final cols = <ColumnDiff>[];
    for (final (i, c) in s.columns.indexed) {
      final m = tCols.remove(k(c.originalName ?? c.name));
      if (m == null) {
        cols.add(ColumnDiff(DiffStatus.onlyInSource, c, null));
        continue;
      }
      final aspects = _columnAspects(c, m.$2);
      if (!o.ignoreColumnOrder && i != m.$1) aspects.add(ColumnAspect.position);
      cols.add(ColumnDiff(aspects.isEmpty ? DiffStatus.identical : DiffStatus.different, c, m.$2, aspects));
    }
    for (final m in tCols.values) {
      cols.add(ColumnDiff(DiffStatus.onlyInTarget, null, m.$2));
    }

    // Primary key
    ItemDiff<PrimaryKeyDef>? pk;
    final sp = s.primaryKey, tp = t.primaryKey;
    if (sp != null || tp != null) {
      if (sp == null) {
        pk = ItemDiff(DiffStatus.onlyInTarget, null, tp);
      } else if (tp == null) {
        pk = ItemDiff(DiffStatus.onlyInSource, sp, null);
      } else {
        final a = sp.columns.map(k).join(',');
        final b = tp.columns.map((c) => k(_col(t.name, c))).join(',');
        pk = ItemDiff(a == b ? DiffStatus.identical : DiffStatus.different, sp, tp);
      }
    }

    // Foreign keys, matched by structure (constraint names are often generated).
    final fks = <ItemDiff<ForeignKeyDef>>[];
    if (o.compareForeignKeys) {
      String sig(ForeignKeyDef f) => k('${f.columns.join(',')}>${f.refTable}(${f.refColumns.join(',')})');
      String tSig(ForeignKeyDef f) => k(
        '${f.columns.map((c) => _col(t.name, c)).join(',')}>${_tbl(f.refTable)}'
        '(${f.refColumns.map((c) => _col(f.refTable, c)).join(',')})',
      );
      final remaining = <String, ForeignKeyDef>{for (final f in t.foreignKeys) tSig(f): f};
      for (final f in s.foreignKeys) {
        final m = remaining.remove(sig(f));
        if (m == null) {
          fks.add(ItemDiff(DiffStatus.onlyInSource, f, null));
        } else {
          final same = _rule(f.onDelete) == _rule(m.onDelete) && _rule(f.onUpdate) == _rule(m.onUpdate);
          fks.add(ItemDiff(same ? DiffStatus.identical : DiffStatus.different, f, m));
        }
      }
      for (final f in remaining.values) {
        fks.add(ItemDiff(DiffStatus.onlyInTarget, null, f));
      }
    }

    // Indexes: by name first, then by structure.
    final ixs = <ItemDiff<IndexDef>>[];
    if (o.compareIndexes) {
      String sig(IndexDef i, String? table) =>
          '${i.unique ? 'u' : ''}(${i.columns.map((c) => k(table == null ? c : _col(table, c))).join(',')})';
      final byName = <String, IndexDef>{for (final i in t.indexes) k(i.name): i};
      final unmatched = <IndexDef>[];
      for (final i in s.indexes) {
        final m = byName.remove(k(i.name));
        if (m == null) {
          unmatched.add(i);
        } else {
          ixs.add(ItemDiff(sig(i, null) == sig(m, t.name) ? DiffStatus.identical : DiffStatus.different, i, m));
        }
      }
      final bySig = <String, IndexDef>{for (final i in byName.values) sig(i, t.name): i};
      for (final i in unmatched) {
        final m = bySig.remove(sig(i, null));
        ixs.add(m == null ? ItemDiff(DiffStatus.onlyInSource, i, null) : ItemDiff(DiffStatus.identical, i, m));
      }
      for (final i in bySig.values) {
        ixs.add(ItemDiff(DiffStatus.onlyInTarget, null, i));
      }
    }

    final renamed = s.originalName != null && s.originalName != s.name;
    final commentChanged = !o.ignoreComments && (s.comment ?? '') != (t.comment ?? '');
    final changed =
        renamed ||
        commentChanged ||
        cols.any((c) => c.status != DiffStatus.identical) ||
        (pk != null && pk.status != DiffStatus.identical) ||
        fks.any((f) => f.status != DiffStatus.identical) ||
        ixs.any((i) => i.status != DiffStatus.identical);
    return TableDiff(
      status: changed ? DiffStatus.different : DiffStatus.identical,
      source: s,
      target: t,
      columns: cols,
      primaryKey: pk,
      foreignKeys: fks,
      indexes: ixs,
      commentChanged: commentChanged,
      renamed: renamed,
    );
  }

  static FkRule _rule(FkRule r) => r == FkRule.restrict ? FkRule.noAction : r;

  Set<ColumnAspect> _columnAspects(ColumnDef s, ColumnDef t) {
    final a = <ColumnAspect>{};
    if (s.originalName != null && s.originalName != s.name) a.add(ColumnAspect.name);
    if (!sameType(s, t)) a.add(ColumnAspect.type);
    if (s.nullable != t.nullable) a.add(ColumnAspect.nullable);
    if (!o.ignoreDefaults && !s.autoIncrement && !t.autoIncrement) {
      final ds = normalizeDefault(s.defaultValue), dt = normalizeDefault(t.defaultValue);
      if (ds != dt) a.add(ColumnAspect.defaultValue);
    }
    if (s.autoIncrement != t.autoIncrement) a.add(ColumnAspect.autoIncrement);
    if (!o.ignoreComments && (s.comment ?? '') != (t.comment ?? '')) a.add(ColumnAspect.comment);
    return a;
  }
}

/// Compares the declared types of two columns across dialects.
bool sameType(ColumnDef a, ColumnDef b) {
  final ca = canonicalType(a.type), cb = canonicalType(b.type);
  if (ca != cb) return false;
  // Explicit declarations such as tinyint(1) carry their own size.
  final ea = RegExp(r'\((.*?)\)').firstMatch(a.type)?.group(1)?.replaceAll(' ', '');
  final eb = RegExp(r'\((.*?)\)').firstMatch(b.type)?.group(1)?.replaceAll(' ', '');
  if (ea != null || eb != null) {
    final sa = ea ?? _sizeText(a), sb = eb ?? _sizeText(b);
    return sa == sb;
  }
  if (isSizedType(a.type)) return _size(a.size) == _size(b.size);
  if (isScaledType(a.type)) {
    // NUMBER without precision is unconstrained: only compare declared sizes.
    if (a.size == null || b.size == null) return true;
    return a.size == b.size && (a.scale ?? 0) == (b.scale ?? 0);
  }
  return true;
}

String _sizeText(ColumnDef c) => c.size == null
    ? ''
    : (c.scale != null && c.scale! > 0 ? '${c.size},${c.scale}' : '${c.size == -1 ? 'max' : c.size}');

int? _size(int? s) => s == null || s <= 0 || s >= 1073741823 ? -1 : s;
