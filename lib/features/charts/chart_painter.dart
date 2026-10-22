import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/theme/app_theme.dart';
import 'chart_data.dart';
import 'chart_palette.dart';

/// What the pointer is over: a category (bar/line/area/pie) or a point of a
/// series (scatter).
@immutable
class ChartHover {
  const ChartHover(this.index, {this.series});
  final int index;
  final int? series;

  @override
  bool operator ==(Object other) => other is ChartHover && other.index == index && other.series == series;

  @override
  int get hashCode => Object.hash(index, series);
}

/// Geometry recorded while painting, used for hit testing.
class ChartHitMap {
  /// Category bands (vertical charts: x ranges; horizontal bars: y ranges).
  final List<(int, double, double)> bands = [];
  bool horizontalBands = false;

  /// Anchor points per category (line/area/scatter markers).
  final List<(int, int, Offset)> points = [];

  /// Pie slices: index, start angle, sweep.
  final List<(int, double, double)> slices = [];
  Offset pieCenter = Offset.zero;
  double pieOuter = 0, pieInner = 0;
  Rect plot = Rect.zero;

  void clear() {
    bands.clear();
    points.clear();
    slices.clear();
  }

  ChartHover? hitTest(Offset p, ChartKind kind) {
    if (kind.isPie) {
      final d = p - pieCenter;
      final r = d.distance;
      if (r < pieInner || r > pieOuter + 6) return null;
      var a = math.atan2(d.dy, d.dx) + math.pi / 2;
      if (a < 0) a += 2 * math.pi;
      for (final (i, start, sweep) in slices) {
        if (a >= start && a < start + sweep) return ChartHover(i);
      }
      return null;
    }
    if (kind == ChartKind.scatter) {
      (int, int, Offset)? best;
      var bd = 12.0;
      for (final pt in points) {
        final dd = (pt.$3 - p).distance;
        if (dd < bd) {
          bd = dd;
          best = pt;
        }
      }
      return best == null ? null : ChartHover(best.$2, series: best.$1);
    }
    if (!plot.inflate(4).contains(p)) return null;
    if (bands.isNotEmpty) {
      final v = horizontalBands ? p.dy : p.dx;
      for (final (i, a, b) in bands) {
        if (v >= a && v < b) return ChartHover(i);
      }
    }
    // Time axis: nearest category by x.
    if (points.isNotEmpty) {
      (int, int, Offset)? best;
      var bd = double.infinity;
      for (final pt in points) {
        final dd = (pt.$3.dx - p.dx).abs();
        if (dd < bd) {
          bd = dd;
          best = pt;
        }
      }
      return best == null ? null : ChartHover(best.$2);
    }
    return null;
  }
}

/// Paints every chart kind with the DbCraft tokens.
class ChartPainter extends CustomPainter {
  ChartPainter({
    required this.data,
    required this.kind,
    required this.stacked,
    required this.colors,
    required this.palette,
    required this.hits,
    this.hover,
  });

  final ChartData data;
  final ChartKind kind;
  final bool stacked;
  final DbColors colors;
  final ChartPalette palette;
  final ChartHitMap hits;
  final ChartHover? hover;

  static const double _barMax = 24;
  static const double _gap = 2;
  static const double _radius = 4;

  TextStyle get _tickStyle => uiText(TypeSize.caption, color: colors.textSecondary, features: kTabular);

  TextPainter _text(String s, {TextStyle? style, double maxWidth = 200}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style ?? _tickStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    return tp;
  }

  Color _color(int slot) => palette[slot];

  @override
  void paint(Canvas canvas, Size size) {
    hits.clear();
    if (data.isEmpty || size.width < 60 || size.height < 60) return;
    if (kind.isPie) {
      _paintPie(canvas, size);
    } else if (kind == ChartKind.barHorizontal) {
      _paintHorizontalBars(canvas, size);
    } else {
      _paintCartesian(canvas, size);
    }
  }

  // -------------------------------------------------------------------------
  // Value range
  // -------------------------------------------------------------------------

  (double, double) _valueRange({required bool includeZero, required bool stack}) {
    var lo = double.infinity, hi = -double.infinity;
    final n = data.labels.length;
    if (stack) {
      for (var i = 0; i < n; i++) {
        var pos = 0.0, neg = 0.0;
        for (final s in data.series) {
          final v = s.values[i] ?? 0;
          if (v >= 0) {
            pos += v;
          } else {
            neg += v;
          }
        }
        lo = math.min(lo, neg);
        hi = math.max(hi, pos);
      }
    } else {
      for (final s in data.series) {
        for (final v in s.values) {
          if (v == null || v.isNaN || v.isInfinite) continue;
          lo = math.min(lo, v);
          hi = math.max(hi, v);
        }
      }
    }
    if (lo == double.infinity) return (0, 1);
    if (includeZero) {
      lo = math.min(lo, 0);
      hi = math.max(hi, 0);
    }
    return (lo, hi);
  }

  void _grid(Canvas canvas, Rect plot, NiceScale scale, {required bool horizontal}) {
    final grid = Paint()
      ..color = colors.separator
      ..strokeWidth = 1;
    final base = Paint()
      ..color = colors.textTertiary.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (final t in scale.ticks) {
      final f = (t - scale.min) / (scale.max - scale.min);
      final label = _text(formatTick(t, scale));
      if (horizontal) {
        final x = (plot.left + f * plot.width).roundToDouble() + 0.5;
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), t == 0 ? base : grid);
        label.paint(canvas, Offset(x - label.width / 2, plot.bottom + 4));
      } else {
        final y = (plot.bottom - f * plot.height).roundToDouble() + 0.5;
        canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), t == 0 ? base : grid);
        label.paint(canvas, Offset(plot.left - label.width - 6, y - label.height / 2));
      }
    }
  }

  void _titles(Canvas canvas, Size size, Rect plot, {required String x, required String y}) {
    final style = uiText(TypeSize.caption, weight: FontWeight.w600, color: colors.textSecondary);
    if (y.isNotEmpty) _text(y, style: style, maxWidth: size.width - 16).paint(canvas, const Offset(4, 0));
    if (x.isNotEmpty) {
      final t = _text(x, style: style, maxWidth: plot.width);
      t.paint(canvas, Offset(plot.right - t.width, size.height - t.height));
    }
  }

  double _yLabelWidth(NiceScale s) => s.ticks.fold<double>(0, (m, t) => math.max(m, _text(formatTick(t, s)).width));

  // -------------------------------------------------------------------------
  // Vertical bars, lines, areas, scatter
  // -------------------------------------------------------------------------

  void _paintCartesian(Canvas canvas, Size size) {
    final isBar = kind == ChartKind.bar;
    final isScatter = kind == ChartKind.scatter;
    final stack = stacked && kind.canStack && data.series.length > 1;
    final (lo, hi) = _valueRange(includeZero: isBar || kind == ChartKind.area, stack: stack);
    final scale = niceScale(lo, hi, target: math.max(3, (size.height / 60).floor()));
    final left = _yLabelWidth(scale) + 10;
    final plot = Rect.fromLTRB(left, 20, size.width - 14, size.height - 36);
    if (plot.width < 20 || plot.height < 20) return;
    hits.plot = plot;
    _grid(canvas, plot, scale, horizontal: false);
    _titles(canvas, size, plot, x: data.xTitle, y: data.yTitle);
    double yOf(double v) => plot.bottom - (v - scale.min) / (scale.max - scale.min) * plot.height;

    final n = data.labels.length;
    final positions = data.positions;
    final numericX = positions != null && (data.timeAxis || isScatter);
    late final double Function(int i) xOf;
    double bandW = plot.width / math.max(1, n);
    if (numericX) {
      var pmin = positions.fold(double.infinity, math.min), pmax = positions.fold(-double.infinity, math.max);
      if (pmin == pmax) {
        pmin -= 1;
        pmax += 1;
      }
      if (data.timeAxis) {
        final ticks = timeTicks(pmin, pmax, target: math.max(2, (plot.width / 110).floor()));
        double tx(double ms) => plot.left + 8 + (ms - pmin) / (pmax - pmin) * (plot.width - 16);
        xOf = (i) => tx(positions[i]);
        for (final t in ticks) {
          final x = tx(t.ms);
          final tp = _text(t.label);
          tp.paint(canvas, Offset(x - tp.width / 2, plot.bottom + 5));
          canvas.drawLine(Offset(x, plot.bottom), Offset(x, plot.bottom + 3), Paint()..color = colors.separator);
        }
      } else {
        final xs = niceScale(pmin, pmax, target: math.max(3, (plot.width / 90).floor()));
        double tx(double v) => plot.left + (v - xs.min) / (xs.max - xs.min) * plot.width;
        xOf = (i) => tx(positions[i]);
        for (final t in xs.ticks) {
          final x = tx(t);
          final tp = _text(formatTick(t, xs));
          tp.paint(canvas, Offset(x - tp.width / 2, plot.bottom + 5));
          canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), Paint()..color = colors.separator);
        }
      }
    } else {
      xOf = (i) => plot.left + (i + 0.5) * bandW;
      // Category labels, skipping some when they would overlap.
      final sample = [for (var i = 0; i < n; i += math.max(1, n ~/ 60)) _text(data.labels[i], maxWidth: 120).width];
      final widest = sample.fold<double>(20, math.max) + 8;
      final every = math.max(1, (widest / bandW).ceil());
      for (var i = 0; i < n; i += every) {
        final tp = _text(data.labels[i], maxWidth: (bandW * every - 4).clamp(24.0, 120.0));
        tp.paint(canvas, Offset(xOf(i) - tp.width / 2, plot.bottom + 5));
      }
      for (var i = 0; i < n; i++) {
        hits.bands.add((i, plot.left + i * bandW, plot.left + (i + 1) * bandW));
      }
    }

    // Hover background / crosshair.
    final h = hover;
    if (h != null && h.index < n && !isScatter) {
      if (isBar) {
        canvas.drawRect(
          Rect.fromLTWH(plot.left + h.index * bandW, plot.top, bandW, plot.height),
          Paint()..color = colors.hover,
        );
      } else {
        final x = xOf(h.index);
        canvas.drawLine(
          Offset(x, plot.top),
          Offset(x, plot.bottom),
          Paint()
            ..color = colors.textTertiary
            ..strokeWidth = 1,
        );
      }
    }

    canvas.save();
    canvas.clipRect(plot.inflate(8));
    if (isBar) {
      _bars(canvas, plot, bandW, xOf, yOf, stack);
    } else if (isScatter) {
      _scatter(canvas, xOf, yOf);
    } else {
      _lines(canvas, plot, xOf, yOf, stack, area: kind == ChartKind.area);
    }
    canvas.restore();
  }

  void _bars(
    Canvas canvas,
    Rect plot,
    double bandW,
    double Function(int) xOf,
    double Function(double) yOf,
    bool stack,
  ) {
    final n = data.labels.length;
    final ns = data.series.length;
    final zero = yOf(0);
    final round = bandW > 8;
    for (var i = 0; i < n; i++) {
      final cx = xOf(i);
      if (stack) {
        final w = math.min(_barMax, bandW * 0.7);
        var pos = 0.0, neg = 0.0;
        // The outermost segment (per sign) gets the rounded data end.
        var lastPos = -1, lastNeg = -1;
        for (var s = 0; s < ns; s++) {
          final v = data.series[s].values[i] ?? 0;
          if (v > 0) lastPos = s;
          if (v < 0) lastNeg = s;
        }
        for (var s = 0; s < ns; s++) {
          final v = data.series[s].values[i] ?? 0;
          if (v == 0) continue;
          final from = v > 0 ? pos : neg;
          final to = from + v;
          if (v > 0) {
            pos = to;
          } else {
            neg = to;
          }
          var top = math.min(yOf(from), yOf(to)), bottom = math.max(yOf(from), yOf(to));
          // 2px surface gap between stacked segments.
          if (v > 0 && from != 0) bottom -= _gap;
          if (v < 0 && from != 0) top += _gap;
          if (bottom - top < 0.5) continue;
          final outer = v > 0 ? s == lastPos : s == lastNeg;
          _bar(
            canvas,
            Rect.fromLTRB(cx - w / 2, top, cx + w / 2, bottom),
            _color(data.series[s].slot),
            roundTop: round && outer && v > 0,
            roundBottom: round && outer && v < 0,
          );
        }
      } else {
        final groupW = math.min(bandW * 0.8, ns * _barMax + (ns - 1) * _gap);
        final w = math.max(1.0, (groupW - (ns - 1) * _gap) / ns);
        var x = cx - groupW / 2;
        for (var s = 0; s < ns; s++) {
          final v = data.series[s].values[i];
          if (v != null && v != 0) {
            final y = yOf(v);
            _bar(
              canvas,
              Rect.fromLTRB(x, math.min(y, zero), x + w, math.max(y, zero)),
              _color(data.series[s].slot),
              roundTop: round && v > 0,
              roundBottom: round && v < 0,
            );
          }
          x += w + _gap;
        }
      }
    }
  }

  void _bar(
    Canvas canvas,
    Rect r,
    Color color, {
    bool roundTop = false,
    bool roundBottom = false,
    bool roundRight = false,
    bool roundLeft = false,
  }) {
    final rad = Radius.circular(math.min(_radius, math.min(r.width, r.height) / 2));
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        r,
        topLeft: roundTop || roundLeft ? rad : Radius.zero,
        topRight: roundTop || roundRight ? rad : Radius.zero,
        bottomLeft: roundBottom || roundLeft ? rad : Radius.zero,
        bottomRight: roundBottom || roundRight ? rad : Radius.zero,
      ),
      Paint()..color = color,
    );
  }

  void _lines(
    Canvas canvas,
    Rect plot,
    double Function(int) xOf,
    double Function(double) yOf,
    bool stack, {
    required bool area,
  }) {
    final n = data.labels.length;
    final cumulative = List<double>.filled(n, 0);
    final markers = n <= 50;
    for (var s = 0; s < data.series.length; s++) {
      final ser = data.series[s];
      final color = _color(ser.slot);
      final line = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final base = List.of(cumulative);
      final pts = <Offset?>[];
      for (var i = 0; i < n; i++) {
        final v = ser.values[i];
        if (stack) {
          cumulative[i] += v ?? 0;
          pts.add(Offset(xOf(i), yOf(cumulative[i])));
        } else {
          pts.add(v == null ? null : Offset(xOf(i), yOf(v)));
        }
      }
      // Split into runs at NULL gaps.
      final runs = <List<int>>[];
      var cur = <int>[];
      for (var i = 0; i < n; i++) {
        if (pts[i] == null) {
          if (cur.isNotEmpty) runs.add(cur);
          cur = [];
        } else {
          cur.add(i);
        }
      }
      if (cur.isNotEmpty) runs.add(cur);
      for (final run in runs) {
        final path = Path()..moveTo(pts[run.first]!.dx, pts[run.first]!.dy);
        for (final i in run.skip(1)) {
          path.lineTo(pts[i]!.dx, pts[i]!.dy);
        }
        if (area) {
          final fill = Path.from(path);
          for (final i in run.reversed) {
            fill.lineTo(xOf(i), stack ? yOf(base[i]) : yOf(0).clamp(plot.top, plot.bottom).toDouble());
          }
          fill.close();
          canvas.drawPath(fill, Paint()..color = color.withValues(alpha: stack ? 0.16 : 0.10));
        }
        if (run.length == 1) {
          canvas.drawCircle(pts[run.first]!, 3, Paint()..color = color);
        } else {
          canvas.drawPath(path, line);
        }
      }
      for (var i = 0; i < n; i++) {
        final p = pts[i];
        if (p == null) continue;
        hits.points.add((s, i, p));
        final hovered = hover?.index == i;
        if (markers || hovered) _marker(canvas, p, color, big: hovered);
      }
    }
  }

  void _marker(Canvas canvas, Offset p, Color color, {bool big = false}) {
    final r = big ? 5.0 : 4.0;
    canvas.drawCircle(p, r + 2, Paint()..color = palette.surface);
    canvas.drawCircle(p, r, Paint()..color = color);
  }

  void _scatter(Canvas canvas, double Function(int) xOf, double Function(double) yOf) {
    final n = data.labels.length;
    final dense = n * data.series.length > 600;
    for (var s = 0; s < data.series.length; s++) {
      final ser = data.series[s];
      final color = _color(ser.slot);
      final paint = Paint()..color = dense ? color.withValues(alpha: 0.7) : color;
      for (var i = 0; i < n; i++) {
        final v = ser.values[i];
        if (v == null) continue;
        final p = Offset(xOf(i), yOf(v));
        hits.points.add((s, i, p));
        if (dense) {
          canvas.drawCircle(p, 3, paint);
        } else {
          _marker(canvas, p, color);
        }
      }
    }
    final h = hover;
    if (h != null && h.series != null && h.series! < data.series.length) {
      final v = data.series[h.series!].values[h.index];
      if (v != null) _marker(canvas, Offset(xOf(h.index), yOf(v)), _color(data.series[h.series!].slot), big: true);
    }
  }

  // -------------------------------------------------------------------------
  // Horizontal bars
  // -------------------------------------------------------------------------

  void _paintHorizontalBars(Canvas canvas, Size size) {
    final stack = stacked && data.series.length > 1;
    final (lo, hi) = _valueRange(includeZero: true, stack: stack);
    final scale = niceScale(lo, hi, target: math.max(3, (size.width / 110).floor()));
    final n = data.labels.length;
    final labelW = math.min(
      160.0,
      [for (var i = 0; i < n; i += math.max(1, n ~/ 80)) _text(data.labels[i], maxWidth: 160).width]
          .fold<double>(20, math.max),
    );
    final plot = Rect.fromLTRB(labelW + 12, 20, size.width - 24, size.height - 36);
    if (plot.width < 20 || plot.height < 20) return;
    hits.plot = plot;
    hits.horizontalBands = true;
    _grid(canvas, plot, scale, horizontal: true);
    _titles(canvas, size, plot, x: data.yTitle, y: data.xTitle);
    double xOf(double v) => plot.left + (v - scale.min) / (scale.max - scale.min) * plot.width;
    final bandH = plot.height / math.max(1, n);
    final zero = xOf(0);
    final ns = data.series.length;
    final every = math.max(1, (16 / bandH).ceil());
    final round = bandH > 8;
    for (var i = 0; i < n; i++) {
      final top = plot.top + i * bandH, cy = top + bandH / 2;
      hits.bands.add((i, top, top + bandH));
      if (hover?.index == i) {
        canvas.drawRect(Rect.fromLTWH(plot.left, top, plot.width, bandH), Paint()..color = colors.hover);
      }
      if (i % every == 0) {
        final tp = _text(data.labels[i], maxWidth: labelW);
        tp.paint(canvas, Offset(plot.left - tp.width - 8, cy - tp.height / 2));
      }
      if (stack) {
        final h = math.min(_barMax, bandH * 0.7);
        var pos = 0.0, neg = 0.0;
        var lastPos = -1, lastNeg = -1;
        for (var s = 0; s < ns; s++) {
          final v = data.series[s].values[i] ?? 0;
          if (v > 0) lastPos = s;
          if (v < 0) lastNeg = s;
        }
        for (var s = 0; s < ns; s++) {
          final v = data.series[s].values[i] ?? 0;
          if (v == 0) continue;
          final from = v > 0 ? pos : neg;
          final to = from + v;
          if (v > 0) {
            pos = to;
          } else {
            neg = to;
          }
          var l = math.min(xOf(from), xOf(to)), r = math.max(xOf(from), xOf(to));
          if (v > 0 && from != 0) l += _gap;
          if (v < 0 && from != 0) r -= _gap;
          if (r - l < 0.5) continue;
          final outer = v > 0 ? s == lastPos : s == lastNeg;
          _bar(
            canvas,
            Rect.fromLTRB(l, cy - h / 2, r, cy + h / 2),
            _color(data.series[s].slot),
            roundRight: round && outer && v > 0,
            roundLeft: round && outer && v < 0,
          );
        }
      } else {
        final groupH = math.min(bandH * 0.8, ns * _barMax + (ns - 1) * _gap);
        final h = math.max(1.0, (groupH - (ns - 1) * _gap) / ns);
        var y = cy - groupH / 2;
        for (var s = 0; s < ns; s++) {
          final v = data.series[s].values[i];
          if (v != null && v != 0) {
            final x = xOf(v);
            _bar(
              canvas,
              Rect.fromLTRB(math.min(x, zero), y, math.max(x, zero), y + h),
              _color(data.series[s].slot),
              roundRight: round && v > 0,
              roundLeft: round && v < 0,
            );
          }
          y += h + _gap;
        }
      }
    }
  }

  // -------------------------------------------------------------------------
  // Pie / donut
  // -------------------------------------------------------------------------

  void _paintPie(Canvas canvas, Size size) {
    final values = data.series.first.values;
    final total = values.fold<double>(0, (t, v) => t + (v ?? 0));
    if (total <= 0) return;
    final center = size.center(Offset.zero);
    final outer = math.max(10.0, math.min(size.width, size.height) / 2 - 12);
    final inner = kind == ChartKind.donut ? outer * 0.6 : 0.0;
    hits
      ..pieCenter = center
      ..pieOuter = outer
      ..pieInner = inner;
    var start = 0.0;
    final gap = Paint()
      ..color = palette.surface
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < values.length; i++) {
      final v = values[i] ?? 0;
      if (v <= 0) continue;
      final sweep = v / total * 2 * math.pi;
      hits.slices.add((i, start, sweep));
      final hovered = hover?.index == i;
      final r = hovered ? outer + 4 : outer;
      final color = i == data.otherIndex ? palette.other : palette[i];
      final rect = Rect.fromCircle(center: center, radius: r);
      final a0 = start - math.pi / 2;
      final path = Path();
      if (inner > 0) {
        path
          ..arcTo(rect, a0, sweep, true)
          ..arcTo(Rect.fromCircle(center: center, radius: inner), a0 + sweep, -sweep, false)
          ..close();
      } else {
        path
          ..moveTo(center.dx, center.dy)
          ..arcTo(rect, a0, sweep, false)
          ..close();
      }
      canvas.drawPath(path, Paint()..color = color);
      if (values.length > 1) canvas.drawPath(path, gap);
      // Percent label inside slices that have room for it.
      final pct = v / total;
      if (pct >= 0.06) {
        final mid = a0 + sweep / 2;
        final lr = inner > 0 ? (inner + r) / 2 : r * 0.62;
        final pos = center + Offset(math.cos(mid), math.sin(mid)) * lr;
        final ink = palette.inkOn(color);
        final tp = _text(
          '${formatNumber(pct * 100, maxDecimals: pct < 0.1 ? 1 : 0)}%',
          style: uiText(TypeSize.caption, weight: FontWeight.w600, color: ink, features: kTabular),
        );
        if (tp.width < r - inner) tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
      }
      start += sweep;
    }
    if (inner > 0) {
      final t1 = _text(
        formatNumber(total),
        style: uiText(TypeSize.title, weight: FontWeight.w600, color: colors.text, features: kTabular),
        maxWidth: inner * 1.6,
      );
      final t2 = _text('totale', maxWidth: inner * 1.6);
      t1.paint(canvas, center - Offset(t1.width / 2, t1.height - 1));
      t2.paint(canvas, center + Offset(-t2.width / 2, 2));
    }
  }

  @override
  bool shouldRepaint(ChartPainter old) =>
      old.data != data ||
      old.kind != kind ||
      old.stacked != stacked ||
      old.hover != hover ||
      old.colors != colors ||
      old.palette.slots.first != palette.slots.first;
}
