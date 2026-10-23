// Snowflake: UNIQUE constraints (recorded, not enforced) and collations.

import '../../../model/db_objects.dart';
import '../../../services/sql_dialect.dart';
import '../../schema/schema_model.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

Future<TableExtras> readSnowflakeTable(CatalogQueries q, SqlDialect d, DbTable t) async {
  final table = d.qualified(t.catalog, t.schema, t.name);
  final keys = await q.first(['SHOW UNIQUE KEYS IN TABLE $table']);
  final uniques = [
    for (final e in groupRows(keys, 'constraint_name').entries)
      UniqueDef(
        name: e.key,
        columns: [
          for (final r in (List.of(
            e.value,
          )..sort((a, b) => (rowInt(a, 'key_sequence') ?? 0) - (rowInt(b, 'key_sequence') ?? 0))))
            rowText(r, 'column_name')!,
        ],
      ),
  ];
  final pk = await q.first(['SHOW PRIMARY KEYS IN TABLE $table']);
  final info = t.catalog == null ? 'information_schema' : '${d.quoteIdent(t.catalog!)}.information_schema';
  final cols = await q.first([
    'SELECT COLUMN_NAME, COLLATION_NAME FROM $info.COLUMNS '
        'WHERE TABLE_SCHEMA = ${lit(t.schema ?? '')} AND TABLE_NAME = ${lit(t.name)}',
  ]);
  return TableExtras(
    uniques: uniques,
    primaryKeyName: pk.isEmpty ? null : rowText(pk.first, 'constraint_name'),
    columns: {
      for (final r in cols)
        rowText(r, 'column_name')!.toLowerCase(): ColumnExtra(collation: rowText(r, 'collation_name')),
    },
  );
}
