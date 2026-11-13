// Stage 3 of the SQL completion: fills the typed requests of the context
// with names from the script (CTEs) and the database catalog.

import '../../model/db_objects.dart';
import '../sql_keywords.dart';
import 'catalog.dart';
import 'context.dart';
import 'cte.dart';
import 'scope.dart';

enum SqlItemKind {
  column,
  table,
  view,
  cte,
  keyword,
  function,
  type,

  /// Placeholder while database objects are loading (inserts nothing).
  loading,
}

class SqlCompletionItem {
  const SqlCompletionItem(this.insert, this.kind, {this.label, this.detail, this.prio = 0, this.matchText});

  /// Text inserted in place of the input.
  final String insert;
  final SqlItemKind kind;

  /// Shown in the list (defaults to [insert]).
  final String? label;

  /// Right-aligned hint (owner table, type, schema).
  final String? detail;

  /// Order among the items of the same request (higher first).
  final int prio;

  /// Text matched against the input (defaults to [insert]).
  final String? matchText;

  String get display => label ?? insert;
  String get text => matchText ?? insert;

  @override
  String toString() => 'SqlCompletionItem($insert, ${kind.name}, prio $prio)';
}

/// Keywords proposed before the others with the same prefix.
const kCommonSqlKeywords = [
  'SELECT',
  'FROM',
  'WHERE',
  'AND',
  'OR',
  'NOT',
  'NULL',
  'IS',
  'IN',
  'AS',
  'ON',
  'JOIN',
  'INNER',
  'LEFT',
  'RIGHT',
  'ORDER',
  'GROUP',
  'BY',
  'HAVING',
  'DISTINCT',
  'LIKE',
  'BETWEEN',
  'CASE',
  'WHEN',
  'THEN',
  'ELSE',
  'END',
  'INSERT',
  'INTO',
  'VALUES',
  'UPDATE',
  'SET',
  'DELETE',
  'WITH',
  'UNION',
  'ALL',
  'EXISTS',
  'DESC',
  'ASC',
];

class SqlCandidates {
  SqlCandidates(this.catalog);

  final SqlCompletionCatalog catalog;

  /// One list per request of [ctx], in the same order.
  List<List<SqlCompletionItem>> generate(SqlCompletionContext ctx) => [
    for (final s in ctx.suggestions) _items(s, ctx.scope),
  ];

  List<SqlCompletionItem> _items(SqlSuggestion s, SqlCompletionScope scope) => switch (s) {
    ColumnSuggestion(:final tables) => [
      for (final t in tables) ...columnsOf(t, scope).map((c) => _withPrio(c, -t.depth)),
    ],
    TableSuggestion(:final schema) => _tables(scope, schema),
    KeywordSuggestion() => [
      for (final k in kCommonSqlKeywords) SqlCompletionItem(k, SqlItemKind.keyword, prio: 1),
      for (final k in kSqlKeywords) SqlCompletionItem(k, SqlItemKind.keyword),
    ],
    FunctionSuggestion() => [for (final f in kSqlFunctions) SqlCompletionItem(f, SqlItemKind.function)],
    TypeSuggestion() => [for (final t in kSqlTypes) SqlCompletionItem(t, SqlItemKind.type)],
  };

  static SqlCompletionItem _withPrio(SqlCompletionItem c, int prio) =>
      SqlCompletionItem(c.insert, c.kind, label: c.label, detail: c.detail, prio: prio, matchText: c.matchText);

  List<SqlCompletionItem> _tables(SqlCompletionScope scope, String? schema) {
    final s = schema?.toLowerCase();
    return [
      if (s == null)
        for (final c in scope.ctes.values)
          SqlCompletionItem(catalog.quote(c.name), SqlItemKind.cte, detail: 'CTE', prio: 2),
      for (final t in catalog.tables)
        if (s == null || t.schema?.toLowerCase() == s || t.catalog?.toLowerCase() == s)
          SqlCompletionItem(
            catalog.quote(t.name),
            t.isView ? SqlItemKind.view : SqlItemKind.table,
            detail: t.schema ?? t.catalog,
            prio: t.isView ? 0 : 1,
          ),
    ];
  }

  /// Columns of a table or CTE reference.
  List<SqlCompletionItem> columnsOf(SqlTableRef ref, SqlCompletionScope scope, [int depth = 0]) {
    final cte = ref.schema == null ? scope.cte(ref.name) : null;
    if (cte != null) return _cteColumns(cte, scope, depth);
    final t = catalog.table(ref.name, schema: ref.schema);
    if (t == null) return const [];
    return [
      for (final c in catalog.columns(t) ?? const <DbColumn>[])
        SqlCompletionItem(catalog.quote(c.name), SqlItemKind.column, detail: '${t.name} · ${c.fullType}'),
    ];
  }

  /// Columns of a CTE: its own column names, plus those of the tables behind
  /// `*` / `x.*` in its select list (resolved inside the CTE body).
  List<SqlCompletionItem> _cteColumns(SqlCte cte, SqlCompletionScope scope, int depth) {
    final out = [
      for (final c in cte.columns) SqlCompletionItem(catalog.quote(c), SqlItemKind.column, detail: cte.name),
    ];
    if (cte.starSources.isEmpty || depth > 4) return out;
    final body = sqlTableRefs(cte.body);
    for (final q in cte.starSources) {
      final sources = q == null ? body : body.where((r) => r.identifiedBy(q));
      for (final src in sources) {
        // A recursive CTE references itself.
        if (src.name.toLowerCase() == cte.name.toLowerCase()) continue;
        for (final c in columnsOf(SqlTableRef(src.name, schema: src.schema), scope, depth + 1)) {
          out.add(SqlCompletionItem(c.insert, SqlItemKind.column, detail: '${cte.name} · ${c.detail ?? ''}'));
        }
      }
    }
    return out;
  }
}
