import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'buttons.dart';

// ---------------------------------------------------------------------------
// Form groups
// ---------------------------------------------------------------------------

/// Label column width shared by the [FormRow]s of a [FormGroup].
class _FormLabelWidth extends InheritedWidget {
  const _FormLabelWidth({required this.width, required super.child});

  final double width;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FormLabelWidth>()?.width;

  @override
  bool updateShouldNotify(_FormLabelWidth old) => old.width != width;
}

/// Grouped settings box (System Settings form section) on a
/// `windowBackground`: radius 8, `groupBackground` fill, 0.5 hairline, rows
/// split by inset separators. Optional [title] above (13 semibold) and
/// [footer] below (11 secondary).
///
/// The label column fits the widest label (or help) of the [FormRow]s in
/// [children], at most 40% of the group, unless [labelWidth] fixes it.
class FormGroup extends StatelessWidget {
  const FormGroup({super.key, this.title, required this.children, this.footer, this.labelWidth});

  final String? title;
  final List<Widget> children;
  final String? footer;
  final double? labelWidth;

  double _measureLabels(BuildContext context, double max) {
    final scaler = MediaQuery.textScalerOf(context);
    var widest = 0.0;
    void measure(String text, double size) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: uiText(size)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, tp.width);
      tp.dispose();
    }

    for (final row in children.whereType<FormRow>()) {
      measure(row.label, TypeSize.body);
      if (row.help != null) measure(row.help!, TypeSize.caption);
    }
    return math.min(widest.ceilToDouble() + 1, max);
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 6),
              child: Text(title!, style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text)),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              final inner = constraints.maxWidth - Gap.md * 2;
              final width = labelWidth ?? _measureLabels(context, inner * 0.4);
              return _FormLabelWidth(
                width: width,
                child: Container(
                  decoration: BoxDecoration(
                    color: c.groupBackground,
                    borderRadius: BorderRadius.circular(Radii.panel),
                    border: Border.all(color: c.separator, width: 0.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < children.length; i++) ...[
                        if (i > 0) Divider(height: 1, thickness: 0.5, indent: Gap.md, endIndent: Gap.md, color: c.separator),
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 38),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                            child: Align(alignment: AlignmentDirectional.centerStart, child: children[i]),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 6),
              child: Text(footer!, style: uiText(TypeSize.caption, color: c.textSecondary, height: 1.3)),
            ),
        ],
      ),
    );
  }
}

/// Label on the left (13, optional [help] under it in 11 secondary), control
/// aligned to the right, as in System Settings. Text fields still fill the
/// space; wrap the control in an [Align] to place it elsewhere.
///
/// The label width comes from the enclosing [FormGroup] unless [labelWidth]
/// is given.
class FormRow extends StatelessWidget {
  const FormRow({super.key, required this.label, required this.child, this.help, this.labelWidth});

  final String label;
  final Widget child;
  final String? help;
  final double? labelWidth;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Row(
      children: [
        SizedBox(
          width: labelWidth ?? _FormLabelWidth.maybeOf(context) ?? 150,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: uiText(TypeSize.body, color: c.text)),
              if (help != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(help!, style: uiText(TypeSize.caption, color: c.textSecondary, height: 1.3)),
                ),
            ],
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(child: Align(alignment: AlignmentDirectional.centerEnd, child: child)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Code
// ---------------------------------------------------------------------------

/// Height of one line of [TypeSize.mono] code.
double codeLineHeight(BuildContext context) => MediaQuery.textScalerOf(context).scale(TypeSize.mono) * 1.35;

/// Read-only code: SQL to run, a generated command, a connection string, a
/// fenced block in an answer. `codeBackground`, radius 6, 0.5 hairline, mono
/// 12, selectable.
///
/// With a [label] or [actions] it gets a 24pt `chrome` header with the label
/// (the language) on the left and the actions plus Copia on the right.
/// [maxLines] caps the height (the rest scrolls); without [wrap] long lines
/// scroll sideways.
class CodeBox extends StatelessWidget {
  const CodeBox(
    this.code, {
    super.key,
    this.label,
    this.actions = const [],
    this.copy = true,
    this.maxLines,
    this.wrap = false,
    this.color,
  });

  final String code;
  final String? label;

  /// Header buttons before Copia (mini [ToolButton]s).
  final List<Widget> actions;

  /// Shows Copia in the header.
  final bool copy;
  final int? maxLines;
  final bool wrap;

  /// Text color (secondary for quoted input).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final text = code.trimRight();
    final style = TextStyle(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
      fontSize: TypeSize.mono,
      height: 1.35,
      color: color ?? c.text,
      fontFeatures: kTabular,
    );
    const pad = EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm + 2);
    Widget body = SelectableText(text, style: style);
    if (!wrap) body = SingleChildScrollView(scrollDirection: Axis.horizontal, padding: pad, child: body);
    if (wrap) body = Padding(padding: pad, child: body);
    if (maxLines != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxLines! * codeLineHeight(context) + pad.vertical),
        child: SingleChildScrollView(child: body),
      );
    }
    final header = label != null || actions.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: c.codeBackground,
        borderRadius: BorderRadius.circular(Radii.menu),
        border: Border.all(color: c.separator, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header)
            Container(
              height: 24,
              padding: const EdgeInsets.only(left: Gap.md, right: 3),
              decoration: BoxDecoration(
                color: c.chrome,
                border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: uiText(TypeSize.caption, weight: FontWeight.w500, color: c.textSecondary),
                    ),
                  ),
                  ...actions,
                  if (copy)
                    ToolButton(
                      icon: AppIcons.copy,
                      tooltip: 'Copia',
                      extent: 18,
                      onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                    ),
                ],
              ),
            ),
          body,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Diff
// ---------------------------------------------------------------------------

enum DiffLineKind {
  /// Unchanged line.
  context,
  added,
  removed,

  /// `@@ -a,b +c,d @@` hunk header.
  hunk,

  /// File headers (`diff --git`, `index`, `---`, `+++`) and `\ No newline`.
  meta,
}

/// One line of a [DiffView]. [text] has no leading `+`/`-`/space marker.
class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldLine, this.newLine});

  final DiffLineKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

/// Splits a unified diff (`git diff` output) into [DiffLine]s with old and
/// new line numbers.
List<DiffLine> parseUnifiedDiff(String patch) {
  final out = <DiffLine>[];
  int? oldNo;
  int? newNo;
  final lines = patch.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  for (final l in lines) {
    final hunk = _hunkHeader.firstMatch(l);
    if (hunk != null) {
      oldNo = int.parse(hunk.group(1)!);
      newNo = int.parse(hunk.group(2)!);
      out.add(DiffLine(DiffLineKind.hunk, l));
    } else if (oldNo == null || newNo == null || l.startsWith('diff ') || l.startsWith('\\')) {
      // Before the first hunk, or a new file's header.
      if (l.startsWith('diff ')) oldNo = newNo = null;
      out.add(DiffLine(DiffLineKind.meta, l));
    } else if (l.startsWith('+')) {
      out.add(DiffLine(DiffLineKind.added, l.substring(1), newLine: newNo++));
    } else if (l.startsWith('-')) {
      out.add(DiffLine(DiffLineKind.removed, l.substring(1), oldLine: oldNo++));
    } else {
      out.add(DiffLine(DiffLineKind.context, l.isEmpty ? '' : l.substring(1), oldLine: oldNo++, newLine: newNo++));
    }
  }
  return out;
}

/// The one diff renderer (AI fixes, git): `diff*` tokens, a gutter with old
/// and new line numbers and the +/− marker, no wrapping (long lines scroll
/// sideways), selectable text.
///
/// By default it is a lazy list that fills its parent (give it a bounded
/// height). With [shrinkWrap] it sizes to its lines, to sit inside a scroll
/// view.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.lines, this.shrinkWrap = false});

  DiffView.unified(String patch, {Key? key, bool shrinkWrap = false})
    : this(key: key, lines: parseUnifiedDiff(patch), shrinkWrap: shrinkWrap);

  final List<DiffLine> lines;
  final bool shrinkWrap;

  static const _signWidth = 16.0;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final code = TextStyle(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
      fontSize: TypeSize.mono,
      height: 1.35,
      color: c.text,
    );
    final numbers = code.copyWith(fontSize: TypeSize.monoSmall, color: c.textTertiary, fontFeatures: kTabular);
    final rowHeight = codeLineHeight(context);

    var maxNo = 0;
    var maxChars = 0;
    for (final l in lines) {
      maxNo = math.max(maxNo, math.max(l.oldLine ?? 0, l.newLine ?? 0));
      maxChars = math.max(maxChars, l.text.replaceAll('\t', '    ').length);
    }
    double charWidth(TextStyle style) {
      final tp = TextPainter(
        text: TextSpan(text: '0000000000', style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final w = tp.width / 10;
      tp.dispose();
      return w;
    }

    final numWidth = maxNo == 0 ? 0.0 : (charWidth(numbers) * '$maxNo'.length).ceilToDouble() + Gap.sm;
    final gutter = (numWidth == 0 ? 0 : (numWidth + Gap.sm) * 2) + _signWidth + Gap.xs;
    final contentWidth = gutter + maxChars * charWidth(code) + Gap.md * 2 + 8;

    Widget row(DiffLine l) {
      final (Color? bg, Color sign, String mark) = switch (l.kind) {
        DiffLineKind.added => (c.diffAdded.withValues(alpha: Tint.subtle), c.diffAdded, '+'),
        DiffLineKind.removed => (c.diffRemoved.withValues(alpha: Tint.subtle), c.diffRemoved, '−'),
        DiffLineKind.hunk => (c.diffHunk.withValues(alpha: Tint.subtle), c.diffHunk, ''),
        _ => (null, c.textTertiary, ''),
      };
      final textColor = switch (l.kind) {
        DiffLineKind.hunk => c.diffHunk,
        DiffLineKind.meta => c.textSecondary,
        _ => c.text,
      };
      Widget number(int? n) => SizedBox(
        width: numWidth,
        child: Text(n == null ? '' : '$n', textAlign: TextAlign.right, style: numbers),
      );
      return Container(
        height: rowHeight,
        color: bg,
        child: Row(
          children: [
            if (numWidth > 0) ...[
              Padding(padding: const EdgeInsets.only(right: Gap.sm), child: number(l.oldLine)),
              Padding(padding: const EdgeInsets.only(right: Gap.sm), child: number(l.newLine)),
            ],
            SizedBox(
              width: _signWidth,
              child: Text(mark, textAlign: TextAlign.center, style: code.copyWith(color: sign, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: Gap.xs),
            Text(
              l.text.replaceAll('\t', '    '),
              softWrap: false,
              style: code.copyWith(
                color: textColor,
                fontWeight: l.kind == DiffLineKind.meta && l.text.startsWith('diff ') ? FontWeight.w600 : null,
              ),
            ),
          ],
        ),
      );
    }

    final box = BoxDecoration(
      color: c.codeBackground,
      borderRadius: BorderRadius.circular(Radii.menu),
      border: Border.all(color: c.separator, width: 0.5),
    );
    const vpad = EdgeInsets.symmetric(vertical: Gap.xs);

    if (shrinkWrap) {
      return Container(
        decoration: box,
        clipBehavior: Clip.antiAlias,
        child: SelectionArea(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: vpad,
            child: SizedBox(
              width: contentWidth,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final l in lines) row(l)]),
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: box,
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) => SelectionArea(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: math.max(contentWidth, constraints.maxWidth),
              height: constraints.maxHeight,
              child: ListView.builder(
                padding: vpad,
                itemExtent: rowHeight,
                itemCount: lines.length,
                itemBuilder: (_, i) => row(lines[i]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// App mark
// ---------------------------------------------------------------------------

/// The app icon drawn in Flutter (alerts, About, welcome).
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.accent,
        borderRadius: BorderRadius.circular(size * 0.23),
        boxShadow: [BoxShadow(color: const Color(0x29000000), blurRadius: size * 0.08, offset: Offset(0, size * 0.03))],
      ),
      child: Icon(AppIcons.database, color: c.onAccent, size: size * 0.52),
    );
  }
}
