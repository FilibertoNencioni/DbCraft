// Object actions shared by the Cloud Explorer panel and the bucket browser:
// transfers, share links, properties, open in the SQL editor, CSV import.
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../model/db_objects.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../ui/actions.dart';
import '../../ui/dialogs/import_dialog.dart';
import '../../ui/widgets/common.dart';
import '../cloud_accounts.dart';
import '../cloud_common.dart';
import '../storage/cloud_storage.dart';
import 'cloud_transfers.dart';

/// Extensions opened as text in the SQL editor.
const cloudTextExtensions = {'sql', 'txt', 'json', 'ddl', 'pgsql', 'psql', 'md', 'log', 'yaml', 'yml', 'xml'};

/// Extensions accepted by the CSV import.
const cloudCsvExtensions = {'csv', 'tsv'};

/// Local mirror path of an object (`<workspace>/cloud/<account>/<bucket>/<key>`).
File cloudLocalCopy(AppState app, CloudAccount a, String bucket, String key) =>
    File(p.joinAll([app.workspace.root.path, 'cloud', a.id, bucket, ...key.split('/').where((e) => e.isNotEmpty)]));

Future<void> cloudDownload(BuildContext context, CloudStorage s, CloudObject o) async {
  final loc = await getSaveLocation(suggestedName: o.name);
  if (loc == null) return;
  final target = File(loc.path);
  final ok = await CloudTransfers.instance.run(
    o.name,
    upload: false,
    total: o.size,
    body: (t) => s.download(o.bucket, o.key, target, onProgress: t.progress, cancel: t.cancel),
  );
  if (ok && context.mounted) showToast(context, 'Scaricato ${o.name}');
}

/// Downloads every object under a folder into a local directory.
Future<void> cloudDownloadFolder(BuildContext context, CloudStorage s, String bucket, String prefix) async {
  final dir = await getDirectoryPath(confirmButtonText: 'Scarica qui');
  if (dir == null) return;
  final name = prefix.isEmpty ? bucket : CloudObject(bucket: bucket, key: prefix).name;
  final ok = await CloudTransfers.instance.run(
    '$name/',
    upload: false,
    body: (t) async {
      final all = (await s.listAll(bucket, prefix, cancel: t.cancel)).where((o) => !o.key.endsWith('/')).toList();
      t.total = all.fold(0, (a, o) => a + (o.size > 0 ? o.size : 0));
      var base = 0;
      for (final o in all) {
        t.cancel.throwIfCancelled();
        final rel = o.key.substring(prefix.length).split('/').where((e) => e.isNotEmpty);
        final target = File(p.joinAll([dir, name, ...rel]));
        final b = base;
        await s.download(bucket, o.key, target, onProgress: (d, _) => t.progress(b + d, t.total), cancel: t.cancel);
        base += o.size > 0 ? o.size : 0;
      }
    },
  );
  if (ok && context.mounted) showToast(context, 'Cartella scaricata in $dir');
}

/// Asks for local files and uploads them under [prefix]. Returns true when
/// at least one file was uploaded.
Future<bool> cloudUploadFiles(BuildContext context, CloudStorage s, String bucket, String prefix) async {
  final files = await openFiles();
  if (files.isEmpty || !context.mounted) return false;
  return cloudUploadPaths(context, s, bucket, prefix, files.map((f) => f.path).toList());
}

Future<bool> cloudUploadPaths(
  BuildContext context,
  CloudStorage s,
  String bucket,
  String prefix,
  List<String> paths,
) async {
  final results = await Future.wait([
    for (final path in paths)
      () async {
        final f = File(path);
        final key = '$prefix${p.basename(path)}';
        return CloudTransfers.instance.run(
          p.basename(path),
          upload: true,
          total: await f.length(),
          body: (t) => s.upload(bucket, key, f, onProgress: t.progress, cancel: t.cancel),
        );
      }(),
  ]);
  final n = results.where((e) => e).length;
  if (context.mounted && n > 0) showToast(context, n == 1 ? 'File caricato' : '$n file caricati');
  return n > 0;
}

Future<bool> cloudNewFolder(BuildContext context, CloudStorage s, String bucket, String prefix) async {
  final name = await promptText(context, 'Nuova cartella', label: 'Nome della cartella');
  if (name == null || name.trim().isEmpty || !context.mounted) return false;
  final clean = name.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  return guarded(context, () => s.createFolder(bucket, '$prefix$clean/'), title: 'Creazione cartella non riuscita');
}

Future<bool> cloudRename(BuildContext context, CloudStorage s, CloudObject o) async {
  final name = await promptText(context, o.isFolder ? 'Rinomina cartella' : 'Rinomina file', initial: o.name);
  if (name == null || name.trim().isEmpty || name.trim() == o.name || !context.mounted) return false;
  final newKey = '${o.parent}${name.trim()}${o.isFolder ? '/' : ''}';
  if (o.isFolder) {
    return CloudTransfers.instance.run(
      'Rinomina ${o.name}',
      upload: true,
      body: (t) {
        return s.rename(o.bucket, o.key, newKey, cancel: t.cancel);
      },
    );
  }
  return guarded(context, () => s.rename(o.bucket, o.key, newKey), title: 'Rinomina non riuscita');
}

Future<bool> cloudDelete(BuildContext context, CloudStorage s, List<CloudObject> objects) async {
  if (objects.isEmpty) return false;
  final what = objects.length == 1
      ? (objects.first.isFolder
            ? 'la cartella "${objects.first.name}" e tutto il suo contenuto'
            : 'il file "${objects.first.name}"')
      : '${objects.length} elementi';
  final ok = await confirmDialog(
    context,
    'Elimina',
    'Eliminare definitivamente $what dallo storage?',
    ok: 'Elimina',
    destructive: true,
  );
  if (!ok || !context.mounted) return false;
  return guarded(context, () async {
    for (final o in objects) {
      await s.deleteRecursive(o.bucket, o.key);
    }
  }, title: 'Eliminazione non riuscita');
}

Future<void> cloudCopyUri(BuildContext context, CloudStorage s, String bucket, String key) async {
  final u = s.uri(bucket, key);
  await Clipboard.setData(ClipboardData(text: u));
  if (context.mounted) showToast(context, 'Copiato: $u');
}

/// Asks the expiry, creates a temporary link and copies it.
Future<void> cloudShareLink(BuildContext context, CloudStorage s, CloudObject o) async {
  final expiry = await showSheet<Duration>(context, size: SheetSize.small, builder: (_) => _ExpiryDialog(name: o.name));
  if (expiry == null || !context.mounted) return;
  await guarded(context, () async {
    final url = await s.shareLink(o.bucket, o.key, expiry);
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (context.mounted) showToast(context, 'Link copiato negli appunti (scade tra ${_expiryLabel(expiry)})');
  }, title: 'Link di condivisione non disponibile');
}

String _expiryLabel(Duration d) => d.inDays >= 1
    ? (d.inDays == 1 ? '1 giorno' : '${d.inDays} giorni')
    : (d.inHours == 1 ? '1 ora' : (d.inHours >= 1 ? '${d.inHours} ore' : '${d.inMinutes} minuti'));

class _ExpiryDialog extends StatefulWidget {
  const _ExpiryDialog({required this.name});
  final String name;
  @override
  State<_ExpiryDialog> createState() => _ExpiryDialogState();
}

class _ExpiryDialogState extends State<_ExpiryDialog> {
  Duration _d = const Duration(hours: 1);

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return SheetScaffold(
      title: 'Link di condivisione',
      onSubmit: () => Navigator.pop(context, _d),
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: 'Copia link', onPressed: () => Navigator.pop(context, _d)),
      ],
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Chiunque abbia il link potrà scaricare "${widget.name}" fino alla scadenza.',
            textAlign: TextAlign.center,
            style: uiText(TypeSize.small, color: c.textSecondary),
          ),
          const SizedBox(height: Gap.lg),
          Segmented<Duration>(
            value: _d,
            items: const [
              (Duration(minutes: 15), '15 minuti', null),
              (Duration(hours: 1), '1 ora', null),
              (Duration(days: 1), '1 giorno', null),
              (Duration(days: 7), '7 giorni', null),
            ],
            onChanged: (v) => setState(() => _d = v),
          ),
        ],
      ),
    );
  }
}

/// Properties sheet of an object or a bucket.
Future<void> cloudProperties(BuildContext context, CloudStorage s, CloudObject o) async {
  CloudObject? info;
  await guarded(context, () async {
    info = o.isFolder ? o : await s.stat(o.bucket, o.key);
  }, title: 'Proprietà non disponibili');
  final i = info;
  if (i == null || !context.mounted) return;
  String date(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  await showSheet<void>(
    context,
    builder: (ctx) => SheetScaffold(
      title: i.name.isEmpty ? i.bucket : i.name,
      onSubmit: () => Navigator.pop(ctx),
      actions: [PushButton.primary(label: 'Fine', onPressed: () => Navigator.pop(ctx))],
      body: PropertyTable(
        entries: [
          (s.provider.bucketTerm, i.bucket),
          ('Chiave', i.key),
          ('URI', s.uri(i.bucket, i.key)),
          if (!i.isFolder) ...[
            ('Dimensione', i.size < 0 ? '' : '${formatBytes(i.size)} (${i.size} byte)'),
            ('Ultima modifica', date(i.modified)),
            ('Tipo di contenuto', i.contentType ?? ''),
            ('ETag', i.etag ?? ''),
            ('Classe di archiviazione', i.storageClass ?? ''),
          ],
          for (final e in i.metadata.entries) (e.key, e.value),
        ],
      ),
    ),
  );
}

/// Downloads a text object into the workspace mirror and opens it in a SQL
/// editor bound to the active connection.
Future<void> cloudOpenInEditor(BuildContext context, CloudAccount a, CloudStorage s, CloudObject o) async {
  final app = AppScope.read(context);
  if (o.size > 20 * 1024 * 1024) {
    final ok = await confirmDialog(
      context,
      'File grande',
      '"${o.name}" occupa ${formatBytes(o.size)}: aprirlo nell\'editor può rallentare DbCraft. Continuare?',
    );
    if (!ok || !context.mounted) return;
  }
  final local = cloudLocalCopy(app, a, o.bucket, o.key);
  for (final t in app.tabs) {
    if (t is SqlEditorTab && t.file?.path == local.path) {
      app.activate(t);
      return;
    }
  }
  final ok = await CloudTransfers.instance.run(
    o.name,
    upload: false,
    total: o.size,
    body: (t) => s.download(o.bucket, o.key, local, onProgress: t.progress, cancel: t.cancel),
  );
  if (!ok) return;
  await app.openSqlEditor(app.activeConnection, file: local);
  if (context.mounted) showToast(context, 'Modifiche salvate in locale: usa "Salva nello storage" per caricarle');
}

/// Uploads the local copy (edited in the SQL editor) back to the object.
Future<bool> cloudSaveLocalCopy(BuildContext context, CloudAccount a, CloudStorage s, CloudObject o) async {
  final app = AppScope.read(context);
  final local = cloudLocalCopy(app, a, o.bucket, o.key);
  for (final t in app.tabs) {
    if (t is SqlEditorTab && t.file?.path == local.path) await t.save();
  }
  if (!await local.exists()) return false;
  final ok = await CloudTransfers.instance.run(
    o.name,
    upload: true,
    total: await local.length(),
    body: (t) => s.upload(o.bucket, o.key, local, onProgress: t.progress, cancel: t.cancel),
  );
  if (ok && context.mounted) showToast(context, 'Salvato nello storage: ${o.name}');
  return ok;
}

/// CSV → table: downloads the file to a temporary folder, asks the target
/// table of the active connection and opens the import dialog.
Future<void> cloudImportCsv(BuildContext context, CloudStorage s, CloudObject o) async {
  final app = AppScope.read(context);
  final dc = app.activeConnection ?? await _pickConnection(context, app);
  if (dc == null || !context.mounted) return;
  if (!await ensureConnected(context, dc) || !context.mounted) return;
  if (dc.config.readOnly) {
    showToast(context, 'La connessione "${dc.config.name}" è in sola lettura', error: true);
    return;
  }
  final table = await _pickTable(context, dc);
  if (table == null || !context.mounted) return;
  final tmp = await Directory.systemTemp.createTemp('dbcraft-cloud-');
  final local = File(p.join(tmp.path, o.name));
  final ok = await CloudTransfers.instance.run(
    o.name,
    upload: false,
    total: o.size,
    body: (t) => s.download(o.bucket, o.key, local, onProgress: t.progress, cancel: t.cancel),
  );
  if (!ok || !context.mounted) return;
  await showImportDialog(context, dc, table, initialPath: local.path);
}

Future<DbConnection?> _pickConnection(BuildContext context, AppState app) async {
  if (app.connections.isEmpty) {
    showToast(context, 'Crea prima una connessione al database di destinazione', error: true);
    return null;
  }
  if (app.connections.length == 1) return app.connections.first;
  return showListPicker<DbConnection>(
    context,
    title: 'Connessione di destinazione',
    items: app.connections,
    label: (dc) => dc.config.name,
    detail: (dc) => dc.config.subtitle,
    icon: (dc) => dc.config.icon,
    iconColor: (dc) => dc.config.color,
  );
}

/// Asks one of the tables (not views) of the current catalog, listed while
/// the picker is open.
Future<DbTable?> _pickTable(BuildContext context, DbConnection dc) {
  final accent = DbColors.of(context).accent;
  return showListPicker<DbTable>(
    context,
    title: 'Importa in una tabella di ${dc.config.name}',
    load: () async {
      final m = dc.metadata!;
      return (await m.tables(m.currentCatalog, null)).where((t) => !t.isView).toList();
    },
    label: (t) => t.displayPath,
    icon: (_) => AppIcons.table,
    iconColor: (_) => accent,
    searchHint: 'Filtra tabelle',
    empty: 'Nessuna tabella in ${dc.config.name}',
    loadError: 'Tabelle non disponibili',
  );
}
