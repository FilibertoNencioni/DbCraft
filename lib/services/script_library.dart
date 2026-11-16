import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/connection_folders.dart';

/// A folder or a .sql script of the library. [path] is relative to the
/// scripts folder, with "/" separators ("Report/vendite.sql"); "" is the
/// library itself.
class ScriptNode {
  ScriptNode({required this.path, required this.isFolder, required this.modified, List<ScriptNode>? children})
    : children = children ?? [];

  final String path;
  final bool isFolder;
  final DateTime modified;

  /// Subfolders and scripts (folders only), unsorted.
  final List<ScriptNode> children;

  String get name => folderName(path);

  /// The name without the .sql extension (scripts).
  String get title => isFolder ? name : p.basenameWithoutExtension(name);

  /// Last change of the folder or of anything below it.
  DateTime get lastModified {
    var t = modified;
    for (final c in children) {
      final m = c.lastModified;
      if (m.isAfter(t)) t = m;
    }
    return t;
  }

  /// All the scripts below this folder.
  Iterable<ScriptNode> get scripts sync* {
    for (final c in children) {
      if (c.isFolder) {
        yield* c.scripts;
      } else {
        yield c;
      }
    }
  }

  /// All the folders below this folder.
  Iterable<ScriptNode> get folders sync* {
    for (final c in children) {
      if (c.isFolder) {
        yield c;
        yield* c.folders;
      }
    }
  }
}

/// A script or folder in the trash.
class TrashItem {
  TrashItem({required this.id, required this.path, required this.isFolder, required this.deletedAt});

  final String id;

  /// Where it was (relative to the library).
  final String path;
  final bool isFolder;
  final DateTime deletedAt;

  String get name => folderName(path);

  Map<String, Object?> toJson() => {
    'path': path,
    'folder': isFolder,
    'deletedAt': deletedAt.toIso8601String(),
  };

  static TrashItem? fromJson(String id, Object? j) {
    if (j is! Map) return null;
    final path = j['path'];
    final at = DateTime.tryParse(j['deletedAt'] as String? ?? '');
    if (path is! String || at == null) return null;
    return TrashItem(id: id, path: path, isFolder: j['folder'] == true, deletedAt: at);
  }
}

/// A script whose name or content matches a search.
class ScriptMatch {
  ScriptMatch(this.path, {this.line, this.lineNumber});
  final String path;

  /// The first matching line (trimmed), null when only the name matches.
  final String? line;
  final int? lineNumber;
}

/// Library of saved scripts: the `scripts` folder of the workspace with its
/// subfolders (real directories, shared through Git), plus a trash in
/// `.dbcraft/trash` (local, git-ignored).
class ScriptLibrary {
  ScriptLibrary({required this.root, required Directory stateDir}) : trashDir = Directory(p.join(stateDir.path, 'trash'));

  /// The scripts folder.
  final Directory root;
  final Directory trashDir;

  /// Files larger than this are not searched by content.
  static const maxSearchBytes = 1024 * 1024;

  // -------------------------------------------------------------------------
  // Paths
  // -------------------------------------------------------------------------

  /// Absolute path of the library path [rel].
  String abs(String rel) => rel.isEmpty ? root.path : p.joinAll([root.path, ...rel.split('/')]);

  File fileOf(String rel) => File(abs(rel));

  /// Library path of [path], null when it is not inside the library.
  String? relOf(String path) {
    final full = p.normalize(p.absolute(path));
    final base = p.normalize(p.absolute(root.path));
    if (!p.isWithin(base, full)) return null;
    return p.split(p.relative(full, from: base)).join('/');
  }

  /// Rejects names that cannot be a file name (or would escape the folder).
  static String checkName(String name) {
    final n = name.trim();
    if (n.isEmpty) throw const ScriptLibraryException('Il nome non può essere vuoto');
    if (n.contains(RegExp(r'[/\\:*?"<>|]'))) {
      throw const ScriptLibraryException('Il nome non può contenere / \\ : * ? " < > |');
    }
    if (n == '.' || n == '..' || n.startsWith('.')) {
      throw const ScriptLibraryException('Il nome non può iniziare con un punto');
    }
    return n;
  }

  /// [name] with the .sql extension.
  static String scriptFileName(String name) => name.toLowerCase().endsWith('.sql') ? name : '$name.sql';

  static bool _sameIgnoringCase(String a, String b) => a.toLowerCase() == b.toLowerCase();

  Future<bool> _exists(String path) async => await FileSystemEntity.type(path) != FileSystemEntityType.notFound;

  // -------------------------------------------------------------------------
  // Tree
  // -------------------------------------------------------------------------

  /// The library as a tree (hidden entries skipped). Entries removed while
  /// listing are skipped.
  Future<ScriptNode> tree() async {
    await root.create(recursive: true);
    Future<ScriptNode> walk(Directory dir, String rel) async {
      final st = await dir.stat();
      final node = ScriptNode(path: rel, isFolder: true, modified: st.modified);
      try {
        await for (final e in dir.list(followLinks: false)) {
          final name = p.basename(e.path);
          if (name.startsWith('.')) continue;
          final childRel = joinFolder(rel, name);
          if (e is Directory) {
            node.children.add(await walk(e, childRel));
          } else if (e is File && name.toLowerCase().endsWith('.sql')) {
            final s = await e.stat();
            if (s.type == FileSystemEntityType.notFound) continue;
            node.children.add(ScriptNode(path: childRel, isFolder: false, modified: s.modified));
          }
        }
      } on FileSystemException {
        // Folder removed while listing.
      }
      return node;
    }

    return walk(root, '');
  }

  /// The paths of all the folders, sorted.
  Future<List<String>> folderPaths() async =>
      [for (final f in (await tree()).folders) f.path]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  /// A free name like "[base].sql", "[base] 2.sql"… in [folder].
  Future<String> uniqueScriptPath(String folder, String base) async {
    var i = 1;
    while (true) {
      final name = i == 1 ? '$base.sql' : '$base $i.sql';
      final rel = joinFolder(folder, name);
      if (!await _exists(abs(rel))) return rel;
      i++;
    }
  }

  // -------------------------------------------------------------------------
  // Changes
  // -------------------------------------------------------------------------

  /// Creates the folder [name] in [parent]; returns its path.
  Future<String> createFolder(String parent, String name) async {
    final rel = joinFolder(parent, checkName(name));
    if (await _exists(abs(rel))) throw ScriptLibraryException('Esiste già "${folderName(rel)}"');
    await Directory(abs(rel)).create(recursive: true);
    return rel;
  }

  /// Writes a new script [name] in [folder] (fails when it exists); returns
  /// its path.
  Future<String> createScript(String folder, String name, String text, {bool overwrite = false}) async {
    final rel = joinFolder(folder, scriptFileName(checkName(name)));
    if (!overwrite && await _exists(abs(rel))) {
      throw ScriptLibraryException('Esiste già uno script "${p.basenameWithoutExtension(rel)}"');
    }
    await Directory(abs(folder)).create(recursive: true);
    await fileOf(rel).writeAsString(text);
    return rel;
  }

  /// Renames the script or folder [rel] (".sql" added to scripts); returns
  /// the new path.
  Future<String> rename(String rel, String name) async {
    final isFolder = await FileSystemEntity.isDirectory(abs(rel));
    final n = checkName(name);
    final target = joinFolder(folderParent(rel), isFolder ? n : scriptFileName(n));
    if (target == rel) return rel;
    return _moveTo(rel, target, isFolder);
  }

  /// Moves the script or folder [rel] into [folder]; returns the new path.
  Future<String> move(String rel, String folder) async {
    final isFolder = await FileSystemEntity.isDirectory(abs(rel));
    if (isFolder && isInFolder(folder, rel)) {
      throw const ScriptLibraryException('Una cartella non può essere spostata dentro sé stessa');
    }
    final target = joinFolder(folder, folderName(rel));
    if (target == rel) return rel;
    return _moveTo(rel, target, isFolder);
  }

  Future<String> _moveTo(String rel, String target, bool isFolder) async {
    // Case-only renames point at the same entry on macOS and Windows.
    if (!_sameIgnoringCase(rel, target) && await _exists(abs(target))) {
      throw ScriptLibraryException('Esiste già "${folderName(target)}" in questa cartella');
    }
    await Directory(abs(folderParent(target))).create(recursive: true);
    if (isFolder) {
      await Directory(abs(rel)).rename(abs(target));
    } else {
      await fileOf(rel).rename(abs(target));
    }
    return target;
  }

  /// Copies the script [rel] next to it ("nome copia.sql"); returns the
  /// path of the copy.
  Future<String> duplicate(String rel) async {
    final target = await uniqueScriptPath(folderParent(rel), '${p.basenameWithoutExtension(rel)} copia');
    await fileOf(rel).copy(abs(target));
    return target;
  }

  // -------------------------------------------------------------------------
  // Trash
  // -------------------------------------------------------------------------

  File _trashMeta(String id) => File(p.join(trashDir.path, '$id.json'));
  String _trashPayload(String id, String name) => p.join(trashDir.path, id, name);

  /// Moves the script or folder [rel] to the trash.
  Future<TrashItem> trash(String rel) async {
    final isFolder = await FileSystemEntity.isDirectory(abs(rel));
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final item = TrashItem(id: id, path: rel, isFolder: isFolder, deletedAt: DateTime.now());
    final dest = _trashPayload(id, folderName(rel));
    await Directory(p.dirname(dest)).create(recursive: true);
    await _renameOrCopy(abs(rel), dest, isFolder);
    await _trashMeta(id).writeAsString(jsonEncode(item.toJson()));
    return item;
  }

  /// The trash, most recent first.
  Future<List<TrashItem>> listTrash() async {
    if (!await trashDir.exists()) return [];
    final out = <TrashItem>[];
    await for (final e in trashDir.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        final id = p.basenameWithoutExtension(e.path);
        final item = TrashItem.fromJson(id, jsonDecode(await e.readAsString()));
        if (item != null) out.add(item);
      } catch (_) {
        // Unreadable entry: ignored.
      }
    }
    out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return out;
  }

  /// Puts [item] back where it was (under a free name when taken); returns
  /// its path.
  Future<String> restore(TrashItem item) async {
    final src = _trashPayload(item.id, item.name);
    var target = item.path;
    if (await _exists(abs(target))) {
      final folder = folderParent(item.path);
      if (item.isFolder) {
        var i = 2;
        while (await _exists(abs(joinFolder(folder, '${item.name} $i')))) {
          i++;
        }
        target = joinFolder(folder, '${item.name} $i');
      } else {
        target = await uniqueScriptPath(folder, p.basenameWithoutExtension(item.name));
      }
    }
    await Directory(abs(folderParent(target))).create(recursive: true);
    await _renameOrCopy(src, abs(target), item.isFolder);
    await _dropTrash(item.id);
    return target;
  }

  /// Deletes [item] for good.
  Future<void> deleteForever(TrashItem item) => _dropTrash(item.id);

  Future<void> emptyTrash() async {
    if (await trashDir.exists()) await trashDir.delete(recursive: true);
  }

  /// Deletes the items trashed more than [maxAge] ago.
  Future<void> purgeTrash({Duration maxAge = const Duration(days: 30)}) async {
    final limit = DateTime.now().subtract(maxAge);
    for (final t in await listTrash()) {
      if (t.deletedAt.isBefore(limit)) await _dropTrash(t.id);
    }
  }

  Future<void> _dropTrash(String id) async {
    final dir = Directory(p.join(trashDir.path, id));
    if (await dir.exists()) await dir.delete(recursive: true);
    final meta = _trashMeta(id);
    if (await meta.exists()) await meta.delete();
  }

  /// Rename, or copy and delete across volumes.
  static Future<void> _renameOrCopy(String from, String to, bool isFolder) async {
    try {
      if (isFolder) {
        await Directory(from).rename(to);
      } else {
        await File(from).rename(to);
      }
    } on FileSystemException {
      if (!isFolder) {
        await File(from).copy(to);
        await File(from).delete();
        return;
      }
      await _copyDir(Directory(from), Directory(to));
      await Directory(from).delete(recursive: true);
    }
  }

  static Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final e in from.list()) {
      final dest = p.join(to.path, p.basename(e.path));
      if (e is Directory) {
        await _copyDir(e, Directory(dest));
      } else if (e is File) {
        await e.copy(dest);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Search
  // -------------------------------------------------------------------------

  /// Scripts whose name or content contains [query] (case-insensitive):
  /// name matches first, then content matches with their first matching line.
  Future<List<ScriptMatch>> search(String query, {ScriptNode? tree}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final root = tree ?? await this.tree();
    final byName = <ScriptMatch>[], byContent = <ScriptMatch>[];
    for (final s in root.scripts) {
      if (s.title.toLowerCase().contains(q)) {
        byName.add(ScriptMatch(s.path));
        continue;
      }
      final f = fileOf(s.path);
      try {
        if (await f.length() > maxSearchBytes) continue;
        final lines = const LineSplitter().convert(await f.readAsString());
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].toLowerCase().contains(q)) {
            byContent.add(ScriptMatch(s.path, line: lines[i].trim(), lineNumber: i + 1));
            break;
          }
        }
      } catch (_) {
        // Removed or not text: skipped.
      }
    }
    return [...byName, ...byContent];
  }
}

class ScriptLibraryException implements Exception {
  const ScriptLibraryException(this.message);
  final String message;

  @override
  String toString() => message;
}
