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
  await showDialog<void>(
    context: context,
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
  await showDialog<void>(
    context: context,
    builder: (_) => _ExplainDialog(
      title: 'Spiegazione di ${table.name}',
      subtitle: _subtitle(app, dc),
      connection: dc,
      icon: table.isView ? AppIcons.erDiagram : AppIcons.table,
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
  await showDialog<void>(
    context: context,
    builder: (_) => _ExplainDialog(
      title: 'Spiegazione di ${proc.cleanName}',
      subtitle: _subtitle(app, dc),
      connection: dc,
      icon: AppIcons.function,
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
    this.icon = AppIcons.ai,
  });

  final String title;
  final String subtitle;
  final DbConnection? connection;
  final String? preview;
  final String? sampleLabel;
  final IconData icon;
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
    return AiSheet(
      title: widget.title,
      subtitle: widget.subtitle,
      icon: widget.icon,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.xl),
        children: [
          if (widget.preview != null && widget.preview!.trim().isNotEmpty) ...[
            AiCodePreview(widget.preview!, maxLines: 6),
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
          Checkbox(
            value: _includeSample,
            visualDensity: VisualDensity.compact,
            onChanged: _run.busy ? null : (v) => setState(() => _includeSample = v ?? false),
          ),
          Text(widget.sampleLabel!, style: const TextStyle(fontSize: TypeSize.small + 0.5)),
          const SizedBox(width: Gap.sm),
          ToolButton(
            icon: AppIcons.refresh,
            tooltip: 'Rigenera la spiegazione',
            onPressed: _run.busy ? null : _start,
          ),
        ],
      ],
      actions: [
        OutlinedButton(
          onPressed: done ? () => Clipboard.setData(ClipboardData(text: _run.text)) : null,
          child: const Text('Copia'),
        ),
        OutlinedButton(onPressed: done ? _continueInChat : null, child: const Text('Continua in chat')),
        PrimaryButton(label: 'Chiudi', onPressed: () => Navigator.pop(context)),
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
  return showDialog<String>(
    context: context,
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

  Widget _diff(String fixed) {
    final c = DbColors.of(context);
    final lines = diffLines(widget.sql.trim(), fixed.trim());
    final style = monoStyle(context, size: 12.5);
    return Container(
      decoration: BoxDecoration(
        color: c.codeBackground,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: c.separator),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final l in lines)
                Container(
                  color: switch (l.kind) {
                    DiffKind.added => c.success.withValues(alpha: 0.12),
                    DiffKind.removed => c.danger.withValues(alpha: 0.10),
                    DiffKind.same => null,
                  },
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 1),
                  child: Text(
                    '${switch (l.kind) {
                      DiffKind.added => '+',
                      DiffKind.removed => '−',
                      DiffKind.same => ' ',
                    }} ${l.text}',
                    style: style.copyWith(
                      color: switch (l.kind) {
                        DiffKind.added => c.success,
                        DiffKind.removed => c.danger,
                        DiffKind.same => c.text,
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final fixed = _fixed;
    final done = _run.state == AiRunState.done;
    final unchanged = fixed != null && fixed.trim() == widget.sql.trim();
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl+';
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.enter, meta: Platform.isMacOS, control: !Platform.isMacOS): () {
          if (fixed != null && !unchanged) Navigator.pop(context, fixed);
        },
      },
      child: Focus(
        autofocus: true,
        child: AiSheet(
          title: 'Correggi con AI',
          subtitle: _subtitle(app, widget.connection),
          icon: AppIcons.fix,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.xl),
            children: [
              AiNotice(widget.error.trim()),
              const SizedBox(height: Gap.lg),
              if (!done || fixed == null) ...[
                AiCodePreview(widget.sql, label: 'Istruzione originale', maxLines: 6),
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
                _diff(fixed),
              ] else if (done && _run.response != null && !_run.response!.refused && !_run.response!.truncated) ...[
                const SizedBox(height: Gap.md),
                Text(
                  'La risposta non contiene un\'istruzione corretta da applicare.',
                  style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary),
                ),
              ],
            ],
          ),
          actions: [
            OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
            OutlinedButton(
              onPressed: fixed == null ? null : () => Clipboard.setData(ClipboardData(text: fixed)),
              child: const Text('Copia'),
            ),
            PrimaryButton(
              label: 'Sostituisci nell\'editor',
              icon: AppIcons.check,
              tooltip: 'Sostituisce l\'istruzione nell\'editor (${mod}Invio)',
              onPressed: fixed == null || unchanged ? null : () => Navigator.pop(context, fixed),
            ),
          ],
        ),
      ),
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
  return showDialog<String>(
    context: context,
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
    final c = DbColors.of(context);
    final code = _code;
    final mac = Platform.isMacOS;
    final family = dialectOf(widget.connection).family;
    final target = queryLanguage(family).$1.replaceAll(' commands', '').replaceAll(', one per line', '');
    return AiSheet(
      title: 'Genera query',
      subtitle: _subtitle(app, widget.connection),
      icon: AppIcons.ai,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.xl),
        children: [
          CallbackShortcuts(
            bindings: {SingleActivator(LogicalKeyboardKey.enter, meta: mac, control: !mac): _generate},
            child: TextField(
              controller: _prompt,
              focusNode: _focus,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText:
                    'Descrivi i dati che vuoi ottenere, ad esempio: i 10 clienti con il fatturato più alto '
                    'nel 2025, con il numero di ordini',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
              'Linguaggio: $target${widget.connection == null ? '' : ' · ${widget.connection!.config.name}'} · '
              '${mac ? '⌘' : 'Ctrl+'}Invio per generare',
              style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
            ),
          ),
          const SizedBox(height: Gap.lg),
          if (_run.state != AiRunState.idle) AiAnswerView(run: _run, onRetry: _generate),
        ],
      ),
      leading: [
        if ((widget.currentSql ?? '').trim().isNotEmpty) ...[
          Checkbox(
            value: _useCurrent,
            visualDensity: VisualDensity.compact,
            onChanged: (v) => setState(() => _useCurrent = v ?? false),
          ),
          const Text('Usa la query dell\'editor come contesto', style: TextStyle(fontSize: TypeSize.small + 0.5)),
        ],
      ],
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        if (code == null)
          PrimaryButton(
            label: _run.busy ? 'Generazione…' : 'Genera',
            icon: AppIcons.ai,
            onPressed: _run.busy || _prompt.text.trim().isEmpty ? null : _generate,
          )
        else ...[
          OutlinedButton(onPressed: _generate, child: const Text('Rigenera')),
          OutlinedButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: code)),
            child: const Text('Copia'),
          ),
          PrimaryButton(
            label: 'Inserisci nell\'editor',
            icon: AppIcons.insert,
            onPressed: () => Navigator.pop(context, code),
          ),
        ],
      ],
    );
  }
}
