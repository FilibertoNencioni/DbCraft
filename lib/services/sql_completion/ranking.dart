// Stage 4 of the SQL completion: matches the candidates against the input
// and orders them.
//
// Matching (DataGrip / pgcli style), best first:
//   prefix      `cust`  -> CustomerId
//   word start  `id`    -> Customer_Id, CustomerId (after `_`, space, camel hump)
//   initials    `ci`    -> CustomerId, customer_id
//   contains    `tom`   -> CustomerId            (2+ characters)
//   fuzzy       `cstid` -> CustomerId            (3+ characters, in order)
//
// Order: good matches (prefix, word start, initials) before weak ones
// (contains, fuzzy); then the kind the clause expects (request order); then
// match quality, item priority, usage frequency, shorter names.

import 'candidates.dart';
import 'context.dart';

/// How well an item matches the input (higher is better).
class SqlMatch {
  const SqlMatch(this.tier, this.fine);

  static const prefix = 4, wordStart = 3, initials = 2, contains = 1, fuzzy = 0;

  final int tier;

  /// Finer score within the tier (higher is better).
  final int fine;

  bool get good => tier >= initials;
}

/// Match of [candidate] for [input], null when it does not match.
SqlMatch? sqlMatch(String candidate, String input) {
  final word = bareIdentifier(candidate);
  final w = word.toLowerCase(), i = bareIdentifier(input).toLowerCase();
  if (i.isEmpty) return const SqlMatch(SqlMatch.prefix, 0);
  if (w == i) return null; // already typed
  if (w.startsWith(i)) return SqlMatch(SqlMatch.prefix, word.startsWith(bareIdentifier(input)) ? 1 : 0);
  final parts = sqlIdentifierParts(word);
  for (var k = 1; k < parts.length; k++) {
    if (parts[k].toLowerCase().startsWith(i)) return SqlMatch(SqlMatch.wordStart, -k);
  }
  if (i.length >= 2 && parts.length > 1) {
    final initials = parts.map((p) => p[0].toLowerCase()).join();
    if (initials.startsWith(i)) return SqlMatch(SqlMatch.initials, -initials.length);
  }
  if (i.length >= 2) {
    final at = w.indexOf(i);
    if (at >= 0) return SqlMatch(SqlMatch.contains, -at);
  }
  if (i.length >= 3) {
    // Characters in order, tightest and earliest span first (pgcli).
    var best = -1, bestStart = 0;
    for (var start = w.indexOf(i[0]); start >= 0; start = w.indexOf(i[0], start + 1)) {
      var pos = start, ok = true;
      for (var k = 1; k < i.length; k++) {
        pos = w.indexOf(i[k], pos + 1);
        if (pos < 0) {
          ok = false;
          break;
        }
      }
      if (!ok) break;
      final span = pos - start + 1;
      if (best < 0 || span < best) {
        best = span;
        bestStart = start;
      }
    }
    if (best >= 0) return SqlMatch(SqlMatch.fuzzy, -best * 100 - bestStart);
  }
  return null;
}

/// Matching items of [groups] (one list per request, most relevant request
/// first), ordered and without duplicates. [usage] counts how often a name
/// (lower case) was used in past queries.
List<SqlCompletionItem> rankCompletions(
  String input,
  List<List<SqlCompletionItem>> groups, {
  int limit = 80,
  int Function(String name)? usage,
}) {
  final seen = <String>{};
  final names = <String>{}; // proposed names, to drop duplicate words
  final scored = <_Scored>[];
  for (final (g, items) in groups.indexed) {
    for (final it in items) {
      final m = switch (it.kind) {
        SqlItemKind.loading => const SqlMatch(SqlMatch.fuzzy, -1 << 30),
        SqlItemKind.expand => const SqlMatch(SqlMatch.prefix, 0),
        _ => sqlMatch(it.text, input),
      };
      if (m == null) continue;
      final name = bareIdentifier(it.text).toLowerCase();
      // Words of the document only for names nothing else proposes.
      if (it.kind == SqlItemKind.word) {
        if (names.contains(name)) continue;
      } else {
        names.add(name);
      }
      if (!seen.add('${it.kind.name}:${it.insert.toLowerCase()}')) continue;
      final uses = usage == null ? 0 : usage(name);
      scored.add(_Scored(it, m, g, uses, scored.length));
    }
  }
  scored.sort((a, b) {
    var c = (b.match.good ? 1 : 0).compareTo(a.match.good ? 1 : 0);
    if (c != 0) return c;
    c = a.group.compareTo(b.group);
    if (c != 0) return c;
    c = b.match.tier.compareTo(a.match.tier);
    if (c != 0) return c;
    c = b.item.prio.compareTo(a.item.prio);
    if (c != 0) return c;
    c = b.uses.compareTo(a.uses);
    if (c != 0) return c;
    c = b.match.fine.compareTo(a.match.fine);
    if (c != 0) return c;
    return a.index.compareTo(b.index);
  });
  return [for (final s in scored.take(limit)) s.item];
}

class _Scored {
  _Scored(this.item, this.match, this.group, this.uses, this.index);
  final SqlCompletionItem item;
  final SqlMatch match;
  final int group;
  final int uses;
  final int index;
}
