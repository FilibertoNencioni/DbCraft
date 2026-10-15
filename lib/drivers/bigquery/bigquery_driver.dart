// Native Google BigQuery driver over the REST API (jobs.query /
// jobs.getQueryResults), with ODBC catalog emulation: catalogs = projects,
// schemas = datasets, tables/views from tables.list, columns from the table
// schema (nested fields flattened as a.b).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../cloud/auth/gcp_auth.dart';
import '../../cloud/cloud_common.dart';
import '../../odbc/odbc_types.dart';
import '../db_session.dart';
import '../native_driver.dart';
import 'bigquery_values.dart';

const bigQueryDriver = BigQueryDriver();

const _api = 'https://bigquery.googleapis.com/bigquery/v2';

class BigQueryDriver extends NativeDriver {
  const BigQueryDriver();

  @override
  String get id => 'bigquery';
  @override
  String get label => 'Google BigQuery';
  @override
  String get description => 'Data warehouse di Google Cloud tramite API REST (senza driver ODBC)';
  @override
  IconData get icon => Icons.query_stats_rounded;
  @override
  Color get color => const Color(0xFF4285F4);
  @override
  String get defaultPort => '';
  @override
  String get queryLanguage => 'sql';
  @override
  bool get usesHost => false;
  @override
  bool get usesUser => false;
  @override
  bool get usesPassword => false;
  @override
  String get databaseLabel => 'Progetto';
  @override
  String get databaseHint => 'ID del progetto (vuoto = progetto delle credenziali)';

  @override
  List<NativeDriverField> get fields => const [
    NativeDriverField(
      'location',
      'Località',
      hint: 'EU, US, europe-west8…',
      help: 'Località dei job; vuota = rilevata automaticamente',
    ),
    NativeDriverField('defaultDataset', 'Dataset predefinito', hint: 'dataset o progetto.dataset'),
    NativeDriverField(
      'maximumBytesBilled',
      'Massimo byte fatturati',
      hint: 'Facoltativo, es. 10000000000',
      help: 'Le query oltre il limite falliscono senza costi',
    ),
    NativeDriverField(
      'listProjects',
      'Elenca tutti i progetti',
      options: ['no', 'sì'],
      defaultValue: 'no',
      help: 'Mostra nel navigator tutti i progetti accessibili',
    ),
  ];

  @override
  String get sampleQuery =>
      'SELECT name, SUM(number) AS total\n'
      'FROM `bigquery-public-data.usa_names.usa_1910_2013`\n'
      'GROUP BY name\nORDER BY total DESC\nLIMIT 100;';

  @override
  Future<DbSession> open(NativeConnectParams params) async {
    final method = params.option('authMethod', 'gcpDefault');
    final GcpCredential cred;
    switch (method) {
      case 'keyPair':
        final file = params.option('keyFile');
        if (file.isEmpty) throw CloudException('Indica il file JSON della chiave del service account.');
        cred = await gcpCredentialFromFile(file);
      case 'oauthToken':
        final token = params.option('token');
        if (token.isEmpty) throw CloudException('Indica l\'access token OAuth.');
        cred = GcpStaticTokenCredential(token);
      default:
        cred = GcpDefaultCredential();
    }
    var project = params.database.trim();
    if (project.isEmpty) project = await cred.projectId() ?? '';
    if (project.isEmpty) {
      throw CloudException('Indica l\'ID del progetto Google Cloud (campo "Progetto").');
    }
    final s = BigQuerySession._(cred, project, params);
    await s._ping(Duration(seconds: max(5, params.loginTimeoutSec)));
    return s;
  }
}

class _Cursor {
  _Cursor(this.jobId, this.location, this.schema, this.pageToken, this.projectId);
  final String jobId;
  final String? location;
  final List<BqField> schema;
  String? pageToken;
  final String projectId;
}

class BigQuerySession implements DbSession {
  BigQuerySession._(this._cred, this._project, NativeConnectParams p)
    : _billingProject = _project,
      _location = p.option('location').isEmpty ? null : p.option('location'),
      _defaultDataset = p.option('defaultDataset'),
      _maxBytes = p.option('maximumBytesBilled'),
      _listProjects = p.flag('listProjects'),
      _readOnly = p.readOnly;

  final GcpCredential _cred;

  /// Current catalog (navigator / editor default project).
  String _project;

  /// Project that runs (and pays for) the jobs.
  final String _billingProject;
  final String? _location;
  final String _defaultDataset;
  final String _maxBytes;
  final bool _listProjects;
  final bool _readOnly;

  bool _closed = false;
  int _busy = 0;
  int _nextCursor = 1;
  final Map<int, _Cursor> _cursors = {};
  final Map<String, Map> _tableCache = {};
  String? _runningJob;
  String? _runningLocation;
  bool _cancelRequested = false;

  @override
  String get completedConnectionString =>
      'bigquery://$_billingProject${_location == null ? '' : '?location=$_location'}';

  @override
  bool get isClosed => _closed;

  @override
  bool get isBusy => _busy > 0;

  // -------------------------------------------------------------------------
  // HTTP
  // -------------------------------------------------------------------------

  Future<Map> _call(
    String method,
    String path, {
    Map<String, String> query = const {},
    Object? body,
    Duration? timeout,
    bool allow404 = false,
  }) async {
    if (_closed) throw StateError('Sessione BigQuery chiusa');
    final token = (await _cred.getToken()).token;
    final uri = buildUri(_api, path, query);
    try {
      final r = await cloudRequest(
        method,
        uri,
        headers: {'Authorization': 'Bearer $token', if (body != null) 'Content-Type': 'application/json'},
        body: body == null ? null : utf8.encode(jsonEncode(body)),
        timeout: timeout,
        accept: allow404 ? (s) => (s >= 200 && s < 300) || s == 404 : null,
      );
      if (r.statusCode == 404 || r.body.isEmpty) return const {};
      return jsonDecode(r.body) as Map;
    } on CloudException catch (e) {
      throw _odbcError(e);
    }
  }

  OdbcException _odbcError(CloudException e) {
    var msg = e.message;
    // Keep only the BigQuery message, without the HTTP prefix.
    final nl = msg.indexOf('\n');
    if (nl > 0 && msg.startsWith('HTTP')) msg = msg.substring(nl + 1);
    final state = switch (e.statusCode) {
      400 => '42000',
      401 || 403 => '28000',
      404 => '42S02',
      _ => 'HY000',
    };
    return OdbcException('BigQuery', [OdbcDiag(state, e.statusCode ?? 0, msg)]);
  }

  Future<void> _ping(Duration timeout) async {
    try {
      await _call(
        'GET',
        '/projects/${uriEncode(_billingProject)}/datasets',
        query: {'maxResults': '1'},
        timeout: timeout,
      );
    } on OdbcException catch (e) {
      throw CloudException('Connessione a BigQuery (progetto $_billingProject) non riuscita:\n${e.message}');
    }
  }

  // -------------------------------------------------------------------------
  // Statements
  // -------------------------------------------------------------------------

  Map<String, Object?>? get _datasetRef {
    if (_defaultDataset.isEmpty) return null;
    final parts = _defaultDataset.replaceAll('`', '').split('.');
    return parts.length >= 2
        ? {'projectId': parts[0], 'datasetId': parts[1]}
        : {'projectId': _project, 'datasetId': parts[0]};
  }

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) async {
    if (_readOnly && _isWrite(sql)) {
      throw OdbcException('BigQuery', [
        const OdbcDiag('25006', 0, 'Connessione in sola lettura: istruzione non consentita'),
      ]);
    }
    final sw = Stopwatch()..start();
    _busy++;
    _cancelRequested = false;
    try {
      final body = <String, Object?>{
        'query': sql,
        'useLegacySql': false,
        'maxResults': fetchSize,
        'timeoutMs': 2000,
        'formatOptions': {'useInt64Timestamp': true},
        'requestId': _requestId(),
        'location': ?_location,
        'defaultDataset': ?_datasetRef,
        if (_maxBytes.isNotEmpty) 'maximumBytesBilled': _maxBytes,
        if (params.isNotEmpty) ...{
          'parameterMode': 'POSITIONAL',
          'queryParameters': [for (final p in params) bqParameter(p)],
        },
      };
      var r = await _call('POST', '/projects/${uriEncode(_billingProject)}/queries', body: body);
      final ref = (r['jobReference'] as Map?) ?? const {};
      final jobId = ref['jobId'] as String?;
      final location = ref['location'] as String? ?? _location;
      _runningJob = jobId;
      _runningLocation = location;
      final deadline = queryTimeoutSec > 0 ? DateTime.now().add(Duration(seconds: queryTimeoutSec)) : null;
      while (r['jobComplete'] != true) {
        if (jobId == null) throw CloudException('BigQuery non ha restituito il riferimento del job.');
        if (_cancelRequested) {
          await _cancelJob(jobId, location);
          throw OdbcException('BigQuery', [const OdbcDiag('HY008', 0, 'Query annullata')]);
        }
        if (deadline != null && DateTime.now().isAfter(deadline)) {
          await _cancelJob(jobId, location);
          throw OdbcException('BigQuery', [OdbcDiag('HYT00', 0, 'Timeout della query ($queryTimeoutSec s)')]);
        }
        r = await _results(jobId, location, maxResults: fetchSize, timeoutMs: 5000);
      }
      if (_cancelRequested && jobId != null) {
        // Completed while cancelling: nothing to stop.
        _cancelRequested = false;
      }
      return _page(r, jobId, location, sw.elapsedMilliseconds);
    } finally {
      _busy--;
      _runningJob = null;
    }
  }

  /// First keyword of [sql] (comments skipped) modifies data or schema.
  static bool _isWrite(String sql) {
    final s = sql.replaceAll(RegExp(r'--[^\n]*|#[^\n]*|/\*[\s\S]*?\*/'), ' ').trimLeft().toUpperCase();
    final word = RegExp(r'^[A-Z]+').firstMatch(s)?.group(0) ?? '';
    return const {
      'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'TRUNCATE', 'CREATE', 'DROP', 'ALTER', 'GRANT', 'REVOKE', //
      'CALL', 'EXPORT', 'LOAD', 'BEGIN', 'DECLARE', 'EXECUTE',
    }.contains(word);
  }

  static final _rnd = Random.secure();
  String _requestId() => List.generate(16, (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<Map> _results(String jobId, String? location, {int? maxResults, String? pageToken, int timeoutMs = 0}) =>
      _call(
        'GET',
        '/projects/${uriEncode(_billingProject)}/queries/${uriEncode(jobId)}',
        query: {
          'location': ?location,
          'maxResults': ?maxResults?.toString(),
          'pageToken': ?pageToken,
          if (timeoutMs > 0) 'timeoutMs': '$timeoutMs',
          'formatOptions.useInt64Timestamp': 'true',
        },
      );

  Future<void> _cancelJob(String jobId, String? location) async {
    try {
      await _call(
        'POST',
        '/projects/${uriEncode(_billingProject)}/jobs/${uriEncode(jobId)}/cancel',
        query: {'location': ?location},
      );
    } catch (_) {}
  }

  ResultPage _page(Map r, String? jobId, String? location, int elapsed) {
    final schema = parseBqSchema(r['schema'] as Map?);
    final messages = <String>[];
    final bytes = int.tryParse('${r['totalBytesProcessed'] ?? ''}');
    if (bytes != null) messages.add('Byte elaborati: ${formatBytes(bytes)}${r['cacheHit'] == true ? ' (cache)' : ''}');
    final dml = r['numDmlAffectedRows'];
    if (schema.isEmpty || (dml != null && (r['rows'] as List?) == null)) {
      return ResultPage(
        columns: const [],
        rows: const [],
        rowsAffected: int.tryParse('${dml ?? ''}') ?? -1,
        elapsedMs: elapsed,
        messages: messages,
      );
    }
    final rows = [for (final row in (r['rows'] as List?) ?? const []) convertBqRow(schema, row as Map)];
    final token = r['pageToken'] as String?;
    int? cursor;
    if (token != null && jobId != null) {
      cursor = _nextCursor++;
      _cursors[cursor] = _Cursor(jobId, location, schema, token, _billingProject);
    }
    return ResultPage(
      columns: _columns(schema),
      rows: rows,
      hasMore: cursor != null,
      cursorId: cursor,
      elapsedMs: elapsed,
      messages: messages,
    );
  }

  List<ColumnInfo> _columns(List<BqField> schema) => [
    for (var i = 0; i < schema.length; i++)
      ColumnInfo(
        index: i + 1,
        name: schema[i].name,
        sqlType: bqSqlType(schema[i].type, repeated: schema[i].repeated),
        typeName: schema[i].displayType,
        nullable: schema[i].mode != 'REQUIRED',
        decimals: standardType(schema[i].type) == 'NUMERIC' ? 9 : 0,
      ),
  ];

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) async {
    final c = _cursors[cursorId];
    if (c == null || c.pageToken == null) return ResultPage(columns: const [], rows: const []);
    _busy++;
    try {
      final r = await _results(c.jobId, c.location, maxResults: count, pageToken: c.pageToken);
      final rows = [for (final row in (r['rows'] as List?) ?? const []) convertBqRow(c.schema, row as Map)];
      c.pageToken = r['pageToken'] as String?;
      if (c.pageToken == null) _cursors.remove(cursorId);
      return ResultPage(
        columns: _columns(c.schema),
        rows: rows,
        hasMore: c.pageToken != null,
        cursorId: c.pageToken != null ? cursorId : null,
      );
    } finally {
      _busy--;
    }
  }

  @override
  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize) async => null;

  @override
  Future<void> closeCursor(int cursorId) async => _cursors.remove(cursorId);

  // -------------------------------------------------------------------------
  // Catalog emulation
  // -------------------------------------------------------------------------

  static bool _any(String? s) => s == null || s.isEmpty || s == '%';

  static bool _like(String value, String? pattern) {
    if (_any(pattern)) return true;
    if (!pattern!.contains('%') && !pattern.contains('_')) return value.toLowerCase() == pattern.toLowerCase();
    final re = StringBuffer('^');
    for (final ch in pattern.split('')) {
      re.write(switch (ch) {
        '%' => '.*',
        '_' => '.',
        _ => RegExp.escape(ch),
      });
    }
    re.write(r'$');
    return RegExp(re.toString(), caseSensitive: false).hasMatch(value);
  }

  Future<List<String>> _projects() async {
    if (!_listProjects) return [_project];
    final out = <String>{_project, _billingProject};
    String? token;
    var pages = 0;
    try {
      do {
        final r = await _call('GET', '/projects', query: {'maxResults': '1000', 'pageToken': ?token});
        for (final p in (r['projects'] as List?) ?? const []) {
          final id = ((p as Map)['projectReference'] as Map?)?['projectId'] as String?;
          if (id != null) out.add(id);
        }
        token = r['nextPageToken'] as String?;
      } while (token != null && ++pages < 10);
    } catch (_) {}
    return out.toList()..sort();
  }

  Future<List<String>> _datasets(String project) async {
    final out = <String>[];
    String? token;
    do {
      final r = await _call(
        'GET',
        '/projects/${uriEncode(project)}/datasets',
        query: {'maxResults': '1000', 'all': 'false', 'pageToken': ?token},
      );
      for (final d in (r['datasets'] as List?) ?? const []) {
        final id = ((d as Map)['datasetReference'] as Map?)?['datasetId'] as String?;
        if (id != null) out.add(id);
      }
      token = r['nextPageToken'] as String?;
    } while (token != null);
    return out..sort();
  }

  /// (name, type, description) of the tables of a dataset.
  Future<List<(String, String, String?)>> _tables(String project, String dataset) async {
    final out = <(String, String, String?)>[];
    String? token;
    do {
      final r = await _call(
        'GET',
        '/projects/${uriEncode(project)}/datasets/${uriEncode(dataset)}/tables',
        query: {'maxResults': '1000', 'pageToken': ?token},
      );
      for (final t in (r['tables'] as List?) ?? const []) {
        final m = t as Map;
        final id = (m['tableReference'] as Map?)?['tableId'] as String?;
        if (id == null) continue;
        final type = switch (m['type']) {
          'VIEW' => 'VIEW',
          'MATERIALIZED_VIEW' => 'MATERIALIZED VIEW',
          'EXTERNAL' => 'EXTERNAL TABLE',
          'SNAPSHOT' => 'SNAPSHOT',
          _ => 'TABLE',
        };
        out.add((id, type, (m['labels'] as Map?)?.entries.map((e) => '${e.key}=${e.value}').join(', ')));
      }
      token = r['nextPageToken'] as String?;
    } while (token != null);
    return out;
  }

  Future<Map> _table(String project, String dataset, String table) async {
    final key = '$project.$dataset.$table';
    final hit = _tableCache[key];
    if (hit != null) return hit;
    final r = await _call(
      'GET',
      '/projects/${uriEncode(project)}/datasets/${uriEncode(dataset)}/tables/${uriEncode(table)}',
      allow404: true,
    );
    if (_tableCache.length > 200) _tableCache.clear();
    return _tableCache[key] = r;
  }

  String _cat(String? c) => _any(c) ? _project : c!;

  @override
  Future<ResultPage> catalog(String function, List<String?> args) async {
    _busy++;
    try {
      return await _catalog(function, args);
    } finally {
      _busy--;
    }
  }

  Future<ResultPage> _catalog(String function, List<String?> a) async {
    String? arg(int i) => i < a.length ? a[i] : null;
    switch (function) {
      case 'tables':
        final cat = arg(0), sch = arg(1), name = arg(2), types = arg(3);
        // Special ODBC enumerations (SQLTables with SQL_ALL_*).
        if (cat == '%' && (sch ?? '').isEmpty && (name ?? '').isEmpty) {
          return catalogResult(CatalogColumns.tables, [
            for (final p in await _projects()) [p, null, null, null, null],
          ]);
        }
        if ((cat ?? '').isEmpty && sch == '%' && (name ?? '').isEmpty) {
          return catalogResult(CatalogColumns.tables, [
            for (final d in await _datasets(_project)) [_project, d, null, null, null],
          ]);
        }
        if ((cat ?? '').isEmpty && (sch ?? '').isEmpty && (name ?? '').isEmpty && types == '%') {
          return catalogResult(CatalogColumns.tables, [
            for (final t in const ['TABLE', 'VIEW', 'MATERIALIZED VIEW', 'EXTERNAL TABLE', 'SNAPSHOT'])
              [null, null, null, t, null],
          ]);
        }
        final project = _cat(cat);
        final wanted = _any(types)
            ? null
            : types!
                  .split(',')
                  .map((e) => e.trim().replaceAll("'", '').toUpperCase())
                  .where((e) => e.isNotEmpty)
                  .toSet();
        final datasets = _any(sch) || sch!.contains('%') || sch.contains('_')
            ? (await _datasets(project)).where((d) => _like(d, sch)).toList()
            : [sch];
        final rows = <List<Object?>>[];
        for (final d in datasets) {
          if (!_any(name) && !name!.contains('%') && !name.contains('_')) {
            final t = await _table(project, d, name);
            if (t.isEmpty) continue;
            final type = switch (t['type']) {
              'VIEW' => 'VIEW',
              'MATERIALIZED_VIEW' => 'MATERIALIZED VIEW',
              'EXTERNAL' => 'EXTERNAL TABLE',
              'SNAPSHOT' => 'SNAPSHOT',
              _ => 'TABLE',
            };
            if (wanted == null || wanted.contains(type)) rows.add([project, d, name, type, t['description']]);
            continue;
          }
          for (final (n, type, remarks) in await _tables(project, d)) {
            if (!_like(n, name)) continue;
            if (wanted != null && !wanted.contains(type)) continue;
            rows.add([project, d, n, type, remarks]);
          }
        }
        return catalogResult(CatalogColumns.tables, rows);
      case 'columns':
        final project = _cat(arg(0));
        final dataset = arg(1);
        final table = arg(2);
        if (_any(dataset) || _any(table)) return catalogResult(CatalogColumns.columns, const []);
        final t = await _table(project, dataset!, table!);
        final cols = flattenBqFields(parseBqSchema(t['schema'] as Map?));
        final rows = <List<Object?>>[];
        for (var i = 0; i < cols.length; i++) {
          final c = cols[i];
          if (!_like(c.name, arg(3))) continue;
          rows.add([
            project, dataset, table, c.name, c.sqlType, c.typeName, //
            null, null, c.decimals, 10, c.nullable ? 1 : 0, c.remarks, null, c.sqlType, null, null, i + 1,
            c.nullable ? 'YES' : 'NO',
          ]);
        }
        return catalogResult(CatalogColumns.columns, rows);
      case 'primaryKeys':
        final project = _cat(arg(0));
        if (_any(arg(1)) || _any(arg(2))) return catalogResult(CatalogColumns.primaryKeys, const []);
        final t = await _table(project, arg(1)!, arg(2)!);
        final pk = ((t['tableConstraints'] as Map?)?['primaryKey'] as Map?)?['columns'] as List?;
        return catalogResult(CatalogColumns.primaryKeys, [
          for (var i = 0; i < (pk?.length ?? 0); i++) [project, arg(1), arg(2), '${pk![i]}', i + 1, 'PRIMARY KEY'],
        ]);
      case 'foreignKeys':
        // Only the outgoing keys of a table (args 3..5) are available cheaply.
        if (_any(arg(4)) || _any(arg(5))) return catalogResult(CatalogColumns.foreignKeys, const []);
        final project = _cat(arg(3));
        final t = await _table(project, arg(4)!, arg(5)!);
        final rows = <List<Object?>>[];
        for (final fk in ((t['tableConstraints'] as Map?)?['foreignKeys'] as List?) ?? const []) {
          final m = fk as Map;
          final ref = (m['referencedTable'] as Map?) ?? const {};
          final refs = (m['columnReferences'] as List?) ?? const [];
          for (var i = 0; i < refs.length; i++) {
            final cr = refs[i] as Map;
            rows.add([
              ref['projectId'], ref['datasetId'], ref['tableId'], cr['referencedColumn'], //
              project, arg(4), arg(5), cr['referencingColumn'], i + 1, 3, 3, m['name'], null, 7,
            ]);
          }
        }
        return catalogResult(CatalogColumns.foreignKeys, rows);
      case 'procedures':
        final project = _cat(arg(0));
        final sch = arg(1);
        final datasets = _any(sch) ? await _datasets(project) : [sch!];
        final rows = <List<Object?>>[];
        for (final d in datasets) {
          String? token;
          do {
            final r = await _call(
              'GET',
              '/projects/${uriEncode(project)}/datasets/${uriEncode(d)}/routines',
              query: {'maxResults': '1000', 'pageToken': ?token},
            );
            for (final x in (r['routines'] as List?) ?? const []) {
              final m = x as Map;
              final name = (m['routineReference'] as Map?)?['routineId'] as String?;
              if (name == null || !_like(name, arg(2))) continue;
              final isProc = m['routineType'] == 'PROCEDURE';
              rows.add([project, d, name, -1, -1, -1, m['routineType'], isProc ? 1 : 2]);
            }
            token = r['nextPageToken'] as String?;
          } while (token != null);
        }
        return catalogResult(CatalogColumns.procedures, rows);
      case 'statistics':
        return catalogResult(CatalogColumns.statistics, const []);
      default:
        return catalogResult(const ['RESULT'], const []);
    }
  }

  // -------------------------------------------------------------------------
  // Session
  // -------------------------------------------------------------------------

  @override
  Future<Map<String, Object?>> info() async => {
    'dbmsName': 'Google BigQuery',
    'dbmsVersion': 'GoogleSQL',
    'driverName': 'DbCraft BigQuery (REST v2)',
    'driverVersion': '1.0',
    'serverName': 'bigquery.googleapis.com',
    'databaseName': _project,
    'userName': _cred.description,
    'identifierQuote': '`',
    'catalogTerm': 'Progetto',
    'schemaTerm': 'Dataset',
    'catalogSupported': 'Y',
    'proceduresSupported': 'Y',
    'schemaUsage': 0x1F,
    'catalogUsage': 0x1F,
    'currentCatalog': _project,
    'keywords': '',
    'readOnly': _readOnly,
    'nativeDriver': 'bigquery',
    'queryLanguage': 'sql',
  };

  // BigQuery has no session level transactions outside scripts.
  @override
  Future<void> setAutoCommit(bool value) async {}
  @override
  Future<void> commit() async {}
  @override
  Future<void> rollback() async {}

  @override
  Future<void> setCurrentCatalog(String catalog) async {
    if (catalog.isNotEmpty) _project = catalog;
  }

  @override
  Future<String?> currentCatalog() async => _project;

  @override
  void cancel() {
    _cancelRequested = true;
    final job = _runningJob;
    if (job != null) unawaited(_cancelJob(job, _runningLocation));
  }

  @override
  Future<void> close() async {
    _cursors.clear();
    _tableCache.clear();
    _closed = true;
  }
}
