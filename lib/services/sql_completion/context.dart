// Stage 2 of the SQL completion: what to propose. Turns the scope at the
// caret into typed requests (like pgcli's suggest_type): which columns,
// tables, keywords... in order of relevance for the clause. It knows nothing
// about the database: the requests are filled by the candidates stage.

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
  final suggestions = switch (scope.clause) {
    SqlClause.column => [
      columns,
      const FunctionSuggestion(),
      const KeywordSuggestion(),
      const TableSuggestion(),
      const TypeSuggestion(),
    ],
    SqlClause.table => [
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
  return SqlCompletionContext(input: token, scope: scope, suggestions: suggestions);
}

/// Identifier without its quotes (`[a b]`, `"a b"`, `` `a b` ``).
String bareIdentifier(String s) => s.replaceAll(RegExp(r'^["\[`]|["\]`]$'), '');
