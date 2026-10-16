// Assistant entry points: explain a query or an object, fix a failed
// statement, generate SQL from natural language.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/result_set_model.dart';
import '../../ui/actions.dart';
import '../../ui/widgets/common.dart';
import 'ai_chat.dart';
import 'ai_context.dart';
import 'ai_service.dart';
import 'ai_settings.dart';
import 'ai_widgets.dart';
import 'claude_client.dart';

String _subtitle(AppState app, DbConnection? dc) {
  final conn = dc == null ? 'Nessuna connessione' : dc.config.name;
  return '$conn · ${app.settings.aiModel}';
}

Future<AiDbContext> _context(AppState app, DbConnection? dc, {String? sql, List<DbTable> extra = const []}) =>
    AiDbContext.build(dc, includeSchema: app.settings.aiIncludeSchema, sql: sql, extraTables: extra);

// ---------------------------------------------------------------------------
// Explain
// ---------------------------------------------------------------------------

/// Explains [sql] (streamed Markdown). With [sample] the user can choose to
/// share the first rows of the result (off by default).
Future<void> showAiExplainQuery(BuildContext context, DbConnection? dc, String sql, {ResultSetModel? sample}) async {
  if (sql.trim().isEmpty) {
    showToast(context, 'Scrivi o seleziona una query da spiegare', error: true);
    return;
  }
  if (!await ensureAiReady(context) || !context.mounted) return;
  final app = AppScope.read(context);
  final rows = AiPrefs.of(app).sampleRows;
  await showSheet<void>(
    context,
    size: SheetSize.large,
    builder: (_) => _ExplainDialog(
      title: 'Spiegazione della query',
      subtitle: _subtitle(app, dc),
      connection: dc,
      preview: sql,
      sampleLabel: sample == null || sample.rows.isEmpty ? null : 'Includi le prime $rows righe del risultato',
      build: (includeSample) async {
        final ctx = await _context(app, dc, sql: sql);
        final fence = queryLanguage(ctx.family).$2;
        AiDataSample? data;
        if (includeSample && sample != null) {
          data = AiDataSample(
            [for (final c in sample.columns) c.name],
            [
              for (final r in sample.rows.take(rows))
                [for (final v in r.values) formatValue(v, nullText: 'NULL', maxLen: 200)],
            ],
          );
        }
        return (buildSystem(AiTask.explainQuery, ctx), explainQueryPrompt(sql, fence, sample: data));
      },
    ),
  );
}

/// Explains a table or view from its DDL, keys, relations and indexes.
Future<void> showAiExplainObject(BuildContext context, DbConnection dc, DbTable table) async {
  if (!await ensureAiReady(context) || !context.mounted) return;
  if (!await ensureConnected(context, dc) || !context.mounted) return;
  final app = AppScope.read(context);
  await showSheet<void>(
    context,
    size: SheetSize.large,
    builder: (_) => _ExplainDialog(
      title: 'Spiegazione di ${table.name}',
      subtitle: _subtitle(app, dc),
      connection: dc,
      build: (_) async {
        final md = dc.metadata;
        if (md == null) throw AiException('La connessione non è attiva.');
        final d = await md.tableDetails(table);
        final ddl = dc.dialect.ddl(d);
        final sb = StringBuffer('Spiega questo oggetto del database: ${table.displayPath} (${table.type}).\n\n');
        sb.writeln(fenced(ddl, 'sql'));
        if (table.remarks != null && table.remarks!.trim().isNotEmpty) sb.writeln('\nCommento: ${table.remarks}');
        if (d.referencedBy.isNotEmpty) {
          sb.writeln('\nTabelle che la referenziano:');
          for (final fk in d.referencedBy) {
            sb.writeln('- ${fk.fkTable}(${fk.columns.join(', ')}) → (${fk.refColumns.join(', ')})');
          }
        }
        if (d.indexes.isNotEmpty) {
          sb.writeln('\nIndici:');
          for (final ix in d.indexes) {
            sb.writeln('- ${ix.name}${ix.unique ? ' UNIQUE' : ''} ${ix.typeName} (${ix.columns.join(', ')})');
          }
        }
        // Context: the object plus the tables it is related to.
        final ctx = await _context(app, dc, sql: ddl, extra: [table]);
        return (buildSystem(AiTask.explainObject, ctx), sb.toString());
      },
    ),
  );
}

/// Explains a procedure / function from its parameters and, when
/// available, its [source].
Future<void> showAiExplainProcedure(BuildContext context, DbConnection dc, DbProcedure proc, {String? source}) async {
  if (!await ensureAiReady(context) || !context.mounted) return;
  if (!await ensureConnected(context, dc) || !context.mounted) return;
  final app = AppScope.read(context);
  await showSheet<void>(
    context,
    size: SheetSize.large,
    builder: (_) => _ExplainDialog(
      title: 'Spiegazione di ${proc.cleanName}',
      subtitle: _subtitle(app, dc),
      connection: dc,
      preview: source,
      build: (_) async {
        final md = dc.metadata;
        if (md == null) throw AiException('La connessione non è attiva.');
        final params = await md.procedureParams(proc);
        final path = [proc.catalog, proc.schema, proc.cleanName].where((e) => e != null && e.isNotEmpty).join('.');
        final sb = StringBuffer('Spiega questa ${proc.kindLabel.toLowerCase()}: $path.\n');
        if (proc.remarks != null && proc.remarks!.trim().isNotEmpty) sb.writeln('Commento: ${proc.remarks}');
        if (params.isEmpty) {
          sb.writeln('\nNessun parametro.');
        } else {
          sb.writeln('\nParametri:');
          for (final p in params) {
            sb.writeln(
              '- ${p.name.isEmpty ? '(valore restituito)' : p.name} ${p.modeLabel} ${p.typeName}'
              '${p.size != null && p.size! > 0 ? '(${p.size})' : ''}',
            );
          }
        }
        if (source != null && source.trim().isNotEmpty) sb.writeln('\nCodice sorgente:\n\n${fenced(source, 'sql')}');
        sb.writeln('\nSpiega cosa fa, come si chiama (con un esempio) e i possibili effetti collaterali.');
        final ctx = await _context(app, dc, sql: source ?? '');
        return (buildSystem(AiTask.explainObject, ctx), sb.toString());
      },
    ),
  );
}

typedef _Build = Future<(List<AiSystemBlock>, String)> Function(bool includeSample);

class _ExplainDialog extends StatefulWidget {
  const _ExplainDialog({
    required this.title,
    required this.subtitle,
    required this.connection,
    required this.build,
    this.preview,
    this.sampleLabel,
  });

  final String title;
  final String subtitle;
  final DbConnection? connection;
  final String? preview;
  final String? sampleLabel;
  final _Build build;

  @override
  State<_ExplainDialog> createState() => _ExplainDialogState();
}

class _ExplainDialogState extends State<_ExplainDialog> {
  late final AppState app = AppScope.read(context);
  late final AiRun _run = AiRun(app)..addListener(_changed);
  bool _includeSample = false;
  List<AiSystemBlock> _system = const [];
  String _prompt = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _run.removeListener(_changed);
    _run.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _start() {
    _run.start(() async {
      final (system, prompt) = await widget.build(_includeSample);
      _system = system;
      _prompt = prompt;
      return AiRequest.single(system, prompt);
    });
  }

  /// Opens the chat with this exchange so that the user can ask more.
  void _continueInChat() {
    final r = _run.response;
    if (r == null) return;
    final tab = AiChatTab(widget.connection)..seed(_system, _prompt, widget.title, r);
    app.openFeatureTab(tab);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final r = _run.response;
    final done = _run.state == AiRunState.done && r != null && !r.refused;
    return SheetScaffold(
      title: widget.title,
      subtitle: widget.subtitle,
      padding: EdgeInsets.zero,
      onSubmit: () => Navigator.pop(context),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          if (widget.preview != null && widget.preview!.trim().isNotEmpty) ...[
            CodeBox(widget.preview!.trim(), maxLines: 6, color: DbColors.of(context).textSecondary),
            const SizedBox(height: Gap.lg),
          ],
          AiAnswerView(
            run: _run,
            onRetry: _start,
            codeActions: editorCodeActions(app, widget.connection, before: () => Navigator.pop(context)),
          ),
        ],
      ),
      leading: [
        if (widget.sampleLabel != null) ...[
          CheckboxRow(
            value: _includeSample,
            label: widget.sampleLabel!,
            onChanged: _run.busy ? null : (v) => setState(() => _includeSample = v),
          ),
          ToolButton(
            icon: AppIcons.refresh,
            tooltip: 'Rigenera la spiegazione',
            onPressed: _run.busy ? null : _start,
          ),
        ],
      ],
      actions: [
        PushButton(
          label: 'Copia',
          onPressed: done ? () => Clipboard.setData(ClipboardData(text: _run.text)) : null,
        ),
        PushButton(label: 'Continua in chat', onPressed: done ? _continueInChat : null),
        PushButton.primary(label: 'Chiudi', onPressed: () => Navigator.pop(context)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Fix
// ---------------------------------------------------------------------------

/// Asks Claude to fix [sql] that failed with [errorMessage]. Returns the
/// corrected statement when the user chooses "Sostituisci nell'editor".
Future<String?> showAiFixQuery(BuildContext context, DbConnection? dc, String sql, String errorMessage) async {
  if (sql.trim().isEmpty) return null;
  if (!await ensureAiReady(context) || !context.mounted) return null;
  return showSheet<String>(
    context,
    size: SheetSize.large,
    builder: (_) => _FixDialog(connection: dc, sql: sql, error: errorMessage),
  );
}

class _FixDialog extends StatefulWidget {
  const _FixDialog({required this.connection, required this.sql, required this.error});
  final DbConnection? connection;
  final String sql;
  final String error;

  @override
  State<_FixDialog> createState() => _FixDialogState();
}

class _FixDialogState extends State<_FixDialog> {
  late final AppState app = AppScope.read(context);
  late final AiRun _run = AiRun(app)..addListener(_changed);
  String _fence = 'sql';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _run.removeListener(_changed);
    _run.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _start() {
    _run.start(() async {
      final ctx = await _context(app, widget.connection, sql: widget.sql);
      _fence = queryLanguage(ctx.family).$2;
      return AiRequest.single(buildSystem(AiTask.fixQuery, ctx), fixQueryPrompt(widget.sql, widget.error, _fence));
    });
  }

  /// The corrected statement, only from a complete, accepted answer.
  String? get _fixed {
    final r = _run.response;
    if (_run.state != AiRunState.done || r == null || r.refused || r.truncated) return null;
    return pickQuery(r.text, preferred: _fence);
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final fixed = _fixed;
    final done = _run.state == AiRunState.done;
    final unchanged = fixed != null && fixed.trim() == widget.sql.trim();
    final apply = fixed == null || unchanged ? null : () => Navigator.pop(context, fixed);
    return SheetScaffold(
      title: 'Correggi con AI',
      subtitle: _subtitle(app, widget.connection),
      padding: EdgeInsets.zero,
      onSubmit: apply,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          aiNotice(widget.error.trim()),
          const SizedBox(height: Gap.lg),
          if (!done || fixed == null) ...[
            CodeBox(widget.sql.trim(), label: 'Istruzione originale', maxLines: 6, color: c.textSecondary),
            const SizedBox(height: Gap.lg),
          ],
          AiAnswerView(
            run: _run,
            onRetry: _start,
            markdown: done && fixed != null ? stripCodeBlocks(_run.text) : null,
          ),
          if (fixed != null) ...[
            const SizedBox(height: Gap.lg),
            SectionLabel(
              unchanged ? 'Nessuna modifica proposta' : 'Modifiche proposte',
              padding: const EdgeInsets.only(bottom: Gap.xs),
            ),
            DiffView(lines: diffLines(widget.sql.trim(), fixed.trim()), shrinkWrap: true),
          ] else if (done && _run.response != null && !_run.response!.refused && !_run.response!.truncated) ...[
            const SizedBox(height: Gap.md),
            Text(
              'La risposta non contiene un\'istruzione corretta da applicare.',
              style: uiText(TypeSize.body, color: c.textSecondary),
            ),
          ],
        ],
      ),
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton(
          label: 'Copia',
          onPressed: fixed == null ? null : () => Clipboard.setData(ClipboardData(text: fixed)),
        ),
        PushButton.primary(
          label: 'Sostituisci nell\'editor',
          tooltip: 'Sostituisce l\'istruzione nell\'editor (Invio)',
          onPressed: apply,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Generate
// ---------------------------------------------------------------------------

/// Natural language → query for the connection's dialect (MongoDB shell,
/// Redis commands or CQL for those stores). Returns the code to insert.
Future<String?> showAiGenerateSql(BuildContext context, DbConnection? dc, {String? currentSql}) async {
  if (!await ensureAiReady(context) || !context.mounted) return null;
  return showSheet<String>(
    context,
    size: SheetSize.large,
    builder: (_) => _GenerateDialog(connection: dc, currentSql: currentSql),
  );
}

class _GenerateDialog extends StatefulWidget {
  const _GenerateDialog({required this.connection, this.currentSql});
  final DbConnection? connection;
  final String? currentSql;

  @override
  State<_GenerateDialog> createState() => _GenerateDialogState();
}

class _GenerateDialogState extends State<_GenerateDialog> {
  late final AppState app = AppScope.read(context);
  late final AiRun _run = AiRun(app)..addListener(_changed);
  final _prompt = TextEditingController();
  final _focus = FocusNode();
  late bool _useCurrent = (widget.currentSql ?? '').trim().isNotEmpty;
  String _fence = 'sql';

  @override
  void dispose() {
    _run.removeListener(_changed);
    _run.dispose();
    _prompt.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _generate() {
    final text = _prompt.text.trim();
    if (text.isEmpty || _run.busy) return;
    _run.start(() async {
      final current = _useCurrent ? widget.currentSql : null;
      final ctx = await _context(app, widget.connection, sql: current);
      _fence = queryLanguage(ctx.family).$2;
      return AiRequest.single(
        buildSystem(AiTask.generate, ctx),
        generatePrompt(text, currentSql: current, fence: _fence),
      );
    });
  }

  String? get _code {
    final r = _run.response;
    if (_run.state != AiRunState.done || r == null || r.refused) return null;
    return pickQuery(r.text, preferred: _fence);
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final mac = Platform.isMacOS;
    final family = dialectOf(widget.connection).family;
    final target = queryLanguage(family).$1.replaceAll(' commands', '').replaceAll(', one per line', '');
    return SheetScaffold(
      title: 'Genera query',
      subtitle: _subtitle(app, widget.connection),
      padding: EdgeInsets.zero,
      onSubmit: code == null ? _generate : () => Navigator.pop(context, code),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          CallbackShortcuts(
            bindings: {SingleActivator(LogicalKeyboardKey.enter, meta: mac, control: !mac): _generate},
            child: MacTextField(
              controller: _prompt,
              focusNode: _focus,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              hint:
                  'Descrivi i dati che vuoi ottenere, ad esempio: i 10 clienti con il fatturato più alto '
                  'nel 2025, con il numero di ordini',
              onChanged: (_) => setState(() {}),
            ),
          ),
          FieldMessage(
            'Linguaggio: $target${widget.connection == null ? '' : ' · ${widget.connection!.config.name}'} · '
            '${shortcutLabel(SingleActivator(LogicalKeyboardKey.enter, meta: mac, control: !mac))} per generare',
          ),
          const SizedBox(height: Gap.lg),
          if (_run.state != AiRunState.idle) AiAnswerView(run: _run, onRetry: _generate),
        ],
      ),
      leading: [
        if ((widget.currentSql ?? '').trim().isNotEmpty)
          CheckboxRow(
            value: _useCurrent,
            label: 'Usa la query dell\'editor come contesto',
            onChanged: (v) => setState(() => _useCurrent = v),
          ),
      ],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        if (code == null)
          PushButton.primary(
            label: _run.busy ? 'Generazione…' : 'Genera',
            onPressed: _run.busy || _prompt.text.trim().isEmpty ? null : _generate,
          )
        else ...[
          PushButton(label: 'Rigenera', onPressed: _generate),
          PushButton(
            label: 'Copia',
            onPressed: () => Clipboard.setData(ClipboardData(text: code)),
          ),
          PushButton.primary(label: 'Inserisci nell\'editor', onPressed: () => Navigator.pop(context, code)),
        ],
      ],
    );
  }
}
