// DBMS specific catalog reading for the design tools.
//
// ODBC metadata (MetadataService) covers tables, columns, keys and indexes;
// everything else (view and routine sources, check constraints, sequences,
// triggers, users, grants…) comes from the system catalogs of each DBMS.
// Queries list alternatives tried in order, as the performance providers do:
// newer catalog first, then older or less privileged ones (Oracle DBA_* →
// ALL_* → USER_*).

import '../../../drivers/db_session.dart';
import '../../../odbc/odbc_types.dart';
import '../../../services/metadata_service.dart';
import '../../../services/sql_dialect.dart';
import '../../../state/db_connection.dart';

/// A catalog row keyed by lower-case column name.
typedef CatalogRow = Map<String, Object?>;

/// The user cannot read the catalog views needed (missing privileges).
class CatalogPermissionException implements Exception {
  CatalogPermissionException(this.message);
  final String message;

  @override
  String toString() => 'Privilegi insufficienti per leggere il catalogo: $message';
}

final _permission = RegExp(
  r'permission denied|access denied|insufficient privilege|not authori[sz]ed|'
  r'ORA-01031|ORA-00942|SQL0551N|SQLCODE=-551|denied to user|no privileges',
  caseSensitive: false,
);

/// Heuristic: [e] is a "missing privileges" error. SQLSTATE 42501 is the
/// standard code; drivers often report the generic 42000 with a message.
bool isPermissionError(Object e) {
  if (e is OdbcException && e.sqlState == '42501') return true;
  return _permission.hasMatch(e is OdbcException ? e.message : e.toString());
}

/// Runs catalog queries on a session, fetching every row.
class CatalogQueries {
  CatalogQueries(this.session, {this.maxRows = 100000});

  final DbSession session;

  /// Safety limit on the rows read by one query.
  final int maxRows;

  /// Rows of [sql]; column names are lower-cased.
  Future<List<CatalogRow>> rows(String sql, {List<Object?> params = const []}) async {
    var page = await session.execute(sql, params: params, fetchSize: 1000);
    final names = [for (final c in page.columns) c.name.toLowerCase()];
    final out = <CatalogRow>[];
    void add(ResultPage p) {
      for (final r in p.rows) {
        out.add({for (var i = 0; i < names.length && i < r.length; i++) names[i]: r[i]});
      }
    }

    try {
      add(page);
      while (page.hasMore && page.cursorId != null && out.length < maxRows) {
        page = await session.fetchMore(page.cursorId!, 1000);
        add(page);
      }
    } finally {
      if (page.cursorId != null) {
        try {
          await session.closeCursor(page.cursorId!);
        } catch (_) {}
      }
    }
    return out;
  }

  /// Rows of the first of [alternatives] that runs. When every alternative
  /// fails, throws [CatalogPermissionException] if one failed for missing
  /// privileges, otherwise the last error.
  Future<List<CatalogRow>> first(List<String> alternatives, {List<Object?> params = const []}) async {
    Object? last;
    Object? denied;
    for (final sql in alternatives) {
      try {
        return await rows(sql, params: params);
      } catch (e) {
        last = e;
        if (isPermissionError(e)) denied ??= e;
        if (session.isClosed) rethrow;
      }
    }
    if (denied != null) {
      throw CatalogPermissionException(denied is OdbcException ? denied.message : denied.toString());
    }
    throw last ?? StateError('Nessuna query');
  }
}

/// Reads DBMS specific metadata for the design tools. One subclass per
/// family adds the readers of each object type; results are cached in the
/// [MetadataService] of the connection (keys `design:…`) until the next
/// schema change.
class DesignCatalog {
  DesignCatalog(this.metadata) : queries = CatalogQueries(metadata.session);

  final MetadataService metadata;
  final CatalogQueries queries;

  SqlDialect get dialect => metadata.dialect;

  /// Catalog of a connected [dc] (null when disconnected).
  static DesignCatalog? of(DbConnection dc) {
    final md = dc.metadata;
    if (md == null) return null;
    return DesignCatalog(md);
  }

  /// Cached rows of the first working alternative.
  Future<List<CatalogRow>> cachedRows(String key, List<String> alternatives, {List<Object?> params = const []}) =>
      metadata.cached('design:$key', () => queries.first(alternatives, params: params));
}
