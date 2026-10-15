// Data compare engine (DBeaver PRO "Data compare"): pure Dart, no Flutter.
//
// Both sides deliver rows laid out as `[key columns…, compared columns…]`
// (same order on both sides). Two algorithms are available:
//  * merge-join: both sides are read ordered by the key and merged while
//    streaming; it needs the database ordering to agree with the comparator
//    used here, which is verified on the fly ([CompareOrderException]);
//  * hash-join: the source side is loaded in memory and the target side is
//    streamed against it; independent from collations and DBMS ordering.
import 'dart:typed_data';

/// Classification of a compared row.
enum RowDiff {
  identical('Identici', 'Identico'),
  different('Diversi', 'Diverso'),
  onlySource('Solo in origine', 'Solo in origine'),
  onlyTarget('Solo in destinazione', 'Solo in destinazione');

  const RowDiff(this.plural, this.singular);
  final String plural;
  final String singular;
}

/// How the values of a column are normalized before comparison.
enum ValueKind { auto, numeric, temporal, text, binary }

class CompareOptions {
  const CompareOptions({
    this.trimStrings = true,
    this.ignoreCase = false,
    this.nullEqualsEmpty = false,
    this.floatTolerance = 0,
    this.normalizeDates = true,
  });

  /// Ignore leading/trailing blanks (CHAR padding).
  final bool trimStrings;
  final bool ignoreCase;

  /// NULL and the empty string are considered equal (Oracle).
  final bool nullEqualsEmpty;

  /// Maximum absolute difference between two equal numbers.
  final double floatTolerance;

  /// `2024-01-02 00:00:00.000` equals `2024-01-02`, `T` equals a blank.
  final bool normalizeDates;
}

/// Raised when the rows of a side are not ordered as the comparator expects
/// (different collations): the caller should switch to the hash-join.
class CompareOrderException implements Exception {
  CompareOrderException(this.side, this.previous, this.current);
  final String side;
  final List<Object?> previous;
  final List<Object?> current;

  @override
  String toString() =>
      'L\'ordinamento di $side non coincide con quello del confronto '
      '(${previous.join(', ')} precede ${current.join(', ')}).';
}

/// Raised when the key columns do not identify the rows univocally.
class CompareDuplicateKeyException implements Exception {
  CompareDuplicateKeyException(this.side, this.key);
  final String side;
  final List<Object?> key;

  @override
  String toString() =>
      'La chiave (${key.map((e) => e ?? 'NULL').join(', ')}) è duplicata in $side: '
      'scegli colonne chiave che identificano le righe in modo univoco.';
}

class CompareCancelledException implements Exception {
  @override
  String toString() => 'Confronto interrotto';
}

class _NumVal {
  const _NumVal(this.canon, this.approx, {this.fromDouble = false});
  final String canon;
  final double approx;
  final bool fromDouble;
}

final _numberRe = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');
final _dateRe = RegExp(r'^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2})(:\d{2})?(\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?$');

/// Canonical form of a plain decimal number (no exponent): no leading zeros
/// in the integer part, no trailing zeros in the fraction, no "-0".
String canonicalDecimal(String s) {
  var t = s.trim();
  var neg = false;
  if (t.startsWith('-')) {
    neg = true;
    t = t.substring(1);
  } else if (t.startsWith('+')) {
    t = t.substring(1);
  }
  final dot = t.indexOf('.');
  var ip = dot < 0 ? t : t.substring(0, dot);
  var fp = dot < 0 ? '' : t.substring(dot + 1);
  ip = ip.replaceFirst(RegExp(r'^0+'), '');
  fp = fp.replaceFirst(RegExp(r'0+$'), '');
  if (ip.isEmpty) ip = '0';
  final body = fp.isEmpty ? ip : '$ip.$fp';
  if (body == '0') return '0';
  return neg ? '-$body' : body;
}

/// Normalizes and compares values according to [CompareOptions].
class ValueNormalizer {
  const ValueNormalizer([this.options = const CompareOptions()]);
  final CompareOptions options;

  static _NumVal? _num(Object? v) {
    if (v is int) return _NumVal('$v', v.toDouble());
    if (v is double) {
      if (!v.isFinite) return null;
      final s = v.toString();
      return _NumVal(s.contains('e') ? s : canonicalDecimal(s), v, fromDouble: true);
    }
    if (v is bool) return _NumVal(v ? '1' : '0', v ? 1 : 0);
    if (v is String) {
      final t = v.trim();
      if (!_numberRe.hasMatch(t)) return null;
      final d = double.tryParse(t);
      if (d == null) return null;
      if (t.contains('e') || t.contains('E')) {
        final s = d.toString();
        return _NumVal(s.contains('e') ? s : canonicalDecimal(s), d, fromDouble: true);
      }
      return _NumVal(canonicalDecimal(t), d);
    }
    return null;
  }

  static String _hex(Uint8List b) {
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// `YYYY-MM-DD[ HH:MM:SS[.f]][tz]` with the time dropped at midnight.
  static String? normalizeDate(String s) {
    final m = _dateRe.firstMatch(s.trim());
    if (m == null) return null;
    final date = m.group(1)!;
    final hm = m.group(2);
    final sec = m.group(3) ?? ':00';
    var frac = (m.group(4) ?? '').replaceFirst(RegExp(r'0+$'), '');
    if (frac == '.') frac = '';
    final tz = m.group(5);
    final tzs = tz == null ? '' : (tz == 'Z' || tz == '+00:00' || tz == '+0000' || tz == '+00' ? 'Z' : tz);
    if (hm == null) return '$date$tzs';
    final time = '$hm$sec$frac';
    if (time == '00:00:00' && tzs.isEmpty) return date;
    return '$date $time$tzs';
  }

  ValueKind _effectiveKind(ValueKind k, Object? a, Object? b) {
    if (k != ValueKind.auto) return k;
    if (a is Uint8List || b is Uint8List) return ValueKind.binary;
    if (a is num || b is num || a is bool || b is bool) return ValueKind.numeric;
    if (options.normalizeDates &&
        ((a is String && _dateRe.hasMatch(a.trim())) || (b is String && _dateRe.hasMatch(b.trim())))) {
      return ValueKind.temporal;
    }
    return ValueKind.text;
  }

  String _text(Object v, ValueKind k) {
    if (v is Uint8List) return _hex(v);
    var s = v is String ? v : v.toString();
    if (k == ValueKind.temporal && options.normalizeDates) {
      final n = normalizeDate(s);
      if (n != null) return n;
    }
    if (options.trimStrings) s = s.trim();
    if (options.ignoreCase) s = s.toLowerCase();
    return s;
  }

  bool _isNullLike(Object? v) => v == null || (options.nullEqualsEmpty && v is String && v.trim().isEmpty);

  /// True when [a] and [b] are equal for a column of kind [kind].
  bool equal(Object? a, Object? b, [ValueKind kind = ValueKind.auto]) {
    if (a == null && b == null) return true;
    if (_isNullLike(a) || _isNullLike(b)) return _isNullLike(a) && _isNullLike(b);
    final k = _effectiveKind(kind, a, b);
    if (k == ValueKind.numeric) {
      final na = _num(a), nb = _num(b);
      if (na != null && nb != null) {
        if (options.floatTolerance > 0) return (na.approx - nb.approx).abs() <= options.floatTolerance;
        if (na.canon == nb.canon) return true;
        return (na.fromDouble || nb.fromDouble) && na.approx == nb.approx;
      }
    }
    if (k == ValueKind.binary && a is Uint8List && b is Uint8List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return _text(a!, k) == _text(b!, k);
  }

  /// Canonical string used to hash a key value.
  String keyPart(Object? v, [ValueKind kind = ValueKind.auto]) {
    if (_isNullLike(v)) return '\u0000';
    final k = _effectiveKind(kind, v, null);
    if (k == ValueKind.numeric) {
      final n = _num(v);
      if (n != null) return 'n${n.canon}';
    }
    return 's${_text(v!, k)}';
  }

  /// Ordering of key values (NULLs first, numbers before text).
  int compare(Object? a, Object? b, [ValueKind kind = ValueKind.auto]) {
    final an = _isNullLike(a), bn = _isNullLike(b);
    if (an || bn) return an && bn ? 0 : (an ? -1 : 1);
    final k = _effectiveKind(kind, a, b);
    if (k == ValueKind.numeric) {
      final na = _num(a), nb = _num(b);
      if (na != null && nb != null) return _compareNum(na, nb);
      if (na != null) return -1;
      if (nb != null) return 1;
    }
    return _text(a!, k).compareTo(_text(b!, k));
  }

  static int _compareNum(_NumVal a, _NumVal b) {
    if (a.canon == b.canon) return 0;
    final c = a.approx.compareTo(b.approx);
    if (c != 0) return c;
    // Same double but different decimals (precision beyond 2^53).
    final ia = BigInt.tryParse(a.canon), ib = BigInt.tryParse(b.canon);
    if (ia != null && ib != null) return ia.compareTo(ib);
    if (a.fromDouble || b.fromDouble) return 0;
    return a.canon.compareTo(b.canon);
  }
}

/// A compared row. [source] / [target] hold the full row
/// (`[keys…, columns…]`); for identical rows only [source] is kept.
class CompareRow {
  CompareRow(this.kind, this.source, this.target, [this.diffColumns = const []]);
  final RowDiff kind;
  final List<Object?>? source;
  final List<Object?>? target;

  /// Indexes (in the row layout) of the columns that differ.
  final List<int> diffColumns;

  List<Object?> get values => source ?? target!;
}

class CompareResult {
  CompareResult({
    required this.columns,
    required this.keyCount,
    required this.rows,
    required this.sourceRows,
    required this.targetRows,
    required this.truncated,
    required this.hashJoin,
    required this.elapsed,
  });

  /// Row layout: key columns first.
  final List<String> columns;
  final int keyCount;
  final List<CompareRow> rows;
  final int sourceRows;
  final int targetRows;

  /// The row cap was reached: the result covers only part of the data.
  final bool truncated;
  final bool hashJoin;
  final Duration elapsed;

  late final Map<RowDiff, int> counts = () {
    final m = {for (final k in RowDiff.values) k: 0};
    for (final r in rows) {
      m[r.kind] = m[r.kind]! + 1;
    }
    return m;
  }();

  int count(RowDiff k) => counts[k] ?? 0;

  bool get inSync => count(RowDiff.different) + count(RowDiff.onlySource) + count(RowDiff.onlyTarget) == 0;
}

/// A paged source of rows (a database cursor or an in-memory list).
abstract class RowSource {
  /// Next page of rows; an empty list means the end of the data.
  Future<List<List<Object?>>> nextPage();
  Future<void> close();
}

/// In-memory [RowSource] (tests, already loaded data).
class ListRowSource implements RowSource {
  ListRowSource(this.rows, {this.pageSize = 100});
  final List<List<Object?>> rows;
  final int pageSize;
  int _pos = 0;
  bool closed = false;

  @override
  Future<List<List<Object?>>> nextPage() async {
    if (_pos >= rows.length) return const [];
    final end = _pos + pageSize > rows.length ? rows.length : _pos + pageSize;
    final page = rows.sublist(_pos, end);
    _pos = end;
    return page;
  }

  @override
  Future<void> close() async => closed = true;
}

/// Progress of a running comparison.
typedef CompareProgress = void Function(int sourceRows, int targetRows);

/// Compares two row sources.
class DataComparer {
  DataComparer({
    required this.columns,
    required this.keyCount,
    List<ValueKind>? kinds,
    this.options = const CompareOptions(),
    this.rowCap = 100000,
    this.onProgress,
    this.isCancelled,
  }) : kinds = kinds ?? List.filled(columns.length, ValueKind.auto),
       normalizer = ValueNormalizer(options);

  final List<String> columns;
  final int keyCount;
  final List<ValueKind> kinds;
  final CompareOptions options;
  final ValueNormalizer normalizer;

  /// Maximum number of rows read from each side (0 = unlimited).
  final int rowCap;
  final CompareProgress? onProgress;
  final bool Function()? isCancelled;

  int compareKeys(List<Object?> a, List<Object?> b) {
    for (var i = 0; i < keyCount; i++) {
      final c = normalizer.compare(a[i], b[i], kinds[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  String hashKey(List<Object?> r) {
    if (keyCount == 1) return normalizer.keyPart(r[0], kinds[0]);
    final sb = StringBuffer();
    for (var i = 0; i < keyCount; i++) {
      if (i > 0) sb.write('\u0001');
      sb.write(normalizer.keyPart(r[i], kinds[i]));
    }
    return sb.toString();
  }

  /// Indexes of the non-key columns whose values differ.
  List<int> diffColumns(List<Object?> a, List<Object?> b) {
    final out = <int>[];
    for (var i = keyCount; i < columns.length; i++) {
      if (!normalizer.equal(a[i], b[i], kinds[i])) out.add(i);
    }
    return out;
  }

  CompareRow _matched(List<Object?> a, List<Object?> b) {
    final d = diffColumns(a, b);
    return d.isEmpty ? CompareRow(RowDiff.identical, a, null) : CompareRow(RowDiff.different, a, b, d);
  }

  void _checkCancel() {
    if (isCancelled?.call() ?? false) throw CompareCancelledException();
  }

  /// Streaming merge on both sides ordered by key.
  Future<CompareResult> mergeJoin(RowSource source, RowSource target) async {
    final sw = Stopwatch()..start();
    final a = _Reader(this, source, 'origine');
    final b = _Reader(this, target, 'destinazione');
    final out = <CompareRow>[];
    var truncated = false;
    while (true) {
      _checkCancel();
      final ra = await a.peek();
      final rb = await b.peek();
      if (a.capped || b.capped) {
        truncated = true;
        break;
      }
      if (ra == null && rb == null) break;
      if (ra == null) {
        out.add(CompareRow(RowDiff.onlyTarget, null, rb));
        b.advance();
      } else if (rb == null) {
        out.add(CompareRow(RowDiff.onlySource, ra, null));
        a.advance();
      } else {
        final c = compareKeys(ra, rb);
        if (c == 0) {
          out.add(_matched(ra, rb));
          a.advance();
          b.advance();
        } else if (c < 0) {
          out.add(CompareRow(RowDiff.onlySource, ra, null));
          a.advance();
        } else {
          out.add(CompareRow(RowDiff.onlyTarget, null, rb));
          b.advance();
        }
      }
      if (a.pageLoaded || b.pageLoaded) {
        a.pageLoaded = b.pageLoaded = false;
        onProgress?.call(a.consumed, b.consumed);
      }
    }
    onProgress?.call(a.consumed, b.consumed);
    return CompareResult(
      columns: columns,
      keyCount: keyCount,
      rows: out,
      sourceRows: a.consumed,
      targetRows: b.consumed,
      truncated: truncated,
      hashJoin: false,
      elapsed: sw.elapsed,
    );
  }

  /// Order independent comparison: the source is kept in memory.
  Future<CompareResult> hashJoin(RowSource source, RowSource target) async {
    final sw = Stopwatch()..start();
    final map = <String, List<Object?>>{};
    var nSource = 0, nTarget = 0;
    var truncated = false;
    outer:
    while (true) {
      _checkCancel();
      final page = await source.nextPage();
      if (page.isEmpty) break;
      for (final r in page) {
        if (rowCap > 0 && nSource >= rowCap) {
          truncated = true;
          break outer;
        }
        final k = hashKey(r);
        if (map.containsKey(k)) throw CompareDuplicateKeyException('origine', r.sublist(0, keyCount));
        map[k] = r;
        nSource++;
      }
      onProgress?.call(nSource, nTarget);
    }
    final out = <CompareRow>[];
    final seen = <String>{};
    outer2:
    while (true) {
      _checkCancel();
      final page = await target.nextPage();
      if (page.isEmpty) break;
      for (final r in page) {
        if (rowCap > 0 && nTarget >= rowCap) {
          truncated = true;
          break outer2;
        }
        nTarget++;
        final k = hashKey(r);
        if (!seen.add(k)) throw CompareDuplicateKeyException('destinazione', r.sublist(0, keyCount));
        final s = map.remove(k);
        out.add(s == null ? CompareRow(RowDiff.onlyTarget, null, r) : _matched(s, r));
      }
      onProgress?.call(nSource, nTarget);
    }
    for (final r in map.values) {
      out.add(CompareRow(RowDiff.onlySource, r, null));
    }
    out.sort((x, y) => compareKeys(x.values, y.values));
    return CompareResult(
      columns: columns,
      keyCount: keyCount,
      rows: out,
      sourceRows: nSource,
      targetRows: nTarget,
      truncated: truncated,
      hashJoin: true,
      elapsed: sw.elapsed,
    );
  }
}

/// Buffered cursor over a [RowSource] that verifies the key ordering.
class _Reader {
  _Reader(this.cmp, this.source, this.side);
  final DataComparer cmp;
  final RowSource source;
  final String side;
  List<List<Object?>> _page = const [];
  int _pos = 0;
  bool _done = false;
  List<Object?>? _prev;
  int consumed = 0;
  bool capped = false;
  bool pageLoaded = false;

  Future<List<Object?>?> peek() async {
    if (capped) return null;
    while (_pos >= _page.length) {
      if (_done) return null;
      _page = await source.nextPage();
      _pos = 0;
      pageLoaded = true;
      if (_page.isEmpty) {
        _done = true;
        return null;
      }
    }
    if (cmp.rowCap > 0 && consumed >= cmp.rowCap) {
      capped = true;
      return null;
    }
    final cur = _page[_pos];
    final prev = _prev;
    if (prev != null && !identical(prev, cur)) {
      final c = cmp.compareKeys(prev, cur);
      if (c == 0) throw CompareDuplicateKeyException(side, cur.sublist(0, cmp.keyCount));
      if (c > 0) {
        throw CompareOrderException(side, prev.sublist(0, cmp.keyCount), cur.sublist(0, cmp.keyCount));
      }
    }
    _prev = cur;
    return cur;
  }

  void advance() {
    _pos++;
    consumed++;
  }
}
