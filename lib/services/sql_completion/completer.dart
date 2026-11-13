// SQL editor autocompletion, staged like pgcli / DBeaver's legacy engine:
//
//   scope.dart       where the caret is (statement, query blocks, tables,
//                    aliases, CTEs, clause)
//   context.dart     what to propose (typed requests: columns of..., tables,
//                    keywords...)
//   candidates.dart  names for each request (script CTEs + database catalog)
//   ranking.dart     matching against the input and ordering
//   usage.dart       how often names were used (query history)
//
// Text based, no full SQL parser: the same rules work for every database and
// on incomplete statements.

import 'candidates.dart';
import 'catalog.dart';
import 'context.dart';
import 'ranking.dart';
import 'usage.dart';

export 'candidates.dart' show SqlCompletionItem, SqlItemKind;
export 'catalog.dart';
export 'usage.dart';

class SqlCompletionResult {
  const SqlCompletionResult(this.input, this.items);

  /// Text before the caret replaced by the accepted item.
  final String input;
  final List<SqlCompletionItem> items;
}

class SqlCompleter {
  SqlCompleter(this.catalog, {this.usage});

  final SqlCompletionCatalog catalog;

  /// Past uses of names, to order equally relevant items.
  final SqlUsageStats? usage;

  /// Proposals at [offset] of [script]; null when there is none.
  SqlCompletionResult? complete(String script, int offset) {
    final ctx = sqlCompletionContext(script, offset);
    if (ctx == null) return null;
    final candidates = SqlCandidates(catalog);
    final groups = candidates.generate(ctx);
    // Objects still loading: a placeholder row keeps the popup open, it is
    // refreshed when they arrive ([SqlCompletionCatalog.changes]).
    if (candidates.waiting) {
      groups.add([SqlCompletionItem(ctx.input, SqlItemKind.loading, label: 'Caricamento oggetti del database…')]);
    }
    final items = rankCompletions(ctx.input, groups, usage: usage?.count);
    if (items.isEmpty) return null;
    return SqlCompletionResult(ctx.input, items);
  }
}
