import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/styles/github-dark-dimmed.dart';
import 'package:re_highlight/styles/xcode.dart';

import '../../services/sql_completion/completer.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../widgets/common.dart';
import 'code_folding.dart';

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

/// A proposal of the SQL autocompletion ([SqlCompleter]) for re_editor.
class SqlPrompt extends CodePrompt {
  SqlPrompt(this.item) : super(word: item.insert);
  final SqlCompletionItem item;

  SqlItemKind get kind => item.kind;
  String? get detail => item.detail;

  @override
  CodeAutocompleteResult get autocomplete => CodeAutocompleteResult.fromWord(word);

  /// Filtering is done by [SqlCompleter]; re_editor never calls this.
  @override
  bool match(String input) => true;
}

/// Bridges [SqlCompleter] (lib/services/sql_completion) to re_editor: the
/// proposals are computed on the whole editor text at the caret.
class SqlPromptsBuilder implements CodeAutocompletePromptsBuilder {
  /// [history]: executed statements, newest first (ranks the names used
  /// most). [lines]: the editor lines, needed when some are collapsed (the
  /// caret line index counts only the visible ones).
  SqlPromptsBuilder(
    DbConnection? Function() connection,
    this.textProvider, {
    required this.enabled,
    this.lines,
    String? Function()? catalog,
    Iterable<String> Function()? history,
  }) : _catalog = MetadataCompletionCatalog(connection, catalog: catalog) {
    _completer = SqlCompleter(_catalog, usage: history == null ? null : SqlUsageStats(history));
  }

  final String Function() textProvider;
  final bool Function() enabled;
  final CodeLines Function()? lines;
  final MetadataCompletionCatalog _catalog;
  late final SqlCompleter _completer;

  /// Fires when database objects requested by the proposals have been loaded
  /// (the open popup can be refreshed).
  Listenable get changes => _catalog;

  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) {
    if (!enabled()) return null;
    final text = textProvider();
    final column = min(selection.extentOffset, codeLine.text.length);
    final l = lines?.call();
    final line = l == null ? selection.extentIndex : scriptLineIndex(l, selection.extentIndex);
    final r = _completer.complete(text, _caretOffset(text, line, column));
    if (r == null) return null;
    return CodeAutocompleteEditingValue(input: r.input, prompts: [for (final it in r.items) SqlPrompt(it)], index: 0);
  }

  /// Offset in [text] of column [column] of line [line].
  static int _caretOffset(String text, int line, int column) {
    var offset = 0;
    for (var l = 0; l < line; l++) {
      final nl = text.indexOf('\n', offset);
      if (nl < 0) return text.length;
      offset = nl + 1;
    }
    return min(offset + column, text.length);
  }
}

/// The autocompletion popup currently shown by an editor, if any: lets the
/// editor accept the selected prompt with Tab and close the popup with Esc.
class SqlAutocompleteSession {
  Object? _owner;
  ValueNotifier<CodeAutocompleteEditingValue>? _notifier;
  ValueChanged<CodeAutocompleteResult>? _onSelected;

  bool get isOpen => _notifier != null;

  void _attach(Object owner, ValueNotifier<CodeAutocompleteEditingValue> n, ValueChanged<CodeAutocompleteResult> f) {
    _owner = owner;
    _notifier = n;
    _onSelected = f;
  }

  void _detach(Object owner) {
    if (_owner == owner) clear();
  }

  /// Forgets the popup (it is being closed).
  void clear() {
    _owner = null;
    _notifier = null;
    _onSelected = null;
  }

  /// Replaces the proposals of the open popup, keeping the selected one.
  void update(CodeAutocompleteEditingValue value) {
    final n = _notifier;
    if (n == null) return;
    final old = n.value;
    final selected = old.index < old.prompts.length ? old.prompts[old.index].word : null;
    final i = value.prompts.indexWhere((p) => p.word == selected);
    n.value = value.copyWith(index: i < 0 ? 0 : i);
  }

  /// Inserts the selected prompt; false when no popup is shown.
  bool accept() {
    final n = _notifier, f = _onSelected;
    if (n == null || f == null) return false;
    clear();
    f(n.value.autocomplete);
    return true;
  }
}

/// Popup list shown by the autocompletion ([CompletionList]).
class SqlAutocompleteView extends StatefulWidget implements PreferredSizeWidget {
  const SqlAutocompleteView({super.key, required this.notifier, required this.onSelected, this.session});

  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;

  /// Tracks this popup while it is shown (Tab accepts, Esc closes).
  final SqlAutocompleteSession? session;

  static const double width = 380;

  @override
  Size get preferredSize {
    final prompts = notifier.value.prompts.cast<SqlPrompt>();
    final loading = prompts.any((p) => p.kind == SqlItemKind.loading);
    return Size(width, CompletionList.heightFor(prompts.length - (loading ? 1 : 0), footer: loading));
  }

  @override
  State<SqlAutocompleteView> createState() => _SqlAutocompleteViewState();
}

class _SqlAutocompleteViewState extends State<SqlAutocompleteView> {
  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_changed);
    widget.session?._attach(this, widget.notifier, widget.onSelected);
  }

  @override
  void didUpdateWidget(SqlAutocompleteView old) {
    super.didUpdateWidget(old);
    if (old.notifier != widget.notifier) {
      old.notifier.removeListener(_changed);
      widget.notifier.addListener(_changed);
    }
    if (old.session != widget.session) old.session?._detach(this);
    widget.session?._attach(this, widget.notifier, widget.onSelected);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_changed);
    widget.session?._detach(this);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  static CompletionKind _kind(SqlItemKind k) => switch (k) {
    SqlItemKind.keyword => CompletionKind.keyword,
    SqlItemKind.function => CompletionKind.function,
    SqlItemKind.table || SqlItemKind.cte => CompletionKind.table,
    SqlItemKind.view => CompletionKind.view,
    SqlItemKind.column => CompletionKind.column,
    SqlItemKind.type => CompletionKind.type,
    SqlItemKind.join => CompletionKind.join,
    SqlItemKind.expand => CompletionKind.expand,
    SqlItemKind.word => CompletionKind.word,
    SqlItemKind.loading => CompletionKind.loading,
  };

  @override
  Widget build(BuildContext context) {
    final v = widget.notifier.value;
    final loading = v.prompts.cast<SqlPrompt>().where((p) => p.kind == SqlItemKind.loading).firstOrNull;
    // Transparent material: gives the overlay a text style without painting.
    return Material(
      type: MaterialType.transparency,
      child: CompletionList(
        width: SqlAutocompleteView.width,
        // The loading placeholder is shown as the footer; the rows keep the
        // prompt indexes (it is always last).
        items: [
          for (final p in v.prompts.cast<SqlPrompt>())
            if (p.kind != SqlItemKind.loading) CompletionItem(p.item.display, _kind(p.kind), detail: p.detail),
        ],
        footer: loading?.item.display,
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
                Text(
                  count,
                  style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular),
                ),
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
                  PushButton(label: 'Sostituisci', onPressed: controller.replaceMatch),
                  const SizedBox(width: Gap.xs),
                  PushButton(label: 'Tutti', onPressed: controller.replaceAllMatches),
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
    chunkIndicatorColor: c.textTertiary,
    selectionColor: c.accent.withValues(alpha: Tint.strong),
    codeTheme: CodeHighlightTheme(
      languages: {'sql': CodeHighlightThemeMode(mode: langSql)},
      theme: dark ? githubDarkDimmedTheme : xcodeTheme,
    ),
  );
}

/// Gutter shared by the SQL editor and read-only views: line numbers and
/// fold toggles (statements and multi-line comments, [SqlChunkAnalyzer]).
CodeIndicatorBuilder sqlLineNumbers(double fontSize) => (context, editingController, chunkController, notifier) {
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
      DefaultCodeChunkIndicator(
        width: 16,
        controller: chunkController,
        notifier: notifier,
        painter: _FoldChevronPainter(c.textSecondary),
      ),
    ],
  );
};

/// Fold toggle of the gutter: chevron down on a foldable line, right on a
/// collapsed one.
class _FoldChevronPainter implements CodeChunkIndicatorPainter {
  _FoldChevronPainter(Color color)
    : _paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

  final Paint _paint;
  static const double _half = 3;

  @override
  void paintCollapseIndicator(Canvas canvas, Size container) {
    final cx = container.width / 2, cy = container.height / 2;
    canvas.drawPath(
      Path()
        ..moveTo(cx - _half, cy - _half / 2)
        ..lineTo(cx, cy + _half / 2)
        ..lineTo(cx + _half, cy - _half / 2),
      _paint,
    );
  }

  @override
  void paintExpandIndicator(Canvas canvas, Size container) {
    final cx = container.width / 2, cy = container.height / 2;
    canvas.drawPath(
      Path()
        ..moveTo(cx - _half / 2, cy - _half)
        ..lineTo(cx + _half / 2, cy)
        ..lineTo(cx - _half / 2, cy + _half),
      _paint,
    );
  }
}

/// The SQL source editor (highlighting, line numbers, autocompletion).
class SqlCodeEditor extends StatefulWidget {
  const SqlCodeEditor({
    super.key,
    required this.controller,
    required this.findController,
    required this.promptsBuilder,
    required this.fontSize,
    this.focusNode,
    this.blankLineDelimiter = false,
  });

  final CodeLineEditingController controller;
  final CodeFindController findController;
  final CodePromptsBuilderHolder promptsBuilder;
  final double fontSize;
  final FocusNode? focusNode;

  /// Empty lines end statements (folding follows the execution).
  final bool blankLineDelimiter;

  @override
  State<SqlCodeEditor> createState() => _SqlCodeEditorState();
}

/// Autocompletion keys: Tab accepts the selected prompt, Enter always inserts
/// a new line (closing the popup), Esc closes the popup.
class _SqlCodeEditorState extends State<SqlCodeEditor> {
  final _session = SqlAutocompleteSession();

  late final Map<Type, Action<Intent>> _actions = {
    // Mapped (and disabled) here so the editor handles Enter itself instead
    // of the autocompletion's "accept on Enter" action above.
    CodeShortcutNewLineIntent: _SqlEditorAction<CodeShortcutNewLineIntent>(() => false, (_) => null),
    CodeShortcutIndentIntent: _SqlEditorAction<CodeShortcutIndentIntent>(() => _session.isOpen, (i) {
      _session.accept();
      return i;
    }),
  };

  @override
  void initState() {
    super.initState();
    widget.promptsBuilder.builder.changes.addListener(_refresh);
  }

  @override
  void didUpdateWidget(SqlCodeEditor old) {
    super.didUpdateWidget(old);
    if (old.promptsBuilder.builder != widget.promptsBuilder.builder) {
      old.promptsBuilder.builder.changes.removeListener(_refresh);
      widget.promptsBuilder.builder.changes.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.promptsBuilder.builder.changes.removeListener(_refresh);
    super.dispose();
  }

  /// Database objects arrived: recompute the proposals of the open popup.
  void _refresh() {
    if (!mounted || !_session.isOpen) return;
    final ctrl = widget.controller, sel = ctrl.selection;
    if (!sel.isCollapsed || sel.extentIndex >= ctrl.codeLines.length) return;
    final v = widget.promptsBuilder.builder.build(context, ctrl.codeLines[sel.extentIndex], sel);
    if (v == null) {
      _closePopup();
    } else {
      _session.update(v);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape || !_session.isOpen) {
      return KeyEventResult.ignored;
    }
    _closePopup();
    return KeyEventResult.handled;
  }

  void _closePopup() {
    _session.clear();
    // The editor closes the popup on selection-only changes: flip the cursor
    // affinity back and forth (no visible change, wordWrap is off).
    final ctrl = widget.controller, sel = ctrl.selection;
    ctrl.selection = sel.copyWith(
      extentAffinity: sel.extentAffinity == TextAffinity.upstream ? TextAffinity.downstream : TextAffinity.upstream,
    );
    ctrl.selection = sel;
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final w = widget;
    return CodeAutocomplete(
      viewBuilder: (context, notifier, onSelected) =>
          SqlAutocompleteView(notifier: notifier, onSelected: onSelected, session: _session),
      promptsBuilder: w.promptsBuilder.builder,
      child: Actions(
        actions: _actions,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onKeyEvent: _onKey,
          child: _editor(c, w),
        ),
      ),
    );
  }

  Widget _editor(DbColors c, SqlCodeEditor w) => CodeEditor(
    controller: w.controller,
    findController: w.findController,
    focusNode: w.focusNode,
    wordWrap: false,
    autofocus: true,
    shortcutsActivatorsBuilder: const SqlShortcutsActivatorsBuilder(),
    chunkAnalyzer: SqlChunkAnalyzer(blankLineDelimiter: w.blankLineDelimiter),
    commentFormatter: DefaultCodeCommentFormatter(singleLinePrefix: '--', multiLinePrefix: '/*', multiLineSuffix: '*/'),
    findBuilder: (context, c, readOnly) => SqlFindBar(controller: c, readOnly: readOnly),
    style: sqlCodeEditorStyle(context, w.fontSize),
    indicatorBuilder: sqlLineNumbers(w.fontSize),
    leadingDivider: Container(width: 0.5, color: c.separator),
  );
}

/// Callback action whose enabled state is evaluated when the key is pressed.
class _SqlEditorAction<T extends Intent> extends CallbackAction<T> {
  _SqlEditorAction(this._enabled, Object? Function(T) onInvoke) : super(onInvoke: onInvoke);
  final bool Function() _enabled;

  @override
  bool get isActionEnabled => _enabled();
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
      chunkAnalyzer: const SqlChunkAnalyzer(),
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
