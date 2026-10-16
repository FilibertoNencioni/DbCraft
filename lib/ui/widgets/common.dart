import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'lists.dart';

export '../theme/app_theme.dart';
export 'badges.dart';
export 'buttons.dart';
export 'control_base.dart';
export 'feedback.dart';
export 'fields.dart';
export 'lists.dart';
export 'menus.dart';
export 'navigation.dart';
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

/// Kept for compatibility: a light header row with optional actions.
class PanelHeader extends StatelessWidget {
  const PanelHeader({super.key, required this.title, this.icon, this.actions = const []});
  final String title;
  final IconData? icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => SectionLabel(
    title,
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 2),
    trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
  );
}

/// Small rounded count / tag badge. Being split into [CountBadge] (counts)
/// and [Tag] (labels); new code uses those.
class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.color, this.filled = false});
  final String text;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final col = color ?? c.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: filled ? col : col.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: TypeSize.caption,
          fontWeight: FontWeight.w600,
          color: filled ? Colors.white : col,
          fontFeatures: kTabular,
        ),
      ),
    );
  }
}
