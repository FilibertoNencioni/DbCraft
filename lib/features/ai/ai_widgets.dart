// Widgets shared by the assistant dialogs and the chat.
import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../ui/editors/sql_editor_view.dart';
import '../../ui/widgets/common.dart';
import 'ai_context.dart';
import 'ai_service.dart';
import 'claude_client.dart';
import 'markdown_view.dart';

/// Sheet scaffold: title bar, scrollable body and an action bar.
class AiSheet extends StatelessWidget {
  const AiSheet({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.icon = Icons.auto_awesome_outlined,
    this.leading = const [],
    this.actions = const [],
    this.width = 760,
    this.height = 620,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget body;

  /// Widgets on the left of the action bar (options, status).
  final List<Widget> leading;
  final List<Widget> actions;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(Gap.xl),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.md, Gap.sm),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: c.accent),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: Theme.of(context).textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
                          ),
                      ],
                    ),
                  ),
                  ToolButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Chiudi (Esc)',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.separator),
            Expanded(child: body),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
              decoration: BoxDecoration(
                color: c.chrome,
                border: Border(top: BorderSide(color: c.separator)),
              ),
              child: Row(
                children: [
                  ...leading,
                  const Spacer(),
                  for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: Gap.sm), a],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Read-only code preview (the query being explained or fixed).
class AiCodePreview extends StatelessWidget {
  const AiCodePreview(this.code, {super.key, this.label, this.maxLines = 8});
  final String code;
  final String? label;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null) SectionLabel(label!, padding: const EdgeInsets.only(bottom: Gap.xs)),
        Container(
          constraints: BoxConstraints(maxHeight: maxLines * 17.0 + Gap.md * 2),
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: c.codeBackground,
            borderRadius: BorderRadius.circular(Radii.panel),
            border: Border.all(color: c.separator),
          ),
          child: SingleChildScrollView(
            child: SelectableText(code.trim(), style: monoStyle(context, size: 12.5, color: c.textSecondary)),
          ),
        ),
      ],
    );
  }
}

/// Colored message box (error, refusal, truncation).
class AiNotice extends StatelessWidget {
  const AiNotice(this.message, {super.key, this.error = true, this.action});
  final String message;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final col = error ? c.danger : c.warning;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: col.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: col.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(error ? Icons.error_outline_rounded : Icons.warning_amber_rounded, size: 16, color: col),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(fontSize: TypeSize.body, color: c.text),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Progress line shown while waiting for the first token.
class AiProgress extends StatelessWidget {
  const AiProgress(this.text, {super.key, this.onCancel});
  final String text;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Row(
      children: [
        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: Gap.sm),
        Text(
          text,
          style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary),
        ),
        if (onCancel != null) ...[
          const SizedBox(width: Gap.sm),
          TextButton(onPressed: onCancel, child: const Text('Annulla')),
        ],
      ],
    );
  }
}

String formatUsage(AiResponse r) {
  String n(int v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : '$v';
  final cached = r.cacheReadTokens > 0 ? ' (${n(r.cacheReadTokens)} dalla cache)' : '';
  final input = r.inputTokens + r.cacheReadTokens + r.cacheWriteTokens;
  return '${r.model ?? ''}${r.fallbackUsed ? ' (modello di riserva)' : ''} · ${n(input)} token in ingresso$cached · '
      '${n(r.outputTokens)} in uscita';
}

/// Streaming answer of an [AiRun]: progress, Markdown, notices, errors.
class AiAnswerView extends StatelessWidget {
  const AiAnswerView({super.key, required this.run, this.codeActions, this.onRetry, this.markdown});

  final AiRun run;
  final CodeActionsBuilder? codeActions;
  final VoidCallback? onRetry;

  /// Overrides the text shown (e.g. without the code block).
  final String? markdown;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final r = run.response;
    final text = markdown ?? run.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (run.busy && run.text.isEmpty) AiProgress(run.statusText, onCancel: run.cancel),
        if (text.isNotEmpty) MarkdownView(data: text, codeActions: codeActions),
        if (run.state == AiRunState.streaming)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: Row(
              children: [
                const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
                const SizedBox(width: Gap.sm),
                Text(
                  run.statusText,
                  style: TextStyle(fontSize: TypeSize.small, color: c.textTertiary),
                ),
                const SizedBox(width: Gap.xs),
                TextButton(onPressed: run.cancel, child: const Text('Interrompi')),
              ],
            ),
          ),
        if (run.state == AiRunState.error)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: AiNotice(
              run.error ?? 'Errore',
              action: onRetry == null ? null : TextButton(onPressed: onRetry, child: const Text('Riprova')),
            ),
          ),
        if (run.state == AiRunState.cancelled)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: AiNotice(
              'Richiesta annullata.',
              error: false,
              action: onRetry == null ? null : TextButton(onPressed: onRetry, child: const Text('Riprova')),
            ),
          ),
        if (r != null && r.notice != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: AiNotice(r.notice!, error: r.refused),
          ),
        if (r != null && run.state == AiRunState.done)
          Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: Text(
              formatUsage(r),
              style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
            ),
          ),
      ],
    );
  }
}

const _queryLanguages = {'', 'sql', 'plsql', 'tsql', 'pgsql', 'mysql', 'cql', 'javascript', 'js', 'mongo', 'redis'};

bool isQueryBlock(MdCode b) => _queryLanguages.contains(b.language);

/// Opens [code] in a SQL editor of [dc] (re-using the last one).
void insertInEditor(AppState app, DbConnection? dc, String code) {
  if (dc != null) {
    app.sqlEditorWith(dc, code, reuse: true);
  } else {
    app.openSqlEditor(null, initialSql: code);
  }
}

/// Opens [code] in a new SQL editor of [dc] and runs it there (with the
/// usual confirmations for production connections and dangerous SQL).
Future<void> runInEditor(AppState app, DbConnection? dc, String code) async {
  final tab = await app.openSqlEditor(dc, initialSql: code);
  if (dc == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => SqlEditorView.dispatch(tab, SqlCommand.executeScript));
}

/// "Inserisci nell'editor" / "Esegui in editor SQL" buttons on query blocks.
CodeActionsBuilder editorCodeActions(AppState app, DbConnection? dc, {VoidCallback? before}) =>
    (context, b) => [
      if (isQueryBlock(b)) ...[
        ToolButton(
          icon: Icons.input_rounded,
          size: 14,
          tooltip: 'Inserisci nell\'editor',
          onPressed: () {
            before?.call();
            insertInEditor(app, dc, b.code);
          },
        ),
        if (dc != null && dialectOf(dc).isSql)
          ToolButton(
            icon: Icons.play_arrow_rounded,
            size: 15,
            tooltip: 'Esegui in editor SQL',
            onPressed: () {
              before?.call();
              runInEditor(app, dc, b.code);
            },
          ),
      ],
    ];
