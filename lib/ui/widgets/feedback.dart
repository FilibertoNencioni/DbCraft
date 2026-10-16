import 'dart:async';

import 'package:flutter/material.dart';

import '../../odbc/odbc_types.dart';
import '../theme/app_theme.dart';
import 'buttons.dart';
import 'surfaces.dart';

/// The text to show for an error: the driver message for ODBC errors,
/// without Dart's "Exception: " prefix otherwise.
String describeError(Object error) {
  if (error is OdbcException) return error.message;
  final s = error.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

// ---------------------------------------------------------------------------
// Notice
// ---------------------------------------------------------------------------

enum NoticeKind { info, success, warning, danger }

enum NoticeStyle {
  /// Box in the content flow: one action next to the title.
  inline,

  /// Full-width 28pt bar under a toolbar, one line.
  strip,

  /// Box with several actions under the text (suggestions).
  card,
}

/// A problem or a hint the user can act on without leaving the page: a
/// missing driver, a git conflict, an SQL error, a plan warning.
///
/// [NoticeStyle.inline] and [NoticeStyle.card]: radius 8, kind color at
/// [Tint.subtle] with a [Tint.border] hairline, icon 16, title 13 semibold,
/// message 12 (13 when there is no title), optional [child] (a [CodeBox]).
/// [NoticeStyle.strip]: a bar with a bottom hairline, icon 14, text 12.
class Notice extends StatelessWidget {
  const Notice({
    super.key,
    this.kind = NoticeKind.warning,
    this.title,
    this.message,
    this.child,
    this.actions = const [],
    this.icon,
    this.color,
  }) : style = NoticeStyle.inline,
       assert(title != null || message != null);

  const Notice.strip({
    super.key,
    this.kind = NoticeKind.warning,
    this.title,
    this.message,
    this.actions = const [],
    this.icon,
    this.color,
  }) : style = NoticeStyle.strip,
       child = null,
       assert(title != null || message != null);

  const Notice.card({
    super.key,
    this.kind = NoticeKind.info,
    this.title,
    this.message,
    this.child,
    this.actions = const [],
    this.icon,
    this.color,
  }) : style = NoticeStyle.card,
       assert(title != null || message != null);

  final NoticeKind kind;
  final NoticeStyle style;
  final String? title;
  final String? message;

  /// Extra content under the message (a command to copy, a code box).
  final Widget? child;

  /// Inline and strip show these after the text (one, ideally); the card
  /// lays them out under it.
  final List<Widget> actions;

  /// Overrides the kind's glyph.
  final IconData? icon;

  /// Overrides the kind's color.
  final Color? color;

  Color _color(DbColors c) =>
      color ??
      switch (kind) {
        NoticeKind.info => c.accent,
        NoticeKind.success => c.success,
        NoticeKind.warning => c.warning,
        NoticeKind.danger => c.danger,
      };

  IconData get _icon =>
      icon ??
      switch (kind) {
        NoticeKind.info => AppIcons.info,
        NoticeKind.success => AppIcons.checkCircle,
        NoticeKind.warning => AppIcons.warning,
        NoticeKind.danger => AppIcons.error,
      };

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final col = _color(c);
    if (style == NoticeStyle.strip) return _strip(c, col);

    final hasTitle = title != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm + 2, Gap.sm + 2, Gap.sm + 2),
      decoration: BoxDecoration(
        color: col.withValues(alpha: Tint.subtle),
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: col.withValues(alpha: Tint.border), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_icon, size: 16, color: col),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasTitle) Text(title!, style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text)),
                if (message != null) ...[
                  if (hasTitle) const SizedBox(height: 2),
                  SelectableText(
                    message!,
                    style: hasTitle
                        ? uiText(TypeSize.small, color: c.textSecondary, height: 1.35)
                        : uiText(TypeSize.body, color: c.text, height: 1.35),
                  ),
                ],
                if (child != null) ...[const SizedBox(height: Gap.sm), child!],
                if (style == NoticeStyle.card && actions.isNotEmpty) ...[
                  const SizedBox(height: Gap.sm),
                  Wrap(
                    spacing: Gap.sm,
                    runSpacing: Gap.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
          if (style == NoticeStyle.inline && actions.isNotEmpty) ...[
            const SizedBox(width: Gap.sm),
            for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: Gap.xs), a],
          ],
        ],
      ),
    );
  }

  Widget _strip(DbColors c, Color col) => Container(
    constraints: const BoxConstraints(minHeight: BarHeight.subbar),
    padding: const EdgeInsets.symmetric(horizontal: Gap.md),
    decoration: BoxDecoration(
      color: col.withValues(alpha: Tint.subtle),
      border: Border(bottom: BorderSide(color: col.withValues(alpha: Tint.border), width: 0.5)),
    ),
    child: Row(
      children: [
        Icon(_icon, size: 14, color: col),
        const SizedBox(width: 6),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                if (title != null)
                  TextSpan(text: title, style: uiText(TypeSize.small, weight: FontWeight.w600, color: c.text)),
                if (title != null && message != null) const TextSpan(text: '  '),
                if (message != null) TextSpan(text: message, style: uiText(TypeSize.small, color: c.textSecondary)),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final a in actions) ...[const SizedBox(width: Gap.sm), a],
      ],
    ),
  );
}

/// Former name of the inline [Notice], tinted with an explicit [color], with
/// the bottom margin form sheets expect.
class InlineNotice extends StatelessWidget {
  const InlineNotice({
    super.key,
    required this.color,
    required this.title,
    this.icon = AppIcons.warning,
    this.message,
    this.child,
    this.action,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String? message;
  final Widget? child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.lg),
    child: Notice(
      color: color,
      icon: icon,
      title: title,
      message: message,
      actions: [?action],
      child: child,
    ),
  );
}

// ---------------------------------------------------------------------------
// HUD
// ---------------------------------------------------------------------------

OverlayEntry? _hudEntry;

/// Shows a short confirmation in a capsule centered above the status bar
/// ("Copiato", "Salvato"). It fades in and out over 150ms and stays for
/// [duration]; a click dismisses it. A new HUD replaces the current one.
void showHud(
  BuildContext context,
  String message, {
  IconData? icon,
  Color? iconColor,
  Duration duration = const Duration(seconds: 3),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final themes = InheritedTheme.capture(from: context, to: overlay.context);
  if (_hudEntry?.mounted ?? false) _hudEntry!.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => themes.wrap(
      _HudHost(
        duration: duration,
        onDone: () {
          if (_hudEntry == entry) _hudEntry = null;
          if (entry.mounted) entry.remove();
        },
        child: HudCapsule(message: message, icon: icon, iconColor: iconColor),
      ),
    ),
  );
  _hudEntry = entry;
  overlay.insert(entry);
}

/// [showHud] with a check (or an error glyph and 6 seconds for [error]).
void showToast(BuildContext context, String message, {bool error = false}) {
  final c = DbColors.of(context);
  showHud(
    context,
    message,
    icon: error ? AppIcons.error : AppIcons.checkCircle,
    iconColor: error ? c.danger : c.success,
    duration: Duration(seconds: error ? 6 : 3),
  );
}

/// The HUD capsule: `raised`, popover shadow and hairline, icon plus 13pt
/// text, at most three lines.
class HudCapsule extends StatelessWidget {
  const HudCapsule({super.key, required this.message, this.icon, this.iconColor});

  final String message;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 32, maxWidth: 520),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: 7),
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.separator, width: 0.5),
        boxShadow: Elevation.popover(Theme.of(context).brightness),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: iconColor ?? c.textSecondary),
            const SizedBox(width: Gap.sm),
          ],
          Flexible(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: uiText(TypeSize.body, color: c.text, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _HudHost extends StatefulWidget {
  const _HudHost({required this.duration, required this.onDone, required this.child});

  final Duration duration;
  final VoidCallback onDone;
  final Widget child;

  @override
  State<_HudHost> createState() => _HudHostState();
}

class _HudHostState extends State<_HudHost> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _fade.forward();
    _timer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    _timer?.cancel();
    if (!mounted) return;
    await _fade.reverse();
    if (mounted) widget.onDone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) _fade.duration = Duration.zero;
    return Positioned(
      left: Gap.lg,
      right: Gap.lg,
      bottom: BarHeight.status + Gap.md,
      child: Center(
        child: FadeTransition(
          opacity: _fade,
          child: Semantics(
            liveRegion: true,
            container: true,
            child: GestureDetector(onTap: _dismiss, child: Material(type: MaterialType.transparency, child: widget.child)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

/// Teaching empty state centered in a pane: icon 32 tertiary, title 13
/// semibold, text 12 secondary, optional action ([PushButton]).
///
/// [EmptyState.error] replaces the bare `Text(error)` of failed loads: the
/// first line of the error as message and the full text under "Mostra
/// dettagli", copyable.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action}) : error = null;

  const EmptyState.error(Object this.error, {super.key, this.title = 'Impossibile caricare i dati', this.action})
    : icon = AppIcons.warning,
      message = null;

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    var msg = message;
    String? details;
    if (error != null) {
      final full = describeError(error!).trim();
      final first = full.split('\n').first;
      msg = first.length > 160 ? '${first.substring(0, 157)}…' : first;
      if (msg != full) details = full;
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: details == null ? 320 : 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: c.textTertiary),
              const SizedBox(height: Gap.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text),
              ),
              if (msg != null && msg.isNotEmpty) ...[
                const SizedBox(height: Gap.xs),
                SelectableText(
                  msg,
                  textAlign: TextAlign.center,
                  style: uiText(TypeSize.small, color: c.textSecondary, height: 1.4),
                ),
              ],
              if (details != null) ...[const SizedBox(height: Gap.sm), ErrorDetails(details)],
              if (action != null) ...[const SizedBox(height: Gap.lg), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// "Mostra dettagli" disclosure over the full error text in a copyable
/// [CodeBox] (empty states, alerts).
class ErrorDetails extends StatefulWidget {
  const ErrorDetails(this.text, {super.key});

  final String text;

  @override
  State<ErrorDetails> createState() => _ErrorDetailsState();
}

class _ErrorDetailsState extends State<ErrorDetails> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      DisclosureButton(
        label: _open ? 'Nascondi dettagli' : 'Mostra dettagli',
        expanded: _open,
        onChanged: (v) => setState(() => _open = v),
      ),
      if (_open) ...[
        const SizedBox(height: Gap.xs),
        CodeBox(widget.text, label: 'Dettagli', maxLines: 10, wrap: true),
      ],
    ],
  );
}
