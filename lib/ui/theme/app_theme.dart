import 'dart:io';

import 'package:flutter/material.dart';

import 'tokens.dart';

export 'app_icons.dart';
export 'tokens.dart';

/// Design tokens for DbCraft: macOS system materials, one accent.
///
/// [DbColors.light] and [DbColors.dark] hold the base palette. The app resolves
/// them with [DbColors.resolve] against the system accent color and the window
/// key state, so selections and the default button turn gray when the window
/// is in the background, as in AppKit.
@immutable
class DbColors extends ThemeExtension<DbColors> {
  const DbColors({
    required this.content,
    required this.chrome,
    required this.sidebar,
    required this.raised,
    required this.windowBackground,
    required this.groupBackground,
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
    required this.selectionEmphasized,
    required this.onSelectionEmphasized,
    required this.zebra,
    required this.success,
    required this.warning,
    required this.danger,
    required this.codeBackground,
    required this.codeCurrentLine,
    required this.gutter,
    required this.controlBackground,
    required this.controlBorder,
    required this.focusRing,
    required this.defaultButton,
    required this.onDefaultButton,
    required this.segmentSelected,
    required this.menuBackground,
    required this.tooltipBackground,
    required this.keyIcon,
    required this.foreignKeyIcon,
    required this.codeKeyword,
    required this.codeFunction,
    required this.codeTable,
    required this.codeColumn,
    required this.codeType,
    required this.windowActive,
  });

  /// Main reading surface (editors, grids, field fills).
  final Color content;

  /// Toolbars, tab strip, pane bars, status bars, grid header.
  final Color chrome;

  /// Source list on the left.
  final Color sidebar;

  /// Popovers, cards on a canvas, HUDs.
  final Color raised;

  /// Sheets, inspectors and settings pages (NSColor.windowBackgroundColor).
  final Color windowBackground;

  /// Form groups on a [windowBackground] (System Settings boxes).
  final Color groupBackground;
  final Color separator;
  final Color text;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color onAccent;
  final Color hover;
  final Color pressed;

  /// Selected rows and cells (tinted). Gray when the window is inactive.
  final Color selection;

  /// Selected row when its list does not have focus.
  final Color selectionMuted;

  /// Selected source-list row when the list has focus: the solid accent, or
  /// a gray when the window is inactive.
  final Color selectionEmphasized;
  final Color onSelectionEmphasized;

  /// Alternate row background in tables.
  final Color zebra;
  final Color success;
  final Color warning;
  final Color danger;
  final Color codeBackground;
  final Color codeCurrentLine;
  final Color gutter;

  /// Fill of push buttons and pop-up buttons.
  final Color controlBackground;

  /// 0.5px outline of buttons and fields.
  final Color controlBorder;

  /// Keyboard focus halo around controls.
  final Color focusRing;

  /// Fill and label of the default button (Invio). Gray when inactive.
  final Color defaultButton;
  final Color onDefaultButton;

  /// Selected segment of a segmented control.
  final Color segmentSelected;
  final Color menuBackground;
  final Color tooltipBackground;

  /// Primary key glyphs.
  final Color keyIcon;

  /// Foreign key glyphs.
  final Color foreignKeyIcon;

  /// Completion kinds in the SQL editor.
  final Color codeKeyword;
  final Color codeFunction;
  final Color codeTable;
  final Color codeColumn;
  final Color codeType;

  /// Whether the window is key. Inactive windows dim their emphasis.
  final bool windowActive;

  /// Diff and edit-state colors are the semantic colors.
  Color get diffAdded => success;
  Color get diffRemoved => danger;
  Color get diffChanged => warning;
  Color get diffHunk => accent;

  static const light = DbColors(
    content: Color(0xFFFFFFFF),
    chrome: Color(0xFFF4F4F6),
    sidebar: Color(0xFFEDEDF0),
    raised: Color(0xFFFFFFFF),
    windowBackground: Color(0xFFECECEC),
    groupBackground: Color(0x99FFFFFF),
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
    selectionEmphasized: Color(0xFF007AFF),
    onSelectionEmphasized: Color(0xFFFFFFFF),
    zebra: Color(0xFFF7F7F9),
    success: Color(0xFF28A745),
    warning: Color(0xFFE8890C),
    danger: Color(0xFFE5372C),
    codeBackground: Color(0xFFFFFFFF),
    codeCurrentLine: Color(0xFFF5F8FF),
    gutter: Color(0xFFF9F9FB),
    controlBackground: Color(0xFFFFFFFF),
    controlBorder: Color(0x26000000),
    focusRing: Color(0x80007AFF),
    defaultButton: Color(0xFF007AFF),
    onDefaultButton: Color(0xFFFFFFFF),
    segmentSelected: Color(0xFFFFFFFF),
    menuBackground: Color(0xFFF6F6F6),
    tooltipBackground: Color(0xFFF7F7F7),
    keyIcon: Color(0xFFE8A200),
    foreignKeyIcon: Color(0xFF8E5BD0),
    codeKeyword: Color(0xFFAF52DE),
    codeFunction: Color(0xFF30B0C7),
    codeTable: Color(0xFF007AFF),
    codeColumn: Color(0xFFFF9500),
    codeType: Color(0xFF8E8E93),
    windowActive: true,
  );

  static const dark = DbColors(
    content: Color(0xFF1E1E20),
    chrome: Color(0xFF2A2A2D),
    sidebar: Color(0xFF252528),
    raised: Color(0xFF323236),
    windowBackground: Color(0xFF2B2B2E),
    groupBackground: Color(0x0DFFFFFF),
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
    selectionEmphasized: Color(0xFF0A84FF),
    onSelectionEmphasized: Color(0xFFFFFFFF),
    zebra: Color(0xFF232326),
    success: Color(0xFF32D74B),
    warning: Color(0xFFFF9F0A),
    danger: Color(0xFFFF453A),
    codeBackground: Color(0xFF1E1E20),
    codeCurrentLine: Color(0xFF26262A),
    gutter: Color(0xFF222225),
    controlBackground: Color(0xFF5B5B5F),
    controlBorder: Color(0x14FFFFFF),
    focusRing: Color(0x800A84FF),
    defaultButton: Color(0xFF0A84FF),
    onDefaultButton: Color(0xFFFFFFFF),
    segmentSelected: Color(0xFF636366),
    menuBackground: Color(0xFF2E2E31),
    tooltipBackground: Color(0xFF3A3A3C),
    keyIcon: Color(0xFFFFB300),
    foreignKeyIcon: Color(0xFFB08CF0),
    codeKeyword: Color(0xFFBF5AF2),
    codeFunction: Color(0xFF40C8E0),
    codeTable: Color(0xFF0A84FF),
    codeColumn: Color(0xFFFF9F0A),
    codeType: Color(0xFF98989D),
    windowActive: true,
  );

  static DbColors of(BuildContext context) => Theme.of(context).extension<DbColors>()!;

  bool get _dark => content.computeLuminance() < 0.2;

  /// The palette for a given system [accentColor] and window key state.
  DbColors resolve({Color? accentColor, bool active = true}) {
    final a = accentColor ?? accent;
    final gray = _dark ? const Color(0x26FFFFFF) : const Color(0x1F000000);
    return copyWith(
      accent: a,
      selection: active ? a.withValues(alpha: _dark ? 0.25 : 0.18) : gray,
      selectionEmphasized: active ? a : gray,
      onSelectionEmphasized: active ? onAccent : text,
      focusRing: a.withValues(alpha: 0.5),
      defaultButton: active ? a : controlBackground,
      onDefaultButton: active ? onAccent : text,
      codeTable: a,
      windowActive: active,
    );
  }

  @override
  DbColors copyWith({
    Color? content,
    Color? chrome,
    Color? sidebar,
    Color? raised,
    Color? windowBackground,
    Color? groupBackground,
    Color? separator,
    Color? text,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? onAccent,
    Color? hover,
    Color? pressed,
    Color? selection,
    Color? selectionMuted,
    Color? selectionEmphasized,
    Color? onSelectionEmphasized,
    Color? zebra,
    Color? success,
    Color? warning,
    Color? danger,
    Color? codeBackground,
    Color? codeCurrentLine,
    Color? gutter,
    Color? controlBackground,
    Color? controlBorder,
    Color? focusRing,
    Color? defaultButton,
    Color? onDefaultButton,
    Color? segmentSelected,
    Color? menuBackground,
    Color? tooltipBackground,
    Color? keyIcon,
    Color? foreignKeyIcon,
    Color? codeKeyword,
    Color? codeFunction,
    Color? codeTable,
    Color? codeColumn,
    Color? codeType,
    bool? windowActive,
  }) => DbColors(
    content: content ?? this.content,
    chrome: chrome ?? this.chrome,
    sidebar: sidebar ?? this.sidebar,
    raised: raised ?? this.raised,
    windowBackground: windowBackground ?? this.windowBackground,
    groupBackground: groupBackground ?? this.groupBackground,
    separator: separator ?? this.separator,
    text: text ?? this.text,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    hover: hover ?? this.hover,
    pressed: pressed ?? this.pressed,
    selection: selection ?? this.selection,
    selectionMuted: selectionMuted ?? this.selectionMuted,
    selectionEmphasized: selectionEmphasized ?? this.selectionEmphasized,
    onSelectionEmphasized: onSelectionEmphasized ?? this.onSelectionEmphasized,
    zebra: zebra ?? this.zebra,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    codeBackground: codeBackground ?? this.codeBackground,
    codeCurrentLine: codeCurrentLine ?? this.codeCurrentLine,
    gutter: gutter ?? this.gutter,
    controlBackground: controlBackground ?? this.controlBackground,
    controlBorder: controlBorder ?? this.controlBorder,
    focusRing: focusRing ?? this.focusRing,
    defaultButton: defaultButton ?? this.defaultButton,
    onDefaultButton: onDefaultButton ?? this.onDefaultButton,
    segmentSelected: segmentSelected ?? this.segmentSelected,
    menuBackground: menuBackground ?? this.menuBackground,
    tooltipBackground: tooltipBackground ?? this.tooltipBackground,
    keyIcon: keyIcon ?? this.keyIcon,
    foreignKeyIcon: foreignKeyIcon ?? this.foreignKeyIcon,
    codeKeyword: codeKeyword ?? this.codeKeyword,
    codeFunction: codeFunction ?? this.codeFunction,
    codeTable: codeTable ?? this.codeTable,
    codeColumn: codeColumn ?? this.codeColumn,
    codeType: codeType ?? this.codeType,
    windowActive: windowActive ?? this.windowActive,
  );

  @override
  DbColors lerp(ThemeExtension<DbColors>? other, double t) {
    if (other is! DbColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return DbColors(
      content: l(content, other.content),
      chrome: l(chrome, other.chrome),
      sidebar: l(sidebar, other.sidebar),
      raised: l(raised, other.raised),
      windowBackground: l(windowBackground, other.windowBackground),
      groupBackground: l(groupBackground, other.groupBackground),
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
      selectionEmphasized: l(selectionEmphasized, other.selectionEmphasized),
      onSelectionEmphasized: l(onSelectionEmphasized, other.onSelectionEmphasized),
      zebra: l(zebra, other.zebra),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      danger: l(danger, other.danger),
      codeBackground: l(codeBackground, other.codeBackground),
      codeCurrentLine: l(codeCurrentLine, other.codeCurrentLine),
      gutter: l(gutter, other.gutter),
      controlBackground: l(controlBackground, other.controlBackground),
      controlBorder: l(controlBorder, other.controlBorder),
      focusRing: l(focusRing, other.focusRing),
      defaultButton: l(defaultButton, other.defaultButton),
      onDefaultButton: l(onDefaultButton, other.onDefaultButton),
      segmentSelected: l(segmentSelected, other.segmentSelected),
      menuBackground: l(menuBackground, other.menuBackground),
      tooltipBackground: l(tooltipBackground, other.tooltipBackground),
      keyIcon: l(keyIcon, other.keyIcon),
      foreignKeyIcon: l(foreignKeyIcon, other.foreignKeyIcon),
      codeKeyword: l(codeKeyword, other.codeKeyword),
      codeFunction: l(codeFunction, other.codeFunction),
      codeTable: l(codeTable, other.codeTable),
      codeColumn: l(codeColumn, other.codeColumn),
      codeType: l(codeType, other.codeType),
      windowActive: t < 0.5 ? windowActive : other.windowActive,
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
  /// Tags, keycaps, tooltips, small marks.
  static const double small = 4;

  /// Buttons, fields, pop-ups, segmented controls, list rows.
  static const double control = 5;

  /// Menus and completion lists.
  static const double menu = 6;

  /// Form groups, notices, code boxes, panels.
  static const double panel = 8;

  /// Sheets, alerts and popovers.
  static const double sheet = 10;
}

/// Type sizes tuned for desktop UI (13pt body like AppKit).
abstract final class TypeSize {
  static const double mini = 10;
  static const double caption = 11;
  static const double small = 12;
  static const double body = 13;
  static const double title = 15;
  static const double sheetTitle = 17;
  static const double headline = 20;
  static const double display = 26;

  /// SQL, values and code in prose-sized contexts.
  static const double mono = 12;
  static const double monoSmall = 11;
}

/// The system UI font. Flutter resolves '.AppleSystemUIFont' to SF on macOS;
/// other platforms keep their default UI font.
final String? kUiFamily = Platform.isMacOS ? '.AppleSystemUIFont' : null;

/// SF Pro tracking for a point size (Apple HIG tracking table). Flutter does
/// not apply the font's size-specific tracking, so text looks loose without it.
double sfTracking(double size) {
  if (!Platform.isMacOS) return 0;
  // (point size, tracking) pairs, ascending.
  const table = [
    (9.0, 0.17), (10.0, 0.12), (11.0, 0.06), (12.0, 0.0), (13.0, -0.08), (14.0, -0.15), (15.0, -0.23),
    (16.0, -0.31), (17.0, -0.43), (18.0, -0.44), (20.0, -0.45), (22.0, -0.26), (24.0, 0.07), (26.0, 0.22),
    (28.0, 0.38),
  ];
  if (size <= table.first.$1) return table.first.$2;
  if (size >= table.last.$1) return table.last.$2;
  for (var i = 0; i < table.length - 1; i++) {
    final (a, ta) = table[i];
    final (b, tb) = table[i + 1];
    if (size >= a && size <= b) return ta + (tb - ta) * (size - a) / (b - a);
  }
  return 0;
}

/// UI text style at a point size, with the system font and tracking.
TextStyle uiText(
  double size, {
  FontWeight? weight,
  Color? color,
  double? height,
  FontStyle? style,
  List<FontFeature>? features,
}) => TextStyle(
  fontFamily: kUiFamily,
  fontSize: size,
  fontWeight: weight,
  fontStyle: style,
  color: color,
  height: height,
  letterSpacing: sfTracking(size),
  fontFeatures: features,
);

const kMonoFamily = 'SF Mono';
const kMonoFallback = ['Menlo', 'Consolas', 'Cascadia Mono', 'DejaVu Sans Mono', 'monospace'];
const kTabular = [FontFeature.tabularFigures()];

/// Space reserved for the macOS traffic lights. The empty unified NSToolbar in
/// `MainFlutterWindow` centers them on the toolbar, at x 19–79.
double trafficLightInset(bool fullScreen) => Platform.isMacOS && !fullScreen ? 88 : 0;

/// Field outline with the AppKit focus ring: a 0.5px border, plus a soft
/// accent halo drawn outside the field while it has focus.
class MacFieldBorder extends OutlineInputBorder {
  const MacFieldBorder({
    required this.color,
    this.ring,
    super.borderRadius = const BorderRadius.all(Radius.circular(Radii.control)),
  }) : super(borderSide: BorderSide.none);

  final Color color;

  /// Focus halo color, or null when unfocused.
  final Color? ring;

  @override
  MacFieldBorder copyWith({BorderSide? borderSide, BorderRadius? borderRadius, double? gapPadding}) =>
      MacFieldBorder(color: color, ring: ring, borderRadius: borderRadius ?? this.borderRadius);

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    final rrect = borderRadius.toRRect(rect);
    if (ring != null) {
      canvas.drawRRect(
        rrect.inflate(1.75),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..color = ring!,
      );
    }
    canvas.drawRRect(
      rrect.deflate(0.25),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = color,
    );
  }

  @override
  MacFieldBorder scale(double t) => this;

  @override
  bool operator ==(Object other) =>
      other is MacFieldBorder && other.color == color && other.ring == ring && other.borderRadius == borderRadius;

  @override
  int get hashCode => Object.hash(color, ring, borderRadius);
}

/// Builds the app theme. [accent] is the system accent color (macOS) and
/// [active] whether the window is key.
ThemeData buildTheme(Brightness brightness, {Color? accent, bool active = true}) {
  final c = (brightness == Brightness.dark ? DbColors.dark : DbColors.light).resolve(
    accentColor: accent,
    active: active,
  );
  final base = ThemeData(brightness: brightness, useMaterial3: true, fontFamily: kUiFamily);
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

  TextStyle t(double size, [FontWeight w = FontWeight.w400]) =>
      uiText(size, weight: w, color: c.text, height: 1.3);

  final text = base.textTheme.copyWith(
    displaySmall: t(TypeSize.display, FontWeight.w700),
    headlineSmall: t(TypeSize.headline, FontWeight.w600),
    titleLarge: t(TypeSize.sheetTitle, FontWeight.w600),
    titleMedium: t(TypeSize.title, FontWeight.w600),
    titleSmall: t(TypeSize.body, FontWeight.w600),
    bodyLarge: t(TypeSize.body),
    bodyMedium: t(TypeSize.body),
    bodySmall: t(TypeSize.small).copyWith(color: c.textSecondary),
    labelLarge: t(TypeSize.body, FontWeight.w500),
    labelMedium: t(TypeSize.small, FontWeight.w500),
    labelSmall: t(TypeSize.caption, FontWeight.w500).copyWith(color: c.textSecondary),
  );

  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control));
  const controlSize = Size(0, ControlSize.regular);
  const controlPadding = EdgeInsets.symmetric(horizontal: 10);
  final buttonText = WidgetStatePropertyAll(t(TypeSize.body));

  return base.copyWith(
    colorScheme: scheme,
    extensions: [c],
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    scaffoldBackgroundColor: c.content,
    canvasColor: c.content,
    dividerColor: c.separator,
    hoverColor: c.hover,
    focusColor: c.focusRing,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    disabledColor: c.textTertiary,
    hintColor: c.textTertiary,
    textTheme: text,
    iconTheme: IconThemeData(size: 16, color: c.textSecondary),
    dividerTheme: DividerThemeData(color: c.separator, thickness: 1, space: 1),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 800),
      textStyle: uiText(TypeSize.caption, color: c.text),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.tooltipBackground,
        borderRadius: BorderRadius.circular(Radii.small),
        border: Border.all(color: c.separator, width: 0.5),
        boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.menuBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black54,
      menuPadding: const EdgeInsets.all(5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.menu),
        side: BorderSide(color: c.separator, width: 0.5),
      ),
      textStyle: t(TypeSize.body),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.menuBackground),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(5)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.menu),
          side: BorderSide(color: c.separator, width: 0.5),
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
        minimumSize: const WidgetStatePropertyAll(Size(0, ControlSize.regular)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.small))),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.focused) ? c.accent : null),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.focused) ? c.onAccent : c.text),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.windowBackground,
      surfaceTintColor: Colors.transparent,
      barrierColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sheet),
        side: BorderSide(color: c.separator, width: 0.5),
      ),
      titleTextStyle: t(TypeSize.body, FontWeight.w700),
      contentTextStyle: t(TypeSize.body),
      actionsPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(controlPadding),
        shape: WidgetStatePropertyAll(controlShape),
        textStyle: buttonText,
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return c.pressed;
          if (s.contains(WidgetState.pressed)) return Color.lerp(c.defaultButton, Colors.black, 0.15);
          return c.defaultButton;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.textTertiary : c.onDefaultButton),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(controlPadding),
        shape: WidgetStatePropertyAll(controlShape),
        textStyle: buttonText,
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.textTertiary : c.text),
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.pressed)) return Color.lerp(c.controlBackground, c.text, 0.1);
          return c.controlBackground;
        }),
        side: WidgetStatePropertyAll(BorderSide(color: c.controlBorder, width: 0.5)),
        elevation: const WidgetStatePropertyAll(0.5),
        shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.5)),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
        shape: WidgetStatePropertyAll(controlShape),
        textStyle: buttonText,
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.textTertiary : c.accent),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.pressed) ? c.pressed : Colors.transparent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        iconSize: const WidgetStatePropertyAll(16),
        minimumSize: const WidgetStatePropertyAll(Size(ControlSize.regular, ControlSize.regular)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(3)),
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
        minimumSize: const WidgetStatePropertyAll(Size(0, ControlSize.regular)),
        textStyle: WidgetStatePropertyAll(t(TypeSize.small, FontWeight.w500)),
        shape: WidgetStatePropertyAll(controlShape),
        side: WidgetStatePropertyAll(BorderSide(color: c.controlBorder, width: 0.5)),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.segmentSelected : c.pressed),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.text : c.textSecondary),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      // 22pt fields: 13pt text (17) + 2.5pt padding top and bottom.
      isDense: true,
      visualDensity: VisualDensity.standard,
      filled: true,
      fillColor: c.content,
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      border: MacFieldBorder(color: c.controlBorder),
      enabledBorder: MacFieldBorder(color: c.controlBorder),
      disabledBorder: MacFieldBorder(color: c.separator.withValues(alpha: 0.05)),
      focusedBorder: MacFieldBorder(color: c.controlBorder, ring: c.focusRing),
      errorBorder: MacFieldBorder(color: c.danger),
      focusedErrorBorder: MacFieldBorder(color: c.danger, ring: c.danger.withValues(alpha: 0.5)),
      labelStyle: uiText(TypeSize.body, color: c.textSecondary),
      floatingLabelStyle: uiText(TypeSize.body, color: c.textSecondary),
      hintStyle: uiText(TypeSize.body, color: c.textTertiary),
      helperStyle: uiText(TypeSize.caption, color: c.textSecondary),
      errorStyle: uiText(TypeSize.caption, color: c.danger),
      prefixIconColor: c.textTertiary,
      suffixIconConstraints: const BoxConstraints(minWidth: 26, minHeight: 18, maxHeight: 26),
      suffixIconColor: c.textSecondary,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.28),
      selectionHandleColor: c.accent,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3.5)),
      side: WidgetStateBorderSide.resolveWith((s) => s.contains(WidgetState.selected)
          ? BorderSide.none
          : BorderSide(color: c.textTertiary.withValues(alpha: 0.6), width: 0.75)),
      fillColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return c.pressed;
        return s.contains(WidgetState.selected) ? c.selectionEmphasized : c.controlBackground;
      }),
      checkColor: WidgetStatePropertyAll(c.onSelectionEmphasized),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      visualDensity: VisualDensity.compact,
      splashRadius: 0,
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.selectionEmphasized : c.pressed),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.selectionEmphasized : c.textTertiary),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      visualDensity: VisualDensity.compact,
      splashRadius: 0,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: c.pressed,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
      labelStyle: t(TypeSize.small, FontWeight.w500),
      padding: const EdgeInsets.symmetric(horizontal: 2),
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
      thickness: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? 11 : 7),
      radius: const Radius.circular(8),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => c.text.withValues(alpha: s.contains(WidgetState.dragged) ? 0.5 : 0.3)),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) ? c.text.withValues(alpha: 0.04) : Colors.transparent),
      trackBorderColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) ? c.separator : Colors.transparent),
      interactive: true,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.raised,
      contentTextStyle: t(TypeSize.body),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sheet),
        side: BorderSide(color: c.separator, width: 0.5),
      ),
      elevation: 8,
      width: 440,
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
      titleTextStyle: t(TypeSize.body),
      subtitleTextStyle: t(TypeSize.caption).copyWith(color: c.textSecondary),
      iconColor: c.textSecondary,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.accent,
      inactiveTrackColor: c.pressed,
      thumbColor: Colors.white,
      overlayShape: SliderComponentShape.noOverlay,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 1.5, pressedElevation: 2),
      trackHeight: 4,
      activeTickMarkColor: Colors.transparent,
      inactiveTickMarkColor: c.textTertiary.withValues(alpha: 0.5),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.pressed,
      linearMinHeight: 4,
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
