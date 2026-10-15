import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../odbc/odbc_types.dart';
import '../../services/sql_splitter.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../ui/actions.dart';
import '../../ui/widgets/common.dart';
import 'ddl_builder.dart';

/// Runs DDL [statements] one by one on the main session of [dc].
///
/// Asks for confirmation (twice on production connections), refuses
/// read-only connections, stops at the first error showing which statement
/// failed and refreshes the metadata cache on success. [onProgress] receives
/// (done, total). Returns true when every statement succeeded.
Future<bool> executeDdl(
  BuildContext context,
  DbConnection dc,
  List<String> statements, {
  void Function(int done, int total)? onProgress,
}) async {
  if (dc.config.readOnly) {
    showToast(context, 'La connessione "${dc.config.name}" è in sola lettura', error: true);
    return false;
  }
  final exec = executableStatements(statements).map(stripLeadingComments).where((s) => s.isNotEmpty).toList();
  if (exec.isEmpty) {
    showToast(context, 'Nessuna istruzione da eseguire');
    return false;
  }
  if (!await ensureConnected(context, dc)) return false;
  if (!context.mounted) return false;
  final drops = exec
      .where(
        (s) => RegExp(r'^\s*drop\b|\bdrop\s+(column|constraint|primary|foreign)\b', caseSensitive: false).hasMatch(s),
      )
      .length;
  final ok = await confirmDialog(
    context,
    'Eseguire lo script?',
    'Verranno eseguite ${exec.length} istruzioni DDL su "${dc.config.name}".'
        '${drops > 0 ? '\n$drops istruzioni eliminano oggetti o dati.' : ''}'
        '\nMolti DBMS confermano automaticamente le modifiche allo schema: non sarà possibile annullarle.',
    ok: 'Esegui',
    destructive: drops > 0,
  );
  if (!ok || !context.mounted) return false;
  if (dc.config.type.confirmExecute) {
    final prod = await confirmDialog(
      context,
      'Connessione di produzione',
      'Stai per modificare lo schema di "${dc.config.name}" (${dc.config.type.label}). Continuare?',
      ok: 'Continua',
      destructive: true,
    );
    if (!prod || !context.mounted) return false;
  }
  final session = dc.main;
  if (session == null) return false;
  for (var i = 0; i < exec.length; i++) {
    onProgress?.call(i, exec.length);
    try {
      final r = await session.execute(exec[i]);
      if (r.cursorId != null) await session.closeCursor(r.cursorId!);
      dc.statementExecuted();
    } catch (e) {
      final msg = e is OdbcException ? e.message : e.toString();
      if (context.mounted) {
        showErrorDialog(
          context,
          'Istruzione ${i + 1} di ${exec.length} non riuscita'
          '${i > 0 ? ' (le $i precedenti sono state eseguite)' : ''}:\n\n${exec[i]}\n\n$msg',
          title: 'Esecuzione interrotta',
        );
      }
      dc.refreshMetadata();
      return false;
    }
  }
  onProgress?.call(exec.length, exec.length);
  dc.refreshMetadata();
  if (context.mounted) {
    showToast(
      context,
      '${exec.length} istruzioni eseguite${dc.autoCommit ? '' : ' · ricorda di confermare la transazione'}',
    );
  }
  return true;
}

/// Dialog showing a generated DDL script with "Apri nell'editor SQL", "Copia"
/// and "Esegui". Returns true when the script was executed successfully.
Future<bool> showDdlScriptDialog(
  BuildContext context, {
  required DbConnection dc,
  required List<String> statements,
  String title = 'Script DDL',
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) => _DdlScriptDialog(dc: dc, statements: statements, title: title),
  );
  return r ?? false;
}

class _DdlScriptDialog extends StatefulWidget {
  const _DdlScriptDialog({required this.dc, required this.statements, required this.title});
  final DbConnection dc;
  final List<String> statements;
  final String title;

  @override
  State<_DdlScriptDialog> createState() => _DdlScriptDialogState();
}

class _DdlScriptDialogState extends State<_DdlScriptDialog> {
  bool _running = false;
  String? _progress;

  late final String _script = DdlBuilder(widget.dc.dialect).render(widget.statements);
  late final int _count = executableStatements(widget.statements).length;

  Future<void> _run() async {
    setState(() => _running = true);
    final ok = await executeDdl(
      context,
      widget.dc,
      widget.statements,
      onProgress: (d, n) {
        if (mounted) setState(() => _progress = 'Esecuzione $d di $n…');
      },
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _running = false;
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final readOnly = widget.dc.config.readOnly;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 760,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$_count istruzioni · ${widget.dc.config.name} (${widget.dc.dialect.dbmsName})',
              style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary, fontFeatures: kTabular),
            ),
            const SizedBox(height: Gap.sm),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: c.codeBackground,
                  borderRadius: BorderRadius.circular(Radii.panel),
                  border: Border.all(color: c.separator),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(Gap.md),
                  child: SelectableText(
                    _script.isEmpty ? '-- Nessuna modifica' : _script,
                    style: monoStyle(context, size: 12.5),
                  ),
                ),
              ),
            ),
            if (_progress != null) ...[
              const SizedBox(height: Gap.sm),
              Row(
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: Gap.sm),
                  Text(
                    _progress!,
                    style: const TextStyle(fontSize: TypeSize.small, fontFeatures: kTabular),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _script));
            showToast(context, 'Script copiato');
          },
          child: const Text('Copia'),
        ),
        OutlinedButton(
          onPressed: _running
              ? null
              : () {
                  AppScope.read(context).openSqlEditor(widget.dc, initialSql: _script);
                  Navigator.pop(context, false);
                },
          child: const Text('Apri nell\'editor SQL'),
        ),
        OutlinedButton(onPressed: _running ? null : () => Navigator.pop(context, false), child: const Text('Chiudi')),
        PrimaryButton(
          label: 'Esegui',
          icon: Icons.play_arrow_rounded,
          tooltip: readOnly ? 'Connessione in sola lettura' : null,
          onPressed: _running || readOnly || _count == 0 ? null : _run,
        ),
      ],
    );
  }
}
