import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../features/design/table_design.dart';
import '../features/design/view_design.dart';
import '../model/db_objects.dart';
import '../odbc/odbc_types.dart';
import '../services/sql_splitter.dart';
import '../services/storage.dart';
import 'db_connection.dart';
import 'result_set_model.dart';
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
  ResultTab({required this.title, this.model, this.message, this.error, this.sql, this.stats});
  String title;
  final ResultSetModel? model;
  final String? message;
  final String? error;
  final String? sql;
  final Map<String, String>? stats;
}

/// Callbacks used by the executor to interact with the UI.
abstract class ExecutionUi {
  Future<bool> ensureConnected(DbConnection c);
  Future<bool> confirm(String title, String message);

  /// Returns parameter values (by name) or null if the user cancelled.
  Future<Map<String, Object?>?> askParameters(List<String> names, Map<String, Object?> previous);
}

class SqlEditorTab extends EditorTab {
  SqlEditorTab({
    required this.settings,
    DbConnection? connection,
    String? catalog,
    this.file,
    String initialText = '',
  }) : _connection = connection, // ignore: prefer_initializing_formals
       _catalog = catalog, // ignore: prefer_initializing_formals
       controller = CodeLineEditingController.fromText(initialText) {
    _savedText = initialText;
    controller.addListener(_onChanged);
  }

  final AppSettings settings;
  DbConnection? _connection;
  String? _catalog;
  File? file;
  final CodeLineEditingController controller;
  String _savedText = '';
  bool _dirty = false;
  Timer? _autosave;

  final List<ResultTab> results = [];
  int selectedResult = 0;
  final List<LogEntry> log = [];
  final List<String> serverOutput = [];
  bool running = false;
  String? runningSql;
  DateTime? runningSince;
  final Map<String, Object?> lastParams = {};
  bool _cancelRequested = false;

  @override
  DbConnection? get connection => _connection;

  set connection(DbConnection? c) {
    if (c != _connection) _catalog = null;
    _connection = c;
    notifyListeners();
  }

  /// Database chosen for this editor; null = the connection default.
  /// A `USE xxx` run in the editor updates it.
  String? get catalog => _catalog ?? _connection?.defaultCatalog;

  set catalog(String? v) {
    _catalog = v;
    notifyListeners();
  }

  @override
  String get title {
    final f = file;
    final name = f == null ? 'SQL' : f.uri.pathSegments.last.replaceAll('.sql', '');
    final c = _connection == null ? '' : ' <${_connection!.config.name}>';
    return '$name$c';
  }

  @override
  IconData get icon => AppIcons.document;

  @override
  bool get isDirty => _dirty;

  @override
  String get tooltip => file?.path ?? title;

  void _onChanged() {
    final t = controller.text;
    final d = t != _savedText;
    if (d != _dirty) {
      _dirty = d;
      notifyListeners();
    }
    if (_dirty && file != null) {
      _autosave?.cancel();
      _autosave = Timer(const Duration(seconds: 2), save);
    }
  }

  Future<void> save() async {
    final f = file;
    if (f == null) return;
    final t = controller.text;
    await f.writeAsString(t);
    _savedText = t;
    _dirty = false;
    notifyListeners();
  }

  Future<void> saveAs(File f) async {
    file = f;
    await save();
  }

  @override
  void dispose() {
    _autosave?.cancel();
    if (_dirty && file != null) {
      file!.writeAsStringSync(controller.text);
    }
    for (final r in results) {
      r.model?.close();
    }
    controller.removeListener(_onChanged);
    controller.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------

  int get caretOffset {
    final sel = controller.selection;
    final lines = controller.codeLines;
    var off = 0;
    for (var i = 0; i < sel.extentIndex && i < lines.length; i++) {
      off += lines[i].text.length + 1;
    }
    return off + sel.extentOffset;
  }

  SqlSplitter get _splitter => SqlSplitter(blankLineDelimiter: settings.blankLineDelimiter);

  /// Statement under the caret, or the selection.
  SqlStatement? currentStatement() {
    final sel = controller.selectedText;
    if (sel.trim().isNotEmpty) {
      return SqlStatement(sel.trim(), 0, sel.length);
    }
    return _splitter.statementAt(controller.text, caretOffset);
  }

  /// Statements to run: those of the selection, or of the whole editor.
  List<String> statementsToRun() {
    final sel = controller.selectedText;
    final src = sel.trim().isNotEmpty ? sel : controller.text;
    return _splitter.split(src).map((e) => e.text).toList();
  }

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
    controller.selection = CodeLineSelection(
      baseIndex: a.index,
      baseOffset: a.offset,
      extentIndex: b.index,
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
    final stmts = statementsToRun();
    if (stmts.isEmpty) return;
    await _run(ui, stmts, script: stmts.length > 1, newTab: newTab);
  }

  /// Runs only the statement under the caret.
  Future<void> executeCurrent(ExecutionUi ui, {bool newTab = false}) async {
    final s = currentStatement();
    if (s == null) return;
    if (controller.selectedText.trim().isEmpty) highlight(s);
    await _run(ui, [s.text], script: false, newTab: newTab);
  }

  Future<void> explain(ExecutionUi ui) async {
    final s = currentStatement();
    final c = _connection;
    if (s == null || c == null) return;
    if (!await ui.ensureConnected(c)) return;
    final stmts = c.dialect.explainStatements(s.text);
    await _run(ui, stmts, script: true, newTab: false, titlePrefix: 'Piano');
  }

  Future<void> executeRaw(ExecutionUi ui, String sql, {bool newTab = true}) =>
      _run(ui, [sql], script: false, newTab: newTab);

  Future<void> _run(
    ExecutionUi ui,
    List<String> statements, {
    required bool script,
    required bool newTab,
    String? titlePrefix,
  }) async {
    final c = _connection;
    if (c == null || running) return;
    if (!await ui.ensureConnected(c)) return;
    final session = c.main;
    if (session == null) return;

    // ODBC read-only mode is only a hint that many drivers ignore.
    if (c.config.readOnly) {
      final blocked = statements.where(isModifyingSql).toList();
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
    if (c.config.type.confirmExecute && statements.any(isModifyingSql)) {
      final ok = await ui.confirm(
        'Connessione di produzione',
        'Stai per eseguire istruzioni che modificano i dati su "${c.config.name}" (${c.config.type.label}). Continuare?',
      );
      if (!ok) return;
    }
    if (settings.confirmDangerous) {
      final d = statements.where(isDangerousSql).toList();
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
    try {
      for (var i = 0; i < statements.length; i++) {
        if (_cancelRequested) break;
        var sql = stripLeadingComments(statements[i]);
        if (sql.isEmpty) continue;
        // Parameters
        var params = <Object?>[];
        final refs = findParameters(sql);
        if (refs.isNotEmpty && !sql.trimLeft().startsWith('{')) {
          final names = <String>[];
          for (final r in refs) {
            if (!names.contains(r.name)) names.add(r.name);
          }
          final values = await ui.askParameters(names, lastParams);
          if (values == null) break;
          lastParams.addAll(values);
          final (positional, order) = toPositional(sql, refs);
          sql = positional;
          params = order.map((n) => values[n]).toList();
        }
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
          if (page.messages.isNotEmpty) {
            serverOutput.addAll(page.messages);
            for (final m in page.messages) {
              addLog(LogLevel.info, m);
            }
          }
          c.statementExecuted(modifying: isModifyingSql(sql));
          if (page.isResultSet) {
            fetched += page.rows.length;
            await _addResultSets(c, page, sql, params, titlePrefix);
            addLog(
              LogLevel.success,
              '${page.rows.length}${page.hasMore ? '+' : ''} righe lette in $dur ms',
              sql: sql,
              durationMs: dur,
            );
          } else {
            final n = page.rowsAffected;
            if (n > 0) updated += n;
            final msg = n >= 0 ? 'Righe modificate: $n' : 'Istruzione eseguita';
            addLog(LogLevel.success, '$msg ($dur ms)', sql: sql, durationMs: dur);
            if (!script) {
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
          if (script && i < statements.length - 1) {
            final cont = await ui.confirm(
              'Errore nello script',
              '$msg\n\nContinuare con le istruzioni successive?',
            );
            if (!cont) break;
          }
        }
        notifyListeners();
      }
      if (script && statements.length > 1) {
        results.add(
          ResultTab(
            title: 'Statistiche',
            stats: {
              'Query eseguite': '$executed / ${statements.length}',
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
      if (now != null && now != cat) _catalog = now;
      running = false;
      runningSql = null;
      runningSince = null;
      notifyListeners();
    }
  }

  Future<void> _addResultSets(
    DbConnection c,
    ResultPage page,
    String sql,
    List<Object?> params,
    String? titlePrefix,
  ) async {
    ResultPage? p = page;
    var n = 0;
    while (p != null && p.isResultSet) {
      final model = ResultSetModel(
        connection: c,
        first: p,
        sql: sql,
        fetchSize: settings.fetchSize,
        params: params,
      );
      final tables = p.columns.map((e) => e.baseTable).toSet();
      final single = tables.length == 1 && tables.first != null ? tables.first : null;
      final base = titlePrefix ?? single ?? 'Risultati';
      results.add(ResultTab(title: n == 0 ? base : '$base (${n + 1})', model: model, sql: sql));
      selectedResult = results.length - 1;
      unawaited(model.detectEditTarget());
      n++;
      if (p.hasNextResultSet) {
        p = await model.nextResultSet();
      } else {
        p = null;
      }
    }
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
