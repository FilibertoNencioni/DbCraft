// Small Markdown renderer for the assistant answers: headings, paragraphs,
// bullet / numbered lists, quotes, rules, pipe tables, inline code, bold,
// italic and fenced code blocks. Tolerant of partial (streaming) input.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/widgets/common.dart';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdListItem {
  const MdListItem(this.text, {this.indent = 0, this.number});
  final String text;
  final int indent;

  /// Null for bullets.
  final String? number;
}

class MdList extends MdBlock {
  const MdList(this.items);
  final List<MdListItem> items;
}

class MdCode extends MdBlock {
  const MdCode(this.language, this.code, {this.closed = true});
  final String language;
  final String code;

  /// False while the block is still streaming.
  final bool closed;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdRule extends MdBlock {
  const MdRule();
}

class MdTable extends MdBlock {
  const MdTable(this.header, this.rows);
  final List<String> header;
  final List<List<String>> rows;
}

final _fenceRe = RegExp(r'^(\s*)(`{3,}|~{3,})\s*([\w+#.-]*)');
final _headingRe = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _bulletRe = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _numberRe = RegExp(r'^(\s*)(\d{1,3})[.)]\s+(.*)$');
final _ruleRe = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
final _tableSepRe = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');

List<String> _cells(String line) {
  var s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|') && !s.endsWith('\\|')) s = s.substring(0, s.length - 1);
  final out = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '\\' && i + 1 < s.length && s[i + 1] == '|') {
      buf.write('|');
      i++;
    } else if (s[i] == '|') {
      out.add(buf.toString().trim());
      buf.clear();
    } else {
      buf.write(s[i]);
    }
  }
  out.add(buf.toString().trim());
  return out;
}

/// Parses [src] into blocks.
List<MdBlock> parseMarkdown(String src) {
  final lines = src.replaceAll('\r\n', '\n').split('\n');
  final out = <MdBlock>[];
  final para = <String>[];
  final items = <MdListItem>[];

  void flushPara() {
    if (para.isNotEmpty) out.add(MdParagraph(para.join(' ').trim()));
    para.clear();
  }

  void flushList() {
    if (items.isNotEmpty) out.add(MdList(List.of(items)));
    items.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final fm = _fenceRe.firstMatch(line);
    if (fm != null) {
      flushPara();
      flushList();
      final fence = fm[2]!;
      final lang = (fm[3] ?? '').toLowerCase();
      final indent = fm[1]!.length;
      final code = <String>[];
      var closed = false;
      i++;
      while (i < lines.length) {
        final t = lines[i].trim();
        if (t.startsWith(fence) && t.replaceAll(fence[0], '').isEmpty) {
          closed = true;
          i++;
          break;
        }
        var l = lines[i];
        // Code blocks nested in list items are indented: remove the indent.
        var k = 0;
        while (k < indent && k < l.length && l[k] == ' ') {
          k++;
        }
        l = l.substring(k);
        code.add(l);
        i++;
      }
      out.add(MdCode(lang, code.join('\n'), closed: closed));
      continue;
    }
    if (line.trim().isEmpty) {
      flushPara();
      // A blank line inside a list does not end it if the list continues.
      if (items.isNotEmpty) {
        var j = i + 1;
        while (j < lines.length && lines[j].trim().isEmpty) {
          j++;
        }
        if (j >= lines.length || !(_bulletRe.hasMatch(lines[j]) || _numberRe.hasMatch(lines[j]))) flushList();
      }
      i++;
      continue;
    }
    final hm = _headingRe.firstMatch(line);
    if (hm != null) {
      flushPara();
      flushList();
      out.add(MdHeading(hm[1]!.length, hm[2]!));
      i++;
      continue;
    }
    if (_ruleRe.hasMatch(line) && para.isEmpty) {
      flushList();
      out.add(const MdRule());
      i++;
      continue;
    }
    if (line.contains('|') && i + 1 < lines.length && _tableSepRe.hasMatch(lines[i + 1])) {
      flushPara();
      flushList();
      final header = _cells(line);
      final rows = <List<String>>[];
      i += 2;
      while (i < lines.length && lines[i].contains('|') && lines[i].trim().isNotEmpty) {
        rows.add(_cells(lines[i]));
        i++;
      }
      out.add(MdTable(header, rows));
      continue;
    }
    final bm = _bulletRe.firstMatch(line);
    final nm = bm == null ? _numberRe.firstMatch(line) : null;
    if (bm != null || nm != null) {
      flushPara();
      final indent = ((bm?[1] ?? nm![1])!.length / 2).floor();
      items.add(MdListItem(bm != null ? bm[2]! : nm![3]!, indent: indent, number: nm?[2]));
      i++;
      continue;
    }
    if (line.trimLeft().startsWith('>')) {
      flushPara();
      flushList();
      final q = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
        q.add(lines[i].trimLeft().substring(1).trim());
        i++;
      }
      out.add(MdQuote(q.join(' ')));
      continue;
    }
    // Lazy continuation of a list item.
    if (items.isNotEmpty && para.isEmpty && line.startsWith('  ')) {
      final last = items.removeLast();
      items.add(MdListItem('${last.text} ${line.trim()}', indent: last.indent, number: last.number));
      i++;
      continue;
    }
    flushList();
    para.add(line.trim());
    i++;
  }
  flushPara();
  flushList();
  return out;
}

/// Inline span: plain, bold, italic or code.
class MdInline {
  const MdInline(this.text, {this.bold = false, this.italic = false, this.code = false});
  final String text;
  final bool bold;
  final bool italic;
  final bool code;
}

final _inlineRe = RegExp(
  r'(`+)(.+?)\1' // code
  r'|\*\*(.+?)\*\*' // bold
  r'|__(.+?)__' // bold
  r'|(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])' // italic
  r'|(?<![\w])_(?![\s_])(.+?)(?<![\s_])_(?![\w])' // italic (not snake_case)
  r'|\[([^\]]+)\]\(([^)\s]+)\)', // link: text only
);

List<MdInline> parseInline(String text, {bool bold = false, bool italic = false}) {
  final out = <MdInline>[];
  var pos = 0;
  for (final m in _inlineRe.allMatches(text)) {
    if (m.start > pos) out.add(MdInline(text.substring(pos, m.start), bold: bold, italic: italic));
    if (m[2] != null) {
      out.add(MdInline(m[2]!.trim(), code: true, bold: bold, italic: italic));
    } else if (m[3] != null || m[4] != null) {
      out.addAll(parseInline(m[3] ?? m[4]!, bold: true, italic: italic));
    } else if (m[5] != null || m[6] != null) {
      out.addAll(parseInline(m[5] ?? m[6]!, bold: bold, italic: true));
    } else if (m[7] != null) {
      out.add(MdInline(m[7]!, bold: bold, italic: italic));
    }
    pos = m.end;
  }
  if (pos < text.length) out.add(MdInline(text.substring(pos), bold: bold, italic: italic));
  return out;
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/// Builds extra buttons shown in the header of a code block.
typedef CodeActionsBuilder = List<Widget> Function(BuildContext context, MdCode block);

class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.data, this.codeActions, this.fontSize = TypeSize.body});

  final String data;
  final CodeActionsBuilder? codeActions;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final blocks = parseMarkdown(data);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, b) in blocks.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : (b is MdHeading ? Gap.md : Gap.sm)),
              child: _block(context, b),
            ),
        ],
      ),
    );
  }

  TextSpan _spans(BuildContext context, String text, TextStyle base) {
    final c = DbColors.of(context);
    return TextSpan(
      style: base,
      children: [
        for (final s in parseInline(text))
          if (s.code)
            TextSpan(
              text: s.text,
              style: monoStyle(
                context,
                size: base.fontSize! - 1,
                color: c.text,
              ).copyWith(backgroundColor: c.hover, fontWeight: s.bold ? FontWeight.w600 : null),
            )
          else
            TextSpan(
              text: s.text,
              style: TextStyle(
                fontWeight: s.bold ? FontWeight.w600 : null,
                fontStyle: s.italic ? FontStyle.italic : null,
              ),
            ),
      ],
    );
  }

  Widget _block(BuildContext context, MdBlock b) {
    final c = DbColors.of(context);
    final body = TextStyle(fontSize: fontSize, color: c.text, height: 1.45);
    switch (b) {
      case MdHeading(:final level, :final text):
        final size = switch (level) {
          1 => TypeSize.title + 1,
          2 => TypeSize.title,
          _ => fontSize,
        };
        return Text.rich(_spans(context, text, body.copyWith(fontSize: size, fontWeight: FontWeight.w600)));
      case MdParagraph(:final text):
        return Text.rich(_spans(context, text, body));
      case MdQuote(:final text):
        return Container(
          padding: const EdgeInsets.only(left: Gap.md),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: c.separator, width: 3)),
          ),
          child: Text.rich(_spans(context, text, body.copyWith(color: c.textSecondary))),
        );
      case MdRule():
        return Divider(height: Gap.md, color: c.separator);
      case MdList(:final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final it in items)
              Padding(
                padding: EdgeInsets.only(left: Gap.xs + it.indent * Gap.lg, bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: it.number == null ? 14 : 22,
                      child: Text(
                        it.number == null ? '•' : '${it.number}.',
                        style: body.copyWith(color: c.textSecondary, fontFeatures: kTabular),
                      ),
                    ),
                    Expanded(child: Text.rich(_spans(context, it.text, body))),
                  ],
                ),
              ),
          ],
        );
      case MdTable(:final header, :final rows):
        final cols = [header.length, for (final r in rows) r.length].reduce((a, b) => a > b ? a : b);
        List<String> pad(List<String> r) => [...r, for (var k = r.length; k < cols; k++) ''];
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: c.separator),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            clipBehavior: Clip.antiAlias,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder(horizontalInside: BorderSide(color: c.separator)),
              children: [
                TableRow(
                  decoration: BoxDecoration(color: c.chrome),
                  children: [
                    for (final h in pad(header))
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 5),
                        child: Text.rich(_spans(context, h, body.copyWith(fontWeight: FontWeight.w600))),
                      ),
                  ],
                ),
                for (final (i, r) in rows.indexed)
                  TableRow(
                    decoration: BoxDecoration(color: i.isOdd ? c.zebra : c.content),
                    children: [
                      for (final v in pad(r))
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
                          child: Text.rich(_spans(context, v, body)),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      case MdCode():
        return CodeBlockView(block: b, actions: codeActions?.call(context, b) ?? const []);
    }
  }
}

/// Fenced code block with a language label, copy button and extra actions.
class CodeBlockView extends StatelessWidget {
  const CodeBlockView({super.key, required this.block, this.actions = const []});
  final MdCode block;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.codeBackground,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: c.separator),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 30,
            color: c.chrome,
            padding: const EdgeInsets.only(left: Gap.md, right: Gap.xs),
            child: Row(
              children: [
                Text(
                  block.language.isEmpty ? 'codice' : block.language,
                  style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary, fontWeight: FontWeight.w500),
                ),
                const Spacer(),
                if (block.closed) ...actions,
                ToolButton(
                  icon: Icons.content_copy_rounded,
                  size: 14,
                  tooltip: 'Copia',
                  onPressed: () => Clipboard.setData(ClipboardData(text: block.code)),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(Gap.md),
            child: Text(block.code, style: monoStyle(context, size: 12.5)),
          ),
        ],
      ),
    );
  }
}
