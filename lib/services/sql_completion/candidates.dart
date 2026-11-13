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

  /// Table to join with its ON condition, or a join condition.
  join,

  /// Expansion of `*` into the column list.
  expand,

  /// Word written elsewhere in the editor.
  word,

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

  /// A lookup of the last [generate] is waiting for the database.
  bool waiting = false;

  List<DbTable> get _tablesList {
    final list = catalog.tables;
    if (list.isEmpty && catalog.loading) waiting = true;
    return list;
  }

  DbTable? _table(String name, String? schema) {
    final t = catalog.table(name, schema: schema);
    if (t == null && catalog.loading) waiting = true;
    return t;
  }

  List<DbColumn> _columns(DbTable t) {
    final c = catalog.columns(t);
    if (c == null) waiting = true;
    return c ?? const [];
  }

  /// One list per request of [ctx], in the same order.
  List<List<SqlCompletionItem>> generate(SqlCompletionContext ctx) {
    waiting = false;
    return [for (final s in ctx.suggestions) _items(s, ctx.scope)];
  }

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
    JoinSuggestion(:final tables) => _joins(tables, scope),
    JoinConditionSuggestion(:final last, :final others) => _joinConditions(last, others, scope),
    StarSuggestion(:final tables, :final qualifier) => _star(tables, qualifier, scope),
    WordSuggestion(:final words) => [
      for (final w in words)
        if (!_reserved.contains(w.toUpperCase())) SqlCompletionItem(w, SqlItemKind.word, detail: 'testo'),
    ],
  };

  static final Set<String> _reserved = {
    for (final w in [...kSqlKeywords, ...kSqlFunctions, ...kSqlTypes, ...kCommonSqlKeywords]) w.toUpperCase(),
  };

  /// How the query names [r]: its alias, or its (quoted) name.
  String _refText(SqlTableRef r) => r.alias ?? catalog.quote(r.name);

  /// Database table of a reference (not for CTEs).
  DbTable? _dbTable(SqlTableRef r, SqlCompletionScope scope) =>
      r.schema == null && scope.cte(r.name) != null ? null : _table(r.name, r.schema);

  List<DbForeignKey> _fks(DbTable t, {required bool outgoing}) {
    final l = outgoing ? catalog.foreignKeys(t) : catalog.referencedBy(t);
    if (l == null) waiting = true;
    return l ?? const [];
  }

  static bool _same(String a, String b) => a.toLowerCase() == b.toLowerCase();

  /// Tables related to [tables] by a foreign key, with alias and ON condition
  /// (DataGrip / pgcli): `Orders o ON o.CustomerId = c.Id`.
  List<SqlCompletionItem> _joins(List<SqlTableRef> tables, SqlCompletionScope scope) {
    final used = {
      for (final r in scope.refs) ...[r.name.toLowerCase(), if (r.alias != null) r.alias!.toLowerCase()],
    };
    final out = <SqlCompletionItem>[];
    for (final r in tables.reversed) {
      final t = _dbTable(r, scope);
      if (t == null) continue;
      final ref = _refText(r);
      void add(String other, List<(String, String)> pairs, String? fkName) {
        final alias = _alias(other, {...used});
        final on = pairs.map((p) => '$alias.${catalog.quote(p.$1)} = $ref.${catalog.quote(p.$2)}').join(' AND ');
        final insert = '${catalog.quote(other)} $alias ON $on';
        if (out.any((o) => o.insert == insert)) return;
        out.add(
          SqlCompletionItem(
            insert,
            SqlItemKind.join,
            detail: fkName == null ? 'FK' : 'FK $fkName',
            prio: 2,
            matchText: other,
          ),
        );
      }

      // r is the child: join its parents.
      for (final fk in _fks(t, outgoing: true)) {
        add(fk.pkTable, [for (var i = 0; i < fk.columns.length; i++) (fk.refColumns[i], fk.columns[i])], fk.name);
      }
      // r is the parent: join its children.
      for (final fk in _fks(t, outgoing: false)) {
        add(fk.fkTable, [for (var i = 0; i < fk.columns.length; i++) (fk.columns[i], fk.refColumns[i])], fk.name);
      }
    }
    return out;
  }

  /// Alias for [table] from the initials of its words, not in [used].
  String _alias(String table, Set<String> used) {
    final parts = sqlIdentifierParts(table);
    var base = (parts.isEmpty ? table.substring(0, 1) : parts.map((p) => p[0]).join()).toLowerCase();
    if (!RegExp(r'^[a-z_]').hasMatch(base)) base = 't$base';
    var alias = base;
    for (var n = 2; used.contains(alias) || _reserved.contains(alias.toUpperCase()); n++) {
      alias = '$base$n';
    }
    return alias;
  }

  /// Conditions between the table just joined and the previous ones: foreign
  /// keys first, then key-like columns (…id, …code, …key) with the same name.
  List<SqlCompletionItem> _joinConditions(SqlTableRef last, List<SqlTableRef> others, SqlCompletionScope scope) {
    final out = <SqlCompletionItem>[];
    final lref = _refText(last);
    final lt = _dbTable(last, scope);
    for (final o in others.reversed) {
      final oref = _refText(o);
      final ot = _dbTable(o, scope);
      if (lt != null && ot != null) {
        for (final fk in _fks(lt, outgoing: true)) {
          if (!_same(fk.pkTable, ot.name)) continue;
          final on = [
            for (var i = 0; i < fk.columns.length; i++)
              '$lref.${catalog.quote(fk.columns[i])} = $oref.${catalog.quote(fk.refColumns[i])}',
          ].join(' AND ');
          out.add(SqlCompletionItem(on, SqlItemKind.join, detail: 'FK ${fk.name ?? ''}'.trim(), prio: 2));
        }
        for (final fk in _fks(lt, outgoing: false)) {
          if (!_same(fk.fkTable, ot.name)) continue;
          final on = [
            for (var i = 0; i < fk.columns.length; i++)
              '$lref.${catalog.quote(fk.refColumns[i])} = $oref.${catalog.quote(fk.columns[i])}',
          ].join(' AND ');
          out.add(SqlCompletionItem(on, SqlItemKind.join, detail: 'FK ${fk.name ?? ''}'.trim(), prio: 2));
        }
      }
      final ocols = {for (final c in columnsOf(o, scope)) bareIdentifier(c.insert).toLowerCase(): c.insert};
      for (final c in columnsOf(last, scope)) {
        final name = bareIdentifier(c.insert).toLowerCase();
        if (!RegExp(r'(id|code|key)$').hasMatch(name)) continue;
        final oc = ocols[name];
        if (oc == null) continue;
        final on = '$lref.${c.insert} = $oref.$oc';
        if (out.any((x) => x.insert == on)) continue;
        out.add(SqlCompletionItem(on, SqlItemKind.join, detail: 'stesso nome', prio: 1));
      }
    }
    return out;
  }

  /// `*` -> every column of [tables] (qualified when more than one table or
  /// when written as `x.*`).
  List<SqlCompletionItem> _star(List<SqlTableRef> tables, String? qualifier, SqlCompletionScope scope) {
    final qualify = qualifier != null || tables.length > 1;
    final cols = <String>[];
    for (final t in tables) {
      final ref = qualifier != null ? catalog.quote(qualifier) : _refText(t);
      for (final c in columnsOf(t, scope)) {
        cols.add(qualify ? '$ref.${c.insert}' : c.insert);
      }
    }
    if (cols.isEmpty) return const [];
    return [
      SqlCompletionItem(
        cols.join(', '),
        SqlItemKind.expand,
        label: '* → ${cols.join(', ')}',
        detail: cols.length == 1 ? '1 colonna' : '${cols.length} colonne',
      ),
    ];
  }

  static SqlCompletionItem _withPrio(SqlCompletionItem c, int prio) =>
      SqlCompletionItem(c.insert, c.kind, label: c.label, detail: c.detail, prio: prio, matchText: c.matchText);

  List<SqlCompletionItem> _tables(SqlCompletionScope scope, String? schema) {
    final s = schema?.toLowerCase();
    return [
      if (s == null)
        for (final c in scope.ctes.values)
          SqlCompletionItem(catalog.quote(c.name), SqlItemKind.cte, detail: 'CTE', prio: 2),
      for (final t in _tablesList)
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
    final t = _table(ref.name, ref.schema);
    if (t == null) return const [];
    return [
      for (final c in _columns(t))
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
