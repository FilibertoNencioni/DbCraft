/// Connection folders of the navigator. A folder is a path of names joined
/// by "/" ("Clienti/Produzione"), kept in [ConnectionConfig.folder]; a
/// folder exists while some connection is in it or below it. Their order
/// among siblings is manual ([AppSettings.folderOrder]); folders missing
/// from it follow, alphabetically.
library;

/// [path] with its names trimmed and the empty ones dropped
/// (" Clienti / /Prod " → "Clienti/Prod"); "" is the top level.
String normalizeFolder(String path) =>
    path.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).join('/');

/// Last name of [path].
String folderName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Folder containing [path] ("" at the top level).
String folderParent(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

String joinFolder(String parent, String name) => parent.isEmpty ? name : '$parent/$name';

/// Whether [path] is [folder] or below it.
bool isInFolder(String path, String folder) => path == folder || path.startsWith('$folder/');

/// [path] (in [from]) moved from [from] to [to].
String rebaseFolder(String path, String from, String to) =>
    path == from ? to : joinFolder(to, path.substring(from.length + 1));

/// The folders holding [paths] (the connection folders), ancestors included.
Set<String> allFolders(Iterable<String> paths) {
  final out = <String>{};
  for (final raw in paths) {
    var p = normalizeFolder(raw);
    while (p.isNotEmpty && out.add(p)) {
      p = folderParent(p);
    }
  }
  return out;
}

/// [folders] in navigator order: depth first, siblings by their position
/// in [order], the others after them alphabetically.
List<String> orderedFolders(Set<String> folders, List<String> order) {
  final rank = <String, int>{};
  for (var i = 0; i < order.length; i++) {
    rank.putIfAbsent(order[i], () => i);
  }
  final children = <String, List<String>>{};
  for (final f in folders) {
    children.putIfAbsent(folderParent(f), () => []).add(f);
  }
  int compare(String a, String b) {
    final ra = rank[a], rb = rank[b];
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null) return -1;
    if (rb != null) return 1;
    return folderName(a).toLowerCase().compareTo(folderName(b).toLowerCase());
  }

  final out = <String>[];
  void walk(String parent) {
    for (final f in (children[parent] ?? <String>[])..sort(compare)) {
      out.add(f);
      walk(f);
    }
  }

  walk('');
  return out;
}

/// The direct subfolders of [parent] in [ordered] (see [orderedFolders]).
List<String> subfolders(List<String> ordered, String parent) =>
    [for (final f in ordered) if (f != parent && folderParent(f) == parent) f];

/// Outcome of a folder move: the new path of each moved folder and the
/// new folder order.
typedef FolderMove = ({Map<String, String> renames, List<String> order});

/// Moves [path] (with its subfolders) into [parent], named [name] (its
/// name by default), before the sibling [before] (last when null or not a
/// sibling). Null when [parent] is [path] or below it. A sibling with the
/// same name merges with it.
FolderMove? moveFolder(
  Set<String> folders,
  List<String> order,
  String path, {
  required String parent,
  String? name,
  String? before,
}) {
  if (isInFolder(parent, path)) return null;
  final target = normalizeFolder(joinFolder(parent, name ?? folderName(path)));
  if (target.isEmpty) return null;
  String rebase(String f) => isInFolder(f, path) ? rebaseFolder(f, path, target) : f;
  final renames = {for (final f in folders) if (isInFolder(f, path)) f: rebase(f)};
  final moved = allFolders(folders.map(rebase));
  final current = orderedFolders(moved, order.map(rebase).toList());
  final targetParent = folderParent(target);
  final siblings = subfolders(current, targetParent)..remove(target);
  final at = before == null ? -1 : siblings.indexOf(before);
  siblings.insert(at < 0 ? siblings.length : at, target);
  return (renames: renames, order: orderedFolders(moved, [...siblings, ...current]));
}

/// The folder order with [path] swapped with its previous (delta < 0) or
/// next sibling; null at the edge.
List<String>? shiftFolder(Set<String> folders, List<String> order, String path, int delta) {
  final current = orderedFolders(folders, order);
  final siblings = subfolders(current, folderParent(path));
  final i = siblings.indexOf(path);
  final j = i + delta.sign;
  if (i < 0 || j < 0 || j >= siblings.length) return null;
  siblings[i] = siblings[j];
  siblings[j] = path;
  return orderedFolders(folders, [...siblings, ...current]);
}
