import 'package:flutter/widgets.dart';

/// Control heights (AppKit control sizes).
abstract final class ControlSize {
  /// Push buttons, text fields, pop-ups and segmented controls in forms and bars.
  static const double regular = 22;

  /// Dense bars (grid filters, pane headers).
  static const double small = 19;

  /// Inline accessories inside rows.
  static const double mini = 16;

  /// Items in the unified window toolbar.
  static const double toolbar = 28;
}

/// Heights of the horizontal bars that frame panes.
abstract final class BarHeight {
  /// Unified window toolbar (title bar area on macOS).
  static const double toolbar = 52;

  /// Pane toolbar (SQL editor, results, ER diagram, feature tabs).
  static const double bar = 36;

  /// Pane header, inner tab strip, filter strip.
  static const double subbar = 28;

  /// Document tab strip.
  static const double tabStrip = 30;

  /// Status bar.
  static const double status = 22;
}

/// The only alpha values used to tint a color over a surface.
abstract final class Tint {
  /// Notice backgrounds, soft row highlights.
  static const double subtle = 0.08;

  /// Tags, badges, tokens.
  static const double regular = 0.14;

  /// Grid selection, changed cells.
  static const double strong = 0.22;

  /// Hairline borders of tinted boxes.
  static const double border = 0.35;
}

/// Shadows. A surface uses a hairline or a shadow, never both, except menus,
/// popovers and sheets, which pair a 0.5px border with their shadow.
abstract final class Elevation {
  static List<BoxShadow> control(Brightness b) => b == Brightness.dark
      ? const [BoxShadow(color: Color(0x40000000), blurRadius: 1, offset: Offset(0, 0.5))]
      : const [BoxShadow(color: Color(0x26000000), blurRadius: 1, offset: Offset(0, 0.5))];

  static List<BoxShadow> node(Brightness b) => b == Brightness.dark
      ? const [BoxShadow(color: Color(0x59000000), blurRadius: 6, offset: Offset(0, 2))]
      : const [BoxShadow(color: Color(0x1F000000), blurRadius: 6, offset: Offset(0, 2))];

  static List<BoxShadow> menu(Brightness b) => b == Brightness.dark
      ? const [BoxShadow(color: Color(0x80000000), blurRadius: 24, offset: Offset(0, 8))]
      : const [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 8))];

  static List<BoxShadow> popover(Brightness b) => menu(b);

  /// A tight contact shadow plus a wide, soft one: the sheet floats well
  /// above the dimmed window.
  static List<BoxShadow> sheet(Brightness b) => b == Brightness.dark
      ? const [
          BoxShadow(color: Color(0x66000000), blurRadius: 4, offset: Offset(0, 1)),
          BoxShadow(color: Color(0xA6000000), blurRadius: 60, offset: Offset(0, 24)),
        ]
      : const [
          BoxShadow(color: Color(0x24000000), blurRadius: 4, offset: Offset(0, 1)),
          BoxShadow(color: Color(0x47000000), blurRadius: 60, offset: Offset(0, 24)),
        ];

  /// Dims the window behind a modal sheet or alert.
  static Color scrim(Brightness b) => b == Brightness.dark ? const Color(0x73000000) : const Color(0x38000000);
}

/// Durations. Keyboard-initiated changes and Reduce Motion skip them.
abstract final class Motion {
  /// Focus ring, menu highlight, disclosure chevrons.
  static const fast = Duration(milliseconds: 100);

  /// Sheets, sidebar slide.
  static const regular = Duration(milliseconds: 200);

  /// [d], or zero when the system asks to reduce motion.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;
}
