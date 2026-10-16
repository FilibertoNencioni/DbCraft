import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/theme/tokens.dart';

/// Minimal sparkline: a line with a soft fill, null samples are gaps.
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, required this.color, this.capacity = 120, this.height = 28});

  final List<double?> values;
  final Color color;

  /// Number of slots on the x axis (the buffer capacity), so the line grows
  /// from the right as samples arrive.
  final int capacity;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(painter: SparklinePainter(values, color, capacity)),
  );
}

class SparklinePainter extends CustomPainter {
  SparklinePainter(this.values, this.color, this.capacity);
  final List<double?> values;
  final Color color;
  final int capacity;

  @override
  void paint(Canvas canvas, Size size) {
    final data = values.whereType<double>();
    if (data.isEmpty) return;
    // Scale on the visible range so that small variations stay readable.
    var lo = data.reduce(math.min), hi = data.reduce(math.max);
    if (hi - lo < 1e-9) {
      hi = lo + 1;
      lo = lo - 1;
    }
    final n = math.max(capacity, values.length);
    final step = n <= 1 ? size.width : size.width / (n - 1);
    final offset = n - values.length;
    double x(int i) => (i + offset) * step;
    double y(double v) => size.height - 2 - (v - lo) / (hi - lo) * (size.height - 4);

    final line = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: Tint.strong),
          color.withValues(alpha: 0),
        ],
      ).createShader(Offset.zero & size);

    // Contiguous segments.
    var start = -1;
    void flush(int end) {
      if (start < 0) return;
      final path = Path()..moveTo(x(start), y(values[start]!));
      for (var i = start + 1; i <= end; i++) {
        path.lineTo(x(i), y(values[i]!));
      }
      if (end > start) {
        final area = Path.from(path)
          ..lineTo(x(end), size.height)
          ..lineTo(x(start), size.height)
          ..close();
        canvas.drawPath(area, fill);
        canvas.drawPath(path, line);
      } else {
        canvas.drawCircle(Offset(x(start), y(values[start]!)), 1.5, Paint()..color = color);
      }
      start = -1;
    }

    for (var i = 0; i < values.length; i++) {
      if (values[i] == null) {
        flush(i - 1);
      } else if (start < 0) {
        start = i;
      }
    }
    flush(values.length - 1);
  }

  @override
  bool shouldRepaint(SparklinePainter old) => true;
}
