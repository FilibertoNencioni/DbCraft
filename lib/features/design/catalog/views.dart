// Definition of a view (ODBC does not expose it) from the catalog of each
// DBMS.

import '../../../model/db_objects.dart';
import '../../../services/sql_dialect.dart';
import '../model/object_defs.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

ViewCheckOption _check(String? s) => switch (s?.toUpperCase()) {
  'LOCAL' => ViewCheckOption.local,
  'CASCADED' || 'CASCADE' || 'YES' || 'Y' => ViewCheckOption.cascaded,
  _ => ViewCheckOption.none,
};

/// [t] as a [ViewDef] (null when the definition cannot be found).
Future<ViewDef?> readViewDef(CatalogQueries q, SqlDialect d, DbTable t) async {
  final name = lit(t.name);
  ViewDef view(String def, {bool materialized = false, ViewCheckOption? check, String? comment}) {
    final split = splitViewSql(def);
    return ViewDef(
      catalog: t.catalog,
      schema: t.schema,
      name: t.name,
      definition: split.query,
      materialized: materialized,
      checkOption: check ?? split.check,
      comment: comment ?? (t.remarks == null || t.remarks!.isEmpty ? null : t.remarks),
    );
  }

  switch (d.family) {
    case DbFamily.postgres:
      final schema = lit(t.schema ?? 'public');
      final rows = await q.first([
        'SELECT pg_get_viewdef(c.oid, true) AS def, c.relkind, '
            "coalesce(array_to_string(c.reloptions, ','), '') AS options, obj_description(c.oid, 'pg_class') AS comment, "
            '(SELECT v.check_option FROM information_schema.views v WHERE v.table_schema = n.nspname '
            'AND v.table_name = c.relname) AS check_option '
            'FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace '
            "WHERE n.nspname = $schema AND c.relname = $name AND c.relkind IN ('v', 'm')",
      ]);
      if (rows.isEmpty) return null;
      final r = rows.first;
      final materialized = rowText(r, 'relkind') == 'm';
      final v = view(
        rowText(r, 'def') ?? '',
        materialized: materialized,
        check: materialized ? ViewCheckOption.none : _check(rowText(r, 'check_option')),
        comment: rowText(r, 'comment'),
      );
      return v.copyWith(securityBarrier: (rowText(r, 'options') ?? '').contains('security_barrier=true'));
    case DbFamily.sqlServer:
      final db = t.catalog == null ? '' : '${d.quoteIdent(t.catalog!)}.';
      final obj =
          'OBJECT_ID(N${lit([if (t.catalog != null) t.catalog!, t.schema ?? 'dbo', t.name].map((e) => '[${e.replaceAll(']', ']]')}]').join('.'))})';
      final rows = await q.first([
        'SELECT m.definition, v.with_check_option, OBJECTPROPERTY(v.object_id, \'IsSchemaBound\') AS bound, '
            'CAST(ep.value AS nvarchar(4000)) AS comment '
            'FROM ${db}sys.views v JOIN ${db}sys.sql_modules m ON m.object_id = v.object_id '
            "LEFT JOIN ${db}sys.extended_properties ep ON ep.class = 1 AND ep.major_id = v.object_id AND ep.minor_id = 0 "
            "AND ep.name = 'MS_Description' WHERE v.object_id = $obj",
      ]);
      if (rows.isEmpty) return null;
      final r = rows.first;
      var def = rowText(r, 'definition') ?? '';
      // The stored text keeps WITH SCHEMABINDING in the header.
      def = def.replaceFirst(RegExp(r'\s+WITH\s+SCHEMABINDING\b', caseSensitive: false), '');
      return view(def, comment: rowText(r, 'comment')).copyWith(
        checkOption: rowBool(r, 'with_check_option') ? ViewCheckOption.cascaded : ViewCheckOption.none,
        schemaBinding: rowBool(r, 'bound'),
      );
    case DbFamily.mysql:
      final db = t.catalog ?? t.schema;
      final rows = await q.first([
        'SELECT VIEW_DEFINITION, CHECK_OPTION, SECURITY_TYPE FROM information_schema.VIEWS '
            'WHERE TABLE_SCHEMA = ${db == null ? 'DATABASE()' : lit(db)} AND TABLE_NAME = $name',
      ]);
      if (rows.isEmpty) return null;
      final r = rows.first;
      return view(
        rowText(r, 'view_definition') ?? '',
        check: _check(rowText(r, 'check_option')),
      ).copyWith(sqlSecurity: rowText(r, 'security_type'));
    case DbFamily.oracle:
      final owner = t.schema == null ? 'USER' : lit(t.schema!);
      final rows = await q.first([
        'SELECT text_vc AS def FROM all_views WHERE owner = $owner AND view_name = $name',
        'SELECT text AS def FROM all_views WHERE owner = $owner AND view_name = $name',
      ]);
      if (rows.isNotEmpty) return view(rowText(rows.first, 'def') ?? '');
      final mv = await q.first(['SELECT query AS def FROM all_mviews WHERE owner = $owner AND mview_name = $name']);
      return mv.isEmpty ? null : view(rowText(mv.first, 'def') ?? '', materialized: true);
    case DbFamily.db2:
      final schema = t.schema == null ? 'CURRENT SCHEMA' : lit(t.schema!);
      final rows = await q.first([
        'SELECT text, viewcheck FROM syscat.views WHERE viewschema = $schema AND viewname = $name',
      ]);
      if (rows.isEmpty) return null;
      final r = rows.first;
      final vc = rowText(r, 'viewcheck');
      return view(
        rowText(r, 'text') ?? '',
        check: vc == 'L' ? ViewCheckOption.local : (vc == 'C' ? ViewCheckOption.cascaded : null),
      );
    case DbFamily.sqlite:
      final schema = t.schema == null || t.schema == 'main' ? '' : '"${t.schema}".';
      final rows = await q.first(["SELECT sql FROM ${schema}sqlite_master WHERE type = 'view' AND name = $name"]);
      return rows.isEmpty ? null : view(rowText(rows.first, 'sql') ?? '');
    case DbFamily.firebird:
      final rows = await q.first([
        r'SELECT RDB$VIEW_SOURCE AS def FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = ' + name,
      ]);
      return rows.isEmpty ? null : view(rowText(rows.first, 'def') ?? '');
    case DbFamily.snowflake:
      final rows = await q.first(["SELECT GET_DDL('VIEW', ${lit(d.qualified(t.catalog, t.schema, t.name))}) AS def"]);
      if (rows.isEmpty) return null;
      final def = rowText(rows.first, 'def') ?? '';
      final head = def.substring(0, def.length.clamp(0, 200)).toUpperCase();
      return view(def, materialized: head.contains('MATERIALIZED')).copyWith(secure: head.contains('SECURE'));
    default:
      final rows = await q.first([
        'SELECT VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_NAME = $name'
            '${t.schema == null ? '' : ' AND TABLE_SCHEMA = ${lit(t.schema!)}'}',
      ]);
      return rows.isEmpty ? null : view(rowText(rows.first, 'view_definition') ?? '');
  }
}
