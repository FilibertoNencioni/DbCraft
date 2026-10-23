// MySQL and MariaDB: extras of a table from information_schema. A UNIQUE
// index and a UNIQUE constraint are the same object there.

import '../../../model/db_objects.dart';
import '../../../services/sql_dialect.dart';
import '../../schema/schema_model.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

Future<TableExtras> readMySqlTable(CatalogQueries q, SqlDialect d, DbTable t) async {
  // The MySQL drivers report the database as the catalog.
  final db = t.catalog ?? t.schema;
  final schemaCond = db == null ? 'TABLE_SCHEMA = DATABASE()' : 'TABLE_SCHEMA = ${lit(db)}';
  final cond = '$schemaCond AND TABLE_NAME = ${lit(t.name)}';

  // CHECK constraints (MySQL 8.0.16+, MariaDB 10.2+).
  var checks = <CheckDef>[];
  try {
    final rows = await q.first([
      if (d.isMariaDb)
        'SELECT CONSTRAINT_NAME, CHECK_CLAUSE FROM information_schema.CHECK_CONSTRAINTS '
            'WHERE ${schemaCond.replaceAll('TABLE_SCHEMA', 'CONSTRAINT_SCHEMA')} AND TABLE_NAME = ${lit(t.name)} '
            'ORDER BY CONSTRAINT_NAME',
      'SELECT cc.CONSTRAINT_NAME, cc.CHECK_CLAUSE, tc.ENFORCED FROM information_schema.CHECK_CONSTRAINTS cc '
          'JOIN information_schema.TABLE_CONSTRAINTS tc ON tc.CONSTRAINT_SCHEMA = cc.CONSTRAINT_SCHEMA '
          'AND tc.CONSTRAINT_NAME = cc.CONSTRAINT_NAME '
          "WHERE tc.$schemaCond AND tc.TABLE_NAME = ${lit(t.name)} "
          "AND tc.CONSTRAINT_TYPE = 'CHECK' ORDER BY cc.CONSTRAINT_NAME",
    ]);
    checks = [
      for (final r in rows)
        CheckDef(
          name: rowText(r, 'constraint_name'),
          expression: stripParens(rowText(r, 'check_clause') ?? ''),
          state: ConstraintState(enabled: r['enforced'] == null || rowBool(r, 'enforced')),
        ),
    ];
  } catch (_) {
    // Older servers: no CHECK_CONSTRAINTS view.
  }

  final ixRows = await q.first([
    if (d.isMariaDb)
      'SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, COLLATION, INDEX_TYPE, IGNORED '
          'FROM information_schema.STATISTICS WHERE $cond ORDER BY INDEX_NAME, SEQ_IN_INDEX',
    if (!d.isMariaDb)
      'SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, COLLATION, INDEX_TYPE, EXPRESSION, IS_VISIBLE '
          'FROM information_schema.STATISTICS WHERE $cond ORDER BY INDEX_NAME, SEQ_IN_INDEX',
    'SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, COLLATION, INDEX_TYPE '
        'FROM information_schema.STATISTICS WHERE $cond ORDER BY INDEX_NAME, SEQ_IN_INDEX',
  ]);
  final indexes = <String, IndexDef>{};
  for (final e in groupRows(ixRows, 'index_name').entries) {
    if (e.key == 'PRIMARY') continue;
    final first = e.value.first;
    final cols = <String>[], desc = <String>{};
    for (final r in e.value) {
      final expr = rowText(r, 'expression');
      final col = expr != null ? '(${stripParens(expr)})' : rowText(r, 'column_name')!;
      cols.add(col);
      if (rowText(r, 'collation') == 'D') desc.add(col);
    }
    final type = rowText(first, 'index_type')?.toLowerCase();
    final hidden = rowText(first, 'is_visible') == 'NO' || rowText(first, 'ignored') == 'YES';
    indexes[e.key.toLowerCase()] = IndexDef(
      name: e.key,
      columns: cols,
      unique: !rowBool(first, 'non_unique'),
      descending: desc,
      method: type == null || type == 'btree' ? null : type,
      enabled: !hidden,
    );
  }

  final tableRows = await q.first(['SELECT ENGINE, TABLE_COLLATION FROM information_schema.TABLES WHERE $cond']);
  final tableCollation = tableRows.isEmpty ? null : rowText(tableRows.first, 'table_collation');
  final options = <String, String>{
    if (tableRows.isNotEmpty && rowText(tableRows.first, 'engine') != null)
      'engine': rowText(tableRows.first, 'engine')!,
    'collation': ?tableCollation,
  };

  final colRows = await q.first([
    'SELECT COLUMN_NAME, COLLATION_NAME, GENERATION_EXPRESSION, EXTRA FROM information_schema.COLUMNS WHERE $cond',
    'SELECT COLUMN_NAME, COLLATION_NAME, EXTRA FROM information_schema.COLUMNS WHERE $cond',
  ]);
  final columns = <String, ColumnExtra>{};
  for (final r in colRows) {
    final coll = rowText(r, 'collation_name');
    final extra = (rowText(r, 'extra') ?? '').toUpperCase();
    final expr = rowText(r, 'generation_expression');
    final generated = expr != null && extra.contains('GENERATED');
    columns[rowText(r, 'column_name')!.toLowerCase()] = ColumnExtra(
      collation: coll != null && coll != tableCollation ? coll : null,
      computed: generated ? stripParens(expr) : null,
      computedStored: extra.contains('STORED') || extra.contains('PERSISTENT'),
    );
  }

  // InnoDB creates an index named after each foreign key lacking one.
  final fkRows = await q.first([
    "SELECT CONSTRAINT_NAME FROM information_schema.TABLE_CONSTRAINTS WHERE $cond AND CONSTRAINT_TYPE = 'FOREIGN KEY'",
  ]);

  return TableExtras(
    checks: checks,
    primaryKeyName: 'PRIMARY',
    indexes: indexes,
    constraintIndexes: {'primary', for (final r in fkRows) rowText(r, 'constraint_name')!.toLowerCase()},
    columns: columns,
    options: options,
    uniqueIndexesAreConstraints: true,
  );
}
