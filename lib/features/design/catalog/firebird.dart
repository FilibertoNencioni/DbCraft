// Firebird: extras of a table from the RDB$ system tables (CHAR columns are
// blank padded: rowText trims them).

import '../../../model/db_objects.dart';
import '../../schema/schema_model.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

Future<TableExtras> readFirebirdTable(CatalogQueries q, DbTable t) async {
  final rel = lit(t.name);

  final cons = await q.first([
    r'SELECT rc.RDB$CONSTRAINT_NAME AS name, rc.RDB$CONSTRAINT_TYPE AS kind, rc.RDB$INDEX_NAME AS index_name, '
        r's.RDB$FIELD_NAME AS col, s.RDB$FIELD_POSITION AS pos FROM RDB$RELATION_CONSTRAINTS rc '
        r'LEFT JOIN RDB$INDEX_SEGMENTS s ON s.RDB$INDEX_NAME = rc.RDB$INDEX_NAME '
        'WHERE rc.RDB\$RELATION_NAME = $rel ORDER BY 1, 5',
  ]);
  final uniques = <UniqueDef>[];
  final constraintIndexes = <String>{};
  String? pkName;
  for (final e in groupRows(cons, 'name').entries) {
    final first = e.value.first;
    final kind = rowText(first, 'kind');
    final index = rowText(first, 'index_name');
    // Keys and foreign keys are backed by system indexes (RDB\$PRIMARY…, RDB\$FOREIGN…).
    if (index != null && kind != 'CHECK' && kind != 'NOT NULL') constraintIndexes.add(index.toLowerCase());
    if (kind == 'PRIMARY KEY') pkName = e.key;
    if (kind == 'UNIQUE') {
      uniques.add(
        UniqueDef(
          name: e.key,
          columns: [
            for (final r in e.value)
              if (rowText(r, 'col') != null) rowText(r, 'col')!,
          ],
        ),
      );
    }
  }

  // A CHECK is stored as two triggers (insert and update): one is enough.
  final checkRows = await q.first([
    r'SELECT rc.RDB$CONSTRAINT_NAME AS name, tr.RDB$TRIGGER_SOURCE AS source FROM RDB$RELATION_CONSTRAINTS rc '
        r'JOIN RDB$CHECK_CONSTRAINTS cc ON cc.RDB$CONSTRAINT_NAME = rc.RDB$CONSTRAINT_NAME '
        r'JOIN RDB$TRIGGERS tr ON tr.RDB$TRIGGER_NAME = cc.RDB$TRIGGER_NAME '
        "WHERE rc.RDB\$RELATION_NAME = $rel AND rc.RDB\$CONSTRAINT_TYPE = 'CHECK' AND tr.RDB\$TRIGGER_TYPE = 1 "
        'ORDER BY 1',
  ]);
  final checkNames = <String>{};
  final checks = [
    for (final r in checkRows)
      if (checkNames.add(rowText(r, 'name') ?? ''))
        CheckDef(
          name: rowText(r, 'name'),
          expression: stripParens(
            (rowText(r, 'source') ?? '').replaceFirst(RegExp(r'^CHECK\s*', caseSensitive: false), ''),
          ),
        ),
  ];

  String ixQuery(String condition) =>
      r'SELECT i.RDB$INDEX_NAME AS name, i.RDB$UNIQUE_FLAG AS is_unique, i.RDB$INDEX_TYPE AS descending, '
      r'i.RDB$INDEX_INACTIVE AS inactive, i.RDB$EXPRESSION_SOURCE AS expr, '
      '$condition AS filter, '
      r's.RDB$FIELD_NAME AS col, s.RDB$FIELD_POSITION AS pos FROM RDB$INDICES i '
      r'LEFT JOIN RDB$INDEX_SEGMENTS s ON s.RDB$INDEX_NAME = i.RDB$INDEX_NAME '
      'WHERE i.RDB\$RELATION_NAME = $rel ORDER BY 1, 8';
  final ixRows = await q.first([ixQuery(r'i.RDB$CONDITION_SOURCE'), ixQuery('CAST(NULL AS VARCHAR(1))')]);
  final indexes = <String, IndexDef>{};
  for (final e in groupRows(ixRows, 'name').entries) {
    final first = e.value.first;
    final expr = rowText(first, 'expr');
    final cols = expr != null
        ? ['(${stripParens(expr)})']
        : [
            for (final r in e.value)
              if (rowText(r, 'col') != null) rowText(r, 'col')!,
          ];
    final filter = rowText(first, 'filter');
    indexes[e.key.toLowerCase()] = IndexDef(
      name: e.key,
      columns: cols,
      unique: rowInt(first, 'is_unique') == 1,
      descending: rowInt(first, 'descending') == 1 ? cols.toSet() : const {},
      where: filter == null ? null : stripParens(filter.replaceFirst(RegExp(r'^WHERE\s*', caseSensitive: false), '')),
      enabled: rowInt(first, 'inactive') != 1,
    );
  }

  final colRows = await q.first([
    r'SELECT rf.RDB$FIELD_NAME AS name, co.RDB$COLLATION_NAME AS collation, f.RDB$COMPUTED_SOURCE AS computed '
        r'FROM RDB$RELATION_FIELDS rf JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = rf.RDB$FIELD_SOURCE '
        r'LEFT JOIN RDB$COLLATIONS co ON co.RDB$COLLATION_ID = rf.RDB$COLLATION_ID '
        r'AND co.RDB$CHARACTER_SET_ID = f.RDB$CHARACTER_SET_ID AND rf.RDB$COLLATION_ID > 0 '
        'WHERE rf.RDB\$RELATION_NAME = $rel',
  ]);
  final columns = <String, ColumnExtra>{};
  for (final r in colRows) {
    final computed = rowText(r, 'computed');
    columns[rowText(r, 'name')!.toLowerCase()] = ColumnExtra(
      collation: rowText(r, 'collation'),
      computed: computed == null ? null : stripParens(computed),
    );
  }

  return TableExtras(
    uniques: uniques,
    checks: checks,
    primaryKeyName: pkName,
    indexes: indexes,
    constraintIndexes: constraintIndexes,
    columns: columns,
  );
}
