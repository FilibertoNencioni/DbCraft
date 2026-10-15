// DbSession implementation for Apache Cassandra (CQL native protocol).
// Keyspaces are the catalogs; tables, views, columns, primary keys and
// indexes come from system_schema (Cassandra 3.0+ / ScyllaDB).
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../odbc/odbc_ffi.dart';
import '../../odbc/odbc_types.dart';
import '../common/native_exception.dart';
import '../common/native_session_base.dart';
import '../common/net.dart';
import '../common/sql_subset.dart';
import '../db_session.dart';
import '../native_driver.dart';
import 'cql_connection.dart';
import 'cql_protocol.dart';

/// System keyspaces (their tables are listed as SYSTEM TABLE).
const cassandraSystemKeyspaces = {
  'system', 'system_schema', 'system_auth', 'system_distributed', 'system_traces', 'system_views', //
  'system_virtual_schema', 'system_distributed_everywhere', 'system_replicated_keys', 'dse_system', 'dse_security',
  'dse_perf', 'dse_insights', 'dse_insights_local', 'dse_leases', 'dse_system_local', 'solr_admin',
};

/// ODBC SQL type of a CQL type name.
int sqlTypeForCql(String type) {
  final t = type.toLowerCase().trim();
  if (t.startsWith('frozen<') ||
      t.startsWith('list<') ||
      t.startsWith('set<') ||
      t.startsWith('map<') ||
      t.startsWith('tuple<')) {
    return SQL_LONGVARCHAR;
  }
  return switch (t) {
    'int' => SQL_INTEGER,
    'bigint' || 'counter' => SQL_BIGINT,
    'smallint' => SQL_SMALLINT,
    'tinyint' => SQL_TINYINT,
    'float' => SQL_REAL,
    'double' => SQL_DOUBLE,
    'decimal' => SQL_DECIMAL,
    'varint' => SQL_NUMERIC,
    'blob' => SQL_VARBINARY,
    'timestamp' => SQL_TYPE_TIMESTAMP,
    'date' => SQL_TYPE_DATE,
    'time' => SQL_TYPE_TIME,
    'uuid' || 'timeuuid' => SQL_GUID,
    'text' || 'varchar' || 'ascii' || 'inet' || 'boolean' || 'duration' => SQL_VARCHAR,
    _ => SQL_VARCHAR,
  };
}

/// Splits a CQL script on ';' outside strings, quoted identifiers, $$ blocks
/// and comments. Comment-only statements are dropped.
List<String> splitCql(String text) {
  final out = <String>[];
  final sb = StringBuffer();
  var hasCode = false;
  var i = 0;
  void flush() {
    final s = sb.toString().trim();
    if (s.isNotEmpty && hasCode) out.add(s);
    sb.clear();
    hasCode = false;
  }

  while (i < text.length) {
    final c = text[i];
    if (c == "'" || c == '"') {
      var j = i + 1;
      while (j < text.length) {
        if (text[j] == c) {
          if (j + 1 < text.length && text[j + 1] == c) {
            j += 2;
            continue;
          }
          break;
        }
        j++;
      }
      sb.write(text.substring(i, min(j + 1, text.length)));
      hasCode = true;
      i = j + 1;
    } else if (text.startsWith(r'$$', i)) {
      final e = text.indexOf(r'$$', i + 2);
      final end = e < 0 ? text.length : e + 2;
      sb.write(text.substring(i, end));
      hasCode = true;
      i = end;
    } else if (text.startsWith('--', i) || text.startsWith('//', i)) {
      final e = text.indexOf('\n', i);
      i = e < 0 ? text.length : e;
    } else if (text.startsWith('/*', i)) {
      final e = text.indexOf('*/', i + 2);
      i = e < 0 ? text.length : e + 2;
      sb.write(' ');
    } else if (c == ';') {
      flush();
      i++;
    } else {
      if (c.trim().isNotEmpty) hasCode = true;
      sb.write(c);
      i++;
    }
  }
  flush();
  return out;
}

final _writeCql = RegExp(
  r'^\s*(insert|update|delete|truncate|create|alter|drop|grant|revoke|begin|apply)\b',
  caseSensitive: false,
);

String _lit(String s) => "'${s.replaceAll("'", "''")}'";

String _ident(String s) => RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(s) ? s : '"${s.replaceAll('"', '""')}"';

class CassandraSession extends NativeSessionBase {
  CassandraSession._(
    this._p,
    this._conn,
    this._host,
    this._port,
    this._net, {
    required this.consistency,
    required this.pageSize,
  }) : readOnly = _p.readOnly;

  static Future<CassandraSession> open(NativeConnectParams p) async {
    final port = int.tryParse(p.port.trim()) ?? 9042;
    final hosts = [
      for (final h in p.host.split(','))
        if (h.trim().isNotEmpty) h.trim(),
    ];
    if (hosts.isEmpty) hosts.add('localhost');
    final net = NetOptions(
      tls: p.flag('tls'),
      caFile: p.option('tlsCaFile'),
      allowInvalidCertificates: p.flag('tlsAllowInvalid'),
      certFile: p.option('tlsCertFile'),
      keyFile: p.option('tlsCertFile'),
      keyPassword: p.option('tlsKeyPassword'),
      timeout: Duration(seconds: p.loginTimeoutSec <= 0 ? 15 : p.loginTimeoutSec),
    );
    final user = p.option('authMethod', 'password') == 'none' ? '' : p.user;
    final errors = <String>[];
    CqlConnection? conn;
    var host = hosts.first;
    var hp = port;
    for (final h in hosts) {
      final i = h.lastIndexOf(':');
      host = i > 0 && !h.contains(']') && h.indexOf(':') == i ? h.substring(0, i) : h;
      hp = i > 0 && h.indexOf(':') == i ? int.tryParse(h.substring(i + 1)) ?? port : port;
      try {
        conn = await CqlConnection.connect(
          host,
          hp,
          net,
          user: user,
          password: p.password,
        ).timeout(net.timeout * 2, onTimeout: () => throw NativeDbException('Timeout di connessione a Cassandra ($h)'));
        break;
      } catch (e) {
        errors.add('$h: ${e is NativeDbException ? e.message : e}');
        if (e is NativeDbException && e.code == 'Bad credentials') rethrow;
      }
    }
    if (conn == null) throw NativeDbException('Connessione a Cassandra non riuscita:\n${errors.join('\n')}');
    final consistency =
        cqlConsistency[p.option('consistency', 'LOCAL_ONE').toUpperCase()] ?? cqlConsistency['LOCAL_ONE']!;
    // Prefer a node of the requested datacenter.
    final dc = p.option('localDatacenter');
    if (dc.isNotEmpty) {
      try {
        final local = await _rows(conn, 'SELECT data_center FROM system.local', consistency);
        if (local.isNotEmpty && local.first[0] != dc) {
          final peers = await _rows(conn, 'SELECT peer, rpc_address, data_center FROM system.peers', consistency);
          for (final r in peers) {
            if (r[2] != dc) continue;
            final addr = (r[1] == null || r[1] == '0.0.0.0' || r[1] == '::') ? r[0] as String : r[1] as String;
            try {
              final other = await CqlConnection.connect(addr, hp, net, user: user, password: p.password);
              await conn!.close();
              conn = other;
              host = addr;
              break;
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    final s = CassandraSession._(
      p,
      conn!,
      host,
      hp,
      net,
      consistency: consistency,
      pageSize: int.tryParse(p.option('pageSize', '0')) ?? 0,
    );
    final ks = p.database.trim();
    if (ks.isNotEmpty) {
      try {
        await conn.query('USE ${_ident(ks)}', consistency: consistency);
        s._keyspace = ks;
      } catch (e) {
        await conn.close();
        rethrow;
      }
    }
    return s;
  }

  static Future<List<List<Object?>>> _rows(CqlConnection c, String cql, int consistency) async {
    final out = <List<Object?>>[];
    Uint8List? paging;
    do {
      final r = await c.query(cql, consistency: consistency, pageSize: 1000, pagingState: paging);
      final rows = r.rows;
      if (rows == null) break;
      for (final row in rows.rows) {
        out.add([for (var i = 0; i < rows.columns.length; i++) decodeCqlValue(rows.columns[i].type, row[i])]);
      }
      paging = rows.pagingState;
    } while (paging != null);
    return out;
  }

  final NativeConnectParams _p;
  CqlConnection? _conn;
  final String _host;
  final int _port;
  final NetOptions _net;
  final int consistency;
  final int pageSize;
  final bool readOnly;
  String? _keyspace;
  Map<String, Object?>? _local;

  /// Prepared statements by CQL text.
  final Map<String, CqlResult> _prepared = {};

  @override
  String get engineName => 'Cassandra';

  @override
  String get completedConnectionString =>
      'cassandra://${_p.user.isEmpty ? '' : '${Uri.encodeComponent(_p.user)}@'}$_host:$_port${_keyspace == null ? '' : '/$_keyspace'}';

  Future<CqlConnection> _c() async {
    final c = _conn;
    if (c != null && !c.isClosed) return c;
    dropCursors();
    _prepared.clear();
    _conn = null;
    final user = _p.option('authMethod', 'password') == 'none' ? '' : _p.user;
    final n = await CqlConnection.connect(_host, _port, _net, user: user, password: _p.password);
    if (_keyspace != null) await n.query('USE ${_ident(_keyspace!)}', consistency: consistency);
    _conn = n;
    return n;
  }

  @override
  void abortConnection(String reason) {
    _conn?.abort(reason);
    _conn = null;
  }

  @override
  Future<void> closeConnection() async {
    final c = _conn;
    _conn = null;
    await c?.close();
  }

  // -------------------------------------------------------------------------
  // Info / catalog
  // -------------------------------------------------------------------------

  @override
  Future<Map<String, Object?>> info() => exclusive(() async {
    if (_local == null) {
      try {
        final c = await _c();
        final r = await c.query('SELECT * FROM system.local', consistency: consistency);
        final rows = r.rows;
        if (rows != null && rows.rows.isNotEmpty) {
          _local = {
            for (var i = 0; i < rows.columns.length; i++)
              rows.columns[i].name: decodeCqlValue(rows.columns[i].type, rows.rows.first[i]),
          };
        }
      } catch (_) {}
      _local ??= {};
    }
    final l = _local!;
    final dse = l['dse_version'];
    return {
      'dbmsName': 'Apache Cassandra',
      'dbmsVersion': dse != null ? 'DSE $dse' : (l['release_version']?.toString() ?? ''),
      'driverName': 'DbCraft Cassandra',
      'driverVersion': cassandraDriverVersion,
      'serverName': '$_host:$_port${l['cluster_name'] == null ? '' : ' (${l['cluster_name']})'}',
      'databaseName': _keyspace ?? '',
      'userName': _p.user,
      'identifierQuote': '"',
      'catalogTerm': 'Keyspace',
      'schemaTerm': '',
      'catalogSupported': 'Y',
      'catalogUsage': 1,
      'schemaUsage': 0,
      'proceduresSupported': 'N',
      'currentCatalog': _keyspace,
      'catalogSeparator': '.',
      'keywords': 'KEYSPACE,KEYSPACES,ALLOW,FILTERING,TTL,WRITETIME,TOKEN,FROZEN,COUNTER,MATERIALIZED',
      'nativeDriver': 'cassandra',
      'queryLanguage': 'cql',
      'cqlVersion': l['cql_version']?.toString() ?? '',
      'dataCenter': l['data_center']?.toString() ?? '',
      'protocolVersion': _conn?.version,
    };
  });

  @override
  Future<void> setCurrentCatalog(String catalog) => exclusive(() async {
    final c = await _c();
    await c.query('USE ${_ident(catalog)}', consistency: consistency);
    _keyspace = catalog;
  });

  @override
  Future<String?> currentCatalog() async => _keyspace;

  Future<List<List<Object?>>> _q(String cql) async => _rows(await _c(), cql, consistency);

  Future<List<String>> _keyspaces() async {
    final r = await _q('SELECT keyspace_name FROM system_schema.keyspaces');
    return [for (final row in r) row[0] as String]..sort();
  }

  static bool _like(String? pattern, String value) {
    if (pattern == null || pattern.isEmpty || pattern == '%') return true;
    return likeToRegExp(pattern).hasMatch(value);
  }

  @override
  Future<ResultPage> catalog(String function, List<String?> args) => exclusive(() async {
    String? a(int i) => i < args.length ? args[i] : null;
    bool empty(String? s) => s == null || s.isEmpty;
    switch (function) {
      case 'tables':
        final cat = a(0), sch = a(1), name = a(2), type = a(3);
        if (cat == '%' && empty(sch) && empty(name)) {
          return catalogResult(CatalogColumns.tables, [
            for (final k in await _keyspaces()) [k, null, null, null, null],
          ]);
        }
        if (sch == '%' && empty(cat) && empty(name)) return catalogResult(CatalogColumns.tables, const []);
        if (type == '%' && empty(cat) && empty(sch) && empty(name)) {
          return catalogResult(CatalogColumns.tables, [
            for (final t in const ['TABLE', 'VIEW', 'SYSTEM TABLE']) [null, null, null, t, null],
          ]);
        }
        final where = empty(cat) || cat == '%'
            ? (_keyspace == null || cat == '%' ? '' : ' WHERE keyspace_name = ${_lit(_keyspace!)}')
            : ' WHERE keyspace_name = ${_lit(cat!)}';
        final types = type == null || type.isEmpty || type == '%'
            ? null
            : type.split(',').map((e) => e.trim().replaceAll("'", '').toUpperCase()).toSet();
        final rows = <List<Object?>>[];
        for (final r in await _q('SELECT keyspace_name, table_name, comment FROM system_schema.tables$where')) {
          final ks = r[0] as String, t = r[1] as String;
          if (!_like(name, t)) continue;
          final tt = cassandraSystemKeyspaces.contains(ks) ? 'SYSTEM TABLE' : 'TABLE';
          if (types != null && !types.contains(tt)) continue;
          final comment = (r[2] as String?) ?? '';
          rows.add([ks, null, t, tt, comment.isEmpty ? null : comment]);
        }
        try {
          for (final r in await _q('SELECT keyspace_name, view_name, base_table_name FROM system_schema.views$where')) {
            if (!_like(name, r[1] as String)) continue;
            if (types != null && !types.contains('VIEW')) continue;
            rows.add([r[0], null, r[1], 'VIEW', 'Vista materializzata su ${r[2]}']);
          }
        } catch (_) {}
        return catalogResult(CatalogColumns.tables, rows);
      case 'columns':
        final ks = empty(a(0)) ? _keyspace : a(0);
        if (ks == null) return catalogResult(CatalogColumns.columns, const []);
        final table = a(2) ?? '';
        final cols = await _columns(ks, table);
        return catalogResult(CatalogColumns.columns, [
          for (var i = 0; i < cols.length; i++)
            if (_like(a(3), cols[i].name))
              [
                ks, null, table, cols[i].name, sqlTypeForCql(cols[i].type), cols[i].type, null, null, null, null, //
                cols[i].isKey ? 0 : 1, cols[i].remark, null, sqlTypeForCql(cols[i].type), null, null, i + 1,
                cols[i].isKey ? 'NO' : 'YES',
              ],
        ]);
      case 'primaryKeys':
        final ks = empty(a(0)) ? _keyspace : a(0);
        if (ks == null) return catalogResult(CatalogColumns.primaryKeys, const []);
        final table = a(2) ?? '';
        final cols = (await _columns(ks, table)).where((c) => c.isKey).toList();
        return catalogResult(CatalogColumns.primaryKeys, [
          for (var i = 0; i < cols.length; i++) [ks, null, table, cols[i].name, i + 1, 'PRIMARY KEY'],
        ]);
      case 'statistics':
        final ks = empty(a(0)) ? _keyspace : a(0);
        if (ks == null) return catalogResult(CatalogColumns.statistics, const []);
        final table = a(2) ?? '';
        final rows = <List<Object?>>[];
        try {
          final r = await _q(
            'SELECT index_name, kind, options FROM system_schema.indexes '
            'WHERE keyspace_name = ${_lit(ks)} AND table_name = ${_lit(table)}',
          );
          for (final ix in r) {
            final opts = (ix[2] as Map?) ?? const {};
            var target = opts['target']?.toString() ?? '';
            final m = RegExp(r'^(?:values|keys|entries|full)\((.*)\)$').firstMatch(target);
            if (m != null) target = m.group(1)!;
            if (target.startsWith('"') && target.endsWith('"')) target = target.substring(1, target.length - 1);
            var pos = 0;
            for (final col in target.split(',')) {
              pos++;
              rows.add([ks, null, table, 1, null, ix[0], 3, pos, col.trim(), null, null, null, ix[1]]);
            }
          }
        } catch (_) {}
        return catalogResult(CatalogColumns.statistics, rows);
      case 'foreignKeys':
        return catalogResult(CatalogColumns.foreignKeys, const []);
      case 'procedures':
        return catalogResult(CatalogColumns.procedures, const []);
      default:
        return catalogResult(const ['NAME'], const []);
    }
  });

  Future<List<_Col>> _columns(String ks, String table) async {
    final r = await _q(
      'SELECT column_name, clustering_order, kind, position, type FROM system_schema.columns '
      'WHERE keyspace_name = ${_lit(ks)} AND table_name = ${_lit(table)}',
    );
    final cols = [
      for (final row in r)
        _Col(
          row[0] as String,
          row[4] as String,
          row[2] as String,
          (row[3] as int?) ?? -1,
          (row[1] as String?) ?? 'none',
        ),
    ];
    int rank(String kind) => switch (kind) {
      'partition_key' => 0,
      'clustering' => 1,
      'static' => 2,
      _ => 3,
    };
    cols.sort((a, b) {
      final k = rank(a.kind).compareTo(rank(b.kind));
      if (k != 0) return k;
      if (a.kind == 'partition_key' || a.kind == 'clustering') return a.position.compareTo(b.position);
      return a.name.compareTo(b.name);
    });
    return cols;
  }

  // -------------------------------------------------------------------------
  // Execution
  // -------------------------------------------------------------------------

  @override
  Future<List<StatementOutcome>> runScript(String sql, List<Object?> params, int fetchSize, int queryTimeoutSec) async {
    final statements = splitCql(sql);
    if (statements.isEmpty) return [StatementOutcome.update(-1)];
    final out = <StatementOutcome>[];
    final size = pageSize > 0 ? pageSize : max(1, fetchSize);
    for (final st in statements) {
      if (readOnly && _writeCql.hasMatch(st)) throw readOnlyError(st.split(RegExp(r'\s+')).first.toUpperCase());
      out.add(await _run(st, statements.length == 1 ? params : const [], size));
    }
    return out;
  }

  Future<StatementOutcome> _run(String cql, List<Object?> params, int size) async {
    final c = await _c();
    final messages = <String>[];
    CqlResult r;
    _Exec exec;
    Future<CqlResult> runOnce(String text) async {
      if (params.isEmpty) {
        exec = _Exec(text, null, const []);
        return c.query(text, consistency: consistency, pageSize: size);
      }
      final prepared = _prepared[text] ??= await c.prepare(text);
      final vars = prepared.boundVariables;
      if (vars.length != params.length) {
        throw NativeDbException('Numero di parametri errato: attesi ${vars.length}, forniti ${params.length}');
      }
      final values = [for (var i = 0; i < vars.length; i++) encodeCqlValue(vars[i].type, params[i])];
      exec = _Exec(text, prepared.preparedId, values);
      try {
        return await c.execute(prepared.preparedId!, values, consistency: consistency, pageSize: size);
      } on CqlException catch (e) {
        if (e.errorCode != 0x2500) rethrow; // Unprepared: prepare again
        final again = _prepared[text] = await c.prepare(text);
        exec = _Exec(text, again.preparedId, values);
        return c.execute(again.preparedId!, values, consistency: consistency, pageSize: size);
      }
    }

    exec = _Exec(cql, null, const []);
    try {
      r = await runOnce(cql);
    } on CqlException catch (e) {
      final isSelect = RegExp(r'^\s*select\b', caseSensitive: false).hasMatch(cql);
      if (e.errorCode == 0x2200 &&
          isSelect &&
          e.message.contains('ALLOW FILTERING') &&
          !RegExp(r'allow\s+filtering', caseSensitive: false).hasMatch(cql)) {
        r = await runOnce('$cql ALLOW FILTERING');
        messages.add('Aggiunto ALLOW FILTERING: la query esamina tutte le partizioni');
      } else {
        rethrow;
      }
    }
    messages.addAll(c.lastWarnings);
    switch (r.kind) {
      case resultRows:
        return StatementOutcome.cursor(_CqlCursor(this, c, exec, r.rows!, size), messages: messages);
      case resultSetKeyspace:
        _keyspace = r.keyspace;
        return StatementOutcome.update(-1, messages: [...messages, 'Keyspace corrente: ${r.keyspace}']);
      case resultSchemaChange:
        return StatementOutcome.update(-1, messages: [...messages, 'Schema modificato: ${r.schemaChange}']);
      default:
        return StatementOutcome.update(-1, messages: [...messages, 'Istruzione eseguita']);
    }
  }
}

class _Col {
  _Col(this.name, this.type, this.kind, this.position, this.order);
  final String name;
  final String type;
  final String kind;
  final int position;
  final String order;

  bool get isKey => kind == 'partition_key' || kind == 'clustering';

  String? get remark => switch (kind) {
    'partition_key' => 'Chiave di partizione',
    'clustering' => 'Clustering (${order.toUpperCase()})',
    'static' => 'Statica',
    _ => null,
  };
}

class _Exec {
  _Exec(this.query, this.preparedId, this.values);
  final String query;
  final Uint8List? preparedId;
  final List<Uint8List?> values;
}

class _CqlCursor implements NativeCursor {
  _CqlCursor(this.session, this.conn, this.exec, CqlRows first, this.pageSize)
    : meta = first.columns,
      _paging = first.pagingState {
    _add(first);
    columns = [
      for (var i = 0; i < meta.length; i++)
        ColumnInfo(
          index: i + 1,
          name: meta[i].name,
          sqlType: sqlTypeForCql(meta[i].type.toString()),
          typeName: meta[i].type.toString(),
          baseTable: meta[i].table.isEmpty ? null : meta[i].table,
          baseColumn: meta[i].name,
          catalog: meta[i].keyspace.isEmpty ? null : meta[i].keyspace,
        ),
    ];
  }

  final CassandraSession session;
  final CqlConnection conn;
  final _Exec exec;
  final List<CqlColumn> meta;
  final int pageSize;
  Uint8List? _paging;
  final List<List<Object?>> _buf = [];
  @override
  late final List<ColumnInfo> columns;

  void _add(CqlRows rows) {
    for (final row in rows.rows) {
      _buf.add([for (var i = 0; i < meta.length && i < row.length; i++) cqlGridValue(meta[i].type, row[i])]);
    }
  }

  @override
  bool get hasMore => _buf.isNotEmpty || _paging != null;

  @override
  Future<List<List<Object?>>> fetch(int count) async {
    while ((count <= 0 || _buf.length < count) && _paging != null) {
      if (conn.isClosed) {
        _paging = null;
        throw NativeDbException('Cursore non più valido: la connessione è stata chiusa');
      }
      final r = exec.preparedId == null
          ? await conn.query(exec.query, consistency: session.consistency, pageSize: pageSize, pagingState: _paging)
          : await conn.execute(
              exec.preparedId!,
              exec.values,
              consistency: session.consistency,
              pageSize: pageSize,
              pagingState: _paging,
            );
      final rows = r.rows;
      if (rows == null) {
        _paging = null;
        break;
      }
      _add(rows);
      _paging = rows.pagingState;
    }
    final n = count <= 0 ? _buf.length : min(count, _buf.length);
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  @override
  Future<void> close() async {
    _buf.clear();
    _paging = null;
  }
}
