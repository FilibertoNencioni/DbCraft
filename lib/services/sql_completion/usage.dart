// How often names were used in past queries (pgcli's prioritizer): ties in
// the ranking go to the names the user writes most.

/// Counts the identifiers of the query history, recounted when it changes.
class SqlUsageStats {
  SqlUsageStats(this.source, {this.maxQueries = 500});

  /// Executed statements, newest first.
  final Iterable<String> Function() source;
  final int maxQueries;

  Map<String, int> _counts = const {};
  (int, String?)? _stamp;

  static final _word = RegExp(r'[A-Za-z_][\w$#@]*');

  /// Uses of [name] (lower case).
  int count(String name) {
    _refresh();
    return _counts[name] ?? 0;
  }

  void _refresh() {
    final list = source();
    final stamp = (list.length, list.isEmpty ? null : list.first);
    if (stamp == _stamp) return;
    _stamp = stamp;
    final counts = <String, int>{};
    for (final sql in list.take(maxQueries)) {
      for (final m in _word.allMatches(sql)) {
        final w = m[0]!.toLowerCase();
        counts[w] = (counts[w] ?? 0) + 1;
      }
    }
    _counts = counts;
  }
}
