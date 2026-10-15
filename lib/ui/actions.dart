import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/db_connection.dart';
import '../state/editor_tabs.dart';
import 'dialogs/connection_dialog.dart';
import 'dialogs/parameters_dialog.dart';
import 'widgets/common.dart';

/// Connects [dc] if needed, asking for the password when it is not saved.
Future<bool> ensureConnected(BuildContext context, DbConnection dc) async {
  if (dc.isConnected) return true;
  final app = AppScope.read(context);
  String? pwd;
  if (dc.config.needsPasswordPrompt) {
    pwd = await promptText(
      context,
      'Password per ${dc.config.name}',
      label: 'Password utente "${dc.config.user}"',
      obscure: true,
    );
    if (pwd == null) return false;
  }
  try {
    await app.connect(dc, password: pwd);
    return true;
  } catch (e) {
    if (context.mounted) showErrorDialog(context, e, title: 'Connessione a "${dc.config.name}" fallita');
    return false;
  }
}

Future<void> disconnectWithCheck(BuildContext context, DbConnection dc) async {
  if (!dc.isConnected) return;
  if (!dc.autoCommit && dc.pendingStatements > 0) {
    final commit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Transazione aperta'),
        content: Text('Ci sono ${dc.pendingStatements} istruzioni non confermate su "${dc.config.name}".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Rollback')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Commit')),
        ],
      ),
    );
    if (commit == null) return;
    if (!context.mounted) return;
    final ok = await guarded(context, () => commit ? dc.commit() : dc.rollback());
    if (!ok) return;
  }
  await dc.disconnect();
}

Future<void> newConnection(BuildContext context) async {
  final app = AppScope.read(context);
  final cfg = await showConnectionDialog(context, app: app);
  if (cfg != null) await app.addConnection(cfg);
}

Future<void> editConnection(BuildContext context, DbConnection dc) async {
  final app = AppScope.read(context);
  final cfg = await showConnectionDialog(context, app: app, existing: dc.config);
  if (cfg == null) return;
  final wasConnected = dc.isConnected;
  await app.updateConnection(dc, cfg);
  if (wasConnected && context.mounted) {
    final re = await confirmDialog(
      context,
      'Riconnettere?',
      'La configurazione è cambiata. Riconnettere "${cfg.name}" per applicare le modifiche?',
    );
    if (re && context.mounted) {
      await dc.disconnect();
      if (context.mounted) await ensureConnected(context, dc);
    }
  }
}

Future<void> deleteConnection(BuildContext context, DbConnection dc) async {
  final ok = await confirmDialog(
    context,
    'Elimina connessione',
    'Eliminare la connessione "${dc.config.name}"?',
    ok: 'Elimina',
    destructive: true,
  );
  if (ok && context.mounted) await AppScope.read(context).deleteConnection(dc);
}

Future<void> duplicateConnection(BuildContext context, DbConnection dc) async {
  final app = AppScope.read(context);
  final copy = dc.config.copy(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    name: '${dc.config.name} (copia)',
  );
  await app.addConnection(copy);
}

Future<void> openSqlEditor(BuildContext context, {DbConnection? dc, String sql = ''}) async {
  final app = AppScope.read(context);
  final c = dc ?? app.activeConnection;
  await app.openSqlEditor(c, initialSql: sql);
}

Future<void> openScriptFile(BuildContext context) async {
  final app = AppScope.read(context);
  final f = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'SQL', extensions: ['sql', 'txt']),
    ],
    initialDirectory: app.workspace.scriptsDir.path,
  );
  if (f == null) return;
  await app.openSqlEditor(app.activeConnection, file: File(f.path));
}

/// [ExecutionUi] implementation based on dialogs.
class DialogExecutionUi implements ExecutionUi {
  DialogExecutionUi(this.context);
  final BuildContext context;

  @override
  Future<bool> ensureConnected(DbConnection c) => context.mounted ? _ensure(c) : Future.value(false);

  Future<bool> _ensure(DbConnection c) => ensureConnectedFn(context, c);

  @override
  Future<bool> confirm(String title, String message) =>
      context.mounted ? confirmDialog(context, title, message, ok: 'Continua') : Future.value(false);

  @override
  Future<Map<String, Object?>?> askParameters(List<String> names, Map<String, Object?> previous) =>
      context.mounted ? showParametersDialog(context, names, previous) : Future.value(null);
}

const ensureConnectedFn = ensureConnected;
