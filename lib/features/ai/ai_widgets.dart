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

/// Notice for an error, a refusal or a truncation in an answer.
Widget aiNotice(String message, {bool error = true, Widget? action}) => Notice(
  kind: error ? NoticeKind.danger : NoticeKind.warning,
  message: message,
  actions: [?action],
);

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
        if (run.busy && run.text.isEmpty)
          StatusLine.busy(run.statusText, onDetails: run.cancel, detailsLabel: 'Annulla'),
        if (text.isNotEmpty) MarkdownView(data: text, codeActions: codeActions),
        if (run.state == AiRunState.streaming)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: StatusLine.busy(run.statusText, onDetails: run.cancel, detailsLabel: 'Interrompi'),
          ),
        if (run.state == AiRunState.error)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: aiNotice(
              run.error ?? 'Errore',
              action: onRetry == null ? null : LinkButton(label: 'Riprova', onPressed: onRetry),
            ),
          ),
        if (run.state == AiRunState.cancelled)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: aiNotice(
              'Richiesta annullata.',
              error: false,
              action: onRetry == null ? null : LinkButton(label: 'Riprova', onPressed: onRetry),
            ),
          ),
        if (r != null && r.notice != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: aiNotice(r.notice!, error: r.refused),
          ),
        if (r != null && run.state == AiRunState.done)
          Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: Text(
              formatUsage(r),
              style: uiText(TypeSize.caption, color: c.textTertiary),
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
          icon: AppIcons.insert,
          extent: 18,
          tooltip: 'Inserisci nell\'editor',
          onPressed: () {
            before?.call();
            insertInEditor(app, dc, b.code);
          },
        ),
        if (dc != null && dialectOf(dc).isSql)
          ToolButton(
            icon: AppIcons.run,
            extent: 18,
            tooltip: 'Esegui in editor SQL',
            onPressed: () {
              before?.call();
              runInEditor(app, dc, b.code);
            },
          ),
      ],
    ];
