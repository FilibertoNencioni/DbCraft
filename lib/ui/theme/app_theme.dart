import 'dart:io';

import 'package:flutter/material.dart';

/// Design tokens for DbCraft: macOS system materials, one accent.
@immutable
class DbColors extends ThemeExtension<DbColors> {
  const DbColors({
    required this.content,
    required this.chrome,
    required this.sidebar,
    required this.raised,
    required this.separator,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.onAccent,
    required this.hover,
    required this.pressed,
    required this.selection,
    required this.selectionMuted,
    required this.zebra,
    required this.success,
    required this.warning,
    required this.danger,
    required this.codeBackground,
    required this.gutter,
  });

  /// Main reading surface (editors, grids).
  final Color content;

  /// Toolbars, tab strip, status bar.
  final Color chrome;

  /// Source list on the left.
  final Color sidebar;

  /// Popovers, menus, sheets.
  final Color raised;
  final Color separator;
  final Color text;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color onAccent;
  final Color hover;
  final Color pressed;

  /// Selected row / cell (focused).
  final Color selection;

  /// Selected row when the list is not focused.
  final Color selectionMuted;

  /// Alternate row background in tables.
  final Color zebra;
  final Color success;
  final Color warning;
  final Color danger;
  final Color codeBackground;
  final Color gutter;

  static const light = DbColors(
    content: Color(0xFFFFFFFF),
    chrome: Color(0xFFF4F4F6),
    sidebar: Color(0xFFEDEDF0),
    raised: Color(0xFFFFFFFF),
    separator: Color(0x1A000000),
    text: Color(0xFF1D1D1F),
    textSecondary: Color(0xFF6E6E73),
    textTertiary: Color(0xFF8A8A8E),
    accent: Color(0xFF007AFF),
    onAccent: Color(0xFFFFFFFF),
    hover: Color(0x0D000000),
    pressed: Color(0x1A000000),
    selection: Color(0x2E007AFF),
    selectionMuted: Color(0x14000000),
    zebra: Color(0xFFF7F7F9),
    success: Color(0xFF28A745),
    warning: Color(0xFFE8890C),
    danger: Color(0xFFE5372C),
    codeBackground: Color(0xFFFFFFFF),
    gutter: Color(0xFFF9F9FB),
  );

  static const dark = DbColors(
    content: Color(0xFF1E1E20),
    chrome: Color(0xFF2A2A2D),
    sidebar: Color(0xFF252528),
    raised: Color(0xFF323236),
    separator: Color(0x26FFFFFF),
    text: Color(0xFFF2F2F5),
    textSecondary: Color(0xFFA1A1A8),
    textTertiary: Color(0xFF7C7C82),
    accent: Color(0xFF0A84FF),
    onAccent: Color(0xFFFFFFFF),
    hover: Color(0x12FFFFFF),
    pressed: Color(0x1FFFFFFF),
    selection: Color(0x400A84FF),
    selectionMuted: Color(0x1AFFFFFF),
    zebra: Color(0xFF232326),
    success: Color(0xFF32D74B),
    warning: Color(0xFFFF9F0A),
    danger: Color(0xFFFF453A),
    codeBackground: Color(0xFF1E1E20),
    gutter: Color(0xFF222225),
  );

  static DbColors of(BuildContext context) => Theme.of(context).extension<DbColors>()!;

  @override
  DbColors copyWith() => this;

  @override
  DbColors lerp(ThemeExtension<DbColors>? other, double t) {
    if (other is! DbColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return DbColors(
      content: l(content, other.content),
      chrome: l(chrome, other.chrome),
      sidebar: l(sidebar, other.sidebar),
      raised: l(raised, other.raised),
      separator: l(separator, other.separator),
      text: l(text, other.text),
      textSecondary: l(textSecondary, other.textSecondary),
      textTertiary: l(textTertiary, other.textTertiary),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      hover: l(hover, other.hover),
      pressed: l(pressed, other.pressed),
      selection: l(selection, other.selection),
      selectionMuted: l(selectionMuted, other.selectionMuted),
      zebra: l(zebra, other.zebra),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      danger: l(danger, other.danger),
      codeBackground: l(codeBackground, other.codeBackground),
      gutter: l(gutter, other.gutter),
    );
  }
}

/// Spacing scale (4pt grid).
abstract final class Gap {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class Radii {
  static const double control = 6;
  static const double panel = 8;
  static const double sheet = 12;
}

/// Type sizes tuned for desktop UI (13pt body like AppKit).
abstract final class TypeSize {
  static const double caption = 11;
  static const double small = 12;
  static const double body = 13;
  static const double title = 15;
  static const double headline = 20;
  static const double display = 26;
}

const kMonoFamily = 'SF Mono';
const kMonoFallback = ['Menlo', 'Consolas', 'Cascadia Mono', 'DejaVu Sans Mono', 'monospace'];
const kTabular = [FontFeature.tabularFigures()];

/// Height of the unified toolbar (title bar area on macOS).
const double kUnifiedToolbarHeight = 52;

/// Space reserved for the macOS traffic lights.
double trafficLightInset(bool fullScreen) => Platform.isMacOS && !fullScreen ? 78 : 0;

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? DbColors.dark : DbColors.light;
  final base = ThemeData(brightness: brightness, useMaterial3: true);
  final scheme = ColorScheme.fromSeed(seedColor: c.accent, brightness: brightness).copyWith(
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.accent,
    surface: c.content,
    onSurface: c.text,
    onSurfaceVariant: c.textSecondary,
    surfaceContainerLowest: c.content,
    surfaceContainerLow: c.chrome,
    surfaceContainer: c.chrome,
    surfaceContainerHigh: c.chrome,
    surfaceContainerHighest: c.sidebar,
    outline: c.textTertiary,
    outlineVariant: c.separator,
    error: c.danger,
    onError: Colors.white,
    primaryContainer: c.selection,
    onPrimaryContainer: c.text,
  );

  TextStyle t(double size, [FontWeight w = FontWeight.w400, double? spacing]) =>
      TextStyle(fontSize: size, fontWeight: w, letterSpacing: spacing, color: c.text, height: 1.3);

  final text = base.textTheme.copyWith(
    displaySmall: t(TypeSize.display, FontWeight.w700, -0.5),
    headlineSmall: t(TypeSize.headline, FontWeight.w600, -0.3),
    titleLarge: t(17, FontWeight.w600, -0.2),
    titleMedium: t(TypeSize.title, FontWeight.w600, -0.1),
    titleSmall: t(TypeSize.body, FontWeight.w600),
    bodyLarge: t(14),
    bodyMedium: t(TypeSize.body),
    bodySmall: t(TypeSize.small).copyWith(color: c.textSecondary),
    labelLarge: t(TypeSize.body, FontWeight.w500),
    labelMedium: t(TypeSize.small, FontWeight.w500),
    labelSmall: t(TypeSize.caption, FontWeight.w500).copyWith(color: c.textSecondary),
  );

  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control));
  const controlSize = Size(0, 28);
  const controlPadding = EdgeInsets.symmetric(horizontal: 12);
  final buttonText = WidgetStatePropertyAll(t(TypeSize.body, FontWeight.w500));

  OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.control),
        borderSide: BorderSide(color: color, width: width),
      );

  return base.copyWith(
    colorScheme: scheme,
    extensions: [c],
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    scaffoldBackgroundColor: c.content,
    canvasColor: c.content,
    dividerColor: c.separator,
    hoverColor: c.hover,
    focusColor: c.accent.withValues(alpha: 0.25),
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    disabledColor: c.textTertiary,
    hintColor: c.textTertiary,
    textTheme: text,
    iconTheme: IconThemeData(size: 16, color: c.textSecondary),
    dividerTheme: DividerThemeData(color: c.separator, thickness: 1, space: 1),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 600),
      textStyle: TextStyle(fontSize: TypeSize.caption + 0.5, color: c.text),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: c.separator),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black54,
      menuPadding: const EdgeInsets.all(4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.panel),
        side: BorderSide(color: c.separator),
      ),
      textStyle: t(TypeSize.body),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.panel),
          side: BorderSide(color: c.separator),
        )),
      ),
    ),
    menuBarTheme: MenuBarThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.chrome),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        textStyle: buttonText,
        minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        shape: WidgetStatePropertyAll(controlShape),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sheet),
        side: BorderSide(color: c.separator),
      ),
      titleTextStyle: t(TypeSize.title, FontWeight.w600),
      contentTextStyle: t(TypeSize.body),
      actionsPadding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.lg + 2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(controlPadding),
        shape: WidgetStatePropertyAll(controlShape),
        textStyle: buttonText,
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return c.pressed;
          if (s.contains(WidgetState.pressed)) return Color.lerp(c.accent, Colors.black, 0.15);
          return c.accent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.textTertiary : c.onAccent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(controlPadding),
        shape: WidgetStatePropertyAll(controlShape),
        textStyle: buttonText,
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.textTertiary : c.text),
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.pressed)) return c.pressed;
          if (s.contains(WidgetState.hovered)) return c.hover;
          return c.raised;
        }),
        side: WidgetStatePropertyAll(BorderSide(color: c.separator)),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        shape: WidgetStatePropertyAll(controlShape),
        textStyle: buttonText,
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.textTertiary : c.accent),
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.pressed)) return c.pressed;
          if (s.contains(WidgetState.hovered)) return c.hover;
          return Colors.transparent;
        }),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        iconSize: const WidgetStatePropertyAll(16),
        minimumSize: const WidgetStatePropertyAll(Size(28, 28)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        shape: WidgetStatePropertyAll(controlShape),
        foregroundColor: WidgetStatePropertyAll(c.textSecondary),
        overlayColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.pressed)) return c.pressed;
          if (s.contains(WidgetState.hovered)) return c.hover;
          return Colors.transparent;
        }),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
        textStyle: WidgetStatePropertyAll(t(TypeSize.small + 0.5, FontWeight.w500)),
        shape: WidgetStatePropertyAll(controlShape),
        side: WidgetStatePropertyAll(BorderSide(color: c.separator)),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.raised : c.chrome),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.text : c.textSecondary),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.content,
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: border(c.separator),
      enabledBorder: border(c.separator),
      disabledBorder: border(c.separator.withValues(alpha: 0.05)),
      focusedBorder: border(c.accent.withValues(alpha: 0.7), 2),
      errorBorder: border(c.danger),
      focusedErrorBorder: border(c.danger, 2),
      labelStyle: TextStyle(fontSize: TypeSize.body, color: c.textSecondary),
      floatingLabelStyle: TextStyle(fontSize: TypeSize.body, color: c.textSecondary),
      hintStyle: TextStyle(fontSize: TypeSize.body, color: c.textTertiary),
      helperStyle: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary),
      prefixIconColor: c.textTertiary,
      suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 20, maxHeight: 30),
      suffixIconColor: c.textSecondary,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.28),
      selectionHandleColor: c.accent,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: BorderSide(color: c.textTertiary),
      visualDensity: VisualDensity.compact,
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.success : c.pressed),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.textTertiary)),
    chipTheme: ChipThemeData(
      backgroundColor: c.chrome,
      selectedColor: c.selection,
      side: BorderSide(color: c.separator),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
      labelStyle: t(TypeSize.small + 0.5, FontWeight.w500),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      showCheckmark: false,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.text,
      unselectedLabelColor: c.textSecondary,
      labelStyle: t(TypeSize.body, FontWeight.w600),
      unselectedLabelStyle: t(TypeSize.body, FontWeight.w500),
      indicatorColor: c.accent,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: c.separator,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      tabAlignment: TabAlignment.start,
      labelPadding: const EdgeInsets.symmetric(horizontal: Gap.md),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? 9 : 6),
      radius: const Radius.circular(8),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => c.text.withValues(alpha: s.contains(WidgetState.dragged) ? 0.5 : 0.28)),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
      interactive: true,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: brightness == Brightness.dark ? const Color(0xFF3A3A3E) : const Color(0xFF2C2C2E),
      contentTextStyle: const TextStyle(fontSize: TypeSize.body, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.panel)),
      elevation: 6,
      width: 440,
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.md),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
      titleTextStyle: t(TypeSize.body),
      subtitleTextStyle: t(TypeSize.small).copyWith(color: c.textSecondary),
      iconColor: c.textSecondary,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.accent,
      inactiveTrackColor: c.pressed,
      thumbColor: Colors.white,
      overlayShape: SliderComponentShape.noOverlay,
      trackHeight: 3,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.pressed,
      linearMinHeight: 3,
      strokeWidth: 2,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: c.textSecondary,
      collapsedIconColor: c.textTertiary,
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: t(TypeSize.small, FontWeight.w600).copyWith(color: c.textSecondary),
      dataTextStyle: t(TypeSize.body),
      headingRowColor: WidgetStatePropertyAll(c.chrome),
      dividerThickness: 1,
    ),
  );
}
