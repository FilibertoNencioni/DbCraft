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
  SqlPromptsBuilder(
    DbConnection? Function() connection,
    this.textProvider, {
    required this.enabled,
    String? Function()? catalog,
  }) : _catalog = MetadataCompletionCatalog(connection, catalog: catalog) {
    _completer = SqlCompleter(_catalog);
  }

  final String Function() textProvider;
  final bool Function() enabled;
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
    final r = _completer.complete(text, _caretOffset(text, selection.extentIndex, column));
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
  Size get preferredSize => Size(width, CompletionList.heightFor(notifier.value.prompts.length));

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
          for (final p in v.prompts.cast<SqlPrompt>()) CompletionItem(p.item.display, _kind(p.kind), detail: p.detail),
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
    selectionColor: c.accent.withValues(alpha: Tint.strong),
    codeTheme: CodeHighlightTheme(
      languages: {'sql': CodeHighlightThemeMode(mode: langSql)},
      theme: dark ? githubDarkDimmedTheme : xcodeTheme,
    ),
  );
}

/// Line-number gutter shared by the SQL editor and read-only views.
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
      const SizedBox(width: 6),
    ],
  );
};

/// The SQL source editor (highlighting, line numbers, autocompletion).
class SqlCodeEditor extends StatefulWidget {
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

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape || !_session.isOpen) {
      return KeyEventResult.ignored;
    }
    _session.clear();
    // The editor closes the popup on selection-only changes: flip the cursor
    // affinity back and forth (no visible change, wordWrap is off).
    final ctrl = widget.controller, sel = ctrl.selection;
    ctrl.selection = sel.copyWith(
      extentAffinity: sel.extentAffinity == TextAffinity.upstream ? TextAffinity.downstream : TextAffinity.upstream,
    );
    ctrl.selection = sel;
    return KeyEventResult.handled;
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
