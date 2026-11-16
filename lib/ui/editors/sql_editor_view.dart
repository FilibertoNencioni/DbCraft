import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../../features/ai/ai.dart';
import '../../features/performance/visual_plan.dart';
import '../../features/query_builder/query_builder_tab.dart';
import '../../model/connection_config.dart';
import '../../services/metadata_service.dart';
import '../../services/sql_formatter.dart';
import '../../services/sql_splitter.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../state/editor_zoom.dart';
import '../actions.dart';
import '../dialogs/export_dialog.dart';
import '../results/results_viewer.dart';
import '../scripts/script_actions.dart';
import '../widgets/common.dart';
import '../widgets/split_view.dart';
import 'sql_code_editor.dart';
import 'sql_variables_panel.dart';

/// Commands that the native / window menu can send to a SQL editor.
enum SqlCommand {
  execute,
  executeCurrent,
  executeNewTab,
  executeScript,
  explain,
  format,
  find,
  toggleResults,
  toggleVariables,
  saveAs,
  aiExplain,
  aiFix,
  aiGenerate,
  visualPlan,
}

/// Text zoom shortcuts of the SQL editor: Cmd/Ctrl + "+" / "-" (also "=" and
/// the numeric keypad); back to 100% with ⌃⌘0 on macOS (⌘0 toggles the
/// sidebar; same choice as Xcode), Ctrl+Alt+0 elsewhere, or Cmd/Ctrl +
/// keypad 0.
abstract final class SqlZoomKeys {
  static bool get _mac => Platform.isMacOS;

  static SingleActivator _a(LogicalKeyboardKey k, {bool shift = false}) =>
      SingleActivator(k, control: !_mac, meta: _mac, shift: shift);

  static SingleActivator get zoomIn => _a(LogicalKeyboardKey.add);
  static SingleActivator get zoomOut => _a(LogicalKeyboardKey.minus);
  static SingleActivator get reset => _mac
      ? const SingleActivator(LogicalKeyboardKey.digit0, control: true, meta: true)
      : const SingleActivator(LogicalKeyboardKey.digit0, control: true, alt: true);

  static Map<ShortcutActivator, VoidCallback> bindings(EditorZoom z) => {
        for (final k in [LogicalKeyboardKey.add, LogicalKeyboardKey.equal]) ...{
          _a(k): z.zoomIn,
          _a(k, shift: true): z.zoomIn,
        },
        _a(LogicalKeyboardKey.numpadAdd): z.zoomIn,
        _a(LogicalKeyboardKey.minus): z.zoomOut,
        _a(LogicalKeyboardKey.numpadSubtract): z.zoomOut,
        reset: z.reset,
        _a(LogicalKeyboardKey.numpad0): z.reset,
      };
}

class SqlEditorView extends StatefulWidget {
  const SqlEditorView({super.key, required this.tab});
  final SqlEditorTab tab;

  static final Map<SqlEditorTab, _SqlEditorViewState> _views = {};

  /// Runs [cmd] on the editor showing [tab] (no-op if not built yet).
  static void dispatch(SqlEditorTab tab, SqlCommand cmd) => _views[tab]?._run(cmd);

  /// "Correggi con AI" on an error result of [tab].
  static void fixWithAi(SqlEditorTab tab, ResultTab failed) => _views[tab]?._aiFix(failed);

  @override
  State<SqlEditorView> createState() => _SqlEditorViewState();
}

class _SqlEditorViewState extends State<SqlEditorView> {
  late final CodeFindController _find = CodeFindController(tab.controller);
  late final CodePromptsBuilderHolder _prompts = CodePromptsBuilderHolder(
    SqlPromptsBuilder(
      () => tab.connection,
      () => tab.controller.text,
      lines: () => tab.controller.codeLines,
      enabled: () => AppScope.read(context).settings.autoComplete,
      catalog: () => tab.catalog,
      history: () => AppScope.read(context).history.map((h) => h.sql),
    ),
  );
  final _editorFocus = FocusNode(debugLabel: 'sql-editor');
  bool _showResults = true;
  int _bottomTab = 0; // index in results, or -1 = output, -2 = log
  Timer? _ticker;
  MetadataService? _catalogsOf;
  Future<List<String>>? _catalogs;

  SqlEditorTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    tab.addListener(_changed);
    SqlEditorView._views[tab] = this;
  }

  @override
  void dispose() {
    if (SqlEditorView._views[tab] == this) SqlEditorView._views.remove(tab);
    tab.removeListener(_changed);
    _ticker?.cancel();
    _find.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (tab.running && _ticker == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}));
    } else if (!tab.running) {
      _ticker?.cancel();
      _ticker = null;
    }
    setState(() {
      if (_bottomTab >= 0) _bottomTab = tab.selectedResult;
    });
  }

  ExecutionUi get _ui => DialogExecutionUi(context);

  /// The last run asked (Invio in the Variabili panel repeats it once the
  /// missing values are given).
  Future<void> Function()? _lastRun;

  /// Runs the selection or, without one, the whole script.
  Future<void> _execute({bool newTab = false}) async {
    _lastRun = () => _execute(newTab: newTab);
    if (!await _checkConnection()) return;
    setState(() {
      _showResults = true;
      _bottomTab = 0;
    });
    await tab.execute(_ui, newTab: newTab);
  }

  Future<void> _executeCurrent() async {
    _lastRun = _executeCurrent;
    if (!await _checkConnection()) return;
    setState(() {
      _showResults = true;
      _bottomTab = 0;
    });
    await tab.executeCurrent(_ui);
  }

  Future<void> _explain() async {
    _lastRun = _explain;
    if (!await _checkConnection()) return;
    setState(() => _showResults = true);
    await tab.explain(_ui);
  }

  Future<bool> _checkConnection() async {
    if (tab.connection != null) return true;
    final app = AppScope.read(context);
    if (app.connections.isEmpty) {
      showToast(context, 'Crea prima una connessione', error: true);
      return false;
    }
    final c = await _chooseConnection();
    if (c == null) return false;
    tab.connection = c;
    return true;
  }

  Future<DbConnection?> _chooseConnection() {
    final app = AppScope.read(context);
    return showListPicker<DbConnection>(
      context,
      title: 'Su quale connessione eseguire?',
      items: app.connections,
      label: (x) => x.config.name,
      detail: (x) => x.isConnected ? 'Connessa · ${x.config.subtitle}' : x.config.subtitle,
      icon: (x) => x.config.icon,
      iconColor: (x) => x.config.color,
      choose: 'Esegui',
    );
  }

  void _toggleVariables() => tab.showVariables = !tab.showVariables;

  /// ⌥⌘V: the Variabili panel.
  static SingleActivator get variablesKey => Platform.isMacOS
      ? const SingleActivator(LogicalKeyboardKey.keyV, meta: true, alt: true)
      : const SingleActivator(LogicalKeyboardKey.keyV, control: true, alt: true);

  void _format() {
    final app = AppScope.read(context);
    final f = SqlFormatter(upperCaseKeywords: app.settings.upperCaseKeywords);
    final sel = tab.controller.selectedText;
    if (sel.trim().isNotEmpty) {
      tab.controller.replaceSelection(f.format(sel));
    } else {
      tab.controller.text = f.format(tab.controller.text);
    }
  }

  void _toUpper(bool upper) {
    final sel = tab.controller.selectedText;
    if (sel.isEmpty) return;
    tab.controller.replaceSelection(upper ? sel.toUpperCase() : sel.toLowerCase());
  }

  Future<void> _saveAs() => saveSqlTabAs(context, tab);

  Future<void> _load() async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SQL', extensions: ['sql', 'txt']),
      ],
    );
    if (f == null) return;
    tab.controller.text = await f.readAsString();
  }

  void _run(SqlCommand cmd) {
    switch (cmd) {
      case SqlCommand.execute || SqlCommand.executeScript:
        if (!tab.running) _execute();
      case SqlCommand.executeCurrent:
        if (!tab.running) _executeCurrent();
      case SqlCommand.executeNewTab:
        if (!tab.running) _execute(newTab: true);
      case SqlCommand.explain:
        if (!tab.running) _explain();
      case SqlCommand.format:
        _format();
      case SqlCommand.find:
        _find.findMode();
      case SqlCommand.toggleResults:
        setState(() => _showResults = !_showResults);
      case SqlCommand.toggleVariables:
        _toggleVariables();
      case SqlCommand.saveAs:
        _saveAs();
      case SqlCommand.aiExplain:
        _aiExplain();
      case SqlCommand.aiFix:
        _aiFix();
      case SqlCommand.aiGenerate:
        _aiGenerate();
      case SqlCommand.visualPlan:
        _visualPlan();
    }
  }

  // -------------------------------------------------------------------------
  // AI assistant
  // -------------------------------------------------------------------------

  /// Statement under the caret / selection, or the whole text.
  String get _aiSql {
    final s = tab.currentStatement();
    return (s?.text ?? tab.controller.text).trim();
  }

  Future<void> _visualPlan() async {
    final c = tab.connection;
    final sql = _aiSql;
    if (c == null || sql.isEmpty) return;
    await showVisualPlan(context, c, sql, catalog: tab.catalog);
  }

  Future<void> _aiExplain() async {
    final sql = _aiSql;
    if (sql.isEmpty || !await ensureAiReady(context) || !mounted) return;
    await showAiExplainQuery(context, tab.connection, sql);
  }

  /// Last failed statement of this editor (error result tab), if any.
  ResultTab? get _lastError {
    for (final r in tab.results.reversed) {
      if (r.error != null) return r;
    }
    return null;
  }

  /// "Correggi con AI": proposes a corrected statement and replaces it.
  Future<void> _aiFix([ResultTab? failed]) async {
    final err = failed ?? _lastError;
    final sql = err?.sql ?? _aiSql;
    if (sql.isEmpty || !await ensureAiReady(context) || !mounted) return;
    final fixed = await showAiFixQuery(context, tab.connection, sql, err?.error ?? 'Nessun errore registrato');
    if (fixed == null || !mounted) return;
    _replaceStatement(sql, fixed);
  }

  Future<void> _aiGenerate() async {
    if (!await ensureAiReady(context) || !mounted) return;
    final current = tab.controller.text.trim();
    final sql = await showAiGenerateSql(context, tab.connection, currentSql: current.isEmpty ? null : current);
    if (sql == null || !mounted) return;
    final sel = tab.controller.selection;
    if (sel.isCollapsed && current.isNotEmpty) {
      tab.controller.text = '${tab.controller.text.trimRight()}\n\n$sql';
    } else {
      tab.controller.replaceSelection(sql);
    }
    _editorFocus.requestFocus();
  }

  /// Replaces the occurrence of [original] in the editor (or the statement
  /// under the caret) with [replacement].
  void _replaceStatement(String original, String replacement) {
    final text = tab.controller.text;
    final i = text.indexOf(original);
    if (i >= 0) {
      tab.highlight(SqlStatement(original, i, i + original.length));
    } else if (tab.controller.selectedText.trim().isEmpty) {
      final s = tab.currentStatement();
      if (s != null) tab.highlight(s);
    }
    tab.controller.replaceSelection(replacement);
    _editorFocus.requestFocus();
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final mac = Platform.isMacOS;
    SingleActivator a(LogicalKeyboardKey k, {bool shift = false, bool alt = false}) =>
        SingleActivator(k, control: !mac, meta: mac, shift: shift, alt: alt);
    return {
      a(LogicalKeyboardKey.enter): _execute,
      a(LogicalKeyboardKey.numpadEnter): _execute,
      a(LogicalKeyboardKey.enter, shift: true): _executeCurrent,
      a(LogicalKeyboardKey.numpadEnter, shift: true): _executeCurrent,
      a(LogicalKeyboardKey.backslash): () => _execute(newTab: true),
      const SingleActivator(LogicalKeyboardKey.keyX, alt: true): _execute,
      a(LogicalKeyboardKey.keyE, shift: true): _explain,
      a(LogicalKeyboardKey.keyE, alt: true): _visualPlan,
      a(LogicalKeyboardKey.keyF, shift: true): _format,
      a(LogicalKeyboardKey.keyX, shift: true): () => _toUpper(true),
      a(LogicalKeyboardKey.keyY, shift: true): () => _toUpper(false),
      a(LogicalKeyboardKey.keyS): () => saveSqlTab(context, tab),
      a(LogicalKeyboardKey.keyS, shift: true): _saveAs,
      a(LogicalKeyboardKey.period): () {
        if (tab.running) tab.cancel();
      },
      a(LogicalKeyboardKey.keyR, shift: true): () => setState(() => _showResults = !_showResults),
      variablesKey: _toggleVariables,
      const SingleActivator(LogicalKeyboardKey.f5): _execute,
      ...SqlZoomKeys.bindings(AppScope.read(context).sqlZoom),
    };
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Column(children: [
        _toolbar(app),
        Expanded(
          child: SplitView(
            axis: Axis.vertical,
            initialFraction: 0.45,
            minFirst: 80,
            minSecond: 140,
            collapsedSecond: !_showResults,
            first: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SqlCodeEditor(
                    controller: tab.controller,
                    findController: _find,
                    promptsBuilder: _prompts,
                    fontSize: app.settings.editorFontSize,
                    zoom: app.sqlZoom,
                    focusNode: _editorFocus,
                    blankLineDelimiter: app.settings.blankLineDelimiter,
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: tab.variablesTick,
                  builder: (context, _, _) => tab.showVariables
                      ? SqlVariablesPanel(tab: tab, onRun: () => tab.running ? null : (_lastRun ?? _execute)())
                      : const SizedBox.shrink(),
                ),
              ],
            ),
            second: _resultsPanel(app),
          ),
        ),
      ]),
    );
  }

  String get _elapsed {
    final s = tab.runningSince;
    if (s == null) return '';
    final ms = DateTime.now().difference(s).inMilliseconds;
    return ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';
  }

  Widget _toolbar(AppState app) {
    final c = DbColors.of(context);
    final conn = tab.connection;
    final mac = Platform.isMacOS;
    SingleActivator a(LogicalKeyboardKey k, {bool shift = false, bool alt = false}) =>
        SingleActivator(k, control: !mac, meta: mac, shift: shift, alt: alt);
    String sc(LogicalKeyboardKey k, {bool shift = false, bool alt = false}) =>
        shortcutLabel(a(k, shift: shift, alt: alt));
    return PaneBar(children: [
      if (tab.running)
        PushButton(
          label: 'Interrompi',
          icon: AppIcons.stop,
          kind: PushButtonKind.destructive,
          tooltip: 'Interrompi esecuzione (${sc(LogicalKeyboardKey.period)})',
          onPressed: tab.cancel,
        )
      else
        PushButton.primary(
          label: 'Esegui',
          icon: AppIcons.run,
          tooltip: 'Esegui la selezione o, senza selezione, tutto lo script (${sc(LogicalKeyboardKey.enter)})',
          onPressed: _execute,
        ),
      const SizedBox(width: Gap.xs),
      ToolButton(
        icon: AppIcons.shortText,
        tooltip: 'Esegui solo l\'istruzione sotto il cursore (${sc(LogicalKeyboardKey.enter, shift: true)})',
        onPressed: tab.running ? null : _executeCurrent,
      ),
      ToolButton(
        icon: AppIcons.scriptFromSelection,
        tooltip: 'Esegui in una nuova scheda risultati (${sc(LogicalKeyboardKey.backslash)})',
        onPressed: tab.running ? null : () => _execute(newTab: true),
      ),
      ToolButton(
        icon: AppIcons.tree,
        tooltip: 'Piano di esecuzione (${sc(LogicalKeyboardKey.keyE, shift: true)})',
        onPressed: tab.running ? null : _explain,
      ),
      ToolButton(
        icon: AppIcons.schema,
        tooltip: 'Piano visuale (${sc(LogicalKeyboardKey.keyE, alt: true)})',
        onPressed: tab.running || conn == null ? null : _visualPlan,
      ),
      const ToolSeparator(),
      ToolButton(icon: AppIcons.format, tooltip: 'Formatta SQL (${sc(LogicalKeyboardKey.keyF, shift: true)})', onPressed: _format),
      if (app.settings.aiEnabled) _aiMenu(app),
      ToolButton(
        icon: AppIcons.join,
        tooltip: 'Query builder visuale',
        onPressed: conn == null || (conn.isConnected && !conn.dialect.isSql)
            ? null
            : () => app.openFeatureTab(QueryBuilderTab(conn)),
      ),
      ToolButton(icon: AppIcons.search, tooltip: 'Trova e sostituisci (${sc(LogicalKeyboardKey.keyF)})', onPressed: _find.findMode),
      _variablesButton(),
      PulldownButton(
        icon: AppIcons.more,
        tooltip: 'Altre azioni',
        entries: () => [
          MenuEntry('Salva come…', onSelected: _saveAs, shortcut: a(LogicalKeyboardKey.keyS, shift: true)),
          MenuEntry('Carica file SQL…', onSelected: _load),
          const MenuEntry.divider(),
          MenuEntry('Selezione in MAIUSCOLO',
              onSelected: () => _toUpper(true), shortcut: a(LogicalKeyboardKey.keyX, shift: true)),
          MenuEntry('Selezione in minuscolo',
              onSelected: () => _toUpper(false), shortcut: a(LogicalKeyboardKey.keyY, shift: true)),
          const MenuEntry.divider(),
          MenuEntry('Ingrandisci testo', onSelected: app.sqlZoom.zoomIn, shortcut: SqlZoomKeys.zoomIn),
          MenuEntry('Riduci testo', onSelected: app.sqlZoom.zoomOut, shortcut: SqlZoomKeys.zoomOut),
          MenuEntry('Dimensione testo 100%', onSelected: app.sqlZoom.reset, shortcut: SqlZoomKeys.reset),
        ],
      ),
      if (tab.running) ...[
        const SizedBox(width: Gap.sm),
        Text(_elapsed, style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular)),
      ],
      const Spacer(),
      _zoomBadge(app.sqlZoom),
      if (conn != null && conn.isConnected && (conn.metadata?.supportsCatalogs ?? false)) ...[
        _catalogButton(conn),
        const SizedBox(width: Gap.xs),
      ],
      _connectionButton(app, conn),
      if (conn != null && !conn.isConnected) ...[
        const SizedBox(width: Gap.xs),
        PushButton(label: 'Connetti', onPressed: () => ensureConnected(context, conn)),
      ],
      const SizedBox(width: Gap.xs),
      ToolButton(
        icon: AppIcons.palettePanel,
        tooltip: '${_showResults ? 'Nascondi' : 'Mostra'} risultati (${sc(LogicalKeyboardKey.keyR, shift: true)})',
        active: _showResults,
        onPressed: () => setState(() => _showResults = !_showResults),
      ),
    ]);
  }

  /// Opens the Variabili panel; shows how many variables the script has and,
  /// in amber, that some still need a value.
  Widget _variablesButton() => ValueListenableBuilder<int>(
        valueListenable: tab.variablesTick,
        builder: (context, _, _) {
          final c = DbColors.of(context);
          final syntax = tab.varSyntax;
          final rows = syntax == null ? const [] : tab.variableRows;
          final missing = rows.where((r) => r.needsValue).length;
          final key = shortcutLabel(variablesKey);
          return ToolButton(
            icon: AppIcons.variables,
            label: rows.isEmpty ? null : '${rows.length}',
            color: missing > 0 ? c.warning : null,
            active: tab.showVariables,
            tooltip: syntax == null
                ? 'Variabili: non disponibili per questo database'
                : missing > 0
                ? 'Variabili: $missing da valorizzare ($key)'
                : 'Variabili dello script ($key)',
            onPressed: syntax == null ? null : _toggleVariables,
          );
        },
      );

  /// Current text zoom, shown only when it is not 100%; a click resets it.
  Widget _zoomBadge(EditorZoom zoom) => ValueListenableBuilder<double>(
        valueListenable: zoom,
        builder: (context, z, _) => zoom.isDefault
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(right: Gap.xs),
                child: ToolButton(
                  icon: z > 1 ? AppIcons.zoomIn : AppIcons.zoomOut,
                  label: zoom.label,
                  tooltip: 'Zoom del testo: clic per tornare al 100% (${shortcutLabel(SqlZoomKeys.reset)})',
                  onPressed: zoom.reset,
                ),
              ),
      );

  Widget _aiMenu(AppState app) {
    final failed = _lastError;
    return PulldownButton(
      icon: AppIcons.ai,
      tooltip: 'Assistente AI',
      entries: () => [
        MenuEntry('Spiega la query', onSelected: _aiExplain),
        MenuEntry(failed == null ? 'Correggi la query' : 'Correggi l\'errore', onSelected: () => _aiFix()),
        MenuEntry('Genera SQL da una descrizione…', onSelected: _aiGenerate),
        const MenuEntry.divider(),
        MenuEntry('Chat con l\'assistente', onSelected: () async {
          if (await ensureAiReady(context)) app.openFeatureTab(AiChatTab(tab.connection));
        }),
      ],
    );
  }

  /// Database used by this editor (a `USE xxx` in the script overrides it).
  Widget _catalogButton(DbConnection conn) {
    final md = conn.metadata!;
    final current = tab.catalog;
    if (_catalogsOf != md) {
      _catalogsOf = md;
      _catalogs = md.catalogs();
    }
    return FutureBuilder<List<String>>(
      future: _catalogs,
      builder: (context, snap) {
        final cats = snap.data ?? [?current];
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: PopUpButton<String?>(
            style: PopUpStyle.toolbar,
            value: current,
            placeholder: md.catalogTerm,
            tooltip: '${md.catalogTerm} di questo editor',
            items: [for (final x in cats) (x, x, null)],
            onChanged: tab.running || cats.isEmpty ? null : (v) => tab.catalog = v,
          ),
        );
      },
    );
  }

  Widget _connectionButton(AppState app, DbConnection? conn) {
    final c = DbColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: PopUpButton<DbConnection?>(
        style: PopUpStyle.toolbar,
        value: conn,
        placeholder: 'Scegli connessione',
        tooltip: 'Connessione di questo editor',
        items: [for (final x in app.connections) (x, x.config.name, null)],
        entries: () => [
          for (final x in app.connections)
            MenuEntry.connection(
              name: x.config.name,
              status: x.isConnected ? c.success : c.textTertiary,
              environment: x.config.type == ConnectionType.development ? null : x.config.type.label,
              environmentColor: x.config.type.colorOf(c),
              value: x,
              checked: x == conn,
            ),
        ],
        onChanged: tab.running ? null : (v) => tab.connection = v,
      ),
    );
  }

  Widget _resultsPanel(AppState app) {
    final c = DbColors.of(context);
    final results = tab.results;
    final sel = _bottomTab;
    final mac = Platform.isMacOS;
    final run = shortcutLabel(SingleActivator(LogicalKeyboardKey.enter, meta: mac, control: !mac));
    final runCurrent = shortcutLabel(SingleActivator(LogicalKeyboardKey.enter, meta: mac, control: !mac, shift: true));
    Widget body;
    if (sel == -1) {
      body = _outputView();
    } else if (sel == -2) {
      body = _logView();
    } else if (results.isEmpty) {
      body = tab.running
          ? const EmptyState(icon: AppIcons.hourglass, title: 'Esecuzione in corso…')
          : EmptyState(
              icon: AppIcons.runCircle,
              title: 'Nessun risultato',
              message: 'Premi Esegui o $run per eseguire la selezione o tutto lo script; '
                  '$runCurrent esegue solo l\'istruzione sotto il cursore.',
            );
    } else {
      final r = results[sel.clamp(0, results.length - 1)];
      if (r.model != null) {
        body = ResultsViewer(
          key: ObjectKey(r.model),
          model: r.model!,
          onRefresh: tab.running || !r.refreshable
              ? null
              : () => tab.executeRaw(_ui, r.sql ?? '', newTab: false, params: r.params, setup: r.setup),
        );
      } else if (r.error != null) {
        body = _errorView(r);
      } else {
        body = _statsView(r);
      }
    }
    final current = sel < 0 || results.isEmpty ? sel : sel.clamp(0, results.length - 1);
    final withData = [for (final r in results) if (r.model != null) (r.title, r.model!)];
    return Material(
      color: c.content,
      child: Column(children: [
        Stack(children: [
          PaneTabs<int>(
            value: current,
            onChanged: (i) => setState(() {
              _bottomTab = i;
              if (i >= 0) tab.selectedResult = i;
            }),
            tabs: [
              for (var i = 0; i < results.length; i++)
                PaneTab(
                  i,
                  results[i].title,
                  icon: results[i].error != null
                      ? AppIcons.error
                      : results[i].model != null
                          ? AppIcons.rows
                          : AppIcons.insights,
                  iconColor: results[i].error != null ? c.danger : null,
                  onClose: () => tab.closeResult(i),
                ),
              PaneTab(-1, 'Output', icon: AppIcons.terminal, count: tab.serverOutput.isEmpty ? null : tab.serverOutput.length),
              const PaneTab(-2, 'Log', icon: AppIcons.history),
            ],
            trailing: sel == -1 && tab.serverOutput.isNotEmpty
                ? ToolButton(
                    icon: AppIcons.clearAll,
                    tooltip: 'Pulisci l\'output',
                    onPressed: () => setState(tab.serverOutput.clear),
                  )
                : sel >= 0 && withData.length > 1
                ? ToolButton(
                    icon: AppIcons.share,
                    label: 'Esporta tutti',
                    tooltip: 'Esporta tutti i ${withData.length} risultati, un file ciascuno…',
                    onPressed: tab.running ? null : () => showResultsExportDialog(context, withData),
                  )
                : null,
          ),
          if (tab.running) const Positioned(left: 0, right: 0, bottom: 0, child: LoadingLine()),
        ]),
        Expanded(child: body),
      ]),
    );
  }

  Widget _errorView(ResultTab r) {
    final c = DbColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Notice(
          kind: NoticeKind.danger,
          title: 'L\'istruzione non è stata eseguita',
          actions: [
            if (r.sql != null && AppScope.read(context).settings.aiEnabled)
              PushButton(label: 'Correggi con AI', icon: AppIcons.ai, onPressed: () => _aiFix(r)),
          ],
          child: CodeBox(r.error!, label: 'Messaggio del server', wrap: true),
        ),
        if (r.sql != null) ...[
          const SectionLabel('Query', padding: EdgeInsets.only(top: Gap.lg, bottom: Gap.xs)),
          CodeBox(r.sql!, color: c.textSecondary, wrap: true),
        ],
      ]),
    );
  }

  Widget _statsView(ResultTab r) => SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: PropertyTable(
              entries: [for (final e in (r.stats ?? {'Messaggio': r.message ?? ''}).entries) (e.key, e.value)],
            ),
          ),
        ),
      );

  Widget _outputView() {
    final c = DbColors.of(context);
    if (tab.serverOutput.isEmpty) {
      return const EmptyState(
        icon: AppIcons.terminal,
        title: 'Nessun messaggio dal server',
        message: 'Qui compaiono PRINT, RAISE NOTICE e gli avvisi del driver.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      itemCount: tab.serverOutput.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: SelectableText(tab.serverOutput[i], style: monoStyle(context, size: TypeSize.mono, color: c.text)),
      ),
    );
  }

  Widget _logView() {
    final c = DbColors.of(context);
    final log = tab.log.reversed.toList();
    if (log.isEmpty) {
      return const EmptyState(icon: AppIcons.history, title: 'Nessuna esecuzione in questo editor');
    }
    String hms(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      itemCount: log.length,
      itemBuilder: (context, i) {
        final e = log[i];
        final (icon, color) = switch (e.level) {
          LogLevel.success => (AppIcons.checkCircle, c.success),
          LogLevel.error => (AppIcons.error, c.danger),
          LogLevel.warning => (AppIcons.warning, c.warning),
          LogLevel.info => (AppIcons.info, c.textTertiary),
        };
        return ListRow(
          zebra: true,
          index: i,
          mono: true,
          icon: icon,
          iconColor: color,
          title: e.message,
          subtitle: e.sql?.replaceAll(RegExp(r'\s+'), ' '),
          tooltip: e.sql == null ? e.message : '${e.message}\nClic per copiare l\'SQL',
          trailing: Text(hms(e.time), style: monoStyle(context, size: TypeSize.monoSmall, color: c.textTertiary)),
          onTap: e.sql == null ? null : () => Clipboard.setData(ClipboardData(text: e.sql!)),
        );
      },
    );
  }
}
