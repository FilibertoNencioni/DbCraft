import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

export '../theme/app_theme.dart';
export 'badges.dart';
export 'bars.dart';
export 'buttons.dart';
export 'control_base.dart';
export 'editable_grid.dart';
export 'feedback.dart';
export 'fields.dart';
export 'lists.dart';
export 'menus.dart';
export 'navigation.dart';
export 'panels.dart';
export 'progress.dart';
export 'selection.dart';
export 'sheets.dart';
export 'surfaces.dart';
export 'tables.dart';

const kMono = kMonoFamily;

TextStyle monoStyle(BuildContext context, {double size = 13, Color? color}) => TextStyle(
  fontFamily: kMonoFamily,
  fontFamilyFallback: kMonoFallback,
  fontSize: size,
  color: color ?? DbColors.of(context).text,
  height: 1.35,
  fontFeatures: kTabular,
);
