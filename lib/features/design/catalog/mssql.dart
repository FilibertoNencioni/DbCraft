// SQL Server (and Azure SQL): extras of a table from the sys catalog views.

import '../../../model/db_objects.dart';
import '../../schema/schema_model.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

Future<TableExtras> readSqlServerTable(CatalogQueries q, DbTable t) async {
  final path = [if (t.schema != null) '[${t.schema!.replaceAll(']', ']]')}]', '[${t.name.replaceAll(']', ']]')}]'];
  final obj = 'OBJECT_ID(N${lit(path.join('.'))})';

  final keys = await q.first([
    'SELECT kc.name, kc.type, i.type_desc, c.name AS col, ic.key_ordinal '
        'FROM sys.key_constraints kc '
        'JOIN sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id '
        'JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0 '
        'JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id '
        'WHERE kc.parent_object_id = $obj ORDER BY kc.name, ic.key_ordinal',
  ]);
  final uniques = <UniqueDef>[];
  final constraintIndexes = <String>{};
  String? pkName;
  bool? pkClustered;
  for (final e in groupRows(keys, 'name').entries) {
    final first = e.value.first;
    constraintIndexes.add(e.key.toLowerCase());
    final clustered = rowText(first, 'type_desc') == 'CLUSTERED';
    if (rowText(first, 'type') == 'PK') {
      pkName = e.key;
      pkClustered = clustered;
    } else {
      uniques.add(UniqueDef(name: e.key, columns: [for (final r in e.value) rowText(r, 'col')!]));
    }
  }

  final checkRows = await q.first([
    'SELECT name, definition, is_disabled, is_not_trusted FROM sys.check_constraints '
        'WHERE parent_object_id = $obj ORDER BY name',
  ]);
  ConstraintState state(CatalogRow r) =>
      ConstraintState(enabled: !rowBool(r, 'is_disabled'), validated: !rowBool(r, 'is_not_trusted'));
  final checks = [
    for (final r in checkRows)
      CheckDef(name: rowText(r, 'name'), expression: stripParens(rowText(r, 'definition') ?? ''), state: state(r)),
  ];

  final fkRows = await q.first([
    'SELECT name, is_disabled, is_not_trusted FROM sys.foreign_keys WHERE parent_object_id = $obj',
  ]);
  final fks = {for (final r in fkRows) rowText(r, 'name')!.toLowerCase(): (state: state(r), match: FkMatch.simple)};

  final ixRows = await q.first([
    'SELECT i.name, i.type_desc, i.is_unique, i.is_disabled, i.filter_definition, c.name AS col, '
        'ic.is_descending_key, ic.is_included_column '
        'FROM sys.indexes i '
        'JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id '
        'JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id '
        'WHERE i.object_id = $obj AND i.index_id > 0 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 '
        'ORDER BY i.name, ic.is_included_column, ic.key_ordinal, ic.index_column_id',
  ]);
  final indexes = <String, IndexDef>{};
  for (final e in groupRows(ixRows, 'name').entries) {
    final first = e.value.first;
    final cols = <String>[], include = <String>[], desc = <String>{};
    for (final r in e.value) {
      final col = rowText(r, 'col')!;
      if (rowBool(r, 'is_included_column')) {
        include.add(col);
      } else {
        cols.add(col);
        if (rowBool(r, 'is_descending_key')) desc.add(col);
      }
    }
    final filter = rowText(first, 'filter_definition');
    indexes[e.key.toLowerCase()] = IndexDef(
      name: e.key,
      columns: cols,
      unique: rowBool(first, 'is_unique'),
      descending: desc,
      include: include,
      where: filter == null ? null : stripParens(filter),
      clustered: rowText(first, 'type_desc') == 'CLUSTERED',
      enabled: !rowBool(first, 'is_disabled'),
    );
  }

  final colRows = await q.first([
    'SELECT c.name, CASE WHEN c.collation_name <> CAST(DATABASEPROPERTYEX(DB_NAME(), \'Collation\') AS nvarchar(128)) '
        'THEN c.collation_name END AS collation_name, cc.definition AS computed, cc.is_persisted, '
        'CAST(idc.seed_value AS bigint) AS seed, CAST(idc.increment_value AS bigint) AS step, dc.name AS default_name '
        'FROM sys.columns c '
        'LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id '
        'LEFT JOIN sys.identity_columns idc ON idc.object_id = c.object_id AND idc.column_id = c.column_id '
        'LEFT JOIN sys.default_constraints dc ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id '
        'WHERE c.object_id = $obj',
  ]);
  final columns = <String, ColumnExtra>{};
  for (final r in colRows) {
    final seed = rowInt(r, 'seed'), step = rowInt(r, 'step');
    final computed = rowText(r, 'computed');
    columns[rowText(r, 'name')!.toLowerCase()] = ColumnExtra(
      collation: rowText(r, 'collation_name'),
      computed: computed == null ? null : stripParens(computed),
      computedStored: rowBool(r, 'is_persisted'),
      identitySeed: seed == null || seed == 1 ? null : seed,
      identityIncrement: step == null || step == 1 ? null : step,
      defaultName: rowText(r, 'default_name'),
    );
  }

  return TableExtras(
    uniques: uniques,
    checks: checks,
    primaryKeyName: pkName,
    primaryKeyClustered: pkClustered,
    foreignKeys: fks,
    indexes: indexes,
    constraintIndexes: constraintIndexes,
    columns: columns,
  );
}
