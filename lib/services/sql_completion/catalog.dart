// Database objects for the SQL completion. Lookups are synchronous on what
// is already cached; anything missing is loaded in the background and
// [SqlCompletionCatalog.changes] fires when it arrives, so the popup can be
// refreshed.

import 'package:flutter/foundation.dart';

import '../../model/db_objects.dart';
import '../../state/db_connection.dart';

abstract class SqlCompletionCatalog {
  /// Fires when an object requested by a lookup has been loaded.
  Listenable get changes;

  /// Tables and views known so far (starts loading them when none is).
  List<DbTable> get tables;

  /// The table named [name] (optionally in [schema]); null while unknown.
  DbTable? table(String name, {String? schema});

  /// Columns of [t]; null while loading.
  List<DbColumn>? columns(DbTable t);

  /// Foreign keys of [t] (to its parents) and of other tables to [t]; null
  /// while loading.
  List<DbForeignKey>? foreignKeys(DbTable t);
  List<DbForeignKey>? referencedBy(DbTable t);

  /// Something requested is still loading.
  bool get loading;

  /// Identifier as it must be written (quoted when needed).
  String quote(String identifier);
}

/// No database: names only come from the script (CTEs, words).
class EmptyCompletionCatalog implements SqlCompletionCatalog {
  const EmptyCompletionCatalog();
  @override
  Listenable get changes => const _NoChanges();
  @override
  List<DbTable> get tables => const [];
  @override
  DbTable? table(String name, {String? schema}) => null;
  @override
  List<DbColumn>? columns(DbTable t) => const [];
  @override
  List<DbForeignKey>? foreignKeys(DbTable t) => const [];
  @override
  List<DbForeignKey>? referencedBy(DbTable t) => const [];
  @override
  bool get loading => false;
  @override
  String quote(String identifier) => identifier;
}

class _NoChanges implements Listenable {
  const _NoChanges();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

/// Catalog backed by the [DbConnection.metadata] cache of a connection.
class MetadataCompletionCatalog extends ChangeNotifier implements SqlCompletionCatalog {
  MetadataCompletionCatalog(this.connection, {this.catalog});

  final DbConnection? Function() connection;

  /// Database whose tables are preloaded; defaults to the current one.
  final String? Function()? catalog;

  /// Requests in flight or done (keys include the connection id).
  final Set<String> _requested = {};
  final Set<String> _pending = {};

  /// Tables outside the preloaded lists, found by name.
  final Map<String, DbTable> _found = {};

  @override
  Listenable get changes => this;

  @override
  bool get loading => _pending.isNotEmpty;

  /// Loads in the background, then notifies. The metadata cache keeps the
  /// result, so the key is released ([once] = false) to reload after a cache
  /// refresh; name lookups ([once]) are not repeated (unknown names would
  /// otherwise query the database at every keystroke).
  void _load(String key, Future<void> Function() load, {bool once = false}) {
    if (!_requested.add(key)) return;
    _pending.add(key);
    () async {
      var ok = true;
      try {
        await load();
      } catch (_) {
        ok = false; // not retried: a failing query would loop with the refresh
      }
      _pending.remove(key);
      if (ok && !once) _requested.remove(key);
      notifyListeners();
    }();
  }

  @override
  String quote(String identifier) => connection()?.dialect.quoteIdent(identifier) ?? identifier;

  @override
  List<DbTable> get tables {
    final dc = connection();
    final md = dc?.metadata;
    if (dc == null || md == null) return const [];
    final list = md.cachedTables;
    if (list.isEmpty) {
      final cat = catalog?.call() ?? md.currentCatalog;
      _load('tables:${dc.config.id}:$cat', () async {
        if (md.supportsSchemas) {
          final schemas = await md.schemas(md.supportsCatalogs ? cat : null);
          for (final s in schemas.take(20)) {
            await md.tables(md.supportsCatalogs ? cat : null, s);
          }
        } else {
          await md.tables(md.supportsCatalogs ? cat : null, null);
        }
      }, once: true);
    }
    return list;
  }

  @override
  DbTable? table(String name, {String? schema}) {
    final dc = connection();
    final md = dc?.metadata;
    if (dc == null || md == null) return null;
    final l = name.toLowerCase(), sl = schema?.toLowerCase();
    DbTable? any;
    for (final t in md.cachedTables) {
      if (t.name.toLowerCase() != l) continue;
      if (sl == null || t.schema?.toLowerCase() == sl) return t;
      any ??= t;
    }
    final key = '${dc.config.id}:${sl ?? ''}.$l';
    final found = _found[key];
    if (found != null) return found;
    if (any != null && sl == null) return any;
    _load('find:$key', () async {
      final t = await md.findTable(null, schema, name);
      if (t != null) _found[key] = t;
    }, once: true);
    return any;
  }

  @override
  List<DbColumn>? columns(DbTable t) {
    final md = connection()?.metadata;
    if (md == null) return const [];
    final cols = md.cachedColumns(t);
    if (cols == null) _load('cols:${connection()!.config.id}:${t.key}', () => md.columns(t));
    return cols;
  }

  @override
  List<DbForeignKey>? foreignKeys(DbTable t) {
    final md = connection()?.metadata;
    if (md == null) return const [];
    final fks = md.cachedForeignKeys(t);
    if (fks == null) _load('fk:${connection()!.config.id}:${t.key}', () => md.foreignKeys(t));
    return fks;
  }

  @override
  List<DbForeignKey>? referencedBy(DbTable t) {
    final md = connection()?.metadata;
    if (md == null) return const [];
    final refs = md.cachedReferencedBy(t);
    if (refs == null) _load('refs:${connection()!.config.id}:${t.key}', () => md.referencedBy(t));
    return refs;
  }
}
