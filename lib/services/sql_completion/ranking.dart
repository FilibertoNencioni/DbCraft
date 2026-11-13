// Stage 4 of the SQL completion: matches the candidates against the input
// and orders them.

import 'candidates.dart';
import 'context.dart';

/// Matching items of [groups] (one list per request, most relevant request
/// first), ordered and without duplicates.
List<SqlCompletionItem> rankCompletions(String input, List<List<SqlCompletionItem>> groups, {int limit = 80}) {
  final seen = <String>{};
  final scored = <(SqlCompletionItem, int, int)>[]; // item, group, insertion
  for (final (g, items) in groups.indexed) {
    for (final it in items) {
      if (!_matches(it.text, input)) continue;
      if (!seen.add('${it.kind.name}:${it.insert.toLowerCase()}')) continue;
      scored.add((it, g, scored.length));
    }
  }
  scored.sort((a, b) {
    var c = a.$2.compareTo(b.$2);
    if (c != 0) return c;
    c = b.$1.prio.compareTo(a.$1.prio);
    if (c != 0) return c;
    return a.$3.compareTo(b.$3);
  });
  return [for (final s in scored.take(limit)) s.$1];
}

bool _matches(String candidate, String input) {
  if (input.isEmpty) return true;
  final w = bareIdentifier(candidate).toLowerCase(), i = bareIdentifier(input).toLowerCase();
  return candidate.toLowerCase() != input.toLowerCase() && w.startsWith(i);
}
