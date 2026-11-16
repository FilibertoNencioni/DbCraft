import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../model/connection_folders.dart';
import '../../services/script_library.dart';
import '../../state/app_state.dart';
import '../../state/editor_tabs.dart';
import '../widgets/common.dart';

/// ⌘S of a SQL editor: writes the script, or asks where to save a draft.
/// False when the user cancelled or the save failed.
Future<bool> saveSqlTab(BuildContext context, SqlEditorTab tab) async {
  if (tab.isDraft) return saveSqlTabAs(context, tab);
  return guarded(context, tab.save, title: 'Impossibile salvare lo script');
}

enum _SaveChoice { save, elsewhere }

/// "Salva script" sheet: name and library folder, or another location.
/// False when the user cancelled or the save failed.
Future<bool> saveSqlTabAs(BuildContext context, SqlEditorTab tab) async {
  final app = AppScope.read(context);
  final folders = await app.library.folderPaths();
  if (!context.mounted) return false;
  return _saveLoop(context, app, tab, folders);
}

Future<bool> _saveLoop(BuildContext context, AppState app, SqlEditorTab tab, List<String> folders) async {
  final lib = app.library;
  final current = tab.file == null ? null : lib.relOf(tab.file!.path);
  var name = tab.isDraft ? (tab.draftName ?? '') : tab.name;
  var folder = current != null ? folderParent(current) : (tab.suggestedFolder ?? '');
  while (true) {
    if (!context.mounted) return false;
    final choice = await showAlert<_SaveChoice?>(
      context,
      title: tab.isDraft ? 'Salva script' : 'Salva script come',
      message: 'Lo script viene salvato nella libreria, nella cartella scelta.',
      accessory: _SaveFields(
        name: name,
        folder: folder,
        folders: folders,
        onName: (v) => name = v,
        onFolder: (v) => folder = v,
      ),
      buttons: const [
        AlertButton('Salva', _SaveChoice.save, role: AlertRole.defaultAction),
        AlertButton('Altra posizione…', _SaveChoice.elsewhere),
        AlertButton('Annulla', null, role: AlertRole.cancel),
      ],
    );
    if (choice == null || !context.mounted) return false;
    if (choice == _SaveChoice.elsewhere) return _saveElsewhere(context, tab);

    final String rel;
    try {
      rel = joinFolder(normalizeFolder(folder), ScriptLibrary.scriptFileName(ScriptLibrary.checkName(name)));
      for (final f in rel.split('/')) {
        ScriptLibrary.checkName(f);
      }
    } on ScriptLibraryException catch (e) {
      await showErrorDialog(context, e.message, title: 'Nome non valido');
      if (!context.mounted) return false;
      continue;
    }
    final target = lib.fileOf(rel);
    final same = tab.file != null && p.equals(p.absolute(tab.file!.path), p.absolute(target.path));
    if (!same) {
      final other = app.sqlTabOf(target);
      if (other != null) {
        await showErrorDialog(context, 'Lo script "${p.basenameWithoutExtension(rel)}" è aperto in un\'altra scheda.',
            title: 'Impossibile salvare');
        if (!context.mounted) return false;
        continue;
      }
      if (await target.exists()) {
        if (!context.mounted) return false;
        final ok = await confirmDialog(
          context,
          'Sostituire lo script?',
          'Esiste già "${p.basenameWithoutExtension(rel)}" in questa cartella.',
          ok: 'Sostituisci',
          destructive: true,
        );
        if (!context.mounted) return false;
        if (!ok) continue;
      }
    }
    if (!context.mounted) return false;
    final ok = await guarded(context, () => tab.saveAs(target), title: 'Impossibile salvare lo script');
    if (ok) {
      tab.suggestedFolder = null;
      app.scriptsChanged();
    }
    return ok;
  }
}

Future<bool> _saveElsewhere(BuildContext context, SqlEditorTab tab) async {
  final loc = await getSaveLocation(
    suggestedName: '${tab.name}.sql',
    initialDirectory: tab.file?.parent.path,
    acceptedTypeGroups: const [
      XTypeGroup(label: 'SQL', extensions: ['sql']),
    ],
  );
  if (loc == null || !context.mounted) return false;
  final app = AppScope.read(context);
  final ok = await guarded(context, () => tab.saveAs(File(loc.path)), title: 'Impossibile salvare lo script');
  if (ok) app.scriptsChanged();
  return ok;
}

class _SaveFields extends StatefulWidget {
  const _SaveFields({
    required this.name,
    required this.folder,
    required this.folders,
    required this.onName,
    required this.onFolder,
  });

  final String name;
  final String folder;
  final List<String> folders;
  final ValueChanged<String> onName;
  final ValueChanged<String> onFolder;

  @override
  State<_SaveFields> createState() => _SaveFieldsState();
}

class _SaveFieldsState extends State<_SaveFields> {
  late final _name = TextEditingController(text: widget.name)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.name.length);
  late final _folder = TextEditingController(text: widget.folder);

  @override
  void dispose() {
    _name.dispose();
    _folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MacTextField(controller: _name, hint: 'Nome dello script', autofocus: true, onChanged: widget.onName),
      const SizedBox(height: Gap.sm),
      ComboField(
        controller: _folder,
        hint: 'Cartella: livello principale',
        options: () => widget.folders,
        optionIcon: (_) => (AppIcons.folder, null),
        onChanged: widget.onFolder,
      ),
    ],
  );
}

/// Outcome of the question asked before closing an editor with unsaved text.
enum CloseChoice { saved, discard, cancel }

/// Asks whether to save [tab] before closing it: "Salva…", "Non salvare"
/// (the text stays in "Chiuse di recente"), "Annulla".
Future<CloseChoice> askSaveBeforeClose(BuildContext context, SqlEditorTab tab) async {
  final r = await showAlert<CloseChoice>(
    context,
    title: tab.isDraft ? 'Salvare "${tab.name}" come script?' : 'Salvare le modifiche a "${tab.name}"?',
    message: tab.isDraft
        ? 'La bozza non è nella libreria degli script. Se non la salvi resta tra le chiuse di recente per 30 giorni.'
        : 'Se non le salvi, le modifiche restano tra le chiuse di recente per 30 giorni.',
    style: AlertStyle.warning,
    buttons: [
      AlertButton(tab.isDraft ? 'Salva…' : 'Salva', CloseChoice.saved, role: AlertRole.defaultAction),
      const AlertButton('Non salvare', CloseChoice.discard),
      const AlertButton('Annulla', CloseChoice.cancel, role: AlertRole.cancel),
    ],
  );
  if (r != CloseChoice.saved || !context.mounted) return r ?? CloseChoice.cancel;
  return await saveSqlTab(context, tab) ? CloseChoice.saved : CloseChoice.cancel;
}

/// Opens [file] in the library with its remembered connection.
Future<void> openLibraryScript(BuildContext context, File file) async {
  final app = AppScope.read(context);
  await guarded(context, () => app.openScript(file), title: 'Impossibile aprire lo script');
}

/// "Apri rapido" (⌘P): picks a script of the library or a draft by name.
Future<void> quickOpenScript(BuildContext context) async {
  final app = AppScope.read(context);
  final items = <_QuickItem>[];
  final tree = await app.library.tree();
  for (final t in app.tabs.whereType<SqlEditorTab>().where((t) => t.isDraft)) {
    items.add(_QuickItem(t.name, 'Bozza aperta', AppIcons.edit, tab: t));
  }
  for (final b in app.closedDrafts) {
    items.add(_QuickItem(b.label, 'Chiusa di recente', AppIcons.history, closedId: b.id));
  }
  final scripts = tree.scripts.toList()..sort((a, b) => b.modified.compareTo(a.modified));
  for (final s in scripts) {
    final folder = folderParent(s.path);
    items.add(_QuickItem(s.title, folder.isEmpty ? 'Libreria' : folder, AppIcons.document, path: s.path));
  }
  if (!context.mounted) return;
  final pick = await showListPicker<_QuickItem>(
    context,
    title: 'Apri script',
    items: items,
    label: (x) => x.label,
    detail: (x) => x.detail,
    icon: (x) => x.icon,
    choose: 'Apri',
    searchHint: 'Nome dello script',
    empty: 'Nessuno script',
  );
  if (pick == null || !context.mounted) return;
  if (pick.tab != null) {
    app.activate(pick.tab!);
  } else if (pick.closedId != null) {
    await app.reopenClosed(pick.closedId!);
  } else {
    await openLibraryScript(context, app.library.fileOf(pick.path!));
  }
}

class _QuickItem {
  _QuickItem(this.label, this.detail, this.icon, {this.tab, this.closedId, this.path});
  final String label;
  final String detail;
  final IconData icon;
  final SqlEditorTab? tab;
  final String? closedId;
  final String? path;
}

/// Shows [path] in Finder / Explorer / the file manager.
Future<void> revealInFileManager(String path) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else {
      await Process.run('xdg-open', [FileSystemEntity.isDirectorySync(path) ? path : p.dirname(path)]);
    }
  } catch (_) {}
}

/// Name of the system file manager, for menu labels.
String get fileManagerName => Platform.isMacOS
    ? 'Finder'
    : Platform.isWindows
    ? 'Esplora risorse'
    : 'file manager';
