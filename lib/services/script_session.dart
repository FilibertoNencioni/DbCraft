import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/connection_folders.dart';
import 'sql_variables.dart';

/// The text of a SQL editor not (yet) written to its file: a draft, or the
/// unsaved changes of a script. The text lives in `.dbcraft/drafts/<id>.sql`.
class BufferMeta {
  BufferMeta({
    required this.id,
    this.name,
    this.file,
    this.folder,
    this.connection,
    this.catalog,
    this.closedAt,
    List<ScriptVariable>? variables,
  }) : variables = variables ?? [];

  final String id;

  /// Name of a draft ("Bozza 3").
  String? name;

  /// Absolute path of the script, null for a draft.
  String? file;

  /// Library folder proposed when the draft is saved.
  String? folder;

  /// Connection id and database of the editor.
  String? connection;
  String? catalog;

  /// When the editor was closed keeping the text ("Chiuse di recente").
  DateTime? closedAt;

  /// Values of the Variabili panel.
  List<ScriptVariable> variables;

  bool get isDraft => file == null;

  /// Name shown in the lists.
  String get label => file != null ? p.basenameWithoutExtension(file!) : (name ?? 'Bozza');

  Map<String, Object?> toJson() => {
    if (name != null) 'name': name,
    if (file != null) 'file': file,
    if (folder != null && folder!.isNotEmpty) 'folder': folder,
    if (connection != null) 'connection': connection,
    if (catalog != null) 'catalog': catalog,
    if (closedAt != null) 'closedAt': closedAt!.toIso8601String(),
    if (variables.isNotEmpty) 'variables': [for (final v in variables) v.toJson()],
  };

  static BufferMeta fromJson(String id, Map<Object?, Object?> j) => BufferMeta(
    id: id,
    name: j['name'] as String?,
    file: j['file'] as String?,
    folder: j['folder'] as String?,
    connection: j['connection'] as String?,
    catalog: j['catalog'] as String?,
    closedAt: DateTime.tryParse(j['closedAt'] as String? ?? ''),
    variables: ScriptVariable.listFromJson(j['variables']),
  );
}

/// Connection, database and variable values last used with a script (local,
/// never in the shared library).
class ScriptBinding {
  ScriptBinding({this.connection, this.catalog, List<ScriptVariable>? variables}) : variables = variables ?? [];
  String? connection;
  String? catalog;
  List<ScriptVariable> variables;

  bool get isEmpty => connection == null && variables.isEmpty;

  Map<String, Object?> toJson() => {
    if (connection != null) 'connection': connection,
    if (catalog != null) 'catalog': catalog,
    if (variables.isNotEmpty) 'variables': [for (final v in variables) v.toJson()],
  };

  static ScriptBinding fromJson(Map<Object?, Object?> j) => ScriptBinding(
    connection: j['connection'] as String?,
    catalog: j['catalog'] as String?,
    variables: ScriptVariable.listFromJson(j['variables']),
  );
}

enum ScriptSort { name, modified }

/// Local state of the scripts (never shared): open editors, drafts and
/// recently closed ones, connection of each script, favorites, recents,
/// expanded folders. Kept in `.dbcraft/scripts.local.json`.
///
/// Scripts are identified by a key: their library path ("Report/x.sql")
/// or, outside the library, their absolute path.
class ScriptSession {
  ScriptSession._(this.stateDir);

  final Directory stateDir;

  File get _file => File(p.join(stateDir.path, 'scripts.local.json'));
  Directory get buffersDir => Directory(p.join(stateDir.path, 'drafts'));

  final Map<String, BufferMeta> buffers = {};

  /// Buffer ids of the open SQL editors, in tab order.
  List<String> open = [];
  String? active;
  final Map<String, ScriptBinding> bindings = {};
  List<String> favorites = [];
  List<String> recent = [];
  Set<String> expanded = {};
  ScriptSort sort = ScriptSort.name;

  static const maxRecent = 10;
  static const maxClosed = 50;

  static Future<ScriptSession> load(Directory stateDir) async {
    final s = ScriptSession._(stateDir);
    try {
      if (await s._file.exists()) s._fromJson(jsonDecode(await s._file.readAsString()));
    } catch (_) {
      // Damaged file: start empty (the buffers on disk are kept until purge).
    }
    return s;
  }

  void _fromJson(Object? j) {
    if (j is! Map) return;
    final b = j['buffers'];
    if (b is Map) {
      for (final e in b.entries) {
        if (e.key is String && e.value is Map) buffers[e.key as String] = BufferMeta.fromJson(e.key as String, e.value as Map);
      }
    }
    open = [...?(j['open'] as List?)?.whereType<String>().where(buffers.containsKey)];
    active = j['active'] as String?;
    final sc = j['scripts'];
    if (sc is Map) {
      for (final e in sc.entries) {
        if (e.key is String && e.value is Map) bindings[e.key as String] = ScriptBinding.fromJson(e.value as Map);
      }
    }
    favorites = [...?(j['favorites'] as List?)?.whereType<String>()];
    recent = [...?(j['recent'] as List?)?.whereType<String>()];
    expanded = {...?(j['expanded'] as List?)?.whereType<String>()};
    sort = ScriptSort.values.asNameMap()[j['sort']] ?? ScriptSort.name;
  }

  Map<String, Object?> toJson() => {
    'buffers': {for (final e in buffers.entries) e.key: e.value.toJson()},
    'open': open,
    if (active != null) 'active': active,
    'scripts': {
      for (final e in bindings.entries)
        if (!e.value.isEmpty) e.key: e.value.toJson(),
    },
    'favorites': favorites,
    'recent': recent,
    'expanded': expanded.toList()..sort(),
    'sort': sort.name,
  };

  Future<void> save() async {
    await stateDir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
    await tmp.rename(_file.path);
  }

  // -------------------------------------------------------------------------
  // Buffers
  // -------------------------------------------------------------------------

  static int _seq = 0;

  static String newId() => '${DateTime.now().microsecondsSinceEpoch}${(_seq++ % 1000).toString().padLeft(3, '0')}';

  File bufferFile(String id) => File(p.join(buffersDir.path, '$id.sql'));

  Future<String?> readBuffer(String id) async {
    final f = bufferFile(id);
    try {
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeBuffer(String id, String text) async {
    await buffersDir.create(recursive: true);
    final f = bufferFile(id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text);
    await tmp.rename(f.path);
  }

  void writeBufferSync(String id, String text) {
    buffersDir.createSync(recursive: true);
    bufferFile(id).writeAsStringSync(text);
  }

  void deleteBufferSync(String id) {
    try {
      final f = bufferFile(id);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<void> deleteBuffer(String id) async {
    final f = bufferFile(id);
    if (await f.exists()) await f.delete();
  }

  /// The first free "Bozza N" among the drafts (open and closed).
  String newDraftName() {
    final used = {
      for (final b in buffers.values)
        if (b.isDraft && b.name != null) b.name!,
    };
    var i = 1;
    while (used.contains('Bozza $i')) {
      i++;
    }
    return 'Bozza $i';
  }

  /// Closed buffers kept for "Chiuse di recente", most recent first.
  List<BufferMeta> get closed =>
      buffers.values.where((b) => b.closedAt != null).toList()..sort((a, b) => b.closedAt!.compareTo(a.closedAt!));

  /// Drops the closed buffers older than [maxAge] (and beyond [maxClosed]),
  /// the entries neither open nor closed and the orphan buffer files.
  Future<void> purge({Duration maxAge = const Duration(days: 30)}) async {
    final limit = DateTime.now().subtract(maxAge);
    final keepClosed = closed.where((b) => b.closedAt!.isAfter(limit)).take(maxClosed).map((b) => b.id).toSet();
    final openIds = open.toSet();
    buffers.removeWhere((id, _) => !openIds.contains(id) && !keepClosed.contains(id));
    if (!buffers.containsKey(active)) active = null;
    if (!await buffersDir.exists()) return;
    await for (final e in buffersDir.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      final id = name.endsWith('.sql') ? name.substring(0, name.length - 4) : null;
      if (id == null || !buffers.containsKey(id)) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  }

  // -------------------------------------------------------------------------
  // Scripts
  // -------------------------------------------------------------------------

  void touchRecent(String key) {
    recent
      ..remove(key)
      ..insert(0, key);
    if (recent.length > maxRecent) recent.removeRange(maxRecent, recent.length);
  }

  bool isFavorite(String key) => favorites.contains(key);

  void toggleFavorite(String key) {
    if (!favorites.remove(key)) favorites.add(key);
  }

  /// A library script or folder moved from [from] to [to] (library paths):
  /// bindings, favorites, recents and expanded folders follow it.
  void moved(String from, String to) {
    String rebase(String k) => isInFolder(k, from) ? rebaseFolder(k, from, to) : k;
    final moved = {
      for (final e in bindings.entries)
        if (isInFolder(e.key, from)) e.key: e.value,
    };
    for (final e in moved.entries) {
      bindings.remove(e.key);
      bindings[rebase(e.key)] = e.value;
    }
    favorites = favorites.map(rebase).toList();
    recent = recent.map(rebase).toList();
    expanded = expanded.map(rebase).toSet();
  }

  /// A library script or folder was deleted: forget what pointed to it.
  void removed(String path) {
    bindings.removeWhere((k, _) => isInFolder(k, path));
    favorites.removeWhere((k) => isInFolder(k, path));
    recent.removeWhere((k) => isInFolder(k, path));
    expanded.removeWhere((k) => isInFolder(k, path));
  }
}
