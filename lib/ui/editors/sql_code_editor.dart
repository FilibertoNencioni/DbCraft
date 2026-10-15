import 'dart:math';

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/styles/github-dark-dimmed.dart';
import 'package:re_highlight/styles/xcode.dart';

import '../../model/db_objects.dart';
import '../../services/sql_keywords.dart';
import '../../state/db_connection.dart';
import '../widgets/common.dart';

/// Removes Ctrl/Cmd+Enter from "new line" so it can run the statement.
class SqlShortcutsActivatorsBuilder extends CodeShortcutsActivatorsBuilder {
  const SqlShortcutsActivatorsBuilder();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    final def = const DefaultCodeShortcutsActivatorsBuilder().build(type);
    if (type == CodeShortcutType.newLine && def != null) {
      return def.whereType<SingleActivator>().where((a) => !a.control && !a.meta).toList();
    }
    return def;
  }
}

enum PromptKind { keyword, function, table, view, column, type }

class SqlPrompt extends CodePrompt {
  const SqlPrompt({required super.word, required this.kind, this.detail});
  final PromptKind kind;
  final String? detail;

  @override
  CodeAutocompleteResult get autocomplete => CodeAutocompleteResult.fromWord(word);

  @override
  bool match(String input) {
    final w = word.toLowerCase(), i = input.toLowerCase();
    return w != i && w.startsWith(i);
  }
}

/// Autocompletion: keywords, functions, tables of the connection and
/// columns of the tables referenced in the script (also via aliases).
class SqlPromptsBuilder implements CodeAutocompletePromptsBuilder {
  SqlPromptsBuilder(this.connection, this.textProvider, {required this.enabled});

  final DbConnection? Function() connection;
  final String Function() textProvider;
  final bool Function() enabled;

  static final _wordBefore = RegExp(r'[A-Za-z0-9_$#@."\[\]]*$');
  final Set<String> _loading = {};

  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) {
    if (!enabled()) return null;
    final offset = min(selection.extentOffset, codeLine.text.length);
    final before = codeLine.text.substring(0, offset);
    final m = _wordBefore.firstMatch(before);
    final token = m?[0] ?? '';
    if (token.isEmpty) return null;
    final dc = connection();

    final dot = token.lastIndexOf('.');
    if (dot >= 0) {
      final owner = _unquote(token.substring(0, dot).split('.').last);
      final input = token.substring(dot + 1);
      final prompts = _columnsFor(dc, owner).where((p) => input.isEmpty || p.match(input)).toList();
      if (prompts.isEmpty) return null;
      return CodeAutocompleteEditingValue(input: input, prompts: prompts, index: 0);
    }
    if (token.length < 2 && !RegExp(r'^[A-Za-z]$').hasMatch(token)) return null;

    final prompts = <CodePrompt>[];
    final lower = token.toLowerCase();
    final seen = <String>{};
    void add(SqlPrompt p) {
      if (seen.add('${p.kind.name}:${p.word.toLowerCase()}') && p.match(token)) prompts.add(p);
    }

    // Columns of the tables used in the statement come first.
    for (final t in _referencedTables(dc)) {
      for (final p in _columnsFor(dc, t)) {
        add(p);
      }
    }
    if (dc?.metadata != null) {
      final md = dc!.metadata!;
      final tables = md.cachedTables;
      if (tables.isEmpty) _preloadTables(dc);
      for (final t in tables) {
        add(
          SqlPrompt(
            word: dc.dialect.quoteIdent(t.name),
            kind: t.isView ? PromptKind.view : PromptKind.table,
            detail: t.schema ?? t.catalog,
          ),
        );
      }
    }
    for (final k in kSqlKeywords) {
      add(SqlPrompt(word: k, kind: PromptKind.keyword));
    }
    for (final f in kSqlFunctions) {
      add(SqlPrompt(word: f, kind: PromptKind.function));
    }
    for (final t in kSqlTypes) {
      add(SqlPrompt(word: t, kind: PromptKind.type));
    }
    if (prompts.isEmpty) return null;
    // Exact-prefix (case sensitive) matches first.
    prompts.sort((a, b) {
      final ka = (a as SqlPrompt).kind.index, kb = (b as SqlPrompt).kind.index;
      final pa = a.word.toLowerCase().startsWith(lower) ? 0 : 1;
      final pb = b.word.toLowerCase().startsWith(lower) ? 0 : 1;
      if (pa != pb) return pa - pb;
      final order = [
        PromptKind.column,
        PromptKind.table,
        PromptKind.view,
        PromptKind.keyword,
        PromptKind.function,
        PromptKind.type,
      ];
      return order.indexOf(PromptKind.values[ka]).compareTo(order.indexOf(PromptKind.values[kb]));
    });
    return CodeAutocompleteEditingValue(input: token, prompts: prompts.take(60).toList(), index: 0);
  }

  static String _unquote(String s) => s.replaceAll(RegExp(r'^["\[`]|["\]`]$'), '');

  void _preloadTables(DbConnection dc) {
    final key = 'tables:${dc.config.id}';
    if (_loading.contains(key)) return;
    _loading.add(key);
    final md = dc.metadata!;
    () async {
      try {
        final cat = md.currentCatalog;
        if (md.supportsSchemas) {
          final schemas = await md.schemas(md.supportsCatalogs ? cat : null);
          for (final s in schemas.take(20)) {
            await md.tables(md.supportsCatalogs ? cat : null, s);
          }
        } else {
          await md.tables(md.supportsCatalogs ? cat : null, null);
        }
      } catch (_) {}
    }();
  }

  /// Table names referenced in FROM / JOIN / UPDATE / INTO, plus alias map.
  Map<String, String> _aliases(String text) {
    final map = <String, String>{};
    final re = RegExp(
      r'\b(?:from|join|update|into)\s+((?:[\w$#@"\[\]`]+\.)*[\w$#@"\[\]`]+)(?:\s+(?:as\s+)?([A-Za-z_][\w$]*))?',
      caseSensitive: false,
    );
    const notAlias = {
      'where',
      'on',
      'join',
      'left',
      'right',
      'inner',
      'outer',
      'full',
      'cross',
      'group',
      'order',
      'set',
      'values',
      'limit',
      'union',
      'having',
      'using',
      'natural',
      'select',
      'as',
    };
    for (final m in re.allMatches(text)) {
      final table = _unquote(m[1]!.split('.').last);
      map[table.toLowerCase()] = table;
      final alias = m[2];
      if (alias != null && !notAlias.contains(alias.toLowerCase())) {
        map[alias.toLowerCase()] = table;
      }
    }
    return map;
  }

  Iterable<String> _referencedTables(DbConnection? dc) =>
      dc == null ? const [] : _aliases(textProvider()).values.toSet();

  List<SqlPrompt> _columnsFor(DbConnection? dc, String ownerOrAlias) {
    if (dc?.metadata == null) return const [];
    final md = dc!.metadata!;
    final table = _aliases(textProvider())[ownerOrAlias.toLowerCase()] ?? ownerOrAlias;
    DbTable? t;
    for (final x in md.cachedTables) {
      if (x.name.toLowerCase() == table.toLowerCase()) {
        t = x;
        break;
      }
    }
    if (t == null) {
      final key = 'find:${dc.config.id}:$table';
      if (!_loading.contains(key)) {
        _loading.add(key);
        md.findTable(null, null, table).then((found) {
          if (found != null) md.columns(found);
        });
      }
      return const [];
    }
    final cols = md.cachedColumns(t);
    if (cols == null) {
      final key = 'cols:${t.key}';
      if (!_loading.contains(key)) {
        _loading.add(key);
        md.columns(t).whenComplete(() => _loading.remove(key));
      }
      return const [];
    }
    return [
      for (final c in cols)
        SqlPrompt(
          word: dc.dialect.quoteIdent(c.name),
          kind: PromptKind.column,
          detail: '${t.name} · ${c.fullType}',
        ),
    ];
  }
}

/// Popup list shown by the autocompletion.
class SqlAutocompleteView extends StatefulWidget implements PreferredSizeWidget {
  const SqlAutocompleteView({super.key, required this.notifier, required this.onSelected});

  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;

  static const double itemHeight = 24;

  @override
  Size get preferredSize => Size(380, min(itemHeight * notifier.value.prompts.length, 240) + 2);

  @override
  State<SqlAutocompleteView> createState() => _SqlAutocompleteViewState();
}

class _SqlAutocompleteViewState extends State<SqlAutocompleteView> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_changed);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final i = widget.notifier.value.index;
    if (_scroll.hasClients) {
      final top = i * SqlAutocompleteView.itemHeight;
      final vh = _scroll.position.viewportDimension;
      if (top < _scroll.offset) {
        _scroll.jumpTo(top);
      } else if (top + SqlAutocompleteView.itemHeight > _scroll.offset + vh) {
        _scroll.jumpTo(top + SqlAutocompleteView.itemHeight - vh);
      }
    }
  }

  static (IconData, Color) _icon(PromptKind k) => switch (k) {
    PromptKind.keyword => (Icons.code_rounded, const Color(0xFFAF52DE)),
    PromptKind.function => (Icons.functions_rounded, const Color(0xFF30B0C7)),
    PromptKind.table => (Icons.table_chart_outlined, const Color(0xFF007AFF)),
    PromptKind.view => (Icons.view_quilt_outlined, const Color(0xFF007AFF)),
    PromptKind.column => (Icons.view_column_outlined, const Color(0xFFFF9500)),
    PromptKind.type => (Icons.category_outlined, const Color(0xFF8E8E93)),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.notifier.value;
    return Material(
      elevation: 8,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(4),
      color: DbColors.of(context).raised,
      child: Container(
        constraints: BoxConstraints.loose(widget.preferredSize),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: ListView.builder(
          controller: _scroll,
          itemExtent: SqlAutocompleteView.itemHeight,
          itemCount: v.prompts.length,
          itemBuilder: (context, i) {
            final p = v.prompts[i] as SqlPrompt;
            final (icon, color) = _icon(p.kind);
            return InkWell(
              onTap: () => widget.onSelected(v.copyWith(index: i).autocomplete),
              child: Container(
                color: i == v.index ? theme.colorScheme.primary.withValues(alpha: 0.25) : null,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p.word,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(context, size: 12.5),
                      ),
                    ),
                    if (p.detail != null)
                      Flexible(
                        child: Text(
                          p.detail!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: DbColors.of(context).textTertiary),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Compact find / replace bar for the editor (Ctrl+F / Ctrl+H).
class SqlFindBar extends StatelessWidget implements PreferredSizeWidget {
  const SqlFindBar({super.key, required this.controller, required this.readOnly});
  final CodeFindController controller;
  final bool readOnly;

  @override
  Size get preferredSize =>
      Size.fromHeight(controller.value == null ? 0 : (controller.value!.replaceMode ? 72 : 38));

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    if (v == null) return const SizedBox.shrink();
    final result = v.result;
    final count = result == null
        ? ''
        : result.matches.isEmpty
        ? 'Nessun risultato'
        : '${result.index + 1} di ${result.matches.length}';
    Widget input(TextEditingController c, FocusNode f, String hint) => SizedBox(
      width: 240,
      height: 28,
      child: TextField(
        controller: c,
        focusNode: f,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => controller.nextMatch(),
      ),
    );
    return Container(
      color: DbColors.of(context).chrome,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ToolButton(
                icon: v.replaceMode ? Icons.expand_less : Icons.expand_more,
                tooltip: 'Sostituisci',
                onPressed: readOnly ? null : controller.toggleMode,
              ),
              input(controller.findInputController, controller.findInputFocusNode, 'Trova'),
              const SizedBox(width: 4),
              ToolButton(
                icon: Icons.text_fields,
                tooltip: 'Maiuscole/minuscole',
                active: v.option.caseSensitive,
                onPressed: controller.toggleCaseSensitive,
              ),
              ToolButton(
                icon: Icons.code,
                tooltip: 'Espressione regolare',
                active: v.option.regex,
                onPressed: controller.toggleRegex,
              ),
              const SizedBox(width: 8),
              Text(count, style: const TextStyle(fontSize: 12)),
              const Spacer(),
              ToolButton(
                icon: Icons.arrow_upward,
                tooltip: 'Precedente',
                onPressed: controller.previousMatch,
              ),
              ToolButton(icon: Icons.arrow_downward, tooltip: 'Successivo', onPressed: controller.nextMatch),
              ToolButton(icon: Icons.close, tooltip: 'Chiudi (Esc)', onPressed: controller.close),
            ],
          ),
          if (v.replaceMode)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const SizedBox(width: 28),
                  input(
                    controller.replaceInputController,
                    controller.replaceInputFocusNode,
                    'Sostituisci con',
                  ),
                  const SizedBox(width: 8),
                  TextButton(onPressed: controller.replaceMatch, child: const Text('Sostituisci')),
                  TextButton(onPressed: controller.replaceAllMatches, child: const Text('Tutti')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The SQL source editor (highlighting, line numbers, autocompletion).
class SqlCodeEditor extends StatelessWidget {
  const SqlCodeEditor({
    super.key,
    required this.controller,
    required this.findController,
    required this.promptsBuilder,
    required this.fontSize,
    this.focusNode,
  });

  final CodeLineEditingController controller;
  final CodeFindController findController;
  final CodePromptsBuilderHolder promptsBuilder;
  final double fontSize;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final theme = Theme.of(context);
    return CodeAutocomplete(
      viewBuilder: (context, notifier, onSelected) =>
          SqlAutocompleteView(notifier: notifier, onSelected: onSelected),
      promptsBuilder: promptsBuilder.builder,
      child: CodeEditor(
        controller: controller,
        findController: findController,
        focusNode: focusNode,
        wordWrap: false,
        autofocus: true,
        shortcutsActivatorsBuilder: const SqlShortcutsActivatorsBuilder(),
        commentFormatter: DefaultCodeCommentFormatter(
          singleLinePrefix: '--',
          multiLinePrefix: '/*',
          multiLineSuffix: '*/',
        ),
        findBuilder: (context, c, readOnly) => SqlFindBar(controller: c, readOnly: readOnly),
        style: CodeEditorStyle(
          fontSize: fontSize,
          fontFamily: kMono,
          fontFamilyFallback: kMonoFallback,
          backgroundColor: DbColors.of(context).codeBackground,
          cursorLineColor: dark ? const Color(0xFF26262A) : const Color(0xFFF5F8FF),
          selectionColor: DbColors.of(context).accent.withValues(alpha: 0.25),
          codeTheme: CodeHighlightTheme(
            languages: {'sql': CodeHighlightThemeMode(mode: langSql)},
            theme: dark ? githubDarkDimmedTheme : xcodeTheme,
          ),
        ),
        indicatorBuilder: (context, editingController, chunkController, notifier) => Row(
          children: [
            DefaultCodeLineNumber(
              controller: editingController,
              notifier: notifier,
              textStyle: TextStyle(
                fontSize: fontSize - 1,
                color: DbColors.of(context).textTertiary,
                fontFamily: kMono,
                fontFamilyFallback: kMonoFallback,
              ),
              focusedTextStyle: TextStyle(
                fontSize: fontSize - 1,
                color: theme.colorScheme.onSurface,
                fontFamily: kMono,
                fontFamilyFallback: kMonoFallback,
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
        leadingDivider: Container(width: 1, color: DbColors.of(context).separator),
      ),
    );
  }
}

/// Keeps a single prompts builder per editor.
class CodePromptsBuilderHolder {
  CodePromptsBuilderHolder(this.builder);
  final SqlPromptsBuilder builder;
}
