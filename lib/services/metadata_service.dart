import '../model/db_objects.dart';
import '../drivers/db_session.dart';
import '../odbc/odbc_types.dart';
import 'sql_dialect.dart';

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v.toString().trim());
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

bool _same(String? a, String? b) => (a ?? '') == (b ?? '');

/// Reads and caches database metadata through the ODBC catalog functions.
class MetadataService {
  MetadataService(this.session, this.info) : dialect = SqlDialect.fromInfo(info);

  final DbSession session;
  final Map<String, Object?> info;
  final SqlDialect dialect;

  final Map<String, Object> _cache = {};

  bool get supportsCatalogs {
    final usage = info['catalogUsage'] as int? ?? 0;
    final name = info['catalogSupported'] as String?;
    return usage != 0 && name != 'N';
  }

  bool get supportsSchemas => (info['schemaUsage'] as int? ?? 0) != 0;

  bool get supportsProcedures => info['proceduresSupported'] != 'N';

  String get catalogTerm => _term(info['catalogTerm'], 'Database');
  String get schemaTerm => _term(info['schemaTerm'], 'Schema');

  static String _term(Object? v, String def) {
    final s = (v as String?)?.trim() ?? '';
    if (s.isEmpty) return def;
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }

  String? get currentCatalog => _str(info['currentCatalog']);

  void clearCache([String? prefix]) {
    if (prefix == null) {
      _cache.clear();
    } else {
      _cache.removeWhere((k, _) => k.startsWith(prefix));
    }
  }

  /// Caches the result of [load] under [key] until [clearCache]. The design
  /// tools use it for their DBMS specific catalog queries (keys prefixed
  /// `design:`).
  Future<T> cached<T extends Object>(String key, Future<T> Function() load) => _cached(key, load);

  Future<T> _cached<T extends Object>(String key, Future<T> Function() load) async {
    final hit = _cache[key];
    if (hit != null) return hit as T;
    final v = await load();
    _cache[key] = v;
    return v;
  }

  // -------------------------------------------------------------------------

  Future<List<String>> catalogs() => _cached('catalogs', () async {
    if (!supportsCatalogs) return <String>[];
    final r = await session.catalog('tables', ['%', '', '', '']);
    final set = <String>{};
    for (final row in r.rows) {
      final c = _str(row[0]);
      if (c != null) set.add(c);
    }
    if (set.isEmpty && currentCatalog != null) set.add(currentCatalog!);
    return set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  });

  Future<List<String>> schemas(String? catalog) => _cached('schemas:${catalog ?? ''}', () async {
    if (!supportsSchemas) return <String>[];
    final set = <String>{};
    if (catalog != null && supportsCatalogs) {
      try {
        await session.setCurrentCatalog(catalog);
      } catch (_) {
        // Not allowed: rely on the catalog argument below.
      }
    }
    try {
      final r = await session.catalog('tables', ['', '%', '', '']);
      for (final row in r.rows) {
        final cat = _str(row[0]);
        final s = _str(row[1]);
        if (s == null) continue;
        if (catalog != null && cat != null && cat != catalog) continue;
        set.add(s);
      }
    } catch (_) {}
    if (set.isEmpty) {
      // Fallback: derive schemas from the table list.
      final r = await session.catalog('tables', [catalog, '%', '%', null]);
      for (final row in r.rows) {
        final s = _str(row[1]);
        if (s != null) set.add(s);
      }
    }
    return set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  });

  Future<List<String>> tableTypes() => _cached('tableTypes', () async {
    try {
      final r = await session.catalog('tables', ['', '', '', '%']);
      return r.rows.map((e) => _str(e[3])).whereType<String>().toList();
    } catch (_) {
      return <String>['TABLE', 'VIEW'];
    }
  });

  Future<List<DbTable>> tables(String? catalog, String? schema) =>
      _cached('tables:${catalog ?? ''}:${schema ?? ''}', () async {
        final r = await session.catalog('tables', [
          catalog,
          schema ?? (supportsSchemas ? '%' : null),
          '%',
          null,
        ]);
        final list = <DbTable>[];
        for (final row in r.rows) {
          final cat = _str(row[0]);
          final sch = _str(row[1]);
          if (catalog != null && cat != null && cat != catalog) continue;
          if (schema != null && sch != null && sch != schema) continue;
          list.add(
            DbTable(
              catalog: cat ?? catalog,
              schema: sch ?? schema,
              name: _str(row[2]) ?? '',
              type: _str(row[3]) ?? 'TABLE',
              remarks: _str(row[4]),
            ),
          );
        }
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return list;
      });

  Future<List<DbColumn>> columns(DbTable t) => _cached('columns:${t.key}', () async {
    final r = await session.catalog('columns', [t.catalog, t.schema, t.name, null]);
    final idxAuto = r.columns.indexWhere(
      (c) =>
          c.name.toUpperCase() == 'IS_AUTOINCREMENT' ||
          c.name.toUpperCase() == 'SS_IS_IDENTITY' ||
          c.name.toUpperCase() == 'AUTO_INCREMENT',
    );
    final cols = <DbColumn>[];
    for (final row in r.rows) {
      if (_str(row[2]) != t.name) continue;
      if (!_same(_str(row[1]), t.schema) && _str(row[1]) != null && t.schema != null) continue;
      final typeName = _str(row[5]) ?? '';
      final def = row.length > 12 ? _str(row[12]) : null;
      final autoFlag = idxAuto >= 0 ? row[idxAuto] : null;
      final auto =
          autoFlag == 'YES' ||
          autoFlag == 1 ||
          typeName.toLowerCase().contains('identity') ||
          typeName.toLowerCase().contains('serial') ||
          typeName.toLowerCase().contains('auto_increment') ||
          (def?.toLowerCase().contains('nextval(') ?? false);
      cols.add(
        DbColumn(
          name: _str(row[3]) ?? '',
          dataType: _int(row[4]) ?? 0,
          typeName: typeName,
          size: _int(row[6]),
          decimals: _int(row[8]),
          nullable: (_int(row[10]) ?? 1) != 0,
          remarks: _str(row[11]),
          defaultValue: def,
          position: row.length > 16 ? (_int(row[16]) ?? cols.length + 1) : cols.length + 1,
          autoIncrement: auto,
        ),
      );
    }
    cols.sort((a, b) => a.position.compareTo(b.position));
    return cols;
  });

  Future<DbPrimaryKey?> primaryKey(DbTable t) async {
    final key = 'pk:${t.key}';
    if (_cache.containsKey(key)) {
      final v = _cache[key];
      return v is DbPrimaryKey ? v : null;
    }
    DbPrimaryKey? pk;
    try {
      final r = await session.catalog('primaryKeys', [t.catalog, t.schema, t.name]);
      final cols = <(int, String)>[];
      String? name;
      for (final row in r.rows) {
        cols.add((_int(row[4]) ?? cols.length + 1, _str(row[3]) ?? ''));
        name ??= _str(row[5]);
      }
      cols.sort((a, b) => a.$1.compareTo(b.$1));
      if (cols.isNotEmpty) pk = DbPrimaryKey(name, cols.map((e) => e.$2).toList());
    } catch (_) {}
    _cache[key] = pk ?? false;
    return pk;
  }

  List<DbForeignKey> _mapForeignKeys(ResultPage r) {
    final groups = <String, List<List<Object?>>>{};
    for (final row in r.rows) {
      final k = '${_str(row[11]) ?? ''}|${_str(row[2])}|${_str(row[6])}';
      groups.putIfAbsent(k, () => []).add(row);
    }
    final list = <DbForeignKey>[];
    for (final rows in groups.values) {
      rows.sort((a, b) => (_int(a[8]) ?? 0).compareTo(_int(b[8]) ?? 0));
      final f = rows.first;
      list.add(
        DbForeignKey(
          name: _str(f[11]),
          pkCatalog: _str(f[0]),
          pkSchema: _str(f[1]),
          pkTable: _str(f[2]) ?? '',
          fkCatalog: _str(f[4]),
          fkSchema: _str(f[5]),
          fkTable: _str(f[6]) ?? '',
          columns: rows.map((e) => _str(e[7]) ?? '').toList(),
          refColumns: rows.map((e) => _str(e[3]) ?? '').toList(),
          updateRule: _int(f[9]),
          deleteRule: _int(f[10]),
        ),
      );
    }
    return list;
  }

  /// Foreign keys declared on [t].
  Future<List<DbForeignKey>> foreignKeys(DbTable t) => _cached('fk:${t.key}', () async {
    try {
      final r = await session.catalog('foreignKeys', [null, null, null, t.catalog, t.schema, t.name]);
      return _mapForeignKeys(r);
    } catch (_) {
      return <DbForeignKey>[];
    }
  });

  /// Foreign keys of other tables referencing [t].
  Future<List<DbForeignKey>> referencedBy(DbTable t) => _cached('refs:${t.key}', () async {
    try {
      final r = await session.catalog('foreignKeys', [t.catalog, t.schema, t.name, null, null, null]);
      return _mapForeignKeys(r);
    } catch (_) {
      return <DbForeignKey>[];
    }
  });

  Future<List<DbIndex>> indexes(DbTable t) => _cached('ix:${t.key}', () async {
    try {
      final r = await session.catalog('statistics', [t.catalog, t.schema, t.name]);
      final map = <String, (bool, int?, List<(int, String)>)>{};
      for (final row in r.rows) {
        final type = _int(row[6]);
        if (type == 0) continue; // SQL_TABLE_STAT
        final name = _str(row[5]);
        if (name == null) continue;
        final nonUnique = _int(row[3]) ?? 1;
        final e = map.putIfAbsent(name, () => (nonUnique == 0, type, []));
        e.$3.add((_int(row[7]) ?? e.$3.length + 1, _str(row[8]) ?? ''));
      }
      return map.entries.map((e) {
        final cols = e.value.$3..sort((a, b) => a.$1.compareTo(b.$1));
        return DbIndex(
          name: e.key,
          unique: e.value.$1,
          type: e.value.$2,
          columns: cols.map((c) => c.$2).toList(),
        );
      }).toList();
    } catch (_) {
      return <DbIndex>[];
    }
  });

  Future<TableDetails> tableDetails(DbTable t) async {
    final results = await Future.wait<Object?>([
      columns(t),
      primaryKey(t),
      foreignKeys(t),
      referencedBy(t),
      indexes(t),
    ]);
    return TableDetails(
      table: t,
      columns: results[0] as List<DbColumn>,
      primaryKey: results[1] as DbPrimaryKey?,
      foreignKeys: results[2] as List<DbForeignKey>,
      referencedBy: results[3] as List<DbForeignKey>,
      indexes: results[4] as List<DbIndex>,
    );
  }

  Future<List<DbProcedure>> procedures(String? catalog, String? schema) =>
      _cached('procs:${catalog ?? ''}:${schema ?? ''}', () async {
        if (!supportsProcedures) return <DbProcedure>[];
        try {
          final r = await session.catalog('procedures', [
            catalog,
            schema ?? (supportsSchemas ? '%' : null),
            '%',
          ]);
          final list = <DbProcedure>[];
          for (final row in r.rows) {
            final sch = _str(row[1]);
            if (schema != null && sch != null && sch != schema) continue;
            list.add(
              DbProcedure(
                catalog: _str(row[0]) ?? catalog,
                schema: sch ?? schema,
                name: _str(row[2]) ?? '',
                remarks: row.length > 6 ? _str(row[6]) : null,
                type: row.length > 7 ? (_int(row[7]) ?? 0) : 0,
              ),
            );
          }
          list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          return list;
        } catch (_) {
          return <DbProcedure>[];
        }
      });

  Future<List<DbProcedureParam>> procedureParams(DbProcedure p) => _cached('procparams:${p.key}', () async {
    try {
      final r = await session.catalog('procedureColumns', [p.catalog, p.schema, p.name, null]);
      final list = <DbProcedureParam>[];
      for (final row in r.rows) {
        list.add(
          DbProcedureParam(
            name: _str(row[3]) ?? '',
            columnType: _int(row[4]) ?? 0,
            typeName: _str(row[6]) ?? '',
            size: _int(row[7]),
            position: row.length > 17 ? (_int(row[17]) ?? list.length) : list.length,
          ),
        );
      }
      list.sort((a, b) => a.position.compareTo(b.position));
      return list;
    } catch (_) {
      return <DbProcedureParam>[];
    }
  });

  Future<ResultPage> typeInfo() => session.catalog('typeInfo', const []);

  /// Finds the table object matching an (optionally qualified) name.
  Future<DbTable?> findTable(String? catalog, String? schema, String name) async {
    try {
      final r = await session.catalog('tables', [catalog, schema, name, null]);
      for (final row in r.rows) {
        if ((_str(row[2]) ?? '').toLowerCase() == name.toLowerCase()) {
          return DbTable(
            catalog: _str(row[0]),
            schema: _str(row[1]),
            name: _str(row[2])!,
            type: _str(row[3]) ?? 'TABLE',
            remarks: _str(row[4]),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  /// Snapshot of cached table names for autocompletion.
  List<DbTable> get cachedTables => _cache.entries
      .where((e) => e.key.startsWith('tables:'))
      .expand((e) => e.value as List<DbTable>)
      .toList();

  List<DbColumn>? cachedColumns(DbTable t) => _cache['columns:${t.key}'] as List<DbColumn>?;
}
