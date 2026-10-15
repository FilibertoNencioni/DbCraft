// Pure helpers of the performance dashboard: sample buffers for the
// sparklines, rates computed from cumulative counters, the blocking tree and
// value formatting.
import 'dart:math' as math;

/// Fixed size ring of samples (oldest first). Null samples are gaps.
class SampleBuffer {
  SampleBuffer([this.capacity = 120]) : assert(capacity > 0);
  final int capacity;
  final List<double?> _values = [];

  void add(double? v) {
    _values.add(v == null || v.isNaN || v.isInfinite ? null : v);
    if (_values.length > capacity) _values.removeRange(0, _values.length - capacity);
  }

  void clear() => _values.clear();

  List<double?> get values => List.unmodifiable(_values);
  int get length => _values.length;
  bool get isEmpty => _values.every((v) => v == null);

  double? get last {
    for (var i = _values.length - 1; i >= 0; i--) {
      if (_values[i] != null) return _values[i];
    }
    return null;
  }

  double? get min => _values.whereType<double>().fold<double?>(null, (a, v) => a == null ? v : math.min(a, v));
  double? get max => _values.whereType<double>().fold<double?>(null, (a, v) => a == null ? v : math.max(a, v));
}

/// Cumulative counters read at a given time.
class CounterSnapshot {
  CounterSnapshot(this.time, this.values);
  final DateTime time;
  final Map<String, double> values;

  double? operator [](String key) => values[key];
}

/// Rate per second of [key] (or the sum of [keys]) between two snapshots.
/// Null when a value is missing, the interval is empty or the counter was
/// reset (negative delta, e.g. after a server restart / stats reset).
double? ratePerSec(CounterSnapshot? prev, CounterSnapshot cur, List<String> keys) {
  if (prev == null) return null;
  final dt = cur.time.difference(prev.time).inMicroseconds / 1e6;
  if (dt <= 0) return null;
  var delta = 0.0;
  for (final k in keys) {
    final a = prev[k], b = cur[k];
    if (a == null || b == null) return null;
    delta += b - a;
  }
  if (delta < 0) return null;
  return delta / dt;
}

/// Ratio hit / (hit + miss) in percent over the interval between the two
/// snapshots; falls back to the cumulative ratio when nothing happened.
double? hitRatio(CounterSnapshot? prev, CounterSnapshot cur, String hitKey, String missKey) {
  final h = cur[hitKey], m = cur[missKey];
  if (h == null || m == null) return null;
  if (prev != null) {
    final ph = prev[hitKey], pm = prev[missKey];
    if (ph != null && pm != null) {
      final dh = h - ph, dm = m - pm;
      if (dh >= 0 && dm >= 0 && dh + dm > 0) return dh * 100 / (dh + dm);
    }
  }
  return h + m > 0 ? h * 100 / (h + m) : null;
}

double? toDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is bool) return v ? 1 : 0;
  return double.tryParse(v.toString().trim());
}

// ---------------------------------------------------------------------------
// Blocking tree
// ---------------------------------------------------------------------------

/// A session involved in a lock chain.
class BlockingEntry {
  BlockingEntry(this.id, this.blockedBy, this.row);
  final String id;
  final List<String> blockedBy;

  /// Original row (null for blockers that were not returned by the query).
  final List<Object?>? row;
}

/// Flattened node of the blocking tree: [depth] 0 = head blocker.
class BlockingNode {
  BlockingNode(this.entry, this.depth, this.blockedCount);
  final BlockingEntry entry;
  final int depth;

  /// Sessions (directly or indirectly) waiting on this one.
  final int blockedCount;
}

/// Splits a "blocked by" value ("12", "12,15", "{12,15}", 0/null = none).
List<String> parseBlockers(Object? v) {
  if (v == null) return const [];
  return v
      .toString()
      .replaceAll(RegExp(r'[{}\[\]]'), '')
      .split(RegExp(r'[,\s]+'))
      .map((e) => e.trim())
      .map((e) => e.endsWith('.0') ? e.substring(0, e.length - 2) : e)
      .where((e) => e.isNotEmpty && e != '0' && e != 'null')
      .toList();
}

/// Orders the sessions as a "who blocks whom" tree: head blockers first,
/// each followed by the sessions waiting on it (depth first). Blockers that
/// are not in [entries] are added as synthetic entries; cycles (deadlocks
/// not yet resolved) are cut.
List<BlockingNode> buildBlockingTree(List<BlockingEntry> entries) {
  final byId = <String, BlockingEntry>{};
  for (final e in entries) {
    byId.putIfAbsent(e.id, () => e);
  }
  for (final e in entries) {
    for (final b in e.blockedBy) {
      byId.putIfAbsent(b, () => BlockingEntry(b, const [], null));
    }
  }
  final waiters = <String, List<String>>{};
  for (final e in byId.values) {
    for (final b in e.blockedBy) {
      if (b == e.id) continue;
      (waiters[b] ??= []).add(e.id);
    }
  }
  int countBlocked(String id, Set<String> seen) {
    var n = 0;
    for (final w in waiters[id] ?? const <String>[]) {
      if (seen.add(w)) n += 1 + countBlocked(w, seen);
    }
    return n;
  }

  final out = <BlockingNode>[];
  final emitted = <String>{};
  void emit(String id, int depth) {
    if (!emitted.add(id)) return;
    out.add(BlockingNode(byId[id]!, depth, countBlocked(id, {id})));
    final ws = [...?waiters[id]]..sort();
    for (final w in ws) {
      emit(w, depth + 1);
    }
  }

  final heads = byId.values.where((e) => e.blockedBy.where((b) => b != e.id).isEmpty).map((e) => e.id).toList()..sort();
  for (final h in heads) {
    if ((waiters[h] ?? const []).isNotEmpty) emit(h, 0);
  }
  // Cycles: no head; start from any remaining member.
  for (final e in byId.values) {
    if (!emitted.contains(e.id) && (e.blockedBy.isNotEmpty || (waiters[e.id] ?? const []).isNotEmpty)) {
      emit(e.id, 0);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

String formatBytes(double? v) {
  if (v == null) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var x = v.abs();
  var i = 0;
  while (x >= 1024 && i < units.length - 1) {
    x /= 1024;
    i++;
  }
  final s = i == 0 ? x.toStringAsFixed(0) : x.toStringAsFixed(x >= 100 ? 0 : 1);
  return '${v < 0 ? '-' : ''}${s.replaceAll('.', ',')} ${units[i]}';
}

String formatSeconds(double? v) {
  if (v == null) return '—';
  final s = v.round();
  if (s < 60) return '$s s';
  if (s < 3600) return '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
  if (s < 86400) return '${s ~/ 3600}h ${((s % 3600) ~/ 60).toString().padLeft(2, '0')}m';
  return '${s ~/ 86400}g ${((s % 86400) ~/ 3600)}h';
}

String formatNumber(double? v, {int decimals = 0}) {
  if (v == null) return '—';
  final neg = v < 0;
  final fixed = v.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final intPart = parts[0];
  final b = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) b.write('.');
    b.write(intPart[i]);
  }
  if (parts.length > 1) b.write(',${parts[1]}');
  return '${neg ? '-' : ''}$b';
}

/// Compact number for KPI tiles (1,2k, 3,4M).
String formatCompact(double? v, {int decimals = 1}) {
  if (v == null) return '—';
  final a = v.abs();
  if (a >= 1e9) return '${(v / 1e9).toStringAsFixed(decimals).replaceAll('.', ',')}G';
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(decimals).replaceAll('.', ',')}M';
  if (a >= 1e4) return '${(v / 1e3).toStringAsFixed(decimals).replaceAll('.', ',')}k';
  if (a < 10 && v != v.roundToDouble()) return v.toStringAsFixed(decimals).replaceAll('.', ',');
  return formatNumber(v);
}
