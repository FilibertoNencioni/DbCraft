import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'progress.dart';

// ---------------------------------------------------------------------------
// Pane bars
// ---------------------------------------------------------------------------

/// Toolbar of a pane (`bar` 36): SQL editor, results, ER diagram, feature
/// tabs. `chrome` with a hairline below; holds inline [ToolButton]s, small
/// [PushButton]s and pop-ups, [SearchField]s.
///
/// While [loading] the 2pt [LoadingLine] runs over the hairline, so the
/// layout does not move when it starts or stops.
class PaneBar extends StatelessWidget {
  const PaneBar({super.key, required this.children, this.loading = false, this.padding});

  final List<Widget> children;
  final bool loading;

  /// Horizontal padding, [Gap.sm] by default.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      height: BarHeight.bar,
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: padding ?? const EdgeInsets.symmetric(horizontal: Gap.sm),
            child: Row(children: children),
          ),
          if (loading) const Positioned(left: 0, right: 0, bottom: 0, child: LoadingLine()),
        ],
      ),
    );
  }
}

/// Header of a pane (`subbar` 28): an 11 semibold secondary [title], then
/// [actions] (mini [ToolButton]s) on the right.
class PaneHeader extends StatelessWidget {
  const PaneHeader({super.key, required this.title, this.leading, this.actions = const []});

  final String title;

  /// Before the title (a disclosure chevron, a status icon).
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      height: BarHeight.subbar,
      padding: const EdgeInsets.only(left: Gap.md, right: Gap.xs),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: uiText(TypeSize.caption, weight: FontWeight.w600, color: c.textSecondary),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Status bar (`status` 22) at the bottom of the content: `chrome` with a
/// hairline above, 11pt secondary text.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      height: BarHeight.status,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: DefaultTextStyle(
        style: uiText(TypeSize.caption, color: c.textSecondary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: Row(children: children),
      ),
    );
  }
}
