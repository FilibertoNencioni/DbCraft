// SQL editor autocompletion, staged like pgcli / DBeaver's legacy engine:
//
//   scope.dart       where the caret is (statement, query blocks, tables,
//                    aliases, CTEs, clause)
//   context.dart     what to propose (typed requests: columns of..., tables,
//                    keywords...)
//   candidates.dart  names for each request (script CTEs + database catalog)
//   ranking.dart     matching against the input and ordering
//
// Text based, no full SQL parser: the same rules work for every database and
// on incomplete statements.

import 'candidates.dart';
import 'catalog.dart';
import 'context.dart';
import 'ranking.dart';

export 'candidates.dart' show SqlCompletionItem, SqlItemKind;
export 'catalog.dart';

class SqlCompletionResult {
  const SqlCompletionResult(this.input, this.items);

  /// Text before the caret replaced by the accepted item.
  final String input;
  final List<SqlCompletionItem> items;
}

class SqlCompleter {
  SqlCompleter(this.catalog);

  final SqlCompletionCatalog catalog;

  /// Proposals at [offset] of [script]; null when there is none.
  SqlCompletionResult? complete(String script, int offset) {
    final ctx = sqlCompletionContext(script, offset);
    if (ctx == null) return null;
    final items = rankCompletions(ctx.input, SqlCandidates(catalog).generate(ctx));
    if (items.isEmpty) return null;
    return SqlCompletionResult(ctx.input, items);
  }
}
