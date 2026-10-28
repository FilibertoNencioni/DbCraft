// Oracle: extras of a table from the ALL_* dictionary views (the tables the
// user can see; DBA_* would need extra privileges).

import '../../../model/db_objects.dart';
import '../../schema/schema_model.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

final _notNullCheck = RegExp(r'^"?[^"\s]+"?\s+IS\s+NOT\s+NULL$', caseSensitive: false);

Future<TableExtras> readOracleTable(CatalogQueries q, DbTable t) async {
  final owner = t.schema == null ? 'USER' : lit(t.schema!);
  final cond = 'c.owner = $owner AND c.table_name = ${lit(t.name)}';

  String consQuery(String condition) =>
      'SELECT c.constraint_name, c.constraint_type, c.status, c.validated, c.deferrable, c.deferred, '
      'c.generated, $condition AS search_condition, c.index_name, cc.column_name, cc.position '
      'FROM all_constraints c LEFT JOIN all_cons_columns cc ON cc.owner = c.owner '
      'AND cc.constraint_name = c.constraint_name AND cc.table_name = c.table_name '
      "WHERE $cond AND c.constraint_type IN ('P', 'U', 'C', 'R') ORDER BY c.constraint_name, cc.position";
  final cons = await q.first([consQuery('c.search_condition_vc'), consQuery('c.search_condition')]);

  final uniques = <UniqueDef>[];
  final checks = <CheckDef>[];
  final fks = <String, ({ConstraintState state, FkMatch match})>{};
  final constraintIndexes = <String>{};
  String? pkName;
  ConstraintState? pkState;
  for (final e in groupRows(cons, 'constraint_name').entries) {
    final first = e.value.first;
    final state = ConstraintState(
      enabled: rowText(first, 'status') != 'DISABLED',
      validated: rowText(first, 'validated') != 'NOT VALIDATED',
      deferrable: rowText(first, 'deferrable') == 'DEFERRABLE',
      initiallyDeferred: rowText(first, 'deferred') == 'DEFERRED',
    );
    final cols = [
      for (final r in e.value)
        if (rowText(r, 'column_name') != null) rowText(r, 'column_name')!,
    ];
    final index = rowText(first, 'index_name');
    switch (rowText(first, 'constraint_type')) {
      case 'P':
        pkName = e.key;
        pkState = state;
        if (index != null) constraintIndexes.add(index.toLowerCase());
      case 'U':
        uniques.add(UniqueDef(name: e.key, columns: cols, state: state));
        if (index != null) constraintIndexes.add(index.toLowerCase());
      case 'C':
        final cond = rowText(first, 'search_condition') ?? '';
        // NOT NULL columns are system generated checks.
        if (rowText(first, 'generated') == 'GENERATED NAME' && _notNullCheck.hasMatch(cond)) continue;
        checks.add(CheckDef(name: e.key, expression: stripParens(cond), state: state));
      case 'R':
        fks[e.key.toLowerCase()] = (state: state, match: FkMatch.simple);
    }
  }

  final ixRows = await q.first([
    'SELECT i.index_name, i.index_type, i.uniqueness, i.status, ic.column_name, ic.column_position, ic.descend, '
        'ie.column_expression '
        'FROM all_indexes i JOIN all_ind_columns ic ON ic.index_owner = i.owner AND ic.index_name = i.index_name '
        'LEFT JOIN all_ind_expressions ie ON ie.index_owner = ic.index_owner AND ie.index_name = ic.index_name '
        'AND ie.column_position = ic.column_position '
        'WHERE i.table_owner = $owner AND i.table_name = ${lit(t.name)} ORDER BY i.index_name, ic.column_position',
  ]);
  final indexes = <String, IndexDef>{};
  for (final e in groupRows(ixRows, 'index_name').entries) {
    final first = e.value.first;
    final cols = <String>[], desc = <String>{};
    for (final r in e.value) {
      final expr = rowText(r, 'column_expression');
      final descending = rowText(r, 'descend') == 'DESC';
      // A DESC column is stored as the expression "COL".
      final quoted = expr == null ? null : RegExp(r'^"([^"]+)"$').firstMatch(expr.trim());
      final col = quoted != null
          ? quoted.group(1)!
          : (expr != null ? '(${stripParens(expr)})' : rowText(r, 'column_name')!);
      cols.add(col);
      if (descending) desc.add(col);
    }
    final type = rowText(first, 'index_type') ?? '';
    indexes[e.key.toLowerCase()] = IndexDef(
      name: e.key,
      columns: cols,
      unique: rowText(first, 'uniqueness') == 'UNIQUE',
      descending: desc,
      method: type.contains('BITMAP') ? 'bitmap' : null,
      enabled: rowText(first, 'status') != 'UNUSABLE',
    );
  }

  final colCond = 'owner = $owner AND table_name = ${lit(t.name)}';
  final colRows = await q.first([
    "SELECT column_name, NULLIF(collation, 'USING_NLS_COMP') AS collation, virtual_column, data_default "
        "FROM all_tab_cols WHERE $colCond AND hidden_column = 'NO'",
    "SELECT column_name, virtual_column, data_default FROM all_tab_cols WHERE $colCond AND hidden_column = 'NO'",
  ]);
  final identity = <String, String>{};
  try {
    for (final r in await q.first(['SELECT column_name, identity_options FROM all_tab_identity_cols WHERE $colCond'])) {
      identity[rowText(r, 'column_name')!.toLowerCase()] = rowText(r, 'identity_options') ?? '';
    }
  } catch (_) {
    // Before 12c.
  }
  int? option(String text, String name) {
    final v = int.tryParse(RegExp('$name: (-?\\d+)').firstMatch(text)?.group(1) ?? '');
    return v == null || v == 1 ? null : v;
  }

  final columns = <String, ColumnExtra>{};
  for (final r in colRows) {
    final name = rowText(r, 'column_name')!.toLowerCase();
    final id = identity[name];
    columns[name] = ColumnExtra(
      collation: rowText(r, 'collation'),
      computed: rowText(r, 'virtual_column') == 'YES' ? stripParens(rowText(r, 'data_default') ?? '') : null,
      computedStored: false,
      identitySeed: id == null ? null : option(id, 'START WITH'),
      identityIncrement: id == null ? null : option(id, 'INCREMENT BY'),
    );
  }
  for (final e in identity.entries) {
    columns.putIfAbsent(
      e.key,
      () =>
          ColumnExtra(identitySeed: option(e.value, 'START WITH'), identityIncrement: option(e.value, 'INCREMENT BY')),
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
