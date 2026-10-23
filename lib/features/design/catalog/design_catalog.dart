// DBMS specific catalog reading for the design tools.
//
// ODBC metadata (MetadataService) covers tables, columns, keys and indexes;
// everything else (view and routine sources, check constraints, sequences,
// triggers, users, grants…) comes from the system catalogs of each DBMS.
// Queries list alternatives tried in order, as the performance providers do:
// newer catalog first, then older or less privileged ones (Oracle DBA_* →
// ALL_* → USER_*).

import '../../../drivers/db_session.dart';
import '../../../model/db_objects.dart';
import '../../../odbc/odbc_types.dart';
import '../../../services/metadata_service.dart';
import '../../../services/sql_dialect.dart';
import '../../../state/db_connection.dart';
import '../../schema/schema_model.dart';
import '../model/object_defs.dart';
import 'code.dart';
import 'databases.dart';
import 'db2.dart';
import 'firebird.dart';
import 'mssql.dart';
import 'mysql.dart';
import 'oracle.dart';
import 'pg.dart';
import 'snowflake.dart';
import 'sqlite.dart';
import 'table_extras.dart';
import 'views.dart';

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

  /// Extras of table [t] (empty for DBMS without a reader). Cached until the
  /// next schema change.
  Future<TableExtras> tableExtras(DbTable t) => metadata.cached('design:table:${t.key}', () async {
    return switch (dialect.family) {
      DbFamily.postgres => readPostgresTable(queries, t),
      DbFamily.sqlServer => readSqlServerTable(queries, t),
      DbFamily.mysql => readMySqlTable(queries, dialect, t),
      DbFamily.oracle => readOracleTable(queries, t),
      DbFamily.db2 => readDb2Table(queries, t),
      DbFamily.sqlite => readSqliteTable(queries, t),
      DbFamily.firebird => readFirebirdTable(queries, t),
      DbFamily.snowflake => readSnowflakeTable(queries, dialect, t),
      _ => TableExtras.none,
    };
  });

  /// Complete definition of table [t]: the ODBC metadata plus the
  /// [tableExtras]. When the extras cannot be read (missing privileges, old
  /// server) the ODBC definition is returned.
  Future<TableDef> loadTable(DbTable t) async {
    final base = TableDef.fromDetails(await metadata.tableDetails(t));
    try {
      return applyTableExtras(base, await tableExtras(t));
    } catch (_) {
      return base;
    }
  }

  /// Definition of the view [t] (null when the catalog has none).
  Future<ViewDef?> viewDef(DbTable t) async {
    final r = await metadata.cached<Object>(
      'design:view:${t.key}',
      () async => await readViewDef(queries, dialect, t) ?? false,
    );
    return r is ViewDef ? r : null;
  }

  /// Sequences of [catalog].[schema].
  Future<List<SequenceDef>> sequences(String? catalog, String? schema) => metadata.cached(
    'design:seq:${catalog ?? ''}:${schema ?? ''}',
    () => readSequences(queries, dialect, catalog, schema),
  );

  /// Triggers of the table [t].
  Future<List<TriggerDef>> triggers(DbTable t) =>
      metadata.cached('design:trg:${t.key}', () => readTriggers(queries, dialect, t));

  /// Source of the procedure or function [p] (null when not exposed).
  Future<RoutineSource?> routineSource(DbProcedure p) async {
    final params = dialect.family == DbFamily.firebird ? await metadata.procedureParams(p) : const <DbProcedureParam>[];
    final r = await metadata.cached<Object>(
      'design:src:${p.key}',
      () async => await readRoutineSource(queries, dialect, p, params: params) ?? false,
    );
    return r is RoutineSource ? r : null;
  }

  /// Databases with their properties (DBMS where databases are managed).
  Future<List<DatabaseDef>> databases() => metadata.cached('design:databases', () => readDatabases(queries, dialect));

  Future<DatabaseDef?> database(String name) async {
    for (final d in await databases()) {
      if (d.name.toLowerCase() == name.toLowerCase()) return d;
    }
    return null;
  }

  /// Schemas of [catalog] with owner and comment.
  Future<List<SchemaDef>> schemaDefs(String? catalog) =>
      metadata.cached('design:schemas:${catalog ?? ''}', () => readSchemas(queries, dialect, catalog));

  Future<SchemaDef?> schemaDef(String? catalog, String name) async {
    for (final s in await schemaDefs(catalog)) {
      if (s.name.toLowerCase() == name.toLowerCase()) return s;
    }
    return null;
  }

  Future<DatabaseChoices> databaseChoices() =>
      metadata.cached('design:dbchoices', () => readDatabaseChoices(queries, dialect));

  Future<List<String>> schemaOwners(String? catalog) =>
      metadata.cached('design:schemaowners:${catalog ?? ''}', () => readSchemaOwners(queries, dialect, catalog));

  /// Cached rows of the first working alternative.
  Future<List<CatalogRow>> cachedRows(String key, List<String> alternatives, {List<Object?> params = const []}) =>
      metadata.cached('design:$key', () => queries.first(alternatives, params: params));
}
