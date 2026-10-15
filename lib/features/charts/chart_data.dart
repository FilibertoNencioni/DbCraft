// Pure-Dart chart logic: column profiling, default configuration,
// aggregation / grouping, nice axis ticks and number / date formatting.

import 'dart:math' as math;
import 'dart:typed_data';

enum ChartKind {
  bar('Barre'),
  barHorizontal('Barre orizzontali'),
  line('Linee'),
  area('Area'),
  pie('Torta'),
  donut('Ciambella'),
  scatter('Dispersione');

  const ChartKind(this.label);
  final String label;

  bool get isPie => this == ChartKind.pie || this == ChartKind.donut;
  bool get isBar => this == ChartKind.bar || this == ChartKind.barHorizontal;
  bool get canStack => isBar || this == ChartKind.area;
}

enum ChartAgg {
  none('Nessuna'),
  sum('Somma'),
  avg('Media'),
  count('Conteggio'),
  min('Min'),
  max('Max');

  const ChartAgg(this.label);
  final String label;
}

enum ChartSort {
  data('Ordine dei dati'),
  x('Per X'),
  valueDesc('Per valore, decrescente'),
  valueAsc('Per valore, crescente');

  const ChartSort(this.label);
  final String label;
}

/// Column metadata needed by the chart (subset of the ODBC ColumnInfo).
class ChartColumn {
  const ChartColumn(this.name, {this.sqlType = 0, this.typeName = ''});
  final String name;
  final int sqlType;
  final String typeName;
}

/// What a column looks like after sampling its values.
class ColumnProfile {
  const ColumnProfile({
    required this.index,
    required this.name,
    required this.numeric,
    required this.date,
    required this.binary,
    required this.idLike,
    required this.distinct,
  });

  final int index;
  final String name;
  final bool numeric;
  final bool date;
  final bool binary;

  /// Looks like a key (id, *_id): a poor default for a Y series.
  final bool idLike;

  /// Distinct values in the sample.
  final int distinct;

  bool get categorical => !numeric && !binary;
}

const _numericTypes = {2, 3, 4, 5, 6, 7, 8, -5, -6};
const _dateTypes = {9, 11, 91, 93};

final _isoDateRe = RegExp(r'^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2}(\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?$');

/// Number in a cell (ODBC returns decimals as strings), or null.
double? toDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is bool) return v ? 1 : 0;
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }
  return null;
}

/// Date in a cell (ISO strings), or null.
DateTime? toDate(Object? v) {
  if (v is DateTime) return v;
  if (v is! String) return null;
  final s = v.trim();
  if (s.length < 10 || !_isoDateRe.hasMatch(s)) return null;
  return DateTime.tryParse(s);
}

/// True when [v] is an ISO date / timestamp string.
bool looksLikeDate(Object? v) => toDate(v) != null;

/// Samples [rows] to classify every column.
List<ColumnProfile> profileColumns(List<ChartColumn> columns, List<List<Object?>> rows, {int sample = 300}) {
  final n = math.min(rows.length, sample);
  final out = <ColumnProfile>[];
  for (var c = 0; c < columns.length; c++) {
    final col = columns[c];
    var nonNull = 0, nums = 0, dates = 0, bins = 0;
    final distinct = <Object>{};
    for (var i = 0; i < n; i++) {
      final v = rows[i][c];
      if (v == null) continue;
      nonNull++;
      if (v is Uint8List) {
        bins++;
        continue;
      }
      if (distinct.length < 5000) distinct.add(v is String ? v : v.toString());
      if (looksLikeDate(v)) {
        dates++;
      } else if (toDouble(v) != null) {
        nums++;
      }
    }
    final t = col.typeName.toLowerCase();
    final typedDate = _dateTypes.contains(col.sqlType) || t.contains('date') || t.contains('timestamp');
    final date = typedDate || (nonNull > 0 && dates >= nonNull * 0.8);
    final numeric = !date && (_numericTypes.contains(col.sqlType) || (nonNull > 0 && nums == nonNull));
    final name = col.name.toLowerCase();
    out.add(
      ColumnProfile(
        index: c,
        name: col.name,
        numeric: numeric,
        date: date,
        binary: bins > 0 && bins == nonNull,
        idLike:
            name == 'id' || name.endsWith('_id') || name.endsWith('id') && name.length <= 4 || name.startsWith('id_'),
        distinct: distinct.length,
      ),
    );
  }
  return out;
}

/// Chart settings chosen in the side panel.
class ChartConfig {
  ChartConfig({
    this.kind = ChartKind.bar,
    this.x,
    List<int>? y,
    this.agg = ChartAgg.none,
    this.sort = ChartSort.data,
    this.topN = 0,
    this.stacked = false,
    this.legend = true,
    Map<int, int>? slots,
  }) : y = y ?? [],
       slots = slots ?? {for (final (i, c) in (y ?? const <int>[]).indexed) c: i};

  ChartKind kind;

  /// X / category column (null: row number).
  int? x;

  /// Y series (numeric columns).
  List<int> y;

  /// Palette slot per Y column, kept while the column stays selected so a
  /// series never changes color when another one is added or removed.
  final Map<int, int> slots;

  void addY(int column) {
    if (y.contains(column)) return;
    final used = {for (final c in y) slots[c]};
    var slot = 0;
    while (used.contains(slot)) {
      slot++;
    }
    y.add(column);
    slots[column] = slot;
  }

  void removeY(int column) {
    y.remove(column);
    slots.remove(column);
  }

  void clearY() {
    y.clear();
    slots.clear();
  }

  int slotOf(int column, int fallback) => slots[column] ?? fallback;
  ChartAgg agg;
  ChartSort sort;

  /// Keep only the first N categories after sorting (0: all).
  int topN;
  bool stacked;
  bool legend;

  ChartConfig copy() => ChartConfig(
    kind: kind,
    x: x,
    y: List.of(y),
    agg: agg,
    sort: sort,
    topN: topN,
    stacked: stacked,
    legend: legend,
    slots: Map.of(slots),
  );

  /// Sensible defaults: first date/text column as X, first numeric
  /// (non key) columns as Y.
  factory ChartConfig.auto(List<ColumnProfile> p, int rowCount) {
    ColumnProfile? x;
    for (final c in p) {
      if (c.date) {
        x = c;
        break;
      }
    }
    x ??= p.where((c) => c.categorical).firstOrNull;
    final nums = p.where((c) => c.numeric && c.index != x?.index).toList();
    var y = nums.where((c) => !c.idLike).take(3).map((c) => c.index).toList();
    if (y.isEmpty) y = nums.take(1).map((c) => c.index).toList();
    var agg = ChartAgg.none;
    if (x != null && x.distinct < math.min(rowCount, 300)) {
      // Repeated categories: aggregate them.
      agg = y.isEmpty ? ChartAgg.count : ChartAgg.sum;
    } else if (y.isEmpty) {
      agg = ChartAgg.count;
    }
    final kind = x?.date ?? false ? ChartKind.line : ChartKind.bar;
    final sort = x?.date ?? false
        ? ChartSort.x
        : agg != ChartAgg.none
        ? ChartSort.valueDesc
        : ChartSort.data;
    return ChartConfig(
      kind: kind,
      x: x?.index,
      y: y,
      agg: agg,
      sort: sort,
      topN: agg != ChartAgg.none && !(x?.date ?? false) ? 30 : 0,
    );
  }
}

class ChartSeries {
  ChartSeries(this.name, this.values, this.slot);
  final String name;

  /// One value per category / point (null: missing).
  final List<double?> values;

  /// Palette slot (fixed per Y column, so colors follow the entity).
  final int slot;
}

/// Data ready to be painted.
class ChartData {
  ChartData({
    required this.labels,
    required this.series,
    this.positions,
    this.timeAxis = false,
    this.notes = const [],
    this.xTitle = '',
    this.yTitle = '',
    this.otherIndex,
  });

  /// Category labels (or formatted X values for scatter).
  final List<String> labels;
  final List<ChartSeries> series;

  /// Numeric X positions (time axis in epoch ms, or scatter X).
  final List<double>? positions;
  final bool timeAxis;
  final List<String> notes;
  final String xTitle;
  final String yTitle;

  /// Index of the folded "Altro" category (pie), if any.
  final int? otherIndex;

  bool get isEmpty => labels.isEmpty || series.isEmpty;

  static final empty = ChartData(labels: const [], series: const []);
}

String _seriesName(String col, ChartAgg agg) => switch (agg) {
  ChartAgg.none => col,
  ChartAgg.count => 'Conteggio $col',
  _ => '${agg.label} $col',
};

class _Acc {
  double sum = 0;
  int n = 0;
  double? min, max;
  void add(double? v) {
    if (v == null || v.isNaN) return;
    sum += v;
    n++;
    min = min == null ? v : math.min(min!, v);
    max = max == null ? v : math.max(max!, v);
  }

  double? result(ChartAgg a, int rows) => switch (a) {
    ChartAgg.sum => n == 0 ? null : sum,
    ChartAgg.avg => n == 0 ? null : sum / n,
    ChartAgg.count => n.toDouble(),
    ChartAgg.min => min,
    ChartAgg.max => max,
    ChartAgg.none => n == 0 ? null : sum,
  };
}

const kNullLabel = '(vuoto)';
const kOtherLabel = 'Altro';

/// Maximum categories / points drawn without aggregation.
const kMaxPoints = 1000;

/// Maximum slices in a pie before folding the rest into "Altro".
const kMaxSlices = 7;

/// Maximum series (palette slots).
const kMaxSeries = 8;

/// Scatter plots validate only the first three palette slots.
const kMaxScatterSeries = 3;

/// Builds the chart data for [config] from [rows] (already in view order).
ChartData buildChartData(
  List<ChartColumn> columns,
  List<ColumnProfile> profiles,
  List<List<Object?>> rows,
  ChartConfig config, {
  int maxPoints = kMaxPoints,
}) {
  final notes = <String>[];
  final xi = config.x != null && config.x! < columns.length ? config.x : null;
  final xProfile = xi == null ? null : profiles[xi];
  var ys = config.y.where((i) => i >= 0 && i < columns.length && i != xi).toList();
  final maxSeries = config.kind == ChartKind.scatter
      ? kMaxScatterSeries
      : config.kind.isPie
      ? 1
      : kMaxSeries;
  if (ys.length > maxSeries) {
    notes.add(
      config.kind.isPie ? 'La torta mostra solo la prima serie' : 'Mostrate le prime $maxSeries serie su ${ys.length}',
    );
    ys = ys.take(maxSeries).toList();
  }
  final agg = config.kind == ChartKind.scatter ? ChartAgg.none : config.agg;
  if (ys.isEmpty && agg != ChartAgg.count) return ChartData(labels: const [], series: const [], notes: notes);
  final xTitle = xi == null ? 'Riga' : columns[xi].name;
  final yTitle = ys.isEmpty
      ? 'Conteggio'
      : ys.length == 1
      ? _seriesName(columns[ys.first].name, agg)
      : agg == ChartAgg.none
      ? ''
      : agg.label;

  // -------------------------------------------------------------------------
  // Scatter: one point per row, numeric (or date) X.
  // -------------------------------------------------------------------------
  if (config.kind == ChartKind.scatter) {
    final isDate = xProfile?.date ?? false;
    var idx = <int>[];
    for (var r = 0; r < rows.length; r++) {
      final xv = xi == null
          ? r + 1.0
          : (isDate ? toDate(rows[r][xi])?.millisecondsSinceEpoch.toDouble() : toDouble(rows[r][xi]));
      if (xv != null) idx.add(r);
    }
    const cap = 5000;
    if (idx.length > cap) {
      final step = idx.length / cap;
      idx = [for (var i = 0; i < cap; i++) idx[(i * step).floor()]];
      notes.add('Campione di $cap punti su ${rows.length} righe');
    }
    final pos = <double>[];
    final labels = <String>[];
    for (final r in idx) {
      if (xi == null) {
        pos.add(r + 1.0);
        labels.add('${r + 1}');
      } else if (isDate) {
        final d = toDate(rows[r][xi])!;
        pos.add(d.millisecondsSinceEpoch.toDouble());
        labels.add(formatDateLabel(d));
      } else {
        final v = toDouble(rows[r][xi])!;
        pos.add(v);
        labels.add(formatNumber(v, maxDecimals: 6));
      }
    }
    return ChartData(
      labels: labels,
      positions: pos,
      timeAxis: isDate,
      notes: notes,
      xTitle: xTitle,
      yTitle: yTitle,
      series: [
        for (final (s, y) in ys.indexed) ChartSeries(columns[y].name, [for (final r in idx) toDouble(rows[r][y])], s),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Categories
  // -------------------------------------------------------------------------
  final isDate = xProfile?.date ?? false;
  final isNum = xProfile?.numeric ?? false;
  String labelOf(Object? v) {
    if (v == null) return kNullLabel;
    if (isDate) {
      final d = toDate(v);
      if (d != null) return formatDateLabel(d);
    }
    if (v is double) return formatNumber(v, maxDecimals: 6);
    if (v is Uint8List) return '0x…';
    return v.toString();
  }

  // Sort keys (num, date ms or string) for ordering by X.
  Object sortKeyOf(Object? v) {
    if (v == null) return '';
    if (isDate) return toDate(v)?.millisecondsSinceEpoch ?? v.toString();
    if (isNum) return toDouble(v) ?? v.toString();
    return v.toString().toLowerCase();
  }

  var labels = <String>[];
  var keys = <Object>[];
  var values = <List<double?>>[
    for (final _ in ys.isEmpty ? [0] : ys) <double?>[],
  ];
  final seriesCols = ys.isEmpty ? <int?>[null] : ys.cast<int?>();

  if (agg == ChartAgg.none) {
    for (var r = 0; r < rows.length; r++) {
      final xv = xi == null ? r + 1 : rows[r][xi];
      labels.add(xi == null ? '${r + 1}' : labelOf(xv));
      keys.add(xi == null ? r : sortKeyOf(xv));
      for (final (s, y) in seriesCols.indexed) {
        values[s].add(y == null ? null : toDouble(rows[r][y]));
      }
    }
  } else {
    // Insertion ordered (first appearance of each category).
    final groups = <String, (Object, List<_Acc>, int)>{};
    for (var r = 0; r < rows.length; r++) {
      final xv = xi == null ? null : rows[r][xi];
      final label = xi == null ? 'Totale' : labelOf(xv);
      final g = groups.putIfAbsent(label, () => (sortKeyOf(xv), [for (final _ in seriesCols) _Acc()], 0));
      for (final (s, y) in seriesCols.indexed) {
        // COUNT without a series counts the rows.
        g.$2[s].add(y == null ? 1 : toDouble(rows[r][y]) ?? (agg == ChartAgg.count && rows[r][y] != null ? 1 : null));
      }
      groups[label] = (g.$1, g.$2, g.$3 + 1);
    }
    for (final e in groups.entries) {
      labels.add(e.key);
      keys.add(e.value.$1);
      for (var s = 0; s < seriesCols.length; s++) {
        values[s].add(e.value.$2[s].result(agg, e.value.$3));
      }
    }
  }

  // Sorting
  final order = List<int>.generate(labels.length, (i) => i);
  int cmpKey(Object a, Object b) {
    if (a is num && b is num) return a.compareTo(b);
    if (a is num) return -1;
    if (b is num) return 1;
    return a.toString().compareTo(b.toString());
  }

  double total(int i) => values.fold(0.0, (t, s) => t + (s[i] ?? 0));
  switch (config.sort) {
    case ChartSort.data:
      break;
    case ChartSort.x:
      order.sort((a, b) {
        final c = cmpKey(keys[a], keys[b]);
        return c != 0 ? c : a.compareTo(b);
      });
    case ChartSort.valueDesc:
      order.sort((a, b) {
        final c = total(b).compareTo(total(a));
        return c != 0 ? c : a.compareTo(b);
      });
    case ChartSort.valueAsc:
      order.sort((a, b) {
        final c = total(a).compareTo(total(b));
        return c != 0 ? c : a.compareTo(b);
      });
  }
  labels = [for (final i in order) labels[i]];
  keys = [for (final i in order) keys[i]];
  values = [
    for (final s in values) [for (final i in order) s[i]],
  ];

  // Limits
  int? otherIndex;
  final count = labels.length;
  if (config.kind.isPie) {
    // Negative and empty values cannot be drawn as slices.
    final keep = [
      for (var i = 0; i < count; i++)
        if ((values[0][i] ?? 0) > 0) i,
    ];
    if (keep.length < count) notes.add('${count - keep.length} valori nulli, zero o negativi esclusi dalla torta');
    labels = [for (final i in keep) labels[i]];
    values = [
      [for (final i in keep) values[0][i]],
    ];
    final limit = config.topN > 0 ? math.min(config.topN, kMaxSlices) : kMaxSlices;
    if (labels.length > limit) {
      final additive = agg == ChartAgg.sum || agg == ChartAgg.count || agg == ChartAgg.none;
      if (additive) {
        final rest = values[0].skip(limit).fold(0.0, (t, v) => t + (v ?? 0));
        notes.add('${labels.length - limit} categorie raggruppate in "$kOtherLabel"');
        labels = [...labels.take(limit), kOtherLabel];
        values = [
          [...values[0].take(limit), rest],
        ];
        otherIndex = limit;
      } else {
        notes.add('Mostrate le prime $limit categorie su ${labels.length}');
        labels = labels.take(limit).toList();
        values = [values[0].take(limit).toList()];
      }
    }
  } else {
    var limit = config.topN > 0 ? config.topN : count;
    if (limit > maxPoints) limit = maxPoints;
    if (count > limit) {
      notes.add(
        limit == maxPoints && config.topN == 0
            ? 'Mostrati i primi $maxPoints punti su $count: usa un\'aggregazione o un limite'
            : 'Mostrate le prime $limit categorie su $count',
      );
      labels = labels.take(limit).toList();
      keys = keys.take(limit).toList();
      values = [for (final s in values) s.take(limit).toList()];
    }
  }

  // Time axis for line / area charts ordered by date.
  List<double>? positions;
  final timeAxis =
      isDate &&
      (config.kind == ChartKind.line || config.kind == ChartKind.area) &&
      config.sort == ChartSort.x &&
      keys.every((k) => k is int);
  if (timeAxis) positions = [for (final k in keys) (k as int).toDouble()];

  return ChartData(
    labels: labels,
    positions: positions,
    timeAxis: timeAxis,
    notes: notes,
    xTitle: xTitle,
    yTitle: yTitle,
    otherIndex: otherIndex,
    series: [
      for (final (s, y) in seriesCols.indexed)
        ChartSeries(
          y == null ? 'Conteggio' : _seriesName(columns[y].name, agg),
          values[s],
          y == null ? 0 : config.slotOf(y, s),
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Axis ticks
// ---------------------------------------------------------------------------

/// Scale with "nice" round ticks covering a data range.
class NiceScale {
  const NiceScale(this.min, this.max, this.step);
  final double min;
  final double max;
  final double step;

  List<double> get ticks {
    final n = ((max - min) / step).round();
    final dec = decimals;
    return [for (var i = 0; i <= n; i++) double.parse((min + i * step).toStringAsFixed(dec))];
  }

  /// Decimals needed to print the ticks.
  int get decimals => step >= 1 ? 0 : (-(math.log(step) / math.ln10).floor()).clamp(0, 12);
}

double _niceNum(double x, bool round) {
  final exp = (math.log(x) / math.ln10).floor();
  final f = x / math.pow(10, exp);
  double nf;
  if (round) {
    nf = f < 1.5
        ? 1
        : f < 3
        ? 2
        : f < 7
        ? 5
        : 10;
  } else {
    nf = f <= 1
        ? 1
        : f <= 2
        ? 2
        : f <= 5
        ? 5
        : 10;
  }
  return nf * math.pow(10, exp);
}

/// Heckbert's nice numbers: about [target] ticks from [lo] to [hi].
NiceScale niceScale(double lo, double hi, {int target = 5}) {
  if (lo.isNaN || hi.isNaN || lo.isInfinite || hi.isInfinite) return const NiceScale(0, 1, 0.2);
  if (lo > hi) (lo, hi) = (hi, lo);
  if (lo == hi) {
    if (lo == 0) return const NiceScale(0, 1, 0.2);
    final pad = lo.abs() * 0.1;
    lo -= pad;
    hi += pad;
  }
  final range = _niceNum(hi - lo, false);
  final step = _niceNum(range / math.max(1, target - 1), true);
  final min = (lo / step).floor() * step;
  final max = (hi / step).ceil() * step;
  return NiceScale(min, max, step);
}

/// Tick of a time axis.
class TimeTick {
  const TimeTick(this.ms, this.label);
  final double ms;
  final String label;
}

const _monthsIt = ['gen', 'feb', 'mar', 'apr', 'mag', 'giu', 'lug', 'ago', 'set', 'ott', 'nov', 'dic'];

/// Calendar-aligned ticks between two instants (epoch ms).
List<TimeTick> timeTicks(double minMs, double maxMs, {int target = 6}) {
  if (maxMs <= minMs) {
    return [TimeTick(minMs, formatDateLabel(DateTime.fromMillisecondsSinceEpoch(minMs.round())))];
  }
  const h = 3600 * 1000.0, d = 24 * h;
  final span = maxMs - minMs;
  final a = DateTime.fromMillisecondsSinceEpoch(minMs.round());
  final b = DateTime.fromMillisecondsSinceEpoch(maxMs.round());
  String two(int n) => n.toString().padLeft(2, '0');
  final ticks = <TimeTick>[];
  // Sub-month steps
  for (final step in [h, 3 * h, 6 * h, 12 * h, d, 2 * d, 7 * d, 14 * d]) {
    if (span / step <= target) {
      var t = DateTime(a.year, a.month, a.day, step < d ? a.hour : 0);
      while (t.millisecondsSinceEpoch < minMs) {
        t = t.add(Duration(milliseconds: step.round()));
      }
      if (step == 7 * d || step == 14 * d) {
        // Align to Monday.
        while (t.weekday != DateTime.monday) {
          t = t.add(const Duration(days: 1));
        }
      }
      while (!t.isAfter(b)) {
        final label = step < d
            ? '${two(t.day)}/${two(t.month)} ${two(t.hour)}:00'
            : a.year == b.year
            ? '${t.day} ${_monthsIt[t.month - 1]}'
            : '${two(t.day)}/${two(t.month)}/${t.year % 100}';
        ticks.add(TimeTick(t.millisecondsSinceEpoch.toDouble(), label));
        t = step < d
            ? t.add(Duration(milliseconds: step.round()))
            : DateTime(t.year, t.month, t.day + (step / d).round());
      }
      return ticks;
    }
  }
  // Months / years
  final months = (b.year - a.year) * 12 + b.month - a.month + 1;
  for (final step in [1, 2, 3, 6, 12, 24, 60, 120, 240, 600]) {
    if (months / step <= target || step == 600) {
      var t = DateTime(a.year, a.month);
      if (step >= 12) {
        final years = step ~/ 12;
        t = DateTime((a.year ~/ years) * years);
      } else {
        t = DateTime(a.year, ((a.month - 1) ~/ step) * step + 1);
      }
      while (t.millisecondsSinceEpoch < minMs) {
        t = DateTime(t.year, t.month + step);
      }
      while (!t.isAfter(b)) {
        ticks.add(
          TimeTick(
            t.millisecondsSinceEpoch.toDouble(),
            step >= 12 ? '${t.year}' : '${_monthsIt[t.month - 1]} ${t.year}',
          ),
        );
        t = DateTime(t.year, t.month + step);
      }
      return ticks;
    }
  }
  return ticks;
}

// ---------------------------------------------------------------------------
// Formatting (Italian conventions: 1.234,5)
// ---------------------------------------------------------------------------

/// Formats [v] with thousands separators and up to [maxDecimals] decimals
/// (trailing zeros removed), or exactly [decimals] when given.
String formatNumber(double v, {int maxDecimals = 2, int? decimals}) {
  if (v.isNaN) return '–';
  if (v.isInfinite) return v > 0 ? '∞' : '-∞';
  var s = v.abs().toStringAsFixed(decimals ?? maxDecimals);
  var intPart = s, frac = '';
  final dot = s.indexOf('.');
  if (dot >= 0) {
    intPart = s.substring(0, dot);
    frac = s.substring(dot + 1);
    if (decimals == null) frac = frac.replaceFirst(RegExp(r'0+$'), '');
  }
  final sb = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) sb.write('.');
    sb.write(intPart[i]);
  }
  s = sb.toString();
  if (frac.isNotEmpty) s = '$s,$frac';
  final neg = v < 0 && (s.replaceAll(RegExp(r'[0.,]'), '').isNotEmpty);
  return neg ? '-$s' : s;
}

/// Axis label for a tick of a [NiceScale] (compact for millions).
String formatTick(double v, NiceScale scale) {
  final m = math.max(scale.max.abs(), scale.min.abs());
  if (m >= 1e9) return '${formatNumber(v / 1e9, maxDecimals: 2)} Mld';
  if (m >= 1e6) return '${formatNumber(v / 1e6, maxDecimals: 2)} Mln';
  return formatNumber(v, decimals: scale.decimals);
}

/// Date label: `2024-03-01` or `2024-03-01 10:30` when a time is present.
String formatDateLabel(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${d.year}-${two(d.month)}-${two(d.day)}';
  if (d.hour == 0 && d.minute == 0 && d.second == 0) return date;
  return '$date ${two(d.hour)}:${two(d.minute)}${d.second == 0 ? '' : ':${two(d.second)}'}';
}
