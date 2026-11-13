// Stage 2 of the SQL completion: what to propose. Turns the scope at the
// caret into typed requests (like pgcli's suggest_type): which columns,
// tables, keywords... in order of relevance for the clause. It knows nothing
// about the database: the requests are filled by the candidates stage.

import 'cte.dart';
import 'scope.dart';

sealed class SqlSuggestion {
  const SqlSuggestion();
}

/// Columns of [tables] (tables or CTEs), inner query block first.
final class ColumnSuggestion extends SqlSuggestion {
  const ColumnSuggestion(this.tables);
  final List<SqlTableRef> tables;
}

/// CTEs, tables and views ([schema]: only that schema, typed as `schema.`).
final class TableSuggestion extends SqlSuggestion {
  const TableSuggestion({this.schema});
  final String? schema;
}

final class KeywordSuggestion extends SqlSuggestion {
  const KeywordSuggestion();
}

final class FunctionSuggestion extends SqlSuggestion {
  const FunctionSuggestion();
}

final class TypeSuggestion extends SqlSuggestion {
  const TypeSuggestion();
}

/// Tables joinable to [tables] through a foreign key, with the ON condition
/// (`JOIN |`).
final class JoinSuggestion extends SqlSuggestion {
  const JoinSuggestion(this.tables);
  final List<SqlTableRef> tables;
}

/// Join conditions between [last] (the table just joined) and [others]
/// (`JOIN b ON |`): foreign keys, then key-like columns with the same name.
final class JoinConditionSuggestion extends SqlSuggestion {
  const JoinConditionSuggestion(this.last, this.others);
  final SqlTableRef last;
  final List<SqlTableRef> others;
}

/// Expansion of `*` (or `x.*`, [qualifier] = `x`) into the column list.
final class StarSuggestion extends SqlSuggestion {
  const StarSuggestion(this.tables, {this.qualifier});
  final List<SqlTableRef> tables;
  final String? qualifier;
}

/// Words written elsewhere in the editor (DBeaver's "hippie" proposals):
/// names the catalog does not know yet (temp tables, aliases, variables).
final class WordSuggestion extends SqlSuggestion {
  const WordSuggestion(this.words);
  final Set<String> words;
}

class SqlCompletionContext {
  const SqlCompletionContext({required this.input, required this.scope, required this.suggestions, this.parent});

  /// Text before the caret replaced by the accepted proposal.
  final String input;

  /// Qualifier before the input (`alias.`, `schema.`), unquoted.
  final String? parent;

  final SqlCompletionScope scope;

  /// Requests, most relevant kind first.
  final List<SqlSuggestion> suggestions;
}

/// What to propose at [offset] of [script]; null when nothing is being typed.
SqlCompletionContext? sqlCompletionContext(String script, int offset) {
  offset = offset.clamp(0, script.length);
  final star = _starContext(script, offset);
  if (star != null) return star;
  final token = partialWordPattern.firstMatch(script.substring(0, offset))?[0] ?? '';
  if (token.isEmpty) return null;
  final scope = sqlCompletionScope(script, offset);

  final dot = token.lastIndexOf('.');
  if (dot >= 0) {
    final parent = bareIdentifier(token.substring(0, dot).split('.').last);
    final input = token.substring(dot + 1);
    if (scope.clause == SqlClause.table) {
      return SqlCompletionContext(
        input: input,
        parent: parent,
        scope: scope,
        suggestions: [TableSuggestion(schema: parent)],
      );
    }
    final ref = scope.refFor(parent) ?? SqlTableRef(parent);
    return SqlCompletionContext(
      input: input,
      parent: parent,
      scope: scope,
      suggestions: [
        ColumnSuggestion([ref]),
      ],
    );
  }
  if (token.length < 2 && !RegExp(r'^[A-Za-z]$').hasMatch(token)) return null;

  // Columns of the tables / CTEs of the query under the caret. Before its
  // FROM is written, the CTEs of the statement are the likely sources.
  final columns = ColumnSuggestion([
    ...scope.refs,
    if (!scope.hasFrom) ...scope.ctes.values.map((c) => SqlTableRef(c.name)),
  ]);
  final before = scope.refsBefore;
  final suggestions = switch (scope.clause) {
    SqlClause.column => [
      if (scope.keyword == 'on' && before.length > 1)
        JoinConditionSuggestion(before.last, before.sublist(0, before.length - 1)),
      columns,
      const FunctionSuggestion(),
      const KeywordSuggestion(),
      const TableSuggestion(),
      const TypeSuggestion(),
    ],
    SqlClause.table => [
      if (scope.keyword == 'join' && before.isNotEmpty) JoinSuggestion(before),
      const TableSuggestion(),
      const KeywordSuggestion(),
      columns,
      const FunctionSuggestion(),
      const TypeSuggestion(),
    ],
    SqlClause.other => [
      const KeywordSuggestion(),
      columns,
      const TableSuggestion(),
      const FunctionSuggestion(),
      const TypeSuggestion(),
    ],
  };
  if (token.length >= 2) suggestions.add(WordSuggestion(_documentWords(script, offset - token.length, offset)));
  return SqlCompletionContext(input: token, scope: scope, suggestions: suggestions);
}

/// `SELECT *|`, `SELECT a, x.*|`: expansion of the star into the columns.
SqlCompletionContext? _starContext(String script, int offset) {
  final m = RegExp(r'(?:("[^"]*"|\[[^\]]*\]|`[^`]*`|[\w$#@]+)\s*\.\s*)?\*$').firstMatch(script.substring(0, offset));
  if (m == null) return null;
  final prior = script.substring(0, m.start);
  if (!RegExp(r'(?:\bselect|\bdistinct|,)\s*$', caseSensitive: false).hasMatch(prior)) return null;
  final scope = sqlCompletionScope(script, offset);
  final seg = scope.segmentBefore;
  final (_, keyword) = sqlClauseOf(seg.length >= m[0]!.length ? seg.substring(0, seg.length - m[0]!.length) : seg);
  if (keyword != 'select' && keyword != 'distinct') return null;
  final q = m[1] == null ? null : bareIdentifier(m[1]!);
  final tables = q == null
      ? [
          for (final r in scope.refs)
            if (r.depth == 0) r,
        ]
      : [scope.refFor(q) ?? SqlTableRef(q)];
  if (tables.isEmpty) return null;
  return SqlCompletionContext(
    input: m[0]!,
    scope: scope,
    suggestions: [StarSuggestion(tables, qualifier: q)],
  );
}

/// Identifiers (3+ characters) written in [script], except the one being
/// typed between [from] and [to]. Literals and comments are skipped.
Set<String> _documentWords(String script, int from, int to) {
  if (script.length > 200000) return const {};
  final masked = maskSqlLiterals(script);
  return {
    for (final m in RegExp(r'[A-Za-z_#@][\w$#@]{2,}').allMatches(masked))
      if (m.end < from || m.start > to) m[0]!,
  };
}

/// Identifier without its quotes (`[a b]`, `"a b"`, `` `a b` ``).
String bareIdentifier(String s) => s.replaceAll(RegExp(r'^["\[`]|["\]`]$'), '');

/// Words of an identifier: split on `_`, `$`, spaces, digits and camel humps.
List<String> sqlIdentifierParts(String s) =>
    RegExp(r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+').allMatches(s).map((m) => m[0]!).toList();
