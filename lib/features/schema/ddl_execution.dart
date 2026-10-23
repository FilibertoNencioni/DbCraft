import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../drivers/db_session.dart';
import '../../odbc/odbc_types.dart';
import '../../services/sql_splitter.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../ui/actions.dart';
import '../../ui/widgets/common.dart';
import '../design/capabilities.dart';
import '../design/ddl_script.dart';
import 'ddl_builder.dart';

/// Runs DDL [statements] one by one on the main session of [dc] (see
/// [runDdlScript]). Returns true when every statement succeeded.
Future<bool> executeDdl(
  BuildContext context,
  DbConnection dc,
  List<String> statements, {
  SchemaScope scope = SchemaScope.connection,
  void Function(int done, int total)? onProgress,
}) async => (await runDdlScript(context, dc, DdlScript(statements, scope: scope), onProgress: onProgress)).ok;

final _destructive = RegExp(
  r'^\s*(drop|revoke)\b|\bdrop\s+(column|constraint|primary|foreign|index|default)\b',
  caseSensitive: false,
);

/// Runs [script] on [dc].
///
/// Refuses read-only connections, asks for confirmation (twice on production
/// connections) and stops at the first error showing which statement failed.
/// Statements carrying secrets run on the main session without the query
/// history recorder; [DdlScript.autocommitOnly] scripts run on a separate
/// auto-commit session when the connection is in manual commit mode;
/// [DdlScript.transactional] scripts run in one transaction when the DBMS
/// has transactional DDL. Refreshes [DdlScript.scope] in the end.
/// [onProgress] receives (done, total).
Future<DdlResult> runDdlScript(
  BuildContext context,
  DbConnection dc,
  DdlScript script, {
  void Function(int done, int total)? onProgress,
}) async {
  if (dc.config.readOnly) {
    showToast(context, 'La connessione "${dc.config.name}" è in sola lettura', error: true);
    return const DdlResult.skipped();
  }
  final exec = script.executable.map(stripLeadingComments).where((s) => s.isNotEmpty).toList();
  if (exec.isEmpty) {
    showToast(context, 'Nessuna istruzione da eseguire');
    return const DdlResult.skipped();
  }
  if (!await ensureConnected(context, dc)) return const DdlResult.skipped();
  if (!context.mounted) return const DdlResult.skipped();
  final drops = exec.where(_destructive.hasMatch).length;
  final tx =
      script.transactional &&
      !script.autocommitOnly &&
      dc.autoCommit &&
      DesignCapabilities.of(dc.dialect).has(DesignFeature.transactionalDdl);
  final ok = await confirmDialog(
    context,
    'Eseguire lo script?',
    'Verranno eseguite ${exec.length} istruzioni DDL su "${dc.config.name}".'
        '${drops > 0 ? '\n$drops istruzioni eliminano oggetti, dati o permessi.' : ''}'
        '${tx ? '\nLo script viene eseguito in una transazione: se un\'istruzione fallisce, nessuna modifica viene applicata.' : '\nMolti DBMS confermano automaticamente le modifiche allo schema: non sarà possibile annullarle.'}',
    ok: 'Esegui',
    destructive: drops > 0,
  );
  if (!ok || !context.mounted) return const DdlResult.skipped();
  if (dc.config.type.confirmExecute) {
    final prod = await confirmDialog(
      context,
      'Connessione di produzione',
      'Stai per modificare lo schema di "${dc.config.name}" (${dc.config.type.label}). Continuare?',
      ok: 'Continua',
      destructive: true,
    );
    if (!prod || !context.mounted) return const DdlResult.skipped();
  }
  final main = dc.main;
  if (main == null) return const DdlResult.skipped();

  // Sessions: [session] records to the history, [plain] runs the statements
  // with secrets. A separate auto-commit session when the script cannot run
  // inside the open transaction.
  DbSession session = main;
  DbSession plain = dc.unrecordedMain ?? main;
  DbSession? own;
  String? failure;
  var failedAt = -1;
  var rolledBack = false;
  try {
    if (script.autocommitOnly && !dc.autoCommit) {
      own = await dc.openSession();
      final cat = script.catalog ?? dc.mainCatalog;
      if (cat != null && cat.isNotEmpty) await own.setCurrentCatalog(cat);
      session = dc.withHistory(own);
      plain = own;
    } else if (script.catalog != null) {
      await dc.useCatalog(script.catalog);
    }
    if (tx) await session.setAutoCommit(false);
    for (var i = 0; i < exec.length; i++) {
      onProgress?.call(i, exec.length);
      final sql = exec[i];
      final target = script.hasSecret(sql) ? plain : session;
      try {
        final r = await target.execute(script.resolve(sql));
        if (r.cursorId != null) await target.closeCursor(r.cursorId!);
        if (own == null && !tx) dc.statementExecuted();
      } catch (e) {
        failedAt = i;
        failure = _maskSecrets(e is OdbcException ? e.message : e.toString(), script);
        break;
      }
    }
    if (tx) {
      if (failedAt < 0) {
        try {
          await session.commit();
        } catch (e) {
          failedAt = exec.length - 1;
          failure = 'COMMIT non riuscito: ${_maskSecrets(e is OdbcException ? e.message : e.toString(), script)}';
        }
      }
      if (failedAt >= 0) {
        try {
          await session.rollback();
          rolledBack = true;
        } catch (_) {}
      }
    }
  } catch (e) {
    // Opening the separate session or switching the transaction mode.
    failure ??= _maskSecrets(e is OdbcException ? e.message : e.toString(), script);
  } finally {
    if (tx) {
      try {
        await session.setAutoCommit(true);
      } catch (_) {}
    }
    await own?.close();
  }

  dc.schemaChanged(script.scope);
  if (failure != null) {
    if (context.mounted) {
      final done = failedAt < 0
          ? ''
          : rolledBack
          ? ' (nessuna modifica applicata: la transazione è stata annullata)'
          : failedAt > 0
          ? ' (le $failedAt precedenti sono state eseguite)'
          : '';
      showErrorDialog(
        context,
        failedAt < 0
            ? 'Impossibile eseguire lo script:\n\n$failure'
            : 'Istruzione ${failedAt + 1} di ${exec.length} non riuscita$done:\n\n'
                  '${DdlScript.masked(exec[failedAt])}\n\n$failure',
        title: 'Esecuzione interrotta',
      );
    }
    return DdlResult(
      total: exec.length,
      executed: rolledBack || failedAt < 0 ? 0 : failedAt,
      failedIndex: failedAt < 0 ? null : failedAt,
      error: failure,
      rolledBack: rolledBack,
    );
  }
  onProgress?.call(exec.length, exec.length);
  if (context.mounted) {
    final pending = !dc.autoCommit && own == null;
    showToast(context, '${exec.length} istruzioni eseguite${pending ? ' · ricorda di confermare la transazione' : ''}');
  }
  return DdlResult(total: exec.length, executed: exec.length);
}

/// Drivers may echo the failing statement: never show a secret.
String _maskSecrets(String message, DdlScript script) {
  var m = message;
  for (final v in script.secrets.values) {
    if (v.isNotEmpty) m = m.replaceAll(v, DdlScript.mask);
    // The bare value, without the quotes of the SQL fragment.
    if (v.length > 5) m = m.replaceAll(v.substring(1, v.length - 1), '••••••');
  }
  return m;
}

/// Sheet showing a generated DDL script with "Apri nell'editor SQL", "Copia"
/// and "Esegui". Pass either [statements] or a [script]. Returns true when
/// the script was executed successfully.
Future<bool> showDdlScriptDialog(
  BuildContext context, {
  required DbConnection dc,
  List<String>? statements,
  DdlScript? script,
  String title = 'Script DDL',
}) async {
  assert((statements == null) != (script == null), 'Pass statements or script');
  final r = await showSheet<bool>(
    context,
    size: SheetSize.large,
    builder: (_) => _DdlScriptDialog(dc: dc, script: script ?? DdlScript(statements!), title: title),
  );
  return r ?? false;
}

class _DdlScriptDialog extends StatefulWidget {
  const _DdlScriptDialog({required this.dc, required this.script, required this.title});
  final DbConnection dc;
  final DdlScript script;
  final String title;

  @override
  State<_DdlScriptDialog> createState() => _DdlScriptDialogState();
}

class _DdlScriptDialogState extends State<_DdlScriptDialog> {
  bool _running = false;
  String? _progress;

  late final String _script = widget.script.render(DdlBuilder(widget.dc.dialect));
  late final int _count = widget.script.executable.length;

  Future<void> _run() async {
    setState(() => _running = true);
    final r = await runDdlScript(
      context,
      widget.dc,
      widget.script,
      onProgress: (d, n) {
        if (mounted) setState(() => _progress = 'Esecuzione $d di $n…');
      },
    );
    if (!mounted) return;
    if (r.ok) {
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
    final readOnly = widget.dc.config.readOnly;
    final secrets = widget.script.secrets.isNotEmpty;
    return PopScope(
      canPop: !_running,
      child: SheetScaffold(
        title: widget.title,
        subtitle:
            '$_count istruzioni · ${widget.dc.config.name} (${widget.dc.dialect.dbmsName})'
            '${secrets ? ' · password nascoste' : ''}',
        body: SingleChildScrollView(child: CodeBox(_script.isEmpty ? '-- Nessuna modifica' : _script, copy: false)),
        leading: [
          PushButton(
            label: 'Copia',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _script));
              showToast(context, secrets ? 'Script copiato (password nascoste)' : 'Script copiato');
            },
          ),
          PushButton(
            label: 'Apri nell\'editor SQL',
            onPressed: _running
                ? null
                : () {
                    AppScope.read(context).openSqlEditor(widget.dc, initialSql: _script);
                    Navigator.pop(context, false);
                  },
          ),
          if (_progress != null) Flexible(child: StatusLine.busy(_progress!)),
        ],
        actions: [
          PushButton(label: 'Chiudi', onPressed: _running ? null : () => Navigator.pop(context, false)),
          PushButton.primary(
            label: 'Esegui',
            icon: AppIcons.run,
            tooltip: readOnly ? 'Connessione in sola lettura' : null,
            onPressed: _running || readOnly || _count == 0 ? null : _run,
          ),
        ],
      ),
    );
  }
}
