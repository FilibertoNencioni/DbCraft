import 'dart:async';

import '../../model/db_objects.dart';
import '../../services/metadata_service.dart';
import '../../services/sql_dialect.dart';
import 'schema_model.dart';

/// Thrown by [SchemaSnapshot.load] when the operation is cancelled.
class SnapshotCancelled implements Exception {
  @override
  String toString() => 'Operazione annullata';
}

/// Cooperative cancellation flag shared with long running loaders.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;

  void check() {
    if (_cancelled) throw SnapshotCancelled();
  }
}

/// Tables of one schema (with columns, keys and indexes) at a point in time.
class SchemaSnapshot {
  SchemaSnapshot({this.catalog, this.schema, required this.tables, this.family = DbFamily.generic, this.label = ''});

  final String? catalog;
  final String? schema;
  final List<TableDef> tables;

  /// Dialect family of the database the snapshot comes from.
  final DbFamily family;

  /// Human readable origin (connection › catalog › schema).
  final String label;

  TableDef? table(String name, {bool ignoreCase = true}) {
    for (final t in tables) {
      if (ignoreCase ? t.name.toLowerCase() == name.toLowerCase() : t.name == name) return t;
    }
    return null;
  }

  /// Reads the tables of [catalog].[schema] through [md].
  ///
  /// At most [concurrency] tables are read at the same time (the requests are
  /// queued on the metadata session anyway, this keeps the pipe full without
  /// flooding it). [filter] selects the tables to include; views and system
  /// tables are always skipped. [onProgress] reports (done, total, table).
  static Future<SchemaSnapshot> load(
    MetadataService md, {
    String? catalog,
    String? schema,
    bool Function(DbTable t)? filter,
    int concurrency = 4,
    void Function(int done, int total, String table)? onProgress,
    CancelToken? cancel,
    String label = '',
  }) async {
    final all = await md.tables(catalog, schema);
    cancel?.check();
    final tables = all
        .where((t) => !t.isView && !t.type.toUpperCase().contains('SYSTEM'))
        .where((t) => t.type.toUpperCase().contains('TABLE'))
        .where((t) => filter == null || filter(t))
        .toList();
    final result = List<TableDef?>.filled(tables.length, null);
    var next = 0, done = 0;
    onProgress?.call(0, tables.length, '');

    Future<void> worker() async {
      while (true) {
        cancel?.check();
        if (next >= tables.length) return;
        final i = next++;
        final t = tables[i];
        final parts = await Future.wait<Object?>([md.columns(t), md.primaryKey(t), md.foreignKeys(t), md.indexes(t)]);
        cancel?.check();
        result[i] = TableDef.fromMetadata(
          t,
          parts[0] as List<DbColumn>,
          primaryKey: parts[1] as DbPrimaryKey?,
          foreignKeys: parts[2] as List<DbForeignKey>,
          indexes: parts[3] as List<DbIndex>,
        );
        done++;
        onProgress?.call(done, tables.length, t.name);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency.clamp(1, 16); i++) worker()]);
    return SchemaSnapshot(
      catalog: catalog,
      schema: schema,
      tables: result.whereType<TableDef>().toList(),
      family: md.dialect.family,
      label: label,
    );
  }
}
