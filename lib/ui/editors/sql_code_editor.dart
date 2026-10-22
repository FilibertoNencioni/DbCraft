import 'dart:math';

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/styles/github-dark-dimmed.dart';
import 'package:re_highlight/styles/xcode.dart';

import '../../model/db_objects.dart';
import '../../services/sql_keywords.dart';
import '../../state/app_state.dart';
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
  SqlPromptsBuilder(this.connection, this.textProvider, {required this.enabled, this.catalog});

  final DbConnection? Function() connection;

  /// Database of the editor (tables to preload); defaults to the current one.
  final String? Function()? catalog;
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
    final cat = catalog?.call() ?? dc.metadata!.currentCatalog;
    final key = 'tables:${dc.config.id}:$cat';
    if (_loading.contains(key)) return;
    _loading.add(key);
    final md = dc.metadata!;
    () async {
      try {
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

/// Popup list shown by the autocompletion ([CompletionList]).
class SqlAutocompleteView extends StatefulWidget implements PreferredSizeWidget {
  const SqlAutocompleteView({super.key, required this.notifier, required this.onSelected});

  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;

  static const double width = 380;

  @override
  Size get preferredSize => Size(width, CompletionList.heightFor(notifier.value.prompts.length));

  @override
  State<SqlAutocompleteView> createState() => _SqlAutocompleteViewState();
}

class _SqlAutocompleteViewState extends State<SqlAutocompleteView> {
  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_changed);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  static CompletionKind _kind(PromptKind k) => switch (k) {
    PromptKind.keyword => CompletionKind.keyword,
    PromptKind.function => CompletionKind.function,
    PromptKind.table => CompletionKind.table,
    PromptKind.view => CompletionKind.view,
    PromptKind.column => CompletionKind.column,
    PromptKind.type => CompletionKind.type,
  };

  @override
  Widget build(BuildContext context) {
    final v = widget.notifier.value;
    // Transparent material: gives the overlay a text style without painting.
    return Material(
      type: MaterialType.transparency,
      child: CompletionList(
        width: SqlAutocompleteView.width,
        items: [
          for (final p in v.prompts.cast<SqlPrompt>()) CompletionItem(p.word, _kind(p.kind), detail: p.detail),
        ],
        selected: v.index,
        onSelect: (i) => widget.onSelected(v.copyWith(index: i).autocomplete),
      ),
    );
  }
}

/// Compact find / replace bar for the editor (Ctrl+F / Ctrl+H): a `bar`
/// row with the search field, plus a `subbar` row in replace mode.
class SqlFindBar extends StatelessWidget implements PreferredSizeWidget {
  const SqlFindBar({super.key, required this.controller, required this.readOnly});
  final CodeFindController controller;
  final bool readOnly;

  @override
  Size get preferredSize => Size.fromHeight(
    controller.value == null ? 0 : BarHeight.bar + (controller.value!.replaceMode ? BarHeight.subbar : 0),
  );

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final v = controller.value;
    if (v == null) return const SizedBox.shrink();
    final result = v.result;
    final count = result == null
        ? ''
        : result.matches.isEmpty
        ? 'Nessun risultato'
        : '${result.index + 1} di ${result.matches.length}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: BarHeight.bar - 0.5,
            child: Row(
              children: [
                ToolButton(
                  icon: v.replaceMode ? AppIcons.chevronUp : AppIcons.chevronDown,
                  tooltip: 'Sostituisci',
                  onPressed: readOnly ? null : controller.toggleMode,
                ),
                const SizedBox(width: Gap.xs),
                SearchField(
                  width: 240,
                  controller: controller.findInputController,
                  focusNode: controller.findInputFocusNode,
                  hint: 'Trova',
                  onSubmitted: (_) => controller.nextMatch(),
                ),
                const SizedBox(width: Gap.xs),
                ToolButton(
                  icon: AppIcons.text,
                  tooltip: 'Maiuscole/minuscole',
                  active: v.option.caseSensitive,
                  onPressed: controller.toggleCaseSensitive,
                ),
                ToolButton(
                  icon: AppIcons.code,
                  tooltip: 'Espressione regolare',
                  active: v.option.regex,
                  onPressed: controller.toggleRegex,
                ),
                const SizedBox(width: Gap.sm),
                Text(count, style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular)),
                const Spacer(),
                ToolButton(icon: AppIcons.arrowUp, tooltip: 'Precedente', onPressed: controller.previousMatch),
                ToolButton(icon: AppIcons.arrowDown, tooltip: 'Successivo', onPressed: controller.nextMatch),
                ToolButton(icon: AppIcons.close, tooltip: 'Chiudi (Esc)', onPressed: controller.close),
              ],
            ),
          ),
          if (v.replaceMode)
            Container(
              height: BarHeight.subbar,
              padding: const EdgeInsets.only(bottom: BarHeight.subbar - ControlSize.regular),
              child: Row(
                children: [
                  const SizedBox(width: ControlSize.regular + Gap.xs),
                  MacTextField(
                    width: 240,
                    controller: controller.replaceInputController,
                    focusNode: controller.replaceInputFocusNode,
                    hint: 'Sostituisci con',
                    onSubmitted: (_) => controller.replaceMatch(),
                  ),
                  const SizedBox(width: Gap.sm),
                  PushButton(label: 'Sostituisci', size: ControlScale.small, onPressed: controller.replaceMatch),
                  const SizedBox(width: Gap.xs),
                  PushButton(label: 'Tutti', size: ControlScale.small, onPressed: controller.replaceAllMatches),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Editor style shared by every SQL surface (editor and read-only views),
/// so highlighting and colors stay identical everywhere.
CodeEditorStyle sqlCodeEditorStyle(BuildContext context, double fontSize) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final c = DbColors.of(context);
  return CodeEditorStyle(
    fontSize: fontSize,
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    backgroundColor: c.codeBackground,
    cursorLineColor: c.codeCurrentLine,
    selectionColor: c.accent.withValues(alpha: Tint.strong),
    codeTheme: CodeHighlightTheme(
      languages: {'sql': CodeHighlightThemeMode(mode: langSql)},
      theme: dark ? githubDarkDimmedTheme : xcodeTheme,
    ),
  );
}

/// Line-number gutter shared by the SQL editor and read-only views.
CodeIndicatorBuilder sqlLineNumbers(double fontSize) =>
    (context, editingController, chunkController, notifier) {
      final c = DbColors.of(context);
      return Row(
        children: [
          DefaultCodeLineNumber(
            controller: editingController,
            notifier: notifier,
            textStyle: TextStyle(
              fontSize: fontSize - 1,
              color: c.textTertiary,
              fontFamily: kMono,
              fontFamilyFallback: kMonoFallback,
            ),
            focusedTextStyle: TextStyle(
              fontSize: fontSize - 1,
              color: c.text,
              fontFamily: kMono,
              fontFamilyFallback: kMonoFallback,
            ),
          ),
          const SizedBox(width: 6),
        ],
      );
    };

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
    final c = DbColors.of(context);
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
        style: sqlCodeEditorStyle(context, fontSize),
        indicatorBuilder: sqlLineNumbers(fontSize),
        leadingDivider: Container(width: 0.5, color: c.separator),
      ),
    );
  }
}

/// Read-only SQL viewer (DDL, generated scripts): same highlighting and
/// gutter as [SqlCodeEditor], with selection and find but no editing.
/// Uses the editor font size from the settings unless [fontSize] is given.
class SqlCodeView extends StatefulWidget {
  const SqlCodeView({super.key, required this.text, this.fontSize});

  final String text;
  final double? fontSize;

  @override
  State<SqlCodeView> createState() => _SqlCodeViewState();
}

class _SqlCodeViewState extends State<SqlCodeView> {
  late final _controller = CodeLineEditingController.fromText(widget.text);

  @override
  void didUpdateWidget(SqlCodeView old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final fontSize = widget.fontSize ?? AppScope.maybeOf(context)?.settings.editorFontSize ?? TypeSize.mono;
    return CodeEditor(
      controller: _controller,
      readOnly: true,
      showCursorWhenReadOnly: false,
      wordWrap: false,
      findBuilder: (context, c, readOnly) => SqlFindBar(controller: c, readOnly: readOnly),
      style: sqlCodeEditorStyle(context, fontSize),
      indicatorBuilder: sqlLineNumbers(fontSize),
      leadingDivider: Container(width: 0.5, color: c.separator),
    );
  }
}

/// Keeps a single prompts builder per editor.
class CodePromptsBuilderHolder {
  CodePromptsBuilderHolder(this.builder);
  final SqlPromptsBuilder builder;
}
