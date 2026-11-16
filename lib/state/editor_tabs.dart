import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';

import '../features/design/table_design.dart';
import '../features/design/view_design.dart';
import '../model/db_objects.dart';
import '../odbc/odbc_types.dart';
import '../services/script_session.dart';
import '../services/sql_dialect.dart';
import '../services/sql_splitter.dart';
import '../services/sql_variables.dart';
import '../services/storage.dart';
import 'db_connection.dart';
import 'result_set_model.dart';
import '../ui/editors/code_folding.dart';
import '../ui/theme/app_icons.dart';

int _tabSeq = 0;

/// Base class of the editors shown in the main tab area.
abstract class EditorTab extends ChangeNotifier {
  EditorTab() : id = 'tab${_tabSeq++}';
  final String id;
  String get title;
  IconData get icon;
  DbConnection? get connection;
  bool get isDirty => false;
  String get tooltip => title;

  void refresh() => notifyListeners();
}

/// Editor contributed by a feature module (query builder, compare tools,
/// debugger, dashboards, cloud files…): it builds its own view, so the home
/// page does not need to know the concrete type.
abstract class FeatureTab extends EditorTab {
  Widget buildView(BuildContext context);

  /// Return false to keep the tab open (e.g. unsaved work the user did not
  /// want to discard). Called before the tab is closed.
  Future<bool> canClose(BuildContext context) async => true;

  /// Label of File ▸ Salva (⌘S) for this editor; null: nothing to save.
  String? get saveLabel => null;

  /// Runs File ▸ Salva.
  Future<void> save(BuildContext context) async {}
}

// ---------------------------------------------------------------------------
// SQL editor
// ---------------------------------------------------------------------------

enum LogLevel { info, success, warning, error }

class LogEntry {
  LogEntry(this.level, this.message, {this.sql, this.durationMs});
  final DateTime time = DateTime.now();
  final LogLevel level;
  final String message;
  final String? sql;
  final int? durationMs;
}

/// A tab in the results area of a SQL editor.
class ResultTab {
  ResultTab({
    required this.title,
    this.model,
    this.message,
    this.error,
    this.sql,
    this.stats,
    this.params = const [],
    this.setup = const [],
    this.refreshable = true,
  });
  String title;
  final ResultSetModel? model;
  final String? message;
  final String? error;

  /// The text sent to the server (panel DECLAREs included).
  final String? sql;
  final Map<String, String>? stats;

  /// Values bound to [sql] and statements run before it: "Aggiorna" runs
  /// exactly the same again.
  final List<Object?> params;
  final List<String> setup;

  /// Running [sql] again only reads (false for a batch that changes data).
  final bool refreshable;
}

/// Callbacks used by the executor to interact with the UI.
abstract class ExecutionUi {
  Future<bool> ensureConnected(DbConnection c);
  Future<bool> confirm(String title, String message);

  /// Returns parameter values (by name) or null if the user cancelled.
  Future<Map<String, Object?>?> askParameters(List<String> names, Map<String, Object?> previous);
}

/// A SQL editor. Without [file] it is a draft: its text lives only in the
/// local buffer ([bufferId]) until the user saves it as a script. With a
/// file, the file changes only on an explicit save; the unsaved changes
/// live in the buffer meanwhile.
class SqlEditorTab extends EditorTab {
  SqlEditorTab({
    required this.settings,
    DbConnection? connection,
    String? catalog,
    this.file,
    String initialText = '',
    String? savedText,
    String? bufferId,
    this.draftName,
    this.suggestedFolder,
    List<ScriptVariable>? variables,
  }) : _connection = connection, // ignore: prefer_initializing_formals
       _catalog = catalog, // ignore: prefer_initializing_formals
       bufferId = bufferId ?? ScriptSession.newId(),
       variables = variables ?? [],
       controller = CodeLineEditingController.fromText(initialText) {
    _savedText = savedText ?? initialText;
    _bufferedText = initialText;
    _dirty = _computeDirty(initialText);
    controller.addListener(_onChanged);
  }

  final AppSettings settings;
  DbConnection? _connection;
  String? _catalog;

  /// The script file; null for a draft.
  File? file;

  /// Id of the local buffer holding the unsaved text.
  final String bufferId;

  /// Name of a draft ("Bozza 3").
  String? draftName;

  /// Library folder proposed when the draft is saved.
  String? suggestedFolder;
  final CodeLineEditingController controller;
  String _savedText = '';
  String _bufferedText = '';
  bool _dirty = false;
  Timer? _autosave;

  /// Writes the text to the buffer (autosave, 2 s after the last change).
  void Function(SqlEditorTab tab)? onBuffer;

  /// The file was written (bookkeeping: the buffer goes away).
  void Function(SqlEditorTab tab)? onSaved;

  /// Connection or database changed (remembered for the script).
  void Function(SqlEditorTab tab)? onBindingChanged;

  final List<ResultTab> results = [];
  int selectedResult = 0;
  final List<LogEntry> log = [];
  final List<String> serverOutput = [];
  bool running = false;
  String? runningSql;
  DateTime? runningSince;
  final Map<String, Object?> lastParams = {};
  bool _cancelRequested = false;

  // -------------------------------------------------------------------------
  // Variables
  // -------------------------------------------------------------------------

  /// Values of the Variabili panel (saved locally with the script).
  final List<ScriptVariable> variables;

  /// Changes of the variables, of their rows or of the panel visibility.
  final ValueNotifier<int> variablesTick = ValueNotifier(0);

  bool _showVariables = false;

  /// The Variabili panel is open.
  bool get showVariables => _showVariables;
  set showVariables(bool v) {
    if (v == _showVariables) return;
    _showVariables = v;
    variablesTick.value++;
  }

  /// Keys of the variables that stopped the last run (no or bad value).
  Set<String> blockedVariables = {};

  /// The last run was stopped by the variables: once they are all filled,
  /// Invio in the panel runs it.
  bool stoppedByVariables = false;

  /// Asks the panel to focus the first variable in [blockedVariables].
  int focusRequest = 0;

  Timer? _scanTimer;
  VariableScan _scan = VariableScan.empty;
  String? _scannedText;
  DbFamily? _scannedFamily;

  /// Family the variables follow (the connection's, also when offline).
  DbFamily? get family => _connection?.family;

  /// Variable syntax of the connection; null where there is none.
  VarSyntax? get varSyntax => _connection == null ? const VarSyntax() : VarSyntax.of(family);

  VariableScan get variableScan {
    _rescan();
    return _scan;
  }

  void _rescan() {
    final text = controller.text;
    final f = family;
    if (text == _scannedText && f == _scannedFamily) return;
    _scannedText = text;
    _scannedFamily = f;
    _scan = scanVariables(text, f, splitter: SqlSplitter(family: f));
  }

  /// The rows of the Variabili panel.
  List<VariableInfo> get variableRows {
    final syntax = varSyntax;
    if (syntax == null) return const [];
    return buildVariableRows(variableScan, variables, syntax);
  }

  /// Variables referenced without a value (badge of the toolbar button).
  int get variablesNeedingValue => variableRows.where((r) => r.needsValue).length;

  ScriptVariable? variable(String key) => variables.where((v) => v.key == key).firstOrNull;

  /// The panel variable [name], created when missing.
  ScriptVariable variableFor(String name) {
    final key = name.toLowerCase();
    final v = variable(key);
    if (v != null) return v;
    final n = ScriptVariable(name);
    variables.add(n);
    return n;
  }

  /// A panel variable changed: saved with the script.
  void variablesChanged() {
    blockedVariables.removeWhere((k) => variable(k)?.isUsable ?? false);
    variablesTick.value++;
    onBindingChanged?.call(this);
  }

  void removeVariable(String key) {
    variables.removeWhere((v) => v.key == key);
    variablesChanged();
  }

  /// Drops the panel variables the script no longer uses.
  void removeUnusedVariables() {
    final used = {for (final r in variableScan.refs) r.key};
    variables.removeWhere((v) => !used.contains(v.key));
    variablesChanged();
  }

  /// Writes [literal] as the initial value of the declaration [d] in the
  /// script (undoable; the script becomes modified).
  void writeDeclaredValue(VarDecl d, String literal) {
    final a = d.initStart, b = d.initEnd;
    if (a == null || b == null || !d.editable) return;
    final hasInit = d.init != null;
    highlight(SqlStatement('', a, b));
    controller.replaceSelection(hasInit ? literal : ' = $literal');
  }

  @override
  DbConnection? get connection => _connection;

  set connection(DbConnection? c) {
    if (c != _connection) _catalog = null;
    _connection = c;
    notifyListeners();
    variablesTick.value++;
    onBindingChanged?.call(this);
  }

  /// Database chosen for this editor; null = the connection default.
  /// A `USE xxx` run in the editor updates it.
  String? get catalog => _catalog ?? _connection?.defaultCatalog;

  /// The database chosen explicitly (null: the connection default).
  String? get explicitCatalog => _catalog;

  set catalog(String? v) {
    _catalog = v;
    notifyListeners();
    onBindingChanged?.call(this);
  }

  bool get isDraft => file == null;

  /// Name of the script or draft, without the connection.
  String get name => file == null ? (draftName ?? 'SQL') : p.basenameWithoutExtension(file!.path);

  @override
  String get title {
    final c = _connection == null ? '' : ' <${_connection!.config.name}>';
    return '$name$c';
  }

  @override
  IconData get icon => isDraft ? AppIcons.edit : AppIcons.document;

  /// A draft is "dirty" while it has some text (closing it asks), a script
  /// while its text differs from the file.
  @override
  bool get isDirty => _dirty;

  /// The text differs from the file (always false for a draft).
  bool get hasUnsavedChanges => file != null && controller.text != _savedText;

  @override
  String get tooltip => file?.path ?? '$name · bozza non salvata';

  bool _computeDirty(String t) => file == null ? t.trim().isNotEmpty : t != _savedText;

  /// The text not yet written to the buffer.
  bool get needsBuffer => controller.text != _bufferedText;

  /// The buffer now holds [text].
  void markBuffered(String text) => _bufferedText = text;

  void _onChanged() {
    final t = controller.text;
    final d = _computeDirty(t);
    if (d != _dirty) {
      _dirty = d;
      notifyListeners();
    }
    if (t != _bufferedText) {
      _autosave?.cancel();
      _autosave = Timer(const Duration(seconds: 2), () => onBuffer?.call(this));
    }
    if (t != _scannedText) {
      _scanTimer?.cancel();
      _scanTimer = Timer(const Duration(milliseconds: 350), () => variablesTick.value++);
    }
  }

  /// Writes the text to the file. A draft has no file: save it with
  /// [saveAs] (see the save sheet).
  Future<void> save() async {
    final f = file;
    if (f == null) return;
    final t = controller.text;
    await f.parent.create(recursive: true);
    await f.writeAsString(t);
    _savedText = t;
    _dirty = false;
    _autosave?.cancel();
    notifyListeners();
    onSaved?.call(this);
  }

  Future<void> saveAs(File f) async {
    file = f;
    draftName = null;
    await save();
  }

  /// The file was changed elsewhere (Git pull): take its [text] as saved.
  void reloadFrom(String text) {
    _savedText = text;
    _bufferedText = text;
    controller.text = text;
    _dirty = false;
    _autosave?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _scanTimer?.cancel();
    variablesTick.dispose();
    for (final r in results) {
      r.model?.close();
    }
    controller.removeListener(_onChanged);
    controller.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------

  /// Caret offset in the whole text (collapsed lines included).
  int get caretOffset => controller.scriptOffset(controller.selection.extentIndex, controller.selection.extentOffset);

  SqlSplitter get _splitter => SqlSplitter(blankLineDelimiter: settings.blankLineDelimiter, family: family);

  /// Statement under the caret, or the selection.
  SqlStatement? currentStatement() {
    final sel = controller.selectedText;
    if (sel.trim().isNotEmpty) {
      return SqlStatement(sel.trim(), 0, sel.length);
    }
    return _splitter.statementAt(controller.text, caretOffset);
  }

  /// Offset in the script where the selection starts.
  int get _selectionStart {
    final st = controller.selection.start;
    return controller.scriptOffset(st.index, st.offset);
  }

  /// Units to run (statements, or batches on SQL Server): those of the
  /// selection, or of the whole editor; with the offset of the selection.
  (List<SqlUnit>, int) unitsToRun() {
    final sel = controller.selectedText;
    if (sel.trim().isNotEmpty) return (_splitter.units(sel), _selectionStart);
    return (_splitter.units(controller.text), 0);
  }

  /// Texts of the [unitsToRun].
  List<String> statementsToRun() => unitsToRun().$1.map((e) => e.text).toList();

  /// Selects the given statement in the editor (visual feedback).
  void highlight(SqlStatement s) {
    final text = controller.text;
    CodeLinePosition pos(int offset) {
      var line = 0, col = 0;
      for (var i = 0; i < offset && i < text.length; i++) {
        if (text.codeUnitAt(i) == 10) {
          line++;
          col = 0;
        } else {
          col++;
        }
      }
      return CodeLinePosition(index: line, offset: col);
    }

    final a = pos(s.start), b = pos(s.end);
    // Selection indexes count the visible lines: show the collapsed ones in
    // the statement, then map the script lines.
    controller.expandScriptLines(a.index, b.index);
    final lines = controller.codeLines;
    controller.selection = CodeLineSelection(
      baseIndex: visibleLineIndex(lines, a.index),
      baseOffset: a.offset,
      extentIndex: visibleLineIndex(lines, b.index),
      extentOffset: b.offset,
    );
  }

  void addLog(LogLevel level, String message, {String? sql, int? durationMs}) {
    log.add(LogEntry(level, message, sql: sql, durationMs: durationMs));
    if (log.length > 2000) log.removeRange(0, log.length - 2000);
  }

  Future<void> _clearResults() async {
    for (final r in results) {
      await r.model?.close();
    }
    results.clear();
    selectedResult = 0;
  }

  void closeResult(int i) {
    if (i < 0 || i >= results.length) return;
    results[i].model?.close();
    results.removeAt(i);
    if (selectedResult >= results.length) selectedResult = results.isEmpty ? 0 : results.length - 1;
    notifyListeners();
  }

  void cancel() {
    _cancelRequested = true;
    _connection?.main?.cancel();
    addLog(LogLevel.warning, 'Annullamento richiesto');
    notifyListeners();
  }

  /// Runs the selection or, without one, the whole editor.
  Future<void> execute(ExecutionUi ui, {bool newTab = false}) async {
    final (units, base) = unitsToRun();
    if (units.isEmpty) return;
    await _run(ui, units, base: base, script: units.length > 1, newTab: newTab);
  }

  /// Runs only the statement under the caret (on SQL Server with the
  /// declarations of its batch it needs).
  Future<void> executeCurrent(ExecutionUi ui, {bool newTab = false}) async {
    final s = currentStatement();
    if (s == null) return;
    final selected = controller.selectedText.trim().isNotEmpty;
    if (!selected) highlight(s);
    final base = selected ? _selectionStart : 0;
    await _run(ui, [SqlUnit(s.text, s.start, s.end, [s])], base: base, script: false, newTab: newTab);
  }

  Future<void> explain(ExecutionUi ui) async {
    final s = currentStatement();
    final c = _connection;
    if (s == null || c == null) return;
    if (!await ui.ensureConnected(c)) return;
    final base = controller.selectedText.trim().isNotEmpty ? _selectionStart : 0;
    final units = [
      for (final t in c.dialect.explainStatements(s.text)) SqlUnit(t, s.start, s.end, [SqlStatement(t, s.start, s.end)]),
    ];
    await _run(ui, units, base: base, script: true, newTab: false, titlePrefix: 'Piano');
  }

  /// Runs [sql] as it is (no variables): refresh of a result.
  Future<void> executeRaw(
    ExecutionUi ui,
    String sql, {
    bool newTab = true,
    List<Object?> params = const [],
    List<String> setup = const [],
  }) => _run(ui, [SqlUnit.single(sql)], script: false, newTab: newTab, raw: (params: params, setup: setup));

  /// Rows read from each result set of a batch before moving on to the next
  /// one (the rest of the batch runs only once the earlier results are
  /// read).
  static const batchRowLimit = 10000;

  Future<void> _run(
    ExecutionUi ui,
    List<SqlUnit> units, {
    int base = 0,
    required bool script,
    required bool newTab,
    String? titlePrefix,
    ({List<Object?> params, List<String> setup})? raw,
  }) async {
    final c = _connection;
    if (c == null || running) return;
    if (!await ui.ensureConnected(c)) return;
    final session = c.main;
    if (session == null) return;
    final dialect = c.dialect;
    final allStatements = [for (final u in units) for (final s in u.statements) s.text];

    // Variables: every value must be there before anything runs.
    final syntax = VarSyntax.of(dialect.family);
    VariablePlan? plan;
    if (raw == null && syntax != null) {
      plan = prepareVariables(
        script: controller.text,
        units: units,
        textOf: (u) => stripLeadingComments(u.text),
        dialect: dialect,
        variables: variables,
        odbc: !c.config.isNative,
        scriptUnits: dialect.family == DbFamily.sqlServer ? _splitter.units(controller.text) : const [],
        base: base,
      );
      if (!plan.ready) {
        final rows = {for (final r in variableRows) r.key: r.display};
        String names(List<String> keys) => keys.map((k) => rows[k] ?? k).join(', ');
        blockedVariables = {...plan.missing, ...plan.invalid};
        stoppedByVariables = true;
        addLog(
          LogLevel.warning,
          [
            if (plan.missing.isNotEmpty) 'Variabili senza valore: ${names(plan.missing)}',
            if (plan.invalid.isNotEmpty) 'Valori non validi: ${names(plan.invalid)}',
          ].join(' · '),
        );
        _showVariables = true;
        focusRequest++;
        variablesTick.value++;
        notifyListeners();
        return;
      }
      blockedVariables = {};
    }
    stoppedByVariables = false;

    // ODBC read-only mode is only a hint that many drivers ignore.
    if (c.config.readOnly) {
      final blocked = allStatements.where(isModifyingSql).toList();
      if (blocked.isNotEmpty) {
        final msg =
            'La connessione "${c.config.name}" è in sola lettura: '
            'istruzioni che modificano dati o struttura non vengono eseguite.\n\n${blocked.first.trim()}';
        addLog(LogLevel.error, msg);
        if (!newTab) await _clearResults();
        results.add(ResultTab(title: 'Sola lettura', error: msg));
        selectedResult = results.length - 1;
        notifyListeners();
        return;
      }
    }

    // Safety confirmations
    if (c.config.type.confirmExecute && allStatements.any(isModifyingSql)) {
      final ok = await ui.confirm(
        'Connessione di produzione',
        'Stai per eseguire istruzioni che modificano i dati su "${c.config.name}" (${c.config.type.label}). Continuare?',
      );
      if (!ok) return;
    }
    if (settings.confirmDangerous) {
      final d = allStatements.where(isDangerousSql).toList();
      if (d.isNotEmpty) {
        final ok = await ui.confirm(
          'Istruzione pericolosa',
          'L\'istruzione seguente può modificare o eliminare molti dati:\n\n${d.first}\n\nEseguire comunque?',
        );
        if (!ok) return;
      }
    }

    running = true;
    _cancelRequested = false;
    runningSince = DateTime.now();
    if (!newTab) await _clearResults();
    notifyListeners();

    // The main session is shared by the editors of the connection: move it
    // to the database of this editor first.
    final cat = catalog;
    try {
      await c.useCatalog(cat);
    } catch (e) {
      final msg = 'Impossibile usare il database "$cat": ${e is OdbcException ? e.message : e}';
      addLog(LogLevel.error, msg);
      results.add(ResultTab(title: 'Errore', error: msg));
      selectedResult = results.length - 1;
      running = false;
      runningSince = null;
      notifyListeners();
      return;
    }

    final sw = Stopwatch()..start();
    var executed = 0, updated = 0, fetched = 0, errors = 0;
    final setup = raw?.setup ?? plan?.setup ?? const <String>[];
    try {
      if (plan != null && plan.used.isNotEmpty) {
        addLog(LogLevel.info, 'Variabili dal pannello: ${plan.used.join(', ')}');
      }
      if (plan != null && plan.carried.isNotEmpty) {
        addLog(LogLevel.info, 'Dichiarazioni riportate dal batch: ${plan.carried.join(', ')}');
      }
      // Session variables of the panel (MySQL, Snowflake).
      for (final st in setup) {
        try {
          await session.execute(st, queryTimeoutSec: c.config.queryTimeout);
          addLog(LogLevel.info, 'Variabili impostate', sql: st);
        } catch (e) {
          final msg = e is OdbcException ? e.message : e.toString();
          addLog(LogLevel.error, msg, sql: st);
          results.add(ResultTab(title: 'Errore', error: msg, sql: st));
          selectedResult = results.length - 1;
          errors++;
          return;
        }
      }
      for (var i = 0; i < units.length; i++) {
        if (_cancelRequested) break;
        final u = units[i];
        var sql = plan?.units[i].sql ?? stripLeadingComments(u.text);
        if (sql.isEmpty) continue;
        var params = <Object?>[...?plan?.units[i].params];
        if (raw != null) params = [...raw.params];
        // `?` markers: asked to the user (the stores without variables also
        // keep their `:name`).
        final asked = plan == null ? (raw == null ? _legacyParameters(sql) : null) : _positionalNames(plan.units[i]);
        if (asked != null && asked.names.isNotEmpty && sql.trimLeft().startsWith('{')) {
          // ODBC escapes ({? = CALL …}): their markers are not asked.
          if (plan != null) {
            final pos = plan.units[i].positional.toSet();
            params = [for (var k = 0; k < params.length; k++) if (!pos.contains(k)) params[k]];
          }
        } else if (asked != null && asked.names.isNotEmpty) {
          final values = await ui.askParameters(asked.names, lastParams);
          if (values == null) break;
          lastParams.addAll(values);
          if (plan == null) {
            final (positional, order) = toPositional(sql, asked.refs!);
            sql = positional;
            params = order.map((n) => values[n]).toList();
          } else {
            final pos = plan.units[i].positional;
            for (var k = 0; k < pos.length; k++) {
              params[pos[k]] = values['?${k + 1}'];
            }
          }
        }
        final modifying = u.statements.any((s) => isModifyingSql(s.text)) || isModifyingSql(sql);
        final drain = u.isBatch || u.repeat > 1;
        for (var rep = 0; rep < u.repeat && !_cancelRequested; rep++) {
          runningSql = sql;
          notifyListeners();
          final t0 = sw.elapsedMilliseconds;
          try {
            final page = await session.execute(
              sql,
              params: params,
              fetchSize: settings.fetchSize,
              queryTimeoutSec: c.config.queryTimeout,
            );
            executed++;
            final dur = sw.elapsedMilliseconds - t0;
            if (!page.isResultSet) {
              _pageMessages(page);
              _pageErrors(page, sql);
              errors += page.errors.length;
            }
            c.statementExecuted(modifying: modifying);
            if (page.isResultSet) {
              final tally = await _addResultSets(
                c,
                page,
                sql,
                params,
                titlePrefix,
                drain: drain,
                setup: setup,
                refreshable: !drain || !modifying,
              );
              fetched += tally.rows;
              errors += tally.errors;
              if (tally.affected > 0) updated += tally.affected;
              addLog(
                LogLevel.success,
                '${tally.rows}${tally.more ? '+' : ''} righe lette in $dur ms'
                '${tally.sets > 1 ? ' (${tally.sets} result set)' : ''}',
                sql: sql,
                durationMs: dur,
              );
            } else if (page.errors.isEmpty || page.rowsAffected >= 0) {
              final n = page.rowsAffected;
              if (n > 0) updated += n;
              final msg = n >= 0 ? 'Righe modificate: $n' : 'Istruzione eseguita';
              addLog(LogLevel.success, '$msg ($dur ms)', sql: sql, durationMs: dur);
              if (!script && page.errors.isEmpty) {
                results.add(
                  ResultTab(
                    title: 'Statistiche',
                    message: msg,
                    sql: sql,
                    stats: {
                      'Righe modificate': n >= 0 ? '$n' : '-',
                      'Durata': '$dur ms',
                      'Query': sql,
                      'Data': DateTime.now().toString(),
                    },
                  ),
                );
                selectedResult = results.length - 1;
              }
            }
          } catch (e) {
            errors++;
            final dur = sw.elapsedMilliseconds - t0;
            final msg = e is OdbcException ? e.message : e.toString();
            addLog(LogLevel.error, msg, sql: sql, durationMs: dur);
            results.add(ResultTab(title: 'Errore', error: msg, sql: sql));
            selectedResult = results.length - 1;
            if (script && i < units.length - 1) {
              final cont = await ui.confirm(
                'Errore nello script',
                '$msg\n\nContinuare con le istruzioni successive?',
              );
              if (!cont) {
                _cancelRequested = true;
                break;
              }
            }
            break; // the repetitions of a failed batch
          }
          notifyListeners();
        }
        notifyListeners();
      }
      if (script && units.length > 1) {
        results.add(
          ResultTab(
            title: 'Statistiche',
            stats: {
              'Query eseguite': '$executed / ${units.length}',
              'Righe modificate': '$updated',
              'Righe lette': '$fetched',
              'Errori': '$errors',
              'Durata totale': '${sw.elapsedMilliseconds} ms',
              'Data fine': DateTime.now().toString(),
            },
          ),
        );
        selectedResult = results.length - 1;
      }
    } finally {
      // Follow a `USE xxx` run by the script.
      final now = await c.syncMainCatalog();
      if (now != null && now != cat) {
        _catalog = now;
        onBindingChanged?.call(this);
      }
      running = false;
      runningSql = null;
      runningSince = null;
      notifyListeners();
    }
  }

  /// `:name` and `?` of [sql] asked with the dialog (stores without
  /// variables: MongoDB, Redis).
  static ({List<String> names, List<SqlParameterRef>? refs}) _legacyParameters(String sql) {
    final refs = findParameters(sql);
    final names = <String>[];
    for (final r in refs) {
      if (!names.contains(r.name)) names.add(r.name);
    }
    return (names: names, refs: refs);
  }

  /// The user's own `?` markers of a prepared unit.
  static ({List<String> names, List<SqlParameterRef>? refs}) _positionalNames(PreparedUnit u) =>
      (names: [for (var k = 0; k < u.positional.length; k++) '?${k + 1}'], refs: null);

  /// Server messages that came with [page] (PRINT, notices).
  void _pageMessages(ResultPage page) {
    if (page.messages.isEmpty) return;
    serverOutput.addAll(page.messages);
    for (final m in page.messages) {
      addLog(LogLevel.info, m);
    }
  }

  /// Errors that came with [page]: statements of a batch that failed without
  /// stopping it.
  void _pageErrors(ResultPage page, String sql) {
    for (final e in page.errors) {
      addLog(LogLevel.error, e, sql: sql);
      results.add(ResultTab(title: 'Errore', error: e, sql: sql));
      selectedResult = results.length - 1;
    }
  }

  /// Adds a tab for [page] and for each result set that follows it. In a
  /// batch ([drain]) every result set is read (up to [batchRowLimit] rows)
  /// so that the statements after it run too.
  Future<({int rows, bool more, int sets, int errors, int affected})> _addResultSets(
    DbConnection c,
    ResultPage page,
    String sql,
    List<Object?> params,
    String? titlePrefix, {
    bool drain = false,
    List<String> setup = const [],
    bool refreshable = true,
  }) async {
    ResultPage? p = page;
    var n = 0, rows = 0, errors = 0, affected = 0;
    var more = false;
    while (p != null) {
      _pageMessages(p);
      errors += p.errors.length;
      if (!p.isResultSet) {
        // What the batch did after its last result set.
        _pageErrors(p, sql);
        if (p.rowsAffected > 0) affected += p.rowsAffected;
        break;
      }
      final model = ResultSetModel(
        connection: c,
        first: p,
        sql: sql,
        fetchSize: settings.fetchSize,
        params: params,
        setup: setup,
        catalog: c.mainCatalog,
        resultSetIndex: n,
      );
      final tables = p.columns.map((e) => e.baseTable).toSet();
      final single = tables.length == 1 && tables.first != null ? tables.first : null;
      final base = titlePrefix ?? single ?? 'Risultati';
      results.add(
        ResultTab(
          title: n == 0 ? base : '$base (${n + 1})',
          model: model,
          sql: sql,
          params: params,
          setup: setup,
          refreshable: refreshable,
        ),
      );
      selectedResult = results.length - 1;
      _pageErrors(p, sql);
      unawaited(model.detectEditTarget());
      n++;
      if (drain && model.hasMore) {
        await model.fetchNext(count: batchRowLimit - model.rows.length);
        model.markTruncated();
        // A statement after these rows failed (or the fetch did).
        final e = model.error;
        if (e != null) {
          addLog(LogLevel.error, e, sql: sql);
          results.add(ResultTab(title: 'Errore', error: e, sql: sql));
          selectedResult = results.length - 1;
          errors++;
        }
      }
      rows += model.rows.length;
      more = more || model.hasMore;
      if (model.cursorId == null || (!drain && !model.hasNextResultSet)) break;
      try {
        p = await model.nextResultSet();
      } catch (e) {
        final msg = e is OdbcException ? e.message : e.toString();
        addLog(LogLevel.error, msg, sql: sql);
        results.add(ResultTab(title: 'Errore', error: msg, sql: sql));
        selectedResult = results.length - 1;
        errors++;
        break;
      }
    }
    return (rows: rows, more: more, sets: n, errors: errors, affected: affected);
  }
}

// ---------------------------------------------------------------------------
// Object editors
// ---------------------------------------------------------------------------

class TableEditorTab extends EditorTab {
  TableEditorTab(this._connection, this.table, {this.initialPage = 0});

  /// Designer of a new table in [catalog].[schema] ([design] starts from
  /// [template] when given: "Duplica struttura").
  TableEditorTab.create(this._connection, {String? catalog, String? schema, TableDesign? template})
    : table = DbTable(catalog: catalog, schema: schema, name: '', type: 'TABLE'),
      initialPage = 0,
      design = template ?? TableDesign.create(_connection.dialect, catalog: catalog, schema: schema);

  /// Editor of a new view in [catalog].[schema] (from [definition]: "Crea
  /// vista dalla query").
  TableEditorTab.createView(this._connection, {String? catalog, String? schema, String? definition})
    : table = DbTable(catalog: catalog, schema: schema, name: '', type: 'VIEW'),
      initialPage = 8,
      viewDesign = ViewDesign.create(_connection.dialect, catalog: catalog, schema: schema, definition: definition);

  final DbConnection _connection;

  /// The table; it changes when the designer renames or creates it.
  DbTable table;
  int initialPage;

  /// Table designer session (structure changes not yet applied).
  TableDesign? design;

  /// View editor session (definition changes not yet applied).
  ViewDesign? viewDesign;

  /// The table or view does not exist yet in the database.
  bool get isNew => design?.isNew ?? viewDesign?.isNew ?? false;

  /// Data tab state survives switching editor tabs.
  ResultSetModel? data;
  String dataFilter = '';
  String dataOrder = '';

  @override
  DbConnection get connection => _connection;
  @override
  String get title {
    if (!isNew) return table.name;
    final n = design?.working.name ?? viewDesign!.working.name;
    return n.isEmpty ? (viewDesign != null ? 'Nuova vista' : 'Nuova tabella') : n;
  }

  @override
  String get tooltip => isNew ? '${_connection.config.name}: $title (non salvata)' : '${_connection.config.name}: ${table.displayPath}';
  @override
  IconData get icon => table.isView ? AppIcons.erDiagram : AppIcons.table;

  /// Unsaved data edits.
  bool get dataDirty => data?.isDirty ?? false;

  /// Unsaved structure edits (or a table not created yet).
  bool get designDirty => (design?.isDirty ?? false) || (viewDesign?.isDirty ?? false);

  @override
  bool get isDirty => dataDirty || designDirty;

  @override
  void dispose() {
    data?.close();
    design?.dispose();
    viewDesign?.dispose();
    super.dispose();
  }
}

class ProcedureEditorTab extends EditorTab {
  ProcedureEditorTab(this._connection, this.procedure);
  final DbConnection _connection;
  final DbProcedure procedure;
  @override
  DbConnection get connection => _connection;
  @override
  String get title => procedure.cleanName;
  @override
  IconData get icon => AppIcons.function;
}

class ErDiagramTab extends EditorTab {
  ErDiagramTab(this._connection, this.catalog, this.schema, {this.focus});
  final DbConnection _connection;
  final String? catalog;
  final String? schema;
  final DbTable? focus;
  final Map<String, Offset> positions = {};
  @override
  DbConnection get connection => _connection;
  @override
  String get title => 'ER ${focus?.name ?? schema ?? catalog ?? _connection.config.name}';
  @override
  IconData get icon => AppIcons.tree;
}

class ConnectionInfoTab extends EditorTab {
  ConnectionInfoTab(this._connection);
  final DbConnection _connection;
  @override
  DbConnection get connection => _connection;
  @override
  String get title => _connection.config.name;
  @override
  IconData get icon => AppIcons.info;
}
