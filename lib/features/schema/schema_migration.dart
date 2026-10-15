import '../../services/sql_dialect.dart';
import 'ddl_builder.dart';
import 'schema_diff.dart';
import 'schema_model.dart';

class MigrationOptions {
  const MigrationOptions({this.dropExtra = false, this.includeComments = true, this.relocate = true});

  /// Drop tables, columns, keys and indexes that exist only in the target.
  /// Dangerous: off by default.
  final bool dropExtra;
  final bool includeComments;

  /// Create new tables (and point foreign keys) in the catalog / schema of
  /// the target snapshot instead of the source one (schema compare). The ER
  /// editor keeps the location of each table.
  final bool relocate;
}

/// Generates the DDL that turns the target of a [SchemaDiff] into its source.
class SchemaMigration {
  SchemaMigration(this.dialect) : ddl = DdlBuilder(dialect);

  final SqlDialect dialect;
  final DdlBuilder ddl;

  /// Statements in execution order (comment-only entries are section titles
  /// and notes). Changes whose id is in [excluded] are left out.
  List<String> generate(
    SchemaDiff diff, {
    MigrationOptions options = const MigrationOptions(),
    Set<String> excluded = const {},
  }) {
    bool on(String id) => !excluded.contains(id);
    final drop = options.dropExtra;
    final from = diff.source.family, to = dialect.family;
    final sqlite = to == DbFamily.sqlite;

    ColumnDef mapCol(ColumnDef c) => mapColumnType(c, from, to);

    ForeignKeyDef relocateFk(ForeignKeyDef f) {
      if (!options.relocate) return f;
      final sameCat = f.refCatalog == null || f.refCatalog == diff.source.catalog;
      final sameSch = f.refSchema == null || f.refSchema == diff.source.schema;
      if (!sameCat || !sameSch) return f;
      return f.copyWith(refCatalog: diff.target.catalog, refSchema: diff.target.schema);
    }

    TableDef located(TableDef s, {TableDef? at}) => s.copyWith(
      catalog: at != null ? at.catalog : (options.relocate ? diff.target.catalog : s.catalog),
      schema: at != null ? at.schema : (options.relocate ? diff.target.schema : s.schema),
      columns: s.columns.map(mapCol).toList(),
      foreignKeys: s.foreignKeys.map(relocateFk).toList(),
    );

    final fkDrops = <String>[], ixDrops = <String>[], pkDrops = <String>[];
    final renames = <String>[], colRenames = <String>[], creates = <String>[];
    final alters = <String>[], rebuilds = <String>[], pkAdds = <String>[];
    final ixCreates = <String>[], fkAdds = <String>[], comments = <String>[];
    final created = <TableDef>[], dropped = <TableDef>[];

    for (final td in diff.tables) {
      switch (td.status) {
        case DiffStatus.identical:
          continue;
        case DiffStatus.onlyInSource:
          if (on(td.id)) created.add(located(td.source!));
          continue;
        case DiffStatus.onlyInTarget:
          if (drop && on(td.id)) dropped.add(td.target!);
          continue;
        case DiffStatus.different:
          break;
      }
      final s = td.source!, t = td.target!;
      final renamed = td.renamed && on(td.renameId);
      // Current definition of the table as the statements progress.
      final cur = renamed ? t.copyWith(name: s.name) : t;

      if (sqlite && _needsRebuild(td, on, drop)) {
        rebuilds.addAll(_rebuild(td, located(s, at: cur), on, drop));
        continue;
      }
      if (renamed) renames.addAll(ddl.renameTable(t, s.name));

      // Per table: new columns, then modifications, then drops.
      final added = <String>[], modified = <String>[], removed = <String>[];
      for (final c in td.columns) {
        final id = td.columnId(c.name);
        if (!on(id)) continue;
        switch (c.status) {
          case DiffStatus.onlyInSource:
            added.addAll(ddl.addColumn(cur, mapCol(c.source!)));
          case DiffStatus.onlyInTarget:
            if (drop) removed.addAll(ddl.dropColumn(cur, c.target!.name));
          case DiffStatus.different:
            if (c.aspects.contains(ColumnAspect.name)) {
              colRenames.addAll(ddl.renameColumn(cur, c.target!.name, c.source!.name));
            }
            final rest = c.aspects.difference({ColumnAspect.name, ColumnAspect.position});
            if (rest.isNotEmpty) {
              final old = c.target!.copyWith(name: c.source!.name);
              var want = mapCol(c.source!);
              // Only the aspects reported by the diff are changed.
              if (!rest.contains(ColumnAspect.type)) {
                want = want.copyWith(type: old.type, size: old.size, scale: old.scale);
              }
              if (!rest.contains(ColumnAspect.nullable)) want = want.copyWith(nullable: old.nullable);
              if (!rest.contains(ColumnAspect.defaultValue)) want = want.copyWith(defaultValue: old.defaultValue);
              if (!rest.contains(ColumnAspect.autoIncrement)) want = want.copyWith(autoIncrement: old.autoIncrement);
              if (!rest.contains(ColumnAspect.comment) || !options.includeComments) {
                want = want.copyWith(comment: old.comment);
              }
              modified.addAll(ddl.alterColumn(cur, old, want));
            }
          case DiffStatus.identical:
            break;
        }
      }
      alters
        ..addAll(added)
        ..addAll(modified)
        ..addAll(removed);

      final pk = td.primaryKey;
      if (pk != null && pk.status != DiffStatus.identical && on(td.pkId)) {
        if (pk.target != null && (pk.source != null || drop)) pkDrops.addAll(ddl.dropPrimaryKey(t, pk.target!));
        if (pk.source != null) pkAdds.addAll(ddl.addPrimaryKey(cur, pk.source!));
      }

      for (final f in td.foreignKeys) {
        if (f.status == DiffStatus.identical || !on(td.fkId(f))) continue;
        if (f.target != null && (f.source != null || drop)) fkDrops.addAll(ddl.dropForeignKey(t, f.target!));
        if (f.source != null) fkAdds.addAll(ddl.addForeignKey(cur, relocateFk(f.source!)));
      }

      for (final i in td.indexes) {
        if (i.status == DiffStatus.identical || !on(td.indexId(i))) continue;
        if (i.target != null && (i.source != null || drop)) ixDrops.addAll(ddl.dropIndex(t, i.target!));
        if (i.source != null) ixCreates.addAll(ddl.createIndex(cur, i.source!));
      }

      if (td.commentChanged && options.includeComments && on(td.commentId)) {
        comments.addAll(ddl.tableComment(cur, s.comment, previous: t.comment));
      }
    }

    // New tables: dependencies first, foreign keys after every table exists.
    for (final t in DdlBuilder.sortByDependencies(created)) {
      creates.addAll(ddl.createTable(t, withComments: options.includeComments));
      if (!sqlite) {
        for (final f in t.foreignKeys) {
          fkAdds.addAll(ddl.addForeignKey(t, f));
        }
      }
    }
    // Dropped tables: their foreign keys first, then referencing tables before
    // referenced ones.
    final drops = <String>[];
    if (dropped.isNotEmpty) {
      if (!sqlite) {
        for (final t in dropped) {
          for (final f in t.foreignKeys) {
            if (f.name != null && f.name!.isNotEmpty) fkDrops.addAll(ddl.dropForeignKey(t, f));
          }
        }
      }
      for (final t in DdlBuilder.sortByDependencies(dropped).reversed) {
        drops.addAll(ddl.dropTable(t));
      }
    }

    final out = <String>[];
    void section(String title, List<String> stmts) {
      if (stmts.isEmpty) return;
      out.add('-- $title');
      out.addAll(stmts);
    }

    section('Eliminazione chiavi esterne', fkDrops);
    section('Eliminazione indici', ixDrops);
    section('Eliminazione chiavi primarie', pkDrops);
    section('Ridenominazione tabelle', renames);
    section('Ridenominazione colonne', colRenames);
    section('Nuove tabelle', creates);
    section('Modifica colonne', alters);
    section('Ricostruzione tabelle', rebuilds);
    section('Nuove chiavi primarie', pkAdds);
    section('Eliminazione tabelle', drops);
    section('Nuovi indici', ixCreates);
    section('Nuove chiavi esterne', fkAdds);
    section('Commenti', comments);
    return out;
  }

  /// SQLite can only add / rename / drop columns with ALTER TABLE.
  bool _needsRebuild(TableDiff td, bool Function(String) on, bool drop) {
    for (final c in td.columns) {
      if (!on(td.columnId(c.name))) continue;
      if (c.status == DiffStatus.different &&
          c.aspects.difference({ColumnAspect.name, ColumnAspect.position, ColumnAspect.comment}).isNotEmpty) {
        return true;
      }
      // Columns used by keys cannot be dropped.
      if (c.status == DiffStatus.onlyInTarget && drop) {
        final n = c.target!.name;
        final t = td.target!;
        if (t.isPk(n) || t.foreignKeys.any((f) => f.columns.contains(n))) return true;
      }
    }
    final pk = td.primaryKey;
    if (pk != null && pk.status != DiffStatus.identical && on(td.pkId) && (pk.source != null || drop)) return true;
    for (final f in td.foreignKeys) {
      if (f.status != DiffStatus.identical && on(td.fkId(f)) && (f.source != null || drop)) return true;
    }
    return false;
  }

  /// Rebuild of a SQLite table: the wanted definition keeps the target
  /// objects whose removal was not requested.
  List<String> _rebuild(TableDiff td, TableDef want, bool Function(String) on, bool drop) {
    final t = td.target!;
    final columns = <ColumnDef>[];
    final map = <String, String>{};
    for (final c in td.columns) {
      final take = on(td.columnId(c.name));
      switch (c.status) {
        case DiffStatus.onlyInSource:
          if (take) columns.add(want.column(c.name)!);
        case DiffStatus.onlyInTarget:
          if (!(drop && take)) {
            columns.add(c.target!);
            map[c.target!.name] = c.target!.name;
          }
        case DiffStatus.identical || DiffStatus.different:
          final col = take ? want.column(c.source!.name)! : c.target!;
          columns.add(col);
          map[col.name] = c.target!.name;
      }
    }
    final pk = td.primaryKey;
    final keepPk = pk == null || !on(td.pkId) || (pk.source == null && !drop);
    final fks = <ForeignKeyDef>[
      for (final f in td.foreignKeys)
        if (on(td.fkId(f)) ? f.source != null : f.target != null)
          (on(td.fkId(f)) ? f.source : f.target)!
        else if (f.source == null && !drop)
          f.target!,
    ];
    final ixs = <IndexDef>[
      for (final i in td.indexes)
        if (on(td.indexId(i)) ? i.source != null : i.target != null)
          (on(td.indexId(i)) ? i.source : i.target)!
        else if (i.source == null && !drop)
          i.target!,
    ];
    final def = want.copyWith(
      name: td.renamed && on(td.renameId) ? want.name : t.name,
      columns: columns,
      primaryKey: keepPk ? t.primaryKey : pk.source,
      foreignKeys: fks,
      indexes: ixs,
    );
    return ddl.rebuildTable(t, def, map);
  }
}
