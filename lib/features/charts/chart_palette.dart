import 'package:flutter/material.dart';

import '../../ui/theme/app_theme.dart';

/// Categorical palette of the charts.
///
/// Slot 1 is the app accent (system blue); slots 2–8 come from a categorical
/// palette validated for color-vision deficiency on the DbCraft surfaces
/// (white / #1E1E20): adjacent pairs keep CVD ΔE ≥ 8.4 and normal-vision
/// ΔE ≥ 19 in both modes. The order is the safety mechanism: series take
/// slots in order and never cycle; past eight series the chart folds or
/// truncates. Scatter plots use only the first three slots.
class ChartPalette {
  ChartPalette._(this.slots, this.other, this.surface);

  factory ChartPalette.of(BuildContext context) {
    final c = DbColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ChartPalette._([c.accent, ...(dark ? _dark : _light)], c.textTertiary, c.content);
  }

  static const _light = [
    Color(0xFFEB6834), // orange
    Color(0xFF1BAF7A), // aqua
    Color(0xFFEDA100), // yellow
    Color(0xFFE87BA4), // magenta
    Color(0xFF008300), // green
    Color(0xFF4A3AA7), // violet
    Color(0xFFE34948), // red
  ];

  static const _dark = [
    Color(0xFFD95926),
    Color(0xFF199E70),
    Color(0xFFC98500),
    Color(0xFFD55181),
    Color(0xFF008300),
    Color(0xFF9085E9),
    Color(0xFFE66767),
  ];

  final List<Color> slots;

  /// Neutral used for the folded "Altro" category.
  final Color other;

  /// Chart surface (used for the 2px gaps and marker rings).
  final Color surface;

  Color operator [](int slot) => slots[slot % slots.length];
}
