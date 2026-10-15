// DbSession implementation for MongoDB: shell commands, SQL subset for the
// data editor, cursors with getMore and ODBC-like catalog emulation
// (databases → catalogs, collections → tables, sampled fields → columns,
// indexes → statistics).
import 'dart:async';
import 'dart:collection';
import 'dart:math';

import '../../odbc/odbc_ffi.dart';
import '../../odbc/odbc_types.dart';
import '../common/native_exception.dart';
import '../common/native_session_base.dart';
import '../common/net.dart';
import '../common/sql_subset.dart';
import '../db_session.dart';
import '../native_driver.dart';
import 'bson.dart';
import 'mongo_connection.dart';
import 'mongo_shell.dart';
import 'mongo_uri.dart';

typedef Doc = Map<String, Object?>;

/// Builds the connection settings from the dialog parameters / URI.
Future<MongoSettings> mongoSettingsFrom(NativeConnectParams p) async {
  var uriText = p.connectionUri.trim();
  if (uriText.isEmpty && p.host.trim().startsWith('mongodb')) uriText = p.host.trim();
  final uri = uriText.isEmpty ? null : MongoUri.parse(uriText);
  String opt(String uriKey, String field, [String def = '']) {
    final u = uri?.option(uriKey);
    if (u != null && u.isNotEmpty) return u;
    return p.option(field, def);
  }

  bool flag(String uriKey, String field, {bool def = false, List<String> alt = const []}) {
    for (final k in [uriKey, ...alt]) {
      final u = uri?.option(k);
      if (u != null && u.isNotEmpty) return u.toLowerCase() == 'true';
    }
    final v = p.option(field);
    return v.isEmpty ? def : p.flag(field);
  }

  final srv = uri?.srv ?? p.flag('srv');
  final port = int.tryParse(p.port.trim()) ?? 27017;
  var seeds =
      uri?.hosts ??
      [
        for (final h in p.host.split(','))
          if (h.trim().isNotEmpty) MongoHost.parse(h.trim(), defaultPort: port),
      ];
  if (seeds.isEmpty) seeds = [MongoHost('localhost', port)];
  final txt = <String, String>{};
  String? srvHost;
  if (srv) {
    srvHost = seeds.first.host;
    final (s, o) = await MongoConnection.resolveSrvSeeds(srvHost);
    seeds = s;
    txt.addAll(o);
  }
  final timeoutMs = int.tryParse(uri?.option('connecttimeoutms') ?? '');
  final net = NetOptions(
    tls: flag('tls', 'tls', def: srv, alt: const ['ssl']),
    caFile: opt('tlscafile', 'tlsCaFile'),
    allowInvalidCertificates: flag('tlsallowinvalidcertificates', 'tlsAllowInvalid', alt: const ['tlsinsecure']),
    certFile: opt('tlscertificatekeyfile', 'tlsCertFile'),
    keyFile: opt('tlscertificatekeyfile', 'tlsCertFile'),
    keyPassword: opt('tlscertificatekeyfilepassword', 'tlsKeyPassword'),
    timeout: timeoutMs != null
        ? Duration(milliseconds: timeoutMs)
        : Duration(seconds: p.loginTimeoutSec <= 0 ? 15 : p.loginTimeoutSec),
  );
  final props = <String, String>{};
  for (final kv in (uri?.option('authmechanismproperties') ?? '').split(',')) {
    final i = kv.indexOf(':');
    if (i > 0) props[kv.substring(0, i)] = kv.substring(i + 1);
  }
  var mech = opt('authmechanism', 'authMechanism').toUpperCase();
  if (mech == 'DEFAULT') mech = '';
  final user = uri?.user ?? p.user;
  final database = uri?.database ?? (p.database.trim().isEmpty ? 'test' : p.database.trim());
  var authSource = uri?.option('authsource') ?? txt['authsource'] ?? p.option('authSource');
  if (authSource.isEmpty && uri?.database != null && uri?.user != null) authSource = uri!.database!;
  return MongoSettings(
    seeds: seeds,
    srvHost: srvHost,
    net: net,
    user: user,
    password: uri?.password ?? p.password,
    authSource: authSource,
    authMechanism: mech,
    mechanismProperties: props,
    replicaSet: uri?.option('replicaset') ?? txt['replicaset'] ?? p.option('replicaSet'),
    readPreference: opt('readpreference', 'readPreference', 'primary'),
    directConnection: flag('directconnection', 'directConnection'),
    appName: opt('appname', 'appName', 'DbCraft'),
    database: database,
    authMethod: p.option('authMethod', 'password'),
    awsProfile: p.option('awsProfile'),
    awsAccessKeyId: p.option('awsAccessKeyId'),
    awsSecretAccessKey: p.option('awsSecretAccessKey'),
    oidcToken: p.option('token'),
  );
}

/// Masked description of the connection.
String mongoDisplayUri(MongoSettings s) {
  final hosts = s.srvHost ?? s.seeds.join(',');
  final user = s.user.isEmpty ? '' : '${Uri.encodeComponent(s.user)}@';
  final opts = [
    if (s.net.tls) 'tls=true',
    if (s.authSource.isNotEmpty) 'authSource=${s.authSource}',
    if (s.replicaSet.isNotEmpty) 'replicaSet=${s.replicaSet}',
    if (s.readPreference != 'primary') 'readPreference=${s.readPreference}',
  ];
  return 'mongodb${s.srvHost != null ? '+srv' : ''}://$user$hosts/${s.database}${opts.isEmpty ? '' : '?${opts.join('&')}'}';
}

class MongoSession extends NativeSessionBase {
  MongoSession._(
    this._settings,
    this._conn, {
    required this.readOnly,
    required this.sampleSize,
    required this.loginTimeoutSec,
  }) : _db = _settings.database;

  static Future<MongoSession> open(NativeConnectParams p) async {
    final st = await mongoSettingsFrom(p);
    final timeout = Duration(seconds: (p.loginTimeoutSec <= 0 ? 15 : p.loginTimeoutSec) * 2 + 5);
    final conn = await MongoConnection.connect(st)
        .timeout(timeout, onTimeout: () => throw NativeDbException('Timeout di connessione a MongoDB'));
    return MongoSession._(
      st,
      conn,
      readOnly: p.readOnly,
      sampleSize: int.tryParse(p.option('sampleSize', '100')) ?? 100,
      loginTimeoutSec: p.loginTimeoutSec,
    );
  }

  final MongoSettings _settings;
  MongoConnection? _conn;
  String _db;
  final bool readOnly;
  final int sampleSize;
  final int loginTimeoutSec;
  Set<String>? _knownDbs;
  Doc? _buildInfo;

  /// Field types per "db.collection", from sampling and result sets.
  final Map<String, Map<String, String>> _types = {};

  @override
  String get engineName => 'MongoDB';

  @override
  String get completedConnectionString => mongoDisplayUri(_settings);

  Future<MongoConnection> _c() async {
    final c = _conn;
    if (c != null && !c.isClosed) return c;
    dropCursors();
    _conn = null;
    final n = await MongoConnection.connect(_settings).timeout(
      Duration(seconds: (loginTimeoutSec <= 0 ? 15 : loginTimeoutSec) * 2 + 5),
      onTimeout: () => throw NativeDbException('Timeout di riconnessione a MongoDB'),
    );
    _conn = n;
    return n;
  }

  Future<Doc> _cmd(String db, Doc cmd) async => (await _c()).command(db, cmd);

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
    try {
      _buildInfo ??= await _cmd('admin', {'buildInfo': 1});
    } catch (_) {
      _buildInfo = {};
    }
    final c = await _c();
    return {
      'dbmsName': 'MongoDB',
      'dbmsVersion': _buildInfo?['version']?.toString() ?? '',
      'driverName': 'DbCraft MongoDB',
      'driverVersion': mongoDriverVersion,
      'serverName': c.address.toString(),
      'databaseName': _db,
      'userName': _settings.user,
      'identifierQuote': '',
      'catalogTerm': 'Database',
      'schemaTerm': 'Collection',
      'catalogSupported': 'Y',
      'catalogUsage': 1,
      'schemaUsage': 0,
      'proceduresSupported': 'N',
      'currentCatalog': _db,
      'catalogSeparator': '.',
      'keywords': '',
      'nativeDriver': 'mongodb',
      'queryLanguage': 'mongo',
      'replicaSet': c.hello['setName']?.toString() ?? '',
      'secondary': c.secondary,
    };
  });

  @override
  Future<void> setCurrentCatalog(String catalog) async => _db = catalog;

  @override
  Future<String?> currentCatalog() async => _db;

  Future<List<String>> _databases() async {
    Doc r;
    try {
      r = await _cmd('admin', {'listDatabases': 1, 'nameOnly': true});
    } on MongoCommandException {
      try {
        r = await _cmd('admin', {'listDatabases': 1, 'nameOnly': true, 'authorizedDatabases': true});
      } on MongoCommandException {
        return [_db];
      }
    }
    final names = [for (final d in (r['databases'] as List? ?? const [])) (d as Map)['name'].toString()];
    if (!names.contains(_db)) names.add(_db);
    _knownDbs = names.toSet();
    return names;
  }

  Future<List<Doc>> _drain(String db, Doc reply, {int max = 100000}) async {
    final cur = reply['cursor'] as Map? ?? const {};
    final out = <Doc>[for (final d in (cur['firstBatch'] as List? ?? const [])) (d as Map).cast<String, Object?>()];
    var id = bsonInt(cur['id']) ?? 0;
    final ns = cur['ns']?.toString() ?? '';
    final coll = ns.contains('.') ? ns.substring(ns.indexOf('.') + 1) : ns;
    while (id != 0 && out.length < max) {
      final r = await _cmd(db, {'getMore': BsonInt64(id), 'collection': coll});
      final c = r['cursor'] as Map;
      out.addAll([for (final d in (c['nextBatch'] as List? ?? const [])) (d as Map).cast<String, Object?>()]);
      id = bsonInt(c['id']) ?? 0;
    }
    if (id != 0) {
      try {
        await _cmd(db, {
          'killCursors': coll,
          'cursors': [BsonInt64(id)],
        });
      } catch (_) {}
    }
    return out;
  }

  Future<List<Doc>> _collections(String db, {Doc? filter}) async {
    final r = await _cmd(db, {
      'listCollections': 1,
      'nameOnly': filter == null,
      'authorizedCollections': true,
      'filter': ?filter,
    });
    return _drain(db, r);
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
          final dbs = await _databases();
          return catalogResult(CatalogColumns.tables, [
            for (final d in dbs) [d, null, null, null, null],
          ]);
        }
        if (sch == '%' && empty(cat) && empty(name)) return catalogResult(CatalogColumns.tables, const []);
        if (type == '%' && empty(cat) && empty(sch) && empty(name)) {
          return catalogResult(CatalogColumns.tables, [
            for (final t in const ['TABLE', 'VIEW', 'SYSTEM TABLE']) [null, null, null, t, null],
          ]);
        }
        final dbs = cat == '%' ? await _databases() : [empty(cat) ? _db : cat!];
        final types = type == null || type.isEmpty || type == '%'
            ? null
            : type.split(',').map((e) => e.trim().replaceAll("'", '').toUpperCase()).toSet();
        final rows = <List<Object?>>[];
        for (final db in dbs) {
          for (final c in await _collections(db)) {
            final n = c['name'].toString();
            if (!_like(name, n)) continue;
            final kind = c['type']?.toString() ?? 'collection';
            final t = n.startsWith('system.') ? 'SYSTEM TABLE' : (kind == 'view' ? 'VIEW' : 'TABLE');
            if (types != null && !types.contains(t)) continue;
            rows.add([db, null, n, t, kind == 'timeseries' ? 'Serie temporale' : null]);
          }
        }
        return catalogResult(CatalogColumns.tables, rows);
      case 'columns':
        final db = empty(a(0)) ? _db : a(0)!;
        final table = a(2) ?? '';
        final fields = await _sampleFields(db, table);
        final rows = <List<Object?>>[];
        var ord = 0;
        for (final f in fields) {
          ord++;
          if (!_like(a(3), f.name)) continue;
          final sqlType = sqlTypeForBson(f.type);
          rows.add([
            db, null, table, f.name, sqlType, f.type, null, null, null, null, //
            f.nullable ? 1 : 0, f.otherTypes.isEmpty ? null : 'Tipi: ${[f.type, ...f.otherTypes].join(', ')}',
            null, sqlType, null, null, ord, f.nullable ? 'YES' : 'NO',
          ]);
        }
        return catalogResult(CatalogColumns.columns, rows);
      case 'primaryKeys':
        final db = empty(a(0)) ? _db : a(0)!;
        return catalogResult(CatalogColumns.primaryKeys, [
          [db, null, a(2), '_id', 1, '_id_'],
        ]);
      case 'statistics':
        final db = empty(a(0)) ? _db : a(0)!;
        final table = a(2) ?? '';
        List<Doc> ix;
        try {
          ix = await _drain(db, await _cmd(db, {'listIndexes': table}));
        } on MongoCommandException {
          ix = const [];
        }
        final rows = <List<Object?>>[];
        for (final i in ix) {
          final key = (i['key'] as Map?) ?? const {};
          var pos = 0;
          final unique = i['unique'] == true || i['name'] == '_id_';
          key.forEach((k, v) {
            pos++;
            final dir = v is num ? (v < 0 ? 'D' : 'A') : (v is BsonInt64 ? (v.value < 0 ? 'D' : 'A') : null);
            rows.add([
              db, null, table, unique ? 0 : 1, null, i['name'], v == 'hashed' ? 2 : 3, pos, k, dir, null, null, //
              i['partialFilterExpression'] == null ? null : shellJson(i['partialFilterExpression']),
            ]);
          });
        }
        return catalogResult(CatalogColumns.statistics, rows);
      case 'foreignKeys':
        return catalogResult(CatalogColumns.foreignKeys, const []);
      case 'procedures':
        return catalogResult(CatalogColumns.procedures, const []);
      default:
        return catalogResult(const ['NAME'], const []);
    }
  });

  /// Infers the fields of a collection from a sample of documents.
  Future<List<MongoField>> _sampleFields(String db, String coll) async {
    List<Doc> docs;
    final n = sampleSize <= 0 ? 100 : sampleSize;
    try {
      docs = await _drain(
        db,
        await _cmd(db, {
          'aggregate': coll,
          'pipeline': [
            {
              r'$sample': {'size': n},
            },
          ],
          'cursor': {'batchSize': n},
        }),
        max: n,
      );
    } on MongoCommandException {
      docs = await _drain(db, await _cmd(db, {'find': coll, 'limit': n, 'batchSize': n}), max: n);
    }
    final fields = inferFields(docs);
    _types['$db.$coll'] = {for (final f in fields) f.name: f.type};
    return fields;
  }

  Future<Map<String, String>> _typesOf(String db, String coll) async {
    final t = _types['$db.$coll'];
    if (t != null) return t;
    try {
      await _sampleFields(db, coll);
    } catch (_) {
      _types['$db.$coll'] = {};
    }
    return _types['$db.$coll']!;
  }

  // -------------------------------------------------------------------------
  // Execution
  // -------------------------------------------------------------------------

  @override
  Future<List<StatementOutcome>> runScript(String sql, List<Object?> params, int fetchSize, int queryTimeoutSec) async {
    final text = sql.trim();
    if (text.isEmpty) return [StatementOutcome.update(-1)];
    final subset = parseSqlSubset(text, params: params, valueHook: parseMongoValue);
    if (subset != null) return [await _runSubset(subset, fetchSize, queryTimeoutSec)];
    final statements = parseShellScript(text);
    final out = <StatementOutcome>[];
    for (final st in statements) {
      out.add(await _runShell(st, fetchSize, queryTimeoutSec));
    }
    return out;
  }

  void _checkWrite(String what) {
    if (readOnly) throw readOnlyError(what);
  }

  Doc _doc(Object? v, String what) {
    if (v == null) return {};
    if (v is Map) return v.cast<String, Object?>();
    throw NativeDbException('$what: documento atteso');
  }

  List<Object?> _list(Object? v, String what) {
    if (v is List) return v;
    throw NativeDbException('$what: array atteso');
  }

  StatementOutcome _value(String column, Object? v, {List<String> messages = const []}) {
    final g = gridValue(v);
    final type = g is int ? SQL_BIGINT : (g is double ? SQL_DOUBLE : SQL_VARCHAR);
    return StatementOutcome.rows(nativeColumns([(column, type)]), [
      [g],
    ], messages: messages);
  }

  /// Key / value rows of a command reply.
  StatementOutcome _keyValues(Doc d) {
    final rows = <List<Object?>>[];
    d.forEach((k, v) {
      if (k == 'ok' || k.startsWith(r'$') || k == 'operationTime') return;
      rows.add([k, gridValue(v), bsonTypeName(v)]);
    });
    return StatementOutcome.rows(
      nativeColumns([('key', SQL_VARCHAR), ('value', SQL_LONGVARCHAR), ('type', SQL_VARCHAR)]),
      rows,
    );
  }

  StatementOutcome _docs(List<Doc> docs, {String? db, String? coll}) {
    final keys = documentKeys(docs);
    final cols = _columnsFor(keys, docs, db: db, coll: coll);
    return StatementOutcome.rows(cols, [
      for (final d in docs) [for (final k in keys) gridValue(d[k])],
    ]);
  }

  List<ColumnInfo> _columnsFor(List<String> keys, List<Doc> docs, {String? db, String? coll}) {
    final known = db != null && coll != null ? _types['$db.$coll'] : null;
    final cols = <ColumnInfo>[];
    for (var i = 0; i < keys.length; i++) {
      final k = keys[i];
      String? t;
      for (final d in docs) {
        final v = d[k];
        if (v != null) {
          t = bsonTypeName(v);
          break;
        }
      }
      t ??= known?[k] ?? 'null';
      if (known != null && !known.containsKey(k) && t != 'null') known[k] = t;
      cols.add(nativeColumn(i + 1, k, sqlType: sqlTypeForBson(t), typeName: t, table: coll, catalog: db));
    }
    return cols;
  }

  StatementOutcome _write(String verb, int n, {List<String> extra = const []}) =>
      StatementOutcome.update(n, messages: ['$verb: $n', ...extra]);

  Future<StatementOutcome> _commandOutcome(String db, Doc cmd, int fetchSize) async {
    final r = await _cmd(db, cmd);
    final cur = r['cursor'];
    if (cur is Map && cur.containsKey('firstBatch')) {
      return StatementOutcome.cursor(await _cursorFrom(db, r, fetchSize));
    }
    return _keyValues(r);
  }

  Future<_MongoCursor> _cursorFrom(String db, Doc reply, int fetchSize, {String? editColl}) async {
    final c = await _c();
    final cur = reply['cursor'] as Map;
    final ns = cur['ns']?.toString() ?? '$db.';
    final coll = ns.contains('.') ? ns.substring(ns.indexOf('.') + 1) : ns;
    return _MongoCursor(this, c, db, coll, bsonInt(cur['id']) ?? 0, [
      for (final d in (cur['firstBatch'] as List? ?? const [])) d is Map ? d.cast<String, Object?>() : {'value': d},
    ], editColl: editColl);
  }

  // -- SQL subset -------------------------------------------------------------

  Future<(String, String)> _resolveTarget(SqlTarget t) async {
    if (t.parts.length > 1) {
      final first = t.parts.first;
      final known = _knownDbs ?? (await _databases()).toSet();
      if (known.contains(first) || first == _db) return (first, t.parts.skip(1).join('.'));
    }
    return (_db, t.raw);
  }

  Future<StatementOutcome> _runSubset(SqlSubsetStatement st, int fetchSize, int timeoutSec) async {
    final (db, coll) = await _resolveTarget(st.target);
    switch (st) {
      case SubsetSelect():
        final filter = await _filterOf(db, coll, st.where, st.whereText);
        if (st.isCount) {
          final r = await _cmd(db, {'count': coll, 'query': filter});
          return _value('COUNT(*)', bsonInt(r['n']) ?? 0);
        }
        Doc? sort;
        if (st.orderText.trim().startsWith('{')) {
          sort = _doc(parseMongoValue(st.orderText), 'ORDER BY');
        } else if (st.orderBy.isNotEmpty) {
          sort = {for (final o in st.orderBy) o.field: o.descending ? -1 : 1};
        }
        final cmd = <String, Object?>{
          'find': coll,
          'filter': filter,
          'sort': ?sort,
          if (st.columns != null) 'projection': {for (final c in st.columns!) c: 1},
          if (st.offset != null) 'skip': st.offset,
          if (st.limit != null) 'limit': st.limit,
          'batchSize': max(1, st.limit == null ? fetchSize : min(fetchSize, st.limit!)),
          if (timeoutSec > 0) 'maxTimeMS': timeoutSec * 1000,
        };
        return StatementOutcome.cursor(await _cursorFrom(db, await _cmd(db, cmd), fetchSize, editColl: coll));
      case SubsetUpdate():
        _checkWrite('UPDATE');
        final types = await _typesOf(db, coll);
        final filter = await _filterOf(db, coll, st.where, st.whereText);
        final set = <String, Object?>{};
        for (final (k, v) in st.assignments) {
          set[k] = coerceToBsonType(
            v is String && k == '_id' && ObjectId.isValidHex(v) ? ObjectId.parse(v) : v,
            types[k],
          );
        }
        final r = await _cmd(db, {
          'update': coll,
          'updates': [
            {
              'q': filter,
              'u': {r'$set': set},
              'multi': true,
            },
          ],
        });
        return _write('Documenti modificati', bsonInt(r['nModified']) ?? bsonInt(r['n']) ?? 0);
      case SubsetInsert():
        _checkWrite('INSERT');
        final types = await _typesOf(db, coll);
        final docs = <Doc>[];
        for (final row in st.rows) {
          final d = <String, Object?>{};
          for (var i = 0; i < st.columns.length && i < row.length; i++) {
            final k = st.columns[i];
            var v = row[i];
            if (k == '_id' && v == null) continue;
            if (k == '_id' && v is String && ObjectId.isValidHex(v)) v = ObjectId.parse(v);
            d[k] = coerceToBsonType(v, types[k]);
          }
          docs.add(d);
        }
        final r = await _cmd(db, {'insert': coll, 'documents': docs});
        return _write('Documenti inseriti', bsonInt(r['n']) ?? docs.length);
      case SubsetDelete():
        _checkWrite('DELETE');
        final filter = await _filterOf(db, coll, st.where, st.whereText);
        final r = await _cmd(db, {
          'delete': coll,
          'deletes': [
            {'q': filter, 'limit': 0},
          ],
        });
        return _write('Documenti eliminati', bsonInt(r['n']) ?? 0);
    }
  }

  Future<Doc> _filterOf(String db, String coll, SqlExpr? where, String whereText) async {
    if (whereText.trim().startsWith('{')) return _doc(parseMongoValue(whereText), 'WHERE');
    if (where == null) return {};
    return sqlToMongoFilter(where, await _typesOf(db, coll));
  }

  // -- shell ---------------------------------------------------------------

  Future<StatementOutcome> _runShell(ShellStatement st, int fetchSize, int timeoutSec) async {
    switch (st) {
      case ShellUse(:final database):
        _db = database;
        return StatementOutcome.update(-1, messages: ['Database corrente: $database']);
      case ShellShow(:final what):
        return _show(what, fetchSize);
      case ShellCommandDoc(:final command):
        _checkCommand(command);
        return _commandOutcome(_db, command, fetchSize);
      case ShellCallStatement():
        final db = st.database ?? _db;
        if (st.collection == null) return _dbMethod(db, st, fetchSize, timeoutSec);
        return _collMethod(db, st.collection!, st, fetchSize, timeoutSec);
    }
  }

  Future<StatementOutcome> _show(String what, int fetchSize) async {
    switch (what.split(RegExp(r'\s+')).first) {
      case 'dbs':
      case 'databases':
        final r = await _cmd('admin', {'listDatabases': 1});
        final rows = [
          for (final d in (r['databases'] as List? ?? const []))
            [(d as Map)['name'], bsonInt(d['sizeOnDisk']), d['empty'] == true ? 'true' : 'false'],
        ];
        return StatementOutcome.rows(
          nativeColumns([('name', SQL_VARCHAR), ('sizeOnDisk', SQL_BIGINT), ('empty', SQL_VARCHAR)]),
          rows,
        );
      case 'collections':
      case 'tables':
        final list = await _collections(_db);
        list.sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));
        return StatementOutcome.rows(nativeColumns([('name', SQL_VARCHAR), ('type', SQL_VARCHAR)]), [
          for (final c in list) [c['name'], c['type']],
        ]);
      case 'users':
        final r = await _cmd(_db, {'usersInfo': 1});
        return _docs([for (final u in (r['users'] as List? ?? const [])) (u as Map).cast<String, Object?>()]);
      case 'roles':
        final r = await _cmd(_db, {'rolesInfo': 1, 'showBuiltinRoles': true});
        return _docs([for (final u in (r['roles'] as List? ?? const [])) (u as Map).cast<String, Object?>()]);
      case 'profile':
        final r = await _cmd(_db, {
          'find': 'system.profile',
          'sort': {'ts': -1},
          'limit': 5,
        });
        return StatementOutcome.cursor(await _cursorFrom(_db, r, fetchSize));
    }
    throw NativeDbException('show $what: non supportato (usa dbs, collections, users, roles, profile)');
  }

  void _checkCommand(Doc cmd) {
    if (!readOnly || cmd.isEmpty) return;
    final name = cmd.keys.first.toLowerCase();
    if (commandWriteNames.contains(name)) throw readOnlyError(cmd.keys.first);
    if (name == 'aggregate') _checkPipeline(cmd['pipeline']);
  }

  void _checkPipeline(Object? pipeline) {
    if (!readOnly || pipeline is! List) return;
    for (final s in pipeline) {
      if (s is Map && (s.containsKey(r'$out') || s.containsKey(r'$merge'))) throw readOnlyError(r'$out / $merge');
    }
  }

  Future<StatementOutcome> _dbMethod(String db, ShellCallStatement st, int fetchSize, int timeoutSec) async {
    final m = st.method;
    if (shellWriteMethods.contains(m.name)) _checkWrite('db.${m.name}');
    switch (m.name) {
      case 'getName':
        return _value('value', db);
      case 'getCollectionNames':
        final list = await _collections(db);
        final names = [for (final c in list) c['name'].toString()]..sort();
        return StatementOutcome.rows(nativeColumns([('name', SQL_VARCHAR)]), [
          for (final n in names) [n],
        ]);
      case 'getCollectionInfos':
        final list = await _collections(db, filter: _doc(m.arg(0), 'getCollectionInfos'));
        return _docs(list);
      case 'getCollection':
        throw NativeDbException('getCollection: metodo atteso, ad esempio db.getCollection("x").find()');
      case 'createCollection':
        await _cmd(db, {'create': m.arg(0).toString(), ..._doc(m.arg(1), 'createCollection')});
        return StatementOutcome.update(-1, messages: ['Collezione "${m.arg(0)}" creata']);
      case 'createView':
        await _cmd(db, {
          'create': m.arg(0).toString(),
          'viewOn': m.arg(1).toString(),
          'pipeline': m.arg(2) ?? const [],
          ..._doc(m.arg(3), 'createView'),
        });
        return StatementOutcome.update(-1, messages: ['Vista "${m.arg(0)}" creata']);
      case 'dropDatabase':
        await _cmd(db, {'dropDatabase': 1});
        return StatementOutcome.update(-1, messages: ['Database "$db" eliminato']);
      case 'runCommand':
      case 'adminCommand':
        final a = m.arg(0);
        final cmd = a is String ? <String, Object?>{a: 1} : _doc(a, m.name);
        _checkCommand(cmd);
        return _commandOutcome(m.name == 'adminCommand' ? 'admin' : db, cmd, fetchSize);
      case 'stats':
        return _keyValues(await _cmd(db, {'dbStats': 1, if (m.arg(0) is num) 'scale': m.arg(0)}));
      case 'serverStatus':
        return _keyValues(await _cmd('admin', {'serverStatus': 1}));
      case 'hostInfo':
        return _keyValues(await _cmd('admin', {'hostInfo': 1}));
      case 'version':
        return _value('version', (await _cmd('admin', {'buildInfo': 1}))['version']);
      case 'serverBuildInfo':
      case 'buildInfo':
        return _keyValues(await _cmd('admin', {'buildInfo': 1}));
      case 'hello':
      case 'isMaster':
        return _keyValues(await _cmd('admin', {'hello': 1}));
      case 'listCommands':
        final r = await _cmd('admin', {'listCommands': 1});
        final cmds = (r['commands'] as Map? ?? const {});
        return StatementOutcome.rows(nativeColumns([('command', SQL_VARCHAR), ('help', SQL_LONGVARCHAR)]), [
          for (final e in cmds.entries) [e.key, (e.value as Map?)?['help']?.toString()],
        ]);
      case 'currentOp':
        final r = await _cmd('admin', {'currentOp': 1, ..._doc(m.arg(0) is Map ? m.arg(0) : null, 'currentOp')});
        return _docs([for (final o in (r['inprog'] as List? ?? const [])) (o as Map).cast<String, Object?>()]);
      case 'killOp':
        await _cmd('admin', {'killOp': 1, 'op': m.arg(0)});
        return StatementOutcome.update(-1, messages: ['Operazione ${m.arg(0)} terminata']);
      case 'getUsers':
        final r = await _cmd(db, {'usersInfo': 1});
        return _docs([for (final u in (r['users'] as List? ?? const [])) (u as Map).cast<String, Object?>()]);
      case 'getRoles':
        final r = await _cmd(db, {'rolesInfo': 1, ..._doc(m.arg(0), 'getRoles')});
        return _docs([for (final u in (r['roles'] as List? ?? const [])) (u as Map).cast<String, Object?>()]);
      case 'getProfilingStatus':
        return _keyValues(await _cmd(db, {'profile': -1}));
      case 'setProfilingLevel':
        return _keyValues(
          await _cmd(db, {'profile': m.arg(0), if (m.arg(1) is Map) ...(m.arg(1) as Map).cast<String, Object?>()}),
        );
      case 'aggregate':
        final pipeline = _list(m.arg(0), 'aggregate');
        _checkPipeline(pipeline);
        final r = await _cmd(db, {
          'aggregate': 1,
          'pipeline': pipeline,
          'cursor': {'batchSize': fetchSize},
          ..._doc(m.arg(1), 'aggregate'),
        });
        return StatementOutcome.cursor(await _cursorFrom(db, r, fetchSize));
    }
    throw NativeDbException('Metodo db.${m.name}() non supportato');
  }

  Future<StatementOutcome> _collMethod(
    String db,
    String coll,
    ShellCallStatement st,
    int fetchSize,
    int timeoutSec,
  ) async {
    final m = st.method;
    if (shellWriteMethods.contains(m.name)) _checkWrite('${m.name}()');
    final maxTime = st.modifier('maxTimeMS')?.arg(0) ?? (timeoutSec > 0 ? timeoutSec * 1000 : null);
    switch (m.name) {
      case 'find':
      case 'findOne':
        final filter = _doc(m.arg(0), m.name);
        var projection = m.arg(1) == null ? null : _doc(m.arg(1), m.name);
        Doc? sort;
        int? limit, skip, batch;
        Object? hint;
        Doc? collation;
        String? comment;
        String? explain;
        var count = false;
        for (final mod in st.modifiers) {
          switch (mod.name) {
            case 'sort':
              sort = _doc(mod.arg(0), 'sort');
            case 'limit':
              limit = bsonInt(mod.arg(0));
            case 'skip':
              skip = bsonInt(mod.arg(0));
            case 'projection':
            case 'project':
              projection = _doc(mod.arg(0), 'projection');
            case 'batchSize':
              batch = bsonInt(mod.arg(0));
            case 'hint':
              hint = mod.arg(0);
            case 'collation':
              collation = _doc(mod.arg(0), 'collation');
            case 'comment':
              comment = mod.arg(0)?.toString();
            case 'count':
            case 'size':
            case 'itcount':
              count = true;
            case 'explain':
              explain = mod.arg(0)?.toString() ?? 'queryPlanner';
            case 'maxTimeMS':
            case 'pretty':
            case 'toArray':
            case 'allowDiskUse':
            case 'noCursorTimeout':
            case 'readPref':
            case 'readConcern':
            case 'showRecordId':
            case 'returnKey':
              break;
            default:
              throw NativeDbException('Modificatore .${mod.name}() non supportato su find()');
          }
        }
        if (m.name == 'findOne') limit = 1;
        if (count) {
          final r = await _cmd(db, {
            'count': coll,
            'query': filter,
            if (st.modifier('count')?.arg(0) == true ||
                st.modifier('size') != null ||
                st.modifier('itcount') != null) ...{
              'limit': ?limit,
              'skip': ?skip,
            },
          });
          return _value('count', bsonInt(r['n']) ?? 0);
        }
        final find = <String, Object?>{
          'find': coll,
          'filter': filter,
          'sort': ?sort,
          'projection': ?projection,
          'skip': ?skip,
          if (limit != null) 'limit': limit.abs(),
          if (limit != null && limit < 0) 'singleBatch': true,
          'batchSize': max(1, batch ?? (limit == null ? fetchSize : min(fetchSize, limit.abs()))),
          'hint': ?hint,
          'collation': ?collation,
          'comment': ?comment,
          'maxTimeMS': ?maxTime,
          if (st.modifier('allowDiskUse') != null) 'allowDiskUse': true,
        };
        if (explain != null) {
          return _keyValues(await _cmd(db, {'explain': find, 'verbosity': _verbosity(explain)}));
        }
        return StatementOutcome.cursor(await _cursorFrom(db, await _cmd(db, find), fetchSize, editColl: coll));
      case 'countDocuments':
        final opts = _doc(m.arg(1), 'countDocuments');
        final r = await _drain(
          db,
          await _cmd(db, {
            'aggregate': coll,
            'pipeline': [
              {r'$match': _doc(m.arg(0), 'countDocuments')},
              if (opts['skip'] != null) {r'$skip': opts['skip']},
              if (opts['limit'] != null) {r'$limit': opts['limit']},
              {
                r'$group': {
                  '_id': 1,
                  'n': {r'$sum': 1},
                },
              },
            ],
            'cursor': <String, Object?>{},
          }),
        );
        return _value('count', r.isEmpty ? 0 : bsonInt(r.first['n']) ?? 0);
      case 'estimatedDocumentCount':
        return _value('count', bsonInt((await _cmd(db, {'count': coll}))['n']) ?? 0);
      case 'count':
        final r = await _cmd(db, {'count': coll, 'query': _doc(m.arg(0), 'count'), ..._doc(m.arg(1), 'count')});
        return _value('count', bsonInt(r['n']) ?? 0);
      case 'distinct':
        final r = await _cmd(db, {
          'distinct': coll,
          'key': m.arg(0).toString(),
          'query': _doc(m.arg(1), 'distinct'),
          ..._doc(m.arg(2), 'distinct'),
        });
        final values = (r['values'] as List? ?? const []);
        final g = [for (final v in values) gridValue(v)];
        final t = g.every((e) => e is int || e == null) ? SQL_BIGINT : SQL_VARCHAR;
        return StatementOutcome.rows(nativeColumns([(m.arg(0).toString(), t)]), [
          for (final v in g) [v],
        ]);
      case 'aggregate':
        final List<Object?> pipeline;
        Doc opts = {};
        if (m.args.isNotEmpty && m.args.first is List) {
          pipeline = m.args.first as List;
          opts = _doc(m.arg(1), 'aggregate');
        } else {
          pipeline = m.args;
        }
        _checkPipeline(pipeline);
        final cmd = <String, Object?>{
          'aggregate': coll,
          'pipeline': pipeline,
          'cursor': {'batchSize': fetchSize},
          'maxTimeMS': ?maxTime,
          ...opts,
        };
        if (st.modifier('explain') != null) {
          cmd.remove('cursor');
          return _keyValues(
            await _cmd(db, {'explain': cmd, 'verbosity': _verbosity(st.modifier('explain')!.arg(0)?.toString())}),
          );
        }
        return StatementOutcome.cursor(await _cursorFrom(db, await _cmd(db, cmd), fetchSize));
      case 'insertOne':
      case 'insertMany':
      case 'insert':
      case 'save':
        final a = m.arg(0);
        final docs = <Doc>[
          if (a is List) ...[for (final d in a) _doc(d, m.name)] else _doc(a, m.name),
        ];
        for (final d in docs) {
          if (!d.containsKey('_id')) {
            final id = ObjectId.generate();
            final copy = {'_id': id, ...d};
            d
              ..clear()
              ..addAll(copy);
          }
        }
        final opts = _doc(m.name == 'insertMany' || m.name == 'insert' ? m.arg(1) : null, m.name);
        final r = await _cmd(db, {
          'insert': coll,
          'documents': docs,
          if (opts['ordered'] != null) 'ordered': opts['ordered'],
        });
        final ids = docs.take(20).map((d) => gridValue(d['_id'])).join(', ');
        return _write(
          'Documenti inseriti',
          bsonInt(r['n']) ?? docs.length,
          extra: ['_id: $ids${docs.length > 20 ? ', …' : ''}'],
        );
      case 'updateOne':
      case 'updateMany':
      case 'replaceOne':
      case 'update':
        final opts = _doc(m.arg(2), m.name);
        final u = m.arg(1);
        if (u is! Map && u is! List) throw NativeDbException('${m.name}: documento di aggiornamento atteso');
        if (m.name == 'replaceOne' && u is Map && u.keys.any((k) => k.toString().startsWith(r'$'))) {
          throw NativeDbException('replaceOne: il documento sostitutivo non può contenere operatori \$');
        }
        if ((m.name == 'updateOne' || m.name == 'updateMany') &&
            u is Map &&
            u.keys.any((k) => !k.toString().startsWith(r'$'))) {
          throw NativeDbException('${m.name}: usa operatori di aggiornamento (\$set, \$inc, …) oppure replaceOne');
        }
        final multi = m.name == 'updateMany' || (m.name == 'update' && opts['multi'] == true);
        final r = await _cmd(db, {
          'update': coll,
          'updates': [
            {
              'q': _doc(m.arg(0), m.name),
              'u': u,
              'multi': multi,
              'upsert': opts['upsert'] == true,
              'arrayFilters': ?opts['arrayFilters'],
              'collation': ?opts['collation'],
              'hint': ?opts['hint'],
            },
          ],
        });
        final upserted = (r['upserted'] as List?)?.length ?? 0;
        return _write(
          'Documenti modificati',
          (bsonInt(r['nModified']) ?? 0) + upserted,
          extra: [
            'Corrispondenti: ${bsonInt(r['n']) ?? 0}',
            if (upserted > 0) 'Inseriti (upsert): ${gridValue(((r['upserted'] as List).first as Map)['_id'])}',
          ],
        );
      case 'deleteOne':
      case 'deleteMany':
      case 'remove':
        final justOne =
            m.name == 'deleteOne' ||
            (m.name == 'remove' && (m.arg(1) == true || (m.arg(1) is Map && (m.arg(1) as Map)['justOne'] == true)));
        final r = await _cmd(db, {
          'delete': coll,
          'deletes': [
            {
              'q': _doc(m.arg(0), m.name),
              'limit': justOne ? 1 : 0,
              if (m.arg(1) is Map && (m.arg(1) as Map)['collation'] != null)
                'collation': (m.arg(1) as Map)['collation'],
            },
          ],
        });
        return _write('Documenti eliminati', bsonInt(r['n']) ?? 0);
      case 'findOneAndUpdate':
      case 'findOneAndReplace':
      case 'findOneAndDelete':
      case 'findAndModify':
        Doc opts;
        Doc cmd;
        if (m.name == 'findAndModify') {
          opts = _doc(m.arg(0), m.name);
          cmd = {'findAndModify': coll, ...opts};
        } else {
          final del = m.name == 'findOneAndDelete';
          opts = _doc(del ? m.arg(1) : m.arg(2), m.name);
          cmd = {
            'findAndModify': coll,
            'query': _doc(m.arg(0), m.name),
            if (del) 'remove': true else 'update': m.arg(1),
            'new': opts['returnDocument'] == 'after' || opts['returnNewDocument'] == true,
            if (opts['upsert'] != null) 'upsert': opts['upsert'],
            if (opts['projection'] != null) 'fields': opts['projection'],
            if (opts['sort'] != null) 'sort': opts['sort'],
          };
        }
        final r = await _cmd(db, cmd);
        final v = r['value'];
        return _docs(v is Map ? [v.cast<String, Object?>()] : const [], db: db, coll: coll);
      case 'drop':
        try {
          await _cmd(db, {'drop': coll});
        } on MongoCommandException catch (e) {
          if (e.numericCode != 26) rethrow; // NamespaceNotFound
        }
        _types.remove('$db.$coll');
        return StatementOutcome.update(-1, messages: ['Collezione "$coll" eliminata']);
      case 'createIndex':
      case 'ensureIndex':
      case 'createIndexes':
        final keysList = m.name == 'createIndexes' ? _list(m.arg(0), m.name) : [m.arg(0)];
        final opts = _doc(m.arg(1), m.name);
        final indexes = <Doc>[];
        for (final k in keysList) {
          final keys = _doc(k, m.name);
          indexes.add({
            'key': keys,
            'name': opts['name'] ?? keys.entries.map((e) => '${e.key}_${gridValue(e.value)}').join('_'),
            ...opts,
          });
        }
        await _cmd(db, {'createIndexes': coll, 'indexes': indexes});
        return StatementOutcome.update(-1, messages: ['Indici creati: ${indexes.map((e) => e['name']).join(', ')}']);
      case 'getIndexes':
      case 'getIndices':
      case 'getIndexSpecs':
        return _docs(await _drain(db, await _cmd(db, {'listIndexes': coll})));
      case 'dropIndex':
      case 'dropIndexes':
        final which = m.name == 'dropIndexes' ? (m.arg(0) ?? '*') : m.arg(0);
        await _cmd(db, {'dropIndexes': coll, 'index': which});
        return StatementOutcome.update(-1, messages: ['Indice eliminato: ${which is Map ? shellJson(which) : which}']);
      case 'stats':
        try {
          return _keyValues(await _cmd(db, {'collStats': coll}));
        } on MongoCommandException {
          final r = await _drain(
            db,
            await _cmd(db, {
              'aggregate': coll,
              'pipeline': [
                {
                  r'$collStats': {'storageStats': <String, Object?>{}, 'count': <String, Object?>{}},
                },
              ],
              'cursor': <String, Object?>{},
            }),
          );
          return _keyValues(r.isEmpty ? {} : r.first);
        }
      case 'renameCollection':
        await _cmd('admin', {'renameCollection': '$db.$coll', 'to': '$db.${m.arg(0)}', 'dropTarget': m.arg(1) == true});
        return StatementOutcome.update(-1, messages: ['Collezione rinominata in "${m.arg(0)}"']);
      case 'validate':
        return _keyValues(await _cmd(db, {'validate': coll, ..._doc(m.arg(0) is Map ? m.arg(0) : null, 'validate')}));
      case 'getName':
        return _value('value', coll);
      case 'exists':
        final list = await _collections(db, filter: {'name': coll});
        return _docs(list);
    }
    throw NativeDbException('Metodo ${m.name}() non supportato sulle collezioni');
  }

  static String _verbosity(String? v) => switch (v) {
    'executionStats' || 'allPlansExecution' || 'queryPlanner' => v!,
    'true' => 'allPlansExecution',
    _ => 'queryPlanner',
  };
}

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

class _MongoCursor implements NativeCursor {
  _MongoCursor(this.session, this.conn, this.db, this.coll, this._id, List<Doc> firstBatch, {this.editColl})
    : _buf = Queue.of(firstBatch);

  final MongoSession session;
  final MongoConnection conn;
  final String db;
  final String coll;

  /// Collection the documents belong to (enables grid editing).
  final String? editColl;
  final Queue<Doc> _buf;
  int _id;
  List<String>? _keys;
  List<ColumnInfo> _cols = const [];

  @override
  List<ColumnInfo> get columns => _cols;

  @override
  bool get hasMore => _buf.isNotEmpty || _id != 0;

  Future<void> _getMore(int n) async {
    if (conn.isClosed) {
      _id = 0;
      throw NativeDbException('Cursore non più valido: la connessione è stata chiusa');
    }
    final r = await conn.command(db, {'getMore': BsonInt64(_id), 'collection': coll, 'batchSize': max(1, n)});
    final c = r['cursor'] as Map;
    for (final d in (c['nextBatch'] as List? ?? const [])) {
      _buf.add(d is Map ? d.cast<String, Object?>() : {'value': d});
    }
    _id = bsonInt(c['id']) ?? 0;
  }

  @override
  Future<List<List<Object?>>> fetch(int count) async {
    final docs = <Doc>[];
    while (count <= 0 || docs.length < count) {
      if (_buf.isEmpty) {
        if (_id == 0) break;
        await _getMore(count <= 0 ? 1000 : count - docs.length);
        continue;
      }
      docs.add(_buf.removeFirst());
    }
    if (_keys == null) {
      var keys = documentKeys(docs);
      if (keys.isEmpty) {
        final known = session._types['$db.${editColl ?? coll}'];
        keys = known == null || known.isEmpty ? ['_id'] : known.keys.toList();
      }
      _keys = keys;
      _cols = session._columnsFor(keys, docs, db: editColl == null ? null : db, coll: editColl);
    }
    final keys = _keys!;
    return [
      for (final d in docs) [for (final k in keys) gridValue(d[k])],
    ];
  }

  @override
  Future<void> close() async {
    _buf.clear();
    final id = _id;
    _id = 0;
    if (id == 0 || conn.isClosed) return;
    try {
      await conn.command(db, {
        'killCursors': coll,
        'cursors': [BsonInt64(id)],
      });
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Helpers (public for tests)
// ---------------------------------------------------------------------------

/// Union of the top-level keys of [docs] in order of appearance, `_id` first.
List<String> documentKeys(List<Map<String, Object?>> docs) {
  final keys = <String>{};
  for (final d in docs) {
    keys.addAll(d.keys);
  }
  final list = keys.toList();
  if (list.remove('_id')) list.insert(0, '_id');
  return list;
}

class MongoField {
  MongoField(this.name);
  final String name;
  final Map<String, int> counts = {};
  int present = 0;
  bool hasNull = false;
  String type = 'null';
  List<String> otherTypes = const [];
  bool nullable = true;
}

/// Field list inferred from sample documents.
List<MongoField> inferFields(List<Map<String, Object?>> docs) {
  final fields = <String, MongoField>{};
  for (final d in docs) {
    d.forEach((k, v) {
      final f = fields.putIfAbsent(k, () => MongoField(k));
      f.present++;
      if (v == null) {
        f.hasNull = true;
      } else {
        final t = bsonTypeName(v);
        f.counts[t] = (f.counts[t] ?? 0) + 1;
      }
    });
  }
  for (final f in fields.values) {
    final sorted = f.counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    f.type = sorted.isEmpty ? 'null' : sorted.first.key;
    f.otherTypes = sorted.skip(1).map((e) => e.key).toList();
    f.nullable = f.hasNull || f.present < docs.length;
  }
  final list = fields.values.toList();
  final id = list.indexWhere((f) => f.name == '_id');
  if (id > 0) list.insert(0, list.removeAt(id));
  if (id >= 0) list.first.nullable = false;
  return list;
}

/// `{field: type}` inferred from [docs] (most frequent type per field).
Map<String, String> inferFieldTypes(List<Map<String, Object?>> docs) => {
  for (final f in inferFields(docs)) f.name: f.type,
};

Object? _sqlValue(String field, Object? v, Map<String, String> types) {
  if (v is String && field == '_id' && ObjectId.isValidHex(v)) return ObjectId.parse(v);
  final t = types[field];
  if (t == null || t == 'string') return v;
  try {
    return coerceToBsonType(v, t);
  } catch (_) {
    return v;
  }
}

/// Translates a SQL WHERE expression into a MongoDB query filter. [types]
/// (field → BSON type name) converts literals (dates, ObjectIds, longs…).
Map<String, Object?> sqlToMongoFilter(SqlExpr e, [Map<String, String> types = const {}]) {
  Object? val(String f, Object? v) => _sqlValue(f, v, types);
  Object? eq(String f, Object? v) {
    final c = val(f, v);
    // _id values shown as hex may be ObjectIds or plain strings.
    if (c is ObjectId && v is String) {
      return {
        r'$in': [c, v],
      };
    }
    return c;
  }

  switch (e) {
    case SqlAnd(:final items):
      final parts = [for (final i in items) sqlToMongoFilter(i, types)];
      final merged = <String, Object?>{};
      var canMerge = true;
      for (final p in parts) {
        for (final k in p.keys) {
          if (k.startsWith(r'$') || merged.containsKey(k)) canMerge = false;
        }
        if (!canMerge) break;
        merged.addAll(p);
      }
      return canMerge ? merged : {r'$and': parts};
    case SqlOr(:final items):
      return {
        r'$or': [for (final i in items) sqlToMongoFilter(i, types)],
      };
    case SqlNot(:final item):
      return {
        r'$nor': [sqlToMongoFilter(item, types)],
      };
    case SqlIsNull(:final field, :final negated):
      return {
        field: negated ? {r'$ne': null} : null,
      };
    case SqlIn(:final field, :final values, :final negated):
      final list = <Object?>[];
      for (final v in values) {
        final c = val(field, v);
        list.add(c);
        if (c is ObjectId && v is String) list.add(v);
      }
      return {
        field: {negated ? r'$nin' : r'$in': list},
      };
    case SqlBetween(:final field, :final low, :final high, :final negated):
      final r = {
        field: {r'$gte': val(field, low), r'$lte': val(field, high)},
      };
      return negated
          ? {
              r'$nor': [r],
            }
          : r;
    case SqlCmp(:final field, :final op, :final value, :final negated):
      switch (op) {
        case '=':
          return {field: eq(field, value)};
        case '!=':
          final c = val(field, value);
          return {
            field: c is ObjectId && value is String
                ? {
                    r'$nin': [c, value],
                  }
                : {r'$ne': c},
          };
        case '<':
        case '<=':
        case '>':
        case '>=':
          final mop = const {'<': r'$lt', '<=': r'$lte', '>': r'$gt', '>=': r'$gte'}[op]!;
          return {
            field: {mop: val(field, value)},
          };
        default:
          final re = BsonRegex(likeToRegexSource(value.toString()), op == 'ilike' ? 'is' : 's');
          return {
            field: negated ? {r'$not': re} : re,
          };
      }
  }
}
