import 'package:flutter/foundation.dart';

/// Text zoom of the SQL editors, as a factor of the editor font size set in
/// the settings (1.0 = 100%). Shared by every SQL editor and not persisted:
/// the permanent size is the setting, the zoom is a temporary magnification.
class EditorZoom extends ValueNotifier<double> {
  EditorZoom() : super(1.0);

  static const double min = 0.5;
  static const double max = 3.0;

  /// Keyboard / menu steps (browser-like).
  static const List<double> levels = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];

  bool get isDefault => (value - 1.0).abs() < 0.001;

  /// "125%".
  String get label => '${(value * 100).round()}%';

  /// Next level above the current zoom (also from an in-between value left
  /// by a pinch).
  void zoomIn() => value = levels.firstWhere((l) => l > value + 0.001, orElse: () => max);

  void zoomOut() => value = levels.lastWhere((l) => l < value - 0.001, orElse: () => min);

  void reset() => value = 1.0;

  /// Continuous zoom (pinch): clamped and rounded to 5%.
  void set(double v) => value = (v.clamp(min, max) * 20).round() / 20;

  /// Font size for a [base] size from the settings.
  double fontSize(double base) => (base * value * 2).round() / 2;
}
