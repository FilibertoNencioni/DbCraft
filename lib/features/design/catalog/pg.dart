// PostgreSQL (and Redshift / Greenplum where the catalogs match): extras of
// a table from pg_constraint, pg_index and pg_attribute.

import '../../../model/db_objects.dart';
import '../../schema/schema_model.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

/// Separator of aggregated column lists (unit separator).
const _sep = '\u001f';

Future<TableExtras> readPostgresTable(CatalogQueries q, DbTable t) async {
  final schema = t.schema ?? 'public';
  final rel =
      "(SELECT r.oid FROM pg_class r JOIN pg_namespace n ON n.oid = r.relnamespace "
      "WHERE n.nspname = ${lit(schema)} AND r.relname = ${lit(t.name)})";

  final cons = await q.first([
    'SELECT c.conname, c.contype, pg_get_constraintdef(c.oid) AS def, c.condeferrable, c.condeferred, '
        'c.convalidated, c.confmatchtype, '
        "(SELECT string_agg(a.attname, chr(31) ORDER BY k.o) FROM unnest(c.conkey) WITH ORDINALITY k(n, o) "
        'JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n) AS cols, '
        '(SELECT i.relname FROM pg_class i WHERE i.oid = c.conindid) AS index_name '
        'FROM pg_constraint c WHERE c.conrelid = $rel AND c.contype IN (\'p\', \'u\', \'c\', \'f\') '
        'ORDER BY c.conname',
  ]);

  final uniques = <UniqueDef>[];
  final checks = <CheckDef>[];
  final fks = <String, ({ConstraintState state, FkMatch match})>{};
  final constraintIndexes = <String>{};
  String? pkName;
  ConstraintState? pkState;
  for (final r in cons) {
    final name = rowText(r, 'conname')!;
    final state = ConstraintState(
      validated: rowBool(r, 'convalidated'),
      deferrable: rowBool(r, 'condeferrable'),
      initiallyDeferred: rowBool(r, 'condeferred'),
    );
    final cols = (rowText(r, 'cols') ?? '').split(_sep).where((e) => e.isNotEmpty).toList();
    final index = rowText(r, 'index_name');
    switch (rowText(r, 'contype')) {
      case 'p':
        pkName = name;
        pkState = state;
        if (index != null) constraintIndexes.add(index.toLowerCase());
      case 'u':
        uniques.add(UniqueDef(name: name, columns: cols, state: state));
        if (index != null) constraintIndexes.add(index.toLowerCase());
      case 'c':
        final def = rowText(r, 'def') ?? '';
        final m = RegExp(r'^CHECK\s*(.*?)(\s+NO INHERIT)?(\s+NOT VALID)?$', dotAll: true).firstMatch(def);
        checks.add(CheckDef(name: name, expression: stripParens(m?.group(1) ?? def), state: state));
      case 'f':
        fks[name.toLowerCase()] = (
          state: state,
          match: rowText(r, 'confmatchtype') == 'f' ? FkMatch.full : FkMatch.simple,
        );
    }
  }

  // One row per index column (key columns first, then INCLUDE ones).
  String indexQuery(String keyCount) =>
      'SELECT i.relname AS index_name, x.indisunique, x.indisclustered, x.indisvalid, am.amname, '
      'pg_get_expr(x.indpred, x.indrelid, true) AS filter, $keyCount AS key_count, k.n AS pos, '
      'pg_get_indexdef(x.indexrelid, k.n, true) AS col, (x.indoption[k.n - 1] & 1) AS descending, '
      '(x.indkey[k.n - 1] = 0) AS is_expr '
      'FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_am am ON am.oid = i.relam '
      'CROSS JOIN LATERAL generate_series(1, x.indnatts) AS k(n) '
      'WHERE x.indrelid = $rel ORDER BY i.relname, k.n';
  final ixRows = await q.first([indexQuery('x.indnkeyatts'), indexQuery('x.indnatts')]);
  final indexes = <String, IndexDef>{};
  for (final e in groupRows(ixRows, 'index_name').entries) {
    final first = e.value.first;
    final keyCount = rowInt(first, 'key_count') ?? e.value.length;
    final cols = <String>[], include = <String>[], desc = <String>{};
    for (final r in e.value) {
      final raw = rowText(r, 'col') ?? '';
      final col = rowBool(r, 'is_expr') ? '(${stripParens(raw)})' : unquoteIdent(raw);
      if ((rowInt(r, 'pos') ?? 0) > keyCount) {
        include.add(col);
      } else {
        cols.add(col);
        if (rowBool(r, 'descending')) desc.add(col);
      }
    }
    final method = rowText(first, 'amname');
    indexes[e.key.toLowerCase()] = IndexDef(
      name: e.key,
      columns: cols,
      unique: rowBool(first, 'indisunique'),
      descending: desc,
      include: include,
      where: rowText(first, 'filter'),
      method: method == 'btree' ? null : method,
      enabled: rowBool(first, 'indisvalid'),
    );
  }

  // Columns: explicit collation, generated expression, identity sequence.
  const base =
      'SELECT a.attname, CASE WHEN a.attcollation <> 0 AND co.collname <> \'default\' '
      'AND a.attcollation <> t.typcollation THEN co.collname END AS collation';
  final from =
      ' FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid '
      'LEFT JOIN pg_collation co ON co.oid = a.attcollation '
      'LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum';
  final cond = ' WHERE a.attrelid = $rel AND a.attnum > 0 AND NOT a.attisdropped';
  final colRows = await q.first([
    '$base, a.attgenerated, pg_get_expr(d.adbin, d.adrelid) AS expr, s.seqstart, s.seqincrement$from '
        "LEFT JOIN pg_depend dep ON dep.refobjid = a.attrelid AND dep.refobjsubid = a.attnum AND dep.deptype = 'i' "
        "AND dep.classid = 'pg_class'::regclass "
        'LEFT JOIN pg_sequence s ON s.seqrelid = dep.objid$cond',
    '$base$from$cond',
  ]);
  final columns = <String, ColumnExtra>{};
  for (final r in colRows) {
    final generated = rowText(r, 'attgenerated');
    final seed = rowInt(r, 'seqstart'), step = rowInt(r, 'seqincrement');
    columns[rowText(r, 'attname')!.toLowerCase()] = ColumnExtra(
      collation: rowText(r, 'collation'),
      computed: generated == 's' ? stripParens(rowText(r, 'expr') ?? '') : null,
      identitySeed: seed == null || seed == 1 ? null : seed,
      identityIncrement: step == null || step == 1 ? null : step,
    );
  }

  return TableExtras(
    uniques: uniques,
    checks: checks,
    primaryKeyName: pkName,
    primaryKeyState: pkState,
    foreignKeys: fks,
    indexes: indexes,
    constraintIndexes: constraintIndexes,
    columns: columns,
  );
}
