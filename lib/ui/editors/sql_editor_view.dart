import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../../features/ai/ai.dart';
import '../../features/performance/visual_plan.dart';
import '../../features/query_builder/query_builder_tab.dart';
import '../../model/connection_config.dart';
import '../../services/sql_formatter.dart';
import '../../services/sql_splitter.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../actions.dart';
import '../results/results_viewer.dart';
import '../widgets/common.dart';
import '../widgets/split_view.dart';
import 'sql_code_editor.dart';

/// Commands that the native / window menu can send to a SQL editor.
enum SqlCommand {
  execute,
  executeNewTab,
  executeScript,
  explain,
  format,
  find,
  toggleResults,
  saveAs,
  aiExplain,
  aiFix,
  aiGenerate,
  visualPlan,
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
      enabled: () => AppScope.read(context).settings.autoComplete,
    ),
  );
  final _editorFocus = FocusNode(debugLabel: 'sql-editor');
  bool _showResults = true;
  int _bottomTab = 0; // index in results, or -1 = output, -2 = log
  Timer? _ticker;

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

  Future<void> _execute({bool newTab = false}) async {
    if (!await _checkConnection()) return;
    setState(() {
      _showResults = true;
      _bottomTab = 0;
    });
    await tab.executeCurrent(_ui, newTab: newTab);
  }

  Future<void> _executeScript() async {
    if (!await _checkConnection()) return;
    setState(() {
      _showResults = true;
      _bottomTab = 0;
    });
    await tab.executeScript(_ui);
  }

  Future<void> _explain() async {
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
    return showDialog<DbConnection>(
      context: context,
      builder: (ctx) {
        final c = DbColors.of(ctx);
        return SimpleDialog(
          title: const Text('Su quale connessione eseguire?'),
          contentPadding: const EdgeInsets.fromLTRB(Gap.sm, Gap.md, Gap.sm, Gap.md),
          children: [
            for (final x in app.connections)
              ListTile(
                onTap: () => Navigator.pop(ctx, x),
                leading: StatusDot(x.config.type.color),
                minLeadingWidth: 8,
                title: Text(x.config.name),
                subtitle: Text(x.config.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: x.isConnected ? Icon(Icons.check_rounded, size: 16, color: c.success) : null,
              ),
          ],
        );
      },
    );
  }

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

  Future<void> _saveAs() async {
    final loc = await getSaveLocation(
      suggestedName: tab.file?.uri.pathSegments.last ?? 'script.sql',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SQL', extensions: ['sql']),
      ],
    );
    if (loc == null) return;
    await tab.saveAs(File(loc.path));
  }

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
      case SqlCommand.execute:
        if (!tab.running) _execute();
      case SqlCommand.executeNewTab:
        if (!tab.running) _execute(newTab: true);
      case SqlCommand.executeScript:
        if (!tab.running) _executeScript();
      case SqlCommand.explain:
        if (!tab.running) _explain();
      case SqlCommand.format:
        _format();
      case SqlCommand.find:
        _find.findMode();
      case SqlCommand.toggleResults:
        setState(() => _showResults = !_showResults);
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
    await showVisualPlan(context, c, sql);
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
      a(LogicalKeyboardKey.backslash): () => _execute(newTab: true),
      const SingleActivator(LogicalKeyboardKey.keyX, alt: true): _executeScript,
      a(LogicalKeyboardKey.keyE, shift: true): _explain,
      a(LogicalKeyboardKey.keyE, alt: true): _visualPlan,
      a(LogicalKeyboardKey.keyF, shift: true): _format,
      a(LogicalKeyboardKey.keyX, shift: true): () => _toUpper(true),
      a(LogicalKeyboardKey.keyY, shift: true): () => _toUpper(false),
      a(LogicalKeyboardKey.keyS): tab.save,
      a(LogicalKeyboardKey.period): () {
        if (tab.running) tab.cancel();
      },
      a(LogicalKeyboardKey.keyR, shift: true): () => setState(() => _showResults = !_showResults),
      const SingleActivator(LogicalKeyboardKey.f5): _executeScript,
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
            first: SqlCodeEditor(
              controller: tab.controller,
              findController: _find,
              promptsBuilder: _prompts,
              fontSize: app.settings.editorFontSize,
              focusNode: _editorFocus,
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
    final mod = mac ? '⌘' : 'Ctrl+';
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(color: c.content, border: Border(bottom: BorderSide(color: c.separator))),
      child: Row(children: [
        if (tab.running)
          PrimaryButton(
            label: 'Interrompi',
            icon: Icons.stop_rounded,
            color: c.danger,
            tooltip: 'Interrompi esecuzione ($mod.)',
            onPressed: tab.cancel,
          )
        else
          PrimaryButton(
            label: 'Esegui',
            icon: Icons.play_arrow_rounded,
            tooltip: 'Esegui l\'istruzione sotto il cursore o la selezione (${mod}Invio)',
            onPressed: _execute,
          ),
        const SizedBox(width: Gap.xs),
        ToolButton(
          icon: Icons.playlist_play_rounded,
          size: 19,
          tooltip: 'Esegui tutto lo script (⌥X)',
          onPressed: tab.running ? null : _executeScript,
        ),
        ToolButton(
          icon: Icons.add_to_photos_outlined,
          tooltip: 'Esegui in una nuova scheda risultati ($mod\\)',
          onPressed: tab.running ? null : () => _execute(newTab: true),
        ),
        ToolButton(
          icon: Icons.account_tree_outlined,
          tooltip: 'Piano di esecuzione ($mod⇧E)',
          onPressed: tab.running ? null : _explain,
        ),
        ToolButton(
          icon: Icons.schema_outlined,
          tooltip: 'Piano visuale ($mod⌥E)',
          onPressed: tab.running || conn == null ? null : _visualPlan,
        ),
        const ToolSeparator(),
        ToolButton(icon: Icons.auto_fix_high_outlined, tooltip: 'Formatta SQL ($mod⇧F)', onPressed: _format),
        if (app.settings.aiEnabled) _aiMenu(app),
        ToolButton(
          icon: Icons.join_inner_rounded,
          tooltip: 'Query builder visuale',
          onPressed: conn == null || (conn.isConnected && !conn.dialect.isSql)
              ? null
              : () => app.openFeatureTab(QueryBuilderTab(conn)),
        ),
        ToolButton(icon: Icons.search_rounded, tooltip: 'Trova e sostituisci (${mod}F)', onPressed: _find.findMode),
        PopupMenuButton<int>(
          tooltip: 'Altre azioni',
          position: PopupMenuPosition.under,
          icon: Icon(Icons.more_horiz_rounded, size: 16, color: c.textSecondary),
          onSelected: (v) {
            switch (v) {
              case 0:
                _saveAs();
              case 1:
                _load();
              case 2:
                _toUpper(true);
              case 3:
                _toUpper(false);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 0, height: 28, child: Text('Salva come…')),
            const PopupMenuItem(value: 1, height: 28, child: Text('Carica file SQL…')),
            const PopupMenuDivider(height: 9),
            PopupMenuItem(value: 2, height: 28, child: Text('Selezione in MAIUSCOLO   $mod⇧X')),
            PopupMenuItem(value: 3, height: 28, child: Text('Selezione in minuscolo   $mod⇧Y')),
          ],
        ),
        if (tab.running) ...[
          const SizedBox(width: Gap.sm),
          Text(_elapsed, style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary, fontFeatures: kTabular)),
        ],
        const Spacer(),
        _connectionButton(app, conn),
        if (conn != null && !conn.isConnected)
          TextButton(onPressed: () => ensureConnected(context, conn), child: const Text('Connetti')),
        const SizedBox(width: Gap.xs),
        ToolButton(
          icon: Icons.splitscreen_outlined,
          tooltip: _showResults ? 'Nascondi risultati ($mod⇧R)' : 'Mostra risultati ($mod⇧R)',
          active: _showResults,
          onPressed: () => setState(() => _showResults = !_showResults),
        ),
      ]),
    );
  }

  Widget _aiMenu(AppState app) {
    final c = DbColors.of(context);
    final failed = _lastError;
    return PopupMenuButton<VoidCallback>(
      tooltip: 'Assistente AI',
      position: PopupMenuPosition.under,
      icon: Icon(Icons.auto_awesome_outlined, size: 17, color: c.textSecondary),
      onSelected: (f) => f(),
      itemBuilder: (_) => [
        PopupMenuItem(value: _aiExplain, height: 28, child: const Text('Spiega la query')),
        PopupMenuItem(
          value: () => _aiFix(),
          height: 28,
          child: Text(failed == null ? 'Correggi la query' : 'Correggi l\'errore'),
        ),
        PopupMenuItem(value: _aiGenerate, height: 28, child: const Text('Genera SQL da una descrizione…')),
        const PopupMenuDivider(height: 9),
        PopupMenuItem(
          value: () async {
            if (await ensureAiReady(context)) app.openFeatureTab(AiChatTab(tab.connection));
          },
          height: 28,
          child: const Text('Chat con l\'assistente'),
        ),
      ],
    );
  }

  Widget _connectionButton(AppState app, DbConnection? conn) {
    final c = DbColors.of(context);
    return PopupMenuButton<DbConnection>(
      tooltip: 'Connessione di questo editor',
      position: PopupMenuPosition.under,
      enabled: !tab.running,
      onSelected: (v) => tab.connection = v,
      itemBuilder: (_) => [
        for (final x in app.connections)
          PopupMenuItem(
            value: x,
            height: 30,
            child: Row(children: [
              StatusDot(x.isConnected ? c.success : c.textTertiary, size: 7, ring: !x.isConnected),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(x.config.name)),
              if (x.config.type != ConnectionType.development) Badge2(x.config.type.label, color: x.config.type.color),
            ]),
          ),
      ],
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.control),
          border: Border.all(color: c.separator),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (conn != null) ...[
            StatusDot(conn.isConnected ? c.success : c.textTertiary, size: 7, ring: !conn.isConnected),
            const SizedBox(width: 6),
          ],
          Text(
            conn?.config.name ?? 'Scegli connessione',
            style: TextStyle(fontSize: TypeSize.small + 0.5, color: conn == null ? c.textSecondary : c.text),
          ),
          const SizedBox(width: 4),
          Icon(Icons.expand_more_rounded, size: 14, color: c.textTertiary),
        ]),
      ),
    );
  }

  Widget _resultsPanel(AppState app) {
    final c = DbColors.of(context);
    final results = tab.results;
    final sel = _bottomTab;
    final mod = Platform.isMacOS ? '⌘Invio' : 'Ctrl+Invio';
    Widget body;
    if (sel == -1) {
      body = _outputView();
    } else if (sel == -2) {
      body = _logView();
    } else if (results.isEmpty) {
      body = tab.running
          ? const EmptyState(icon: Icons.hourglass_empty_rounded, title: 'Esecuzione in corso…')
          : EmptyState(
              icon: Icons.play_circle_outline_rounded,
              title: 'Nessun risultato',
              message: 'Premi Esegui o $mod per eseguire l\'istruzione sotto il cursore; ⌥X esegue l\'intero script.',
            );
    } else {
      final r = results[sel.clamp(0, results.length - 1)];
      if (r.model != null) {
        body = ResultsViewer(
          key: ObjectKey(r.model),
          model: r.model!,
          onRefresh: tab.running ? null : () => tab.executeRaw(_ui, r.sql ?? '', newTab: false),
        );
      } else if (r.error != null) {
        body = _errorView(r);
      } else {
        body = _statsView(r);
      }
    }
    return Material(
      color: c.content,
      child: Column(children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
          decoration: BoxDecoration(color: c.chrome, border: Border(bottom: BorderSide(color: c.separator))),
          child: Row(children: [
            Expanded(
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (var i = 0; i < results.length; i++)
                  _ResultTabChip(
                    label: results[i].title,
                    icon: results[i].error != null
                        ? Icons.error_outline_rounded
                        : results[i].model != null
                            ? Icons.table_rows_outlined
                            : Icons.insights_rounded,
                    iconColor: results[i].error != null ? c.danger : null,
                    selected: sel == i,
                    onTap: () => setState(() {
                      _bottomTab = i;
                      tab.selectedResult = i;
                    }),
                    onClose: () => tab.closeResult(i),
                  ),
              ]),
            ),
            _ResultTabChip(
              label: 'Output',
              icon: Icons.terminal_rounded,
              badge: tab.serverOutput.isEmpty ? null : '${tab.serverOutput.length}',
              selected: sel == -1,
              onTap: () => setState(() => _bottomTab = -1),
            ),
            _ResultTabChip(
              label: 'Log',
              icon: Icons.history_rounded,
              selected: sel == -2,
              onTap: () => setState(() => _bottomTab = -2),
            ),
          ]),
        ),
        if (tab.running) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: body),
      ]),
    );
  }

  Widget _errorView(ResultTab r) {
    final c = DbColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: c.danger.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(Radii.panel),
            border: Border.all(color: c.danger.withValues(alpha: 0.3)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.error_outline_rounded, size: 18, color: c.danger),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('L\'istruzione non è stata eseguita',
                    style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.text)),
                const SizedBox(height: Gap.xs),
                SelectableText(r.error!, style: monoStyle(context, size: 12.5)),
                if (r.sql != null && AppScope.read(context).settings.aiEnabled) ...[
                  const SizedBox(height: Gap.md),
                  OutlinedButton.icon(
                    onPressed: () => _aiFix(r),
                    icon: const Icon(Icons.auto_awesome_outlined, size: 15),
                    label: const Text('Correggi con AI'),
                  ),
                ],
              ]),
            ),
            ToolButton(
              icon: Icons.content_copy_rounded,
              tooltip: 'Copia messaggio',
              onPressed: () => Clipboard.setData(ClipboardData(text: r.error!)),
            ),
          ]),
        ),
        if (r.sql != null) ...[
          const SectionLabel('Query', padding: EdgeInsets.only(top: Gap.lg, bottom: Gap.xs)),
          SelectableText(r.sql!, style: monoStyle(context, size: 12.5, color: c.textSecondary)),
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
              labelWidth: 150,
              entries: [for (final e in (r.stats ?? {'Messaggio': r.message ?? ''}).entries) (e.key, e.value)],
            ),
          ),
        ),
      );

  Widget _outputView() {
    final c = DbColors.of(context);
    if (tab.serverOutput.isEmpty) {
      return const EmptyState(
        icon: Icons.terminal_rounded,
        title: 'Nessun messaggio dal server',
        message: 'Qui compaiono PRINT, RAISE NOTICE e gli avvisi del driver.',
      );
    }
    return Column(children: [
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(onPressed: () => setState(tab.serverOutput.clear), child: const Text('Pulisci')),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          itemCount: tab.serverOutput.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: SelectableText(tab.serverOutput[i], style: monoStyle(context, size: 12.5, color: c.text)),
          ),
        ),
      ),
    ]);
  }

  Widget _logView() {
    final c = DbColors.of(context);
    final log = tab.log.reversed.toList();
    if (log.isEmpty) {
      return const EmptyState(icon: Icons.history_rounded, title: 'Nessuna esecuzione in questo editor');
    }
    String hms(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      itemCount: log.length,
      itemBuilder: (context, i) {
        final e = log[i];
        final (icon, color) = switch (e.level) {
          LogLevel.success => (Icons.check_circle_outline_rounded, c.success),
          LogLevel.error => (Icons.error_outline_rounded, c.danger),
          LogLevel.warning => (Icons.warning_amber_rounded, c.warning),
          LogLevel.info => (Icons.info_outline_rounded, c.textTertiary),
        };
        return InkWell(
          onTap: e.sql == null ? null : () => Clipboard.setData(ClipboardData(text: e.sql!)),
          child: Container(
            color: i.isOdd ? c.zebra : null,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(hms(e.time), style: monoStyle(context, size: 11.5, color: c.textTertiary)),
              const SizedBox(width: Gap.md),
              Icon(icon, color: color, size: 15),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.message, maxLines: 3, overflow: TextOverflow.ellipsis),
                  if (e.sql != null)
                    Text(
                      e.sql!.replaceAll(RegExp(r'\s+'), ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(context, size: 11.5, color: c.textSecondary),
                    ),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _ResultTabChip extends StatefulWidget {
  const _ResultTabChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.iconColor,
    this.onClose,
    this.badge,
  });

  final String label;
  final IconData icon;
  final Color? iconColor;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onClose;
  final String? badge;

  @override
  State<_ResultTabChip> createState() => _ResultTabChipState();
}

class _ResultTabChipState extends State<_ResultTabChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final sel = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onTertiaryTapUp: widget.onClose == null ? null : (_) => widget.onClose!(),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          decoration: BoxDecoration(
            color: sel ? c.content : (_hover ? c.hover : Colors.transparent),
            borderRadius: BorderRadius.circular(Radii.control),
            border: sel ? Border.all(color: c.separator) : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 13, color: widget.iconColor ?? (sel ? c.accent : c.textSecondary)),
            const SizedBox(width: 5),
            Text(widget.label,
                style: TextStyle(
                  fontSize: TypeSize.small,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                  color: sel ? c.text : c.textSecondary,
                )),
            if (widget.badge != null) ...[const SizedBox(width: 5), Badge2(widget.badge!)],
            if (widget.onClose != null && (_hover || sel)) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: widget.onClose,
                child: Icon(Icons.close_rounded, size: 12, color: c.textTertiary),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
