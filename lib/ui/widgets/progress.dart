import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'badges.dart';
import 'buttons.dart';

// ---------------------------------------------------------------------------
// Spinner
// ---------------------------------------------------------------------------

/// NSProgressIndicator, spinning style: 12 spokes whose opacity rotates
/// once a second, `textSecondary` by default.
///
/// Sizes: [small] 12 inline in rows, [regular] 16 in toolbars and buttons,
/// [large] 32 centered in a page.
class Spinner extends StatefulWidget {
  const Spinner({super.key, this.size = regular, this.color, this.semanticLabel = 'In corso'});

  static const double small = 12;
  static const double regular = 16;
  static const double large = 32;

  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final _ctl = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.semanticLabel,
    child: SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(painter: _SpinnerPainter(_ctl, widget.color ?? DbColors.of(context).textSecondary)),
    ),
  );
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter(this.t, this.color) : super(repaint: t);

  final Animation<double> t;
  final Color color;

  static const _spokes = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final head = (t.value * _spokes).floor();
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.2, r * 0.17);
    canvas.translate(size.width / 2, size.height / 2);
    for (var i = 0; i < _spokes; i++) {
      // The spoke at [head] is darkest; the trail fades behind it.
      final age = (head - i) % _spokes;
      paint.color = color.withValues(alpha: color.a * (1 - age / _spokes * 0.85));
      final a = i / _spokes * 2 * math.pi - math.pi / 2;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(dir * (r * 0.45), dir * (r * 0.92), paint);
    }
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.color != color;
}

// ---------------------------------------------------------------------------
// Bars
// ---------------------------------------------------------------------------

/// Sweeps a highlight across a track forever; static with Reduce Motion.
class _Sweep extends StatefulWidget {
  const _Sweep({required this.builder});

  /// Paints the bar for a sweep phase in 0..1, or null when motion is off.
  final Widget Function(BuildContext context, double? t) builder;

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  late final _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _ctl.stop();
    } else if (!_ctl.isAnimating) {
      _ctl.repeat();
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return widget.builder(context, null);
    return AnimatedBuilder(animation: _ctl, builder: (context, _) => widget.builder(context, _ctl.value));
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.track, required this.fill, this.value, this.phase, this.radius = 0});

  final Color? track;
  final Color fill;

  /// Determinate fraction, or null for indeterminate.
  final double? value;

  /// Indeterminate sweep phase; null paints the static (Reduce Motion) bar.
  final double? phase;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.save();
    canvas.clipRRect(rr);
    if (track != null) canvas.drawRect(rect, Paint()..color = track!);
    final p = Paint()..color = fill;
    if (value != null) {
      final w = size.width * value!.clamp(0.0, 1.0);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, size.height), Radius.circular(radius)), p);
    } else if (phase == null) {
      canvas.drawRect(rect, Paint()..color = fill.withValues(alpha: fill.a * Tint.border));
    } else {
      // A segment a third of the track wide, entering left and leaving right.
      final seg = size.width / 3;
      final x = -seg + (size.width + seg) * Curves.easeInOut.transform(phase!);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, seg, size.height), Radius.circular(radius)), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.track != track || old.fill != fill || old.value != value || old.phase != phase || old.radius != radius;
}

/// NSProgressIndicator, bar style: 6pt track (radius 3, `pressed`), accent
/// fill. A null [value] is indeterminate: a segment sweeps across, still
/// with Reduce Motion.
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, this.value, this.width, this.semanticLabel});

  final double? value;

  /// Fills the parent's width when null.
  final double? width;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    Widget bar(double? phase) => CustomPaint(
      painter: _BarPainter(track: c.pressed, fill: c.accent, value: value, phase: phase, radius: 3),
      size: Size(width ?? double.infinity, 6),
    );
    return Semantics(
      label: semanticLabel,
      value: value == null ? null : '${(value!.clamp(0.0, 1.0) * 100).round()}%',
      child: SizedBox(
        width: width,
        height: 6,
        child: value == null ? _Sweep(builder: (_, t) => bar(t)) : bar(null),
      ),
    );
  }
}

/// The 2pt accent line under a pane bar while it loads (query running,
/// refresh). Indeterminate unless [value] is given; an empty 2pt strip
/// when not [active], so the layout does not jump.
class LoadingLine extends StatelessWidget {
  const LoadingLine({super.key, this.active = true, this.value});

  final bool active;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    if (!active) return const SizedBox(height: 2);
    Widget line(double? phase) => CustomPaint(
      painter: _BarPainter(track: null, fill: c.accent, value: value, phase: phase),
      size: const Size(double.infinity, 2),
    );
    return SizedBox(
      height: 2,
      width: double.infinity,
      child: value == null ? _Sweep(builder: (_, t) => line(t)) : line(null),
    );
  }
}

/// NSLevelIndicator (continuous): 4pt track, radius 2, accent fill that
/// turns `warning` past [warningAt] and `danger` past [dangerAt].
///
/// A null [value] is indeterminate (a transfer of unknown size): a segment
/// sweeps across the track, still with Reduce Motion.
class LevelIndicator extends StatelessWidget {
  const LevelIndicator({
    super.key,
    required this.value,
    this.warningAt,
    this.dangerAt,
    this.width,
    this.color,
    this.tooltip,
    this.semanticLabel,
  });

  /// Fraction in 0..1, or null when unknown.
  final double? value;
  final double? warningAt;
  final double? dangerAt;
  final double? width;

  /// Fixed fill color (series colors in transfer bars), ignoring thresholds.
  final Color? color;
  final String? tooltip;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final v = value;
    var fill = color ?? c.accent;
    if (color == null && v != null) {
      if (dangerAt != null && v >= dangerAt!) {
        fill = c.danger;
      } else if (warningAt != null && v >= warningAt!) {
        fill = c.warning;
      }
    }
    Widget paint(double? phase) => CustomPaint(
      painter: _BarPainter(track: c.pressed, fill: fill, value: v, phase: phase, radius: 2),
      size: Size(width ?? double.infinity, 4),
    );
    Widget bar = SizedBox(
      width: width,
      height: 4,
      child: v == null ? _Sweep(builder: (_, t) => paint(t)) : paint(null),
    );
    if (semanticLabel != null || v != null) {
      bar = Semantics(
        label: semanticLabel,
        value: v == null ? null : '${(v.clamp(0.0, 1.0) * 100).round()}%',
        child: bar,
      );
    }
    return tooltip == null ? bar : Tooltip(message: tooltip!, child: bar);
  }
}

// ---------------------------------------------------------------------------
// Status line
// ---------------------------------------------------------------------------

enum StatusKind { busy, info, success, warning, danger }

/// One line of outcome next to the control that produced it ("Prova
/// connessione", AI check, installed driver, debugger state): a 14pt icon
/// (✓, ⚠, ⓧ) or a small [Spinner], 12pt text, optional "Dettagli…" link.
///
/// A [dot] replaces the icon with a 7pt [StatusDot] for neutral states that
/// are neither outcomes nor problems (debugger paused, dashboard live or
/// suspended); the text stays secondary.
class StatusLine extends StatelessWidget {
  const StatusLine(
    this.text, {
    super.key,
    this.kind = StatusKind.info,
    this.onDetails,
    this.detailsLabel = 'Dettagli…',
    this.selectable = false,
    this.maxLines = 2,
    this.dot,
  });

  const StatusLine.busy(this.text, {super.key, this.onDetails, this.detailsLabel = 'Dettagli…'})
    : kind = StatusKind.busy,
      selectable = false,
      maxLines = 1,
      dot = null;

  final String text;
  final StatusKind kind;

  /// Color of the leading dot; when set it wins over the [kind] icon.
  final Color? dot;
  final VoidCallback? onDetails;
  final String detailsLabel;

  /// Lets the user copy the text (error messages).
  final bool selectable;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final Widget? lead = dot != null
        ? StatusDot(dot!, size: 7)
        : switch (kind) {
            StatusKind.busy => const Spinner(size: Spinner.small),
            StatusKind.info => null,
            StatusKind.success => Icon(AppIcons.checkCircleFill, size: 14, color: c.success),
            StatusKind.warning => Icon(AppIcons.warningFill, size: 14, color: c.warning),
            StatusKind.danger => Icon(AppIcons.clearFill, size: 14, color: c.danger),
          };
    final neutral = dot != null || kind == StatusKind.busy || kind == StatusKind.info;
    final style = uiText(TypeSize.small, color: neutral ? c.textSecondary : c.text, height: 1.3);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lead != null) ...[
          // The dot sits on the middle of the first line, icons on its cap height.
          Padding(
            padding: EdgeInsets.only(top: dot != null ? 4 : 1),
            child: lead,
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: selectable
              ? SelectableText(text, maxLines: maxLines, style: style)
              : Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style),
        ),
        if (onDetails != null) ...[
          const SizedBox(width: Gap.sm),
          LinkButton(label: detailsLabel, small: true, onPressed: onDetails),
        ],
      ],
    );
  }
}
