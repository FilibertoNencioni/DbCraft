// Db2 for LUW: extras of a table from the SYSCAT views.

import '../../../model/db_objects.dart';
import '../../schema/schema_model.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

Future<TableExtras> readDb2Table(CatalogQueries q, DbTable t) async {
  final schema = t.schema == null ? 'CURRENT SCHEMA' : lit(t.schema!);
  String cond(String alias) => '$alias.tabschema = $schema AND $alias.tabname = ${lit(t.name)}';

  final cons = await q.first([
    'SELECT c.constname, c.type, c.enforced, k.colname, k.colseq FROM syscat.tabconst c '
        'LEFT JOIN syscat.keycoluse k ON k.tabschema = c.tabschema AND k.tabname = c.tabname '
        'AND k.constname = c.constname '
        'WHERE ${cond('c')} ORDER BY c.constname, k.colseq',
  ]);
  final uniques = <UniqueDef>[];
  final fks = <String, ({ConstraintState state, FkMatch match})>{};
  final enforced = <String, bool>{};
  String? pkName;
  for (final e in groupRows(cons, 'constname').entries) {
    final first = e.value.first;
    final on = rowText(first, 'enforced') != 'N';
    enforced[e.key.toLowerCase()] = on;
    final state = ConstraintState(enabled: on);
    switch (rowText(first, 'type')) {
      case 'P':
        pkName = e.key;
      case 'U':
        uniques.add(
          UniqueDef(
            name: e.key,
            columns: [
              for (final r in e.value)
                if (rowText(r, 'colname') != null) rowText(r, 'colname')!,
            ],
            state: state,
          ),
        );
      case 'F':
        fks[e.key.toLowerCase()] = (state: state, match: FkMatch.simple);
    }
  }

  final checkRows = await q.first([
    "SELECT c.constname, c.text FROM syscat.checks c WHERE ${cond('c')} AND c.type = 'C' ORDER BY c.constname",
  ]);
  final checks = [
    for (final r in checkRows)
      CheckDef(
        name: rowText(r, 'constname'),
        expression: stripParens(rowText(r, 'text') ?? ''),
        state: ConstraintState(enabled: enforced[rowText(r, 'constname')!.toLowerCase()] ?? true),
      ),
  ];

  String ixQuery(String text) =>
      'SELECT i.indname, i.uniquerule, c.colname, c.colseq, c.colorder, $text AS expr '
      'FROM syscat.indexes i JOIN syscat.indexcoluse c ON c.indschema = i.indschema AND c.indname = i.indname '
      'WHERE ${cond('i')} ORDER BY i.indname, c.colseq';
  final ixRows = await q.first([ixQuery('c.text'), ixQuery('CAST(NULL AS VARCHAR(1))')]);
  final indexes = <String, IndexDef>{};
  final constraintIndexes = <String>{};
  for (final e in groupRows(ixRows, 'indname').entries) {
    final first = e.value.first;
    final rule = rowText(first, 'uniquerule');
    // P: primary key index; U: unique (constraint or index); D: duplicates allowed.
    if (rule == 'P') {
      constraintIndexes.add(e.key.toLowerCase());
      continue;
    }
    final cols = <String>[], include = <String>[], desc = <String>{};
    for (final r in e.value) {
      final expr = rowText(r, 'expr');
      final col = expr != null && expr != rowText(r, 'colname') ? '(${stripParens(expr)})' : rowText(r, 'colname')!;
      switch (rowText(r, 'colorder')) {
        case 'I':
          include.add(col);
        case 'D':
          cols.add(col);
          desc.add(col);
        default:
          cols.add(col);
      }
    }
    indexes[e.key.toLowerCase()] = IndexDef(
      name: e.key,
      columns: cols,
      unique: rule == 'U',
      descending: desc,
      include: include,
    );
  }

  final colRows = await q.first([
    'SELECT colname, generated, identity, text FROM syscat.columns WHERE tabschema = $schema '
        'AND tabname = ${lit(t.name)}',
  ]);
  final columns = <String, ColumnExtra>{};
  for (final r in colRows) {
    final text = rowText(r, 'text');
    final computed = rowText(r, 'generated') == 'A' && rowText(r, 'identity') != 'Y' && text != null;
    columns[rowText(r, 'colname')!.toLowerCase()] = ColumnExtra(
      computed: computed ? stripParens(text.replaceFirst(RegExp(r'^AS\s*', caseSensitive: false), '')) : null,
    );
  }

  return TableExtras(
    uniques: uniques,
    checks: checks,
    primaryKeyName: pkName,
    foreignKeys: fks,
    indexes: indexes,
    constraintIndexes: {
      ...constraintIndexes,
      // Db2 names the index of a UNIQUE constraint after it, or SQL… when unnamed.
      for (final u in uniques) u.name!.toLowerCase(),
    },
    columns: columns,
  );
}
