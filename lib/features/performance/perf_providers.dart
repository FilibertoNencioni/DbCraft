// Dialect specific queries of the performance dashboard.
//
// Every query lists alternatives tried in order (newer catalog first, older
// versions after) so that a missing column on an old server does not break
// the card. Column aliases are snake_case and their suffix tells the view how
// to format the value: `_s` seconds, `_ms` milliseconds, `_b` bytes.
import '../../services/sql_dialect.dart';
import 'perf_metrics.dart';

enum KpiUnit { count, perSec, percent, bytes }

/// A KPI tile: value computed from the current and the previous snapshot.
class KpiSpec {
  const KpiSpec(this.id, this.label, this.unit, this.compute, {this.help, this.warnAbove, this.warnBelow});
  final String id;
  final String label;
  final KpiUnit unit;
  final double? Function(CounterSnapshot cur, CounterSnapshot? prev) compute;
  final String? help;

  /// Thresholds that tint the value (warning color).
  final double? warnAbove;
  final double? warnBelow;
}

/// Query returning cumulative counters / gauges.
class CounterQuery {
  /// One row: every numeric column becomes a counter named after the
  /// lowercase column name.
  const CounterQuery.row(this.sqls, {this.everyTicks = 1}) : pairs = false;

  /// Name / value rows (SHOW GLOBAL STATUS, v$sysstat, performance counters):
  /// the first column is the lowercase counter name, the second its value.
  const CounterQuery.pairs(this.sqls, {this.everyTicks = 1}) : pairs = true;

  final List<String> sqls;
  final bool pairs;

  /// Run every N refreshes (expensive queries such as the database size).
  final int everyTicks;

  Map<String, double> map(List<String> columns, List<List<Object?>> rows) {
    final out = <String, double>{};
    if (pairs) {
      for (final r in rows) {
        if (r.length < 2 || r[0] == null) continue;
        final v = toDouble(r[1]);
        if (v != null) out[r[0].toString().trim().toLowerCase()] = v;
      }
    } else if (rows.isNotEmpty) {
      for (var i = 0; i < columns.length; i++) {
        final v = toDouble(rows.first[i]);
        if (v != null) out[columns[i].toLowerCase()] = v;
      }
    }
    return out;
  }
}

/// Kill / cancel statements built from a session row (column names are
/// lowercase).
class SessionActions {
  const SessionActions({required this.terminate, this.cancel, required this.idLabel});
  final String? Function(Map<String, Object?> row) terminate;
  final String? Function(Map<String, Object?> row)? cancel;

  /// Human readable session identifier of a row.
  final String Function(Map<String, Object?> row) idLabel;
}

/// A table of the dashboard (sessions, locks, top queries, …).
class TableSpec {
  const TableSpec({
    required this.id,
    required this.title,
    required this.sqls,
    this.live = false,
    this.requires,
    this.requiresHint,
    this.emptyTitle = 'Nessun elemento',
    this.idleColumn,
    this.idleValues = const {},
    this.actions,
    this.idColumn,
    this.blockedByColumn,
    this.help,
  });

  final String id;
  final String title;
  final List<String> sqls;

  /// Refreshed at every tick (otherwise only on load / manual refresh).
  final bool live;

  /// Precondition query: when it returns no rows [requiresHint] is shown.
  final String? requires;
  final String? requiresHint;
  final String emptyTitle;

  /// Client-side filter of idle sessions ("Mostra inattive").
  final String? idleColumn;
  final Set<String> idleValues;
  final SessionActions? actions;

  /// Blocking tree: session id and "blocked by" columns.
  final String? idColumn;
  final String? blockedByColumn;
  final String? help;

  bool get isBlockingTree => idColumn != null && blockedByColumn != null;
}

enum ColKind { text, number, seconds, millis, bytes, query }

/// Formatting kind deduced from the column alias.
ColKind columnKind(String name) {
  final n = name.toLowerCase();
  if (n == 'query' || n == 'sql' || n.endsWith('_query') || n == 'sql_text' || n == 'digest_text') {
    return ColKind.query;
  }
  if (n.endsWith('_ms')) return ColKind.millis;
  if (n.endsWith('_s')) return ColKind.seconds;
  if (n.endsWith('_b')) return ColKind.bytes;
  return ColKind.text;
}

/// Header label for a column alias ("durata_s" → "durata").
String columnLabel(String name) {
  var n = name.toLowerCase();
  for (final s in const ['_ms', '_s', '_b']) {
    if (n.endsWith(s) && n.length > s.length) {
      n = n.substring(0, n.length - s.length);
      if (s == '_ms') n = '$n (ms)';
      break;
    }
  }
  return n.replaceAll('_', ' ');
}

String formatCell(Object? v, ColKind kind) {
  if (v == null) return '';
  switch (kind) {
    case ColKind.seconds:
      final d = toDouble(v);
      return d == null ? v.toString() : formatSeconds(d);
    case ColKind.millis:
      final d = toDouble(v);
      return d == null ? v.toString() : formatNumber(d, decimals: d.abs() < 100 ? 2 : 0);
    case ColKind.bytes:
      final d = toDouble(v);
      return d == null ? v.toString() : formatBytes(d);
    case ColKind.query:
      return v.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    case ColKind.number:
    case ColKind.text:
      if (v is double) return formatNumber(v, decimals: v == v.roundToDouble() ? 0 : 2);
      return v.toString();
  }
}

/// Dialect specific set of queries.
class PerfProvider {
  const PerfProvider({required this.label, required this.counters, required this.kpis, required this.tables});

  final String label;
  final List<CounterQuery> counters;
  final List<KpiSpec> kpis;
  final List<TableSpec> tables;

  static PerfProvider? forFamily(DbFamily f) => switch (f) {
    DbFamily.postgres => _postgres,
    DbFamily.sqlServer => _sqlServer,
    DbFamily.mysql => _mysql,
    DbFamily.oracle => _oracle,
    _ => null,
  };
}

double? _g(CounterSnapshot c, String k) => c[k];

KpiSpec _rate(String id, String label, List<String> keys, {String? help}) =>
    KpiSpec(id, label, KpiUnit.perSec, (c, p) => ratePerSec(p, c, keys), help: help);

// ---------------------------------------------------------------------------
// PostgreSQL
// ---------------------------------------------------------------------------

String _pgCancel(Map<String, Object?> r) => 'SELECT pg_cancel_backend(${toDouble(r['pid'])!.round()})';

final _postgres = PerfProvider(
  label: 'PostgreSQL',
  counters: const [
    CounterQuery.row([
      "SELECT count(*) AS total, "
          "sum(CASE WHEN state = 'active' THEN 1 ELSE 0 END) AS active, "
          "sum(CASE WHEN wait_event_type = 'Lock' THEN 1 ELSE 0 END) AS blocked "
          "FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'",
      "SELECT count(*) AS total, "
          "sum(CASE WHEN state = 'active' THEN 1 ELSE 0 END) AS active, "
          "sum(CASE WHEN wait_event_type = 'Lock' THEN 1 ELSE 0 END) AS blocked "
          "FROM pg_stat_activity WHERE pid <> pg_backend_pid()",
      "SELECT count(*) AS total, "
          "sum(CASE WHEN state = 'active' THEN 1 ELSE 0 END) AS active, "
          "sum(CASE WHEN waiting THEN 1 ELSE 0 END) AS blocked "
          "FROM pg_stat_activity WHERE pid <> pg_backend_pid()",
    ]),
    CounterQuery.row([
      'SELECT xact_commit, xact_rollback, blks_hit, blks_read, tup_returned, tup_fetched, '
          'tup_inserted, tup_updated, tup_deleted, deadlocks '
          'FROM pg_stat_database WHERE datname = current_database()',
    ]),
    CounterQuery.row(['SELECT pg_database_size(current_database()) AS db_size'], everyTicks: 12),
  ],
  kpis: [
    KpiSpec('active', 'Sessioni attive', KpiUnit.count, (c, p) => _g(c, 'active')),
    KpiSpec('total', 'Sessioni totali', KpiUnit.count, (c, p) => _g(c, 'total')),
    _rate('tps', 'Transazioni/s', ['xact_commit', 'xact_rollback'], help: 'Commit + rollback al secondo'),
    KpiSpec(
      'hit',
      'Cache hit',
      KpiUnit.percent,
      (c, p) => hitRatio(p, c, 'blks_hit', 'blks_read'),
      help: 'Blocchi letti dalla cache condivisa',
      warnBelow: 90,
    ),
    KpiSpec('blocked', 'In attesa di lock', KpiUnit.count, (c, p) => _g(c, 'blocked'), warnAbove: 0),
    _rate('read', 'Righe lette/s', ['tup_returned', 'tup_fetched']),
    _rate('write', 'Righe scritte/s', ['tup_inserted', 'tup_updated', 'tup_deleted']),
    KpiSpec('size', 'Dimensione database', KpiUnit.bytes, (c, p) => _g(c, 'db_size')),
  ],
  tables: [
    TableSpec(
      id: 'sessions',
      title: 'Sessioni attive',
      live: true,
      sqls: const [
        "SELECT pid, usename AS utente, datname AS database, application_name AS applicazione, "
            "client_addr::text AS client, state AS stato, "
            "COALESCE(wait_event_type || ': ' || wait_event, '') AS attesa, "
            "EXTRACT(EPOCH FROM (now() - COALESCE(query_start, backend_start)))::bigint AS durata_s, "
            "query "
            "FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type = 'client backend' "
            "ORDER BY (state = 'active') DESC, query_start NULLS LAST",
        "SELECT pid, usename AS utente, datname AS database, application_name AS applicazione, "
            "client_addr::text AS client, state AS stato, "
            "EXTRACT(EPOCH FROM (now() - COALESCE(query_start, backend_start)))::bigint AS durata_s, "
            "query "
            "FROM pg_stat_activity WHERE pid <> pg_backend_pid() "
            "ORDER BY (state = 'active') DESC, query_start NULLS LAST",
      ],
      idleColumn: 'stato',
      idleValues: const {'idle', ''},
      actions: SessionActions(
        terminate: (r) => 'SELECT pg_terminate_backend(${toDouble(r['pid'])!.round()})',
        cancel: _pgCancel,
        idLabel: (r) => 'PID ${toDouble(r['pid'])?.round()}',
      ),
    ),
    const TableSpec(
      id: 'locks',
      title: 'Blocchi',
      live: true,
      idColumn: 'pid',
      blockedByColumn: 'bloccata_da',
      emptyTitle: 'Nessuna sessione bloccata',
      sqls: [
        "SELECT a.pid, array_to_string(pg_blocking_pids(a.pid), ',') AS bloccata_da, a.usename AS utente, "
            "a.state AS stato, COALESCE(a.wait_event_type || ': ' || a.wait_event, '') AS attesa, "
            "EXTRACT(EPOCH FROM (now() - a.query_start))::bigint AS durata_s, a.query "
            "FROM pg_stat_activity a "
            "WHERE cardinality(pg_blocking_pids(a.pid)) > 0 "
            "OR a.pid IN (SELECT unnest(pg_blocking_pids(b.pid)) FROM pg_stat_activity b)",
        "SELECT w.pid, string_agg(DISTINCT h.pid::text, ',') AS bloccata_da, a.usename AS utente, "
            "a.state AS stato, EXTRACT(EPOCH FROM (now() - a.query_start))::bigint AS durata_s, a.query "
            "FROM pg_locks w JOIN pg_locks h ON h.granted AND NOT w.granted AND h.pid <> w.pid "
            "AND h.locktype = w.locktype AND h.database IS NOT DISTINCT FROM w.database "
            "AND h.relation IS NOT DISTINCT FROM w.relation "
            "AND h.transactionid IS NOT DISTINCT FROM w.transactionid "
            "JOIN pg_stat_activity a ON a.pid = w.pid GROUP BY w.pid, a.usename, a.state, a.query_start, a.query",
      ],
    ),
    const TableSpec(
      id: 'top',
      title: 'Query più costose',
      requires: "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'",
      requiresHint:
          'L\'estensione pg_stat_statements non è installata in questo database. Aggiungi '
          'pg_stat_statements a shared_preload_libraries in postgresql.conf, riavvia il server ed esegui '
          'CREATE EXTENSION pg_stat_statements;',
      sqls: [
        'SELECT calls AS esecuzioni, round(total_exec_time::numeric, 1) AS totale_ms, '
            'round(mean_exec_time::numeric, 2) AS medio_ms, rows AS righe, '
            'shared_blks_hit + shared_blks_read AS blocchi, query '
            'FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 50',
        'SELECT calls AS esecuzioni, round(total_time::numeric, 1) AS totale_ms, '
            'round(mean_time::numeric, 2) AS medio_ms, rows AS righe, '
            'shared_blks_hit + shared_blks_read AS blocchi, query '
            'FROM pg_stat_statements ORDER BY total_time DESC LIMIT 50',
      ],
    ),
    const TableSpec(
      id: 'tables',
      title: 'Tabelle più grandi',
      sqls: [
        "SELECT n.nspname AS schema, c.relname AS tabella, c.reltuples::bigint AS righe_stimate, "
            "pg_total_relation_size(c.oid) AS totale_b, pg_relation_size(c.oid) AS dati_b, "
            "pg_indexes_size(c.oid) AS indici_b "
            "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
            "WHERE c.relkind IN ('r', 'm', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema') "
            "AND n.nspname NOT LIKE 'pg_toast%' "
            "ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 50",
      ],
    ),
    const TableSpec(
      id: 'unused',
      title: 'Indici inutilizzati',
      emptyTitle: 'Nessun indice inutilizzato',
      help: 'Indici non univoci mai usati dall\'ultimo reset delle statistiche.',
      sqls: [
        'SELECT s.schemaname AS schema, s.relname AS tabella, s.indexrelname AS indice, '
            's.idx_scan AS scansioni, pg_relation_size(s.indexrelid) AS dimensione_b '
            'FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid '
            'WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary '
            'ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT 50',
      ],
    ),
    const TableSpec(
      id: 'seq',
      title: 'Scansioni sequenziali',
      help: 'Tabelle lette spesso per intero: potrebbe mancare un indice.',
      sqls: [
        'SELECT schemaname AS schema, relname AS tabella, seq_scan AS scansioni_seq, '
            'seq_tup_read AS righe_lette_seq, idx_scan AS scansioni_indice, n_live_tup AS righe_vive '
            'FROM pg_stat_user_tables WHERE seq_scan > 0 ORDER BY seq_tup_read DESC LIMIT 50',
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// SQL Server
// ---------------------------------------------------------------------------

final _sqlServer = PerfProvider(
  label: 'SQL Server',
  counters: const [
    CounterQuery.pairs([
      "SELECT RTRIM(counter_name) AS name, cntr_value AS value FROM sys.dm_os_performance_counters "
          "WHERE RTRIM(instance_name) IN ('', '_Total') AND RTRIM(counter_name) IN ("
          "'Batch Requests/sec', 'Transactions/sec', 'Buffer cache hit ratio', 'Buffer cache hit ratio base', "
          "'Lock Waits/sec', 'Page reads/sec', 'Page writes/sec', 'Page life expectancy')",
    ]),
    CounterQuery.row([
      'SELECT COUNT(*) AS total, '
          'SUM(CASE WHEN r.session_id IS NOT NULL THEN 1 ELSE 0 END) AS active, '
          'SUM(CASE WHEN r.blocking_session_id > 0 THEN 1 ELSE 0 END) AS blocked '
          'FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id '
          'WHERE s.is_user_process = 1 AND s.session_id <> @@SPID',
    ]),
    CounterQuery.row(['SELECT SUM(CAST(size AS bigint)) * 8192 AS db_size FROM sys.database_files'], everyTicks: 12),
  ],
  kpis: [
    KpiSpec('active', 'Richieste attive', KpiUnit.count, (c, p) => _g(c, 'active')),
    KpiSpec('total', 'Sessioni utente', KpiUnit.count, (c, p) => _g(c, 'total')),
    _rate('batch', 'Batch/s', ['batch requests/sec']),
    _rate('tps', 'Transazioni/s', ['transactions/sec']),
    KpiSpec('hit', 'Buffer cache hit', KpiUnit.percent, (c, p) {
      final v = c['buffer cache hit ratio'], b = c['buffer cache hit ratio base'];
      return v == null || b == null || b == 0 ? null : v * 100 / b;
    }, warnBelow: 90),
    KpiSpec('blocked', 'Sessioni bloccate', KpiUnit.count, (c, p) => _g(c, 'blocked'), warnAbove: 0),
    _rate('lockwaits', 'Attese lock/s', ['lock waits/sec']),
    _rate('reads', 'Pagine lette/s', ['page reads/sec']),
    _rate('writes', 'Pagine scritte/s', ['page writes/sec']),
    KpiSpec('size', 'Dimensione database', KpiUnit.bytes, (c, p) => _g(c, 'db_size')),
  ],
  tables: [
    TableSpec(
      id: 'sessions',
      title: 'Sessioni attive',
      live: true,
      sqls: const [
        'SELECT s.session_id AS sessione, s.login_name AS utente, '
            'DB_NAME(COALESCE(r.database_id, s.database_id)) AS database_name, s.host_name AS host, '
            's.program_name AS applicazione, COALESCE(r.status, s.status) AS stato, r.wait_type AS attesa, '
            'r.blocking_session_id AS bloccata_da, '
            'DATEDIFF(SECOND, COALESCE(r.start_time, s.last_request_start_time), GETDATE()) AS durata_s, '
            'r.cpu_time AS cpu_ms, r.logical_reads AS letture_logiche, t.text AS query '
            'FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id '
            'OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t '
            'WHERE s.is_user_process = 1 AND s.session_id <> @@SPID '
            'ORDER BY CASE WHEN r.session_id IS NULL THEN 1 ELSE 0 END, durata_s DESC',
      ],
      idleColumn: 'stato',
      idleValues: const {'sleeping', 'dormant'},
      actions: SessionActions(
        terminate: (r) => 'KILL ${toDouble(r['sessione'])!.round()}',
        idLabel: (r) => 'sessione ${toDouble(r['sessione'])?.round()}',
      ),
    ),
    const TableSpec(
      id: 'locks',
      title: 'Blocchi',
      live: true,
      idColumn: 'sessione',
      blockedByColumn: 'bloccata_da',
      emptyTitle: 'Nessuna sessione bloccata',
      sqls: [
        'SELECT s.session_id AS sessione, COALESCE(r.blocking_session_id, 0) AS bloccata_da, '
            's.login_name AS utente, COALESCE(r.status, s.status) AS stato, r.wait_type AS attesa, '
            'r.wait_time AS attesa_ms, r.wait_resource AS risorsa, t.text AS query '
            'FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id '
            'LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id '
            'OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.sql_handle, c.most_recent_sql_handle)) t '
            'WHERE r.blocking_session_id > 0 '
            'OR s.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id > 0)',
      ],
    ),
    const TableSpec(
      id: 'top',
      title: 'Query più costose',
      sqls: [
        'SELECT TOP 50 qs.execution_count AS esecuzioni, qs.total_elapsed_time / 1000 AS totale_ms, '
            'qs.total_elapsed_time / qs.execution_count / 1000.0 AS medio_ms, qs.total_worker_time / 1000 AS cpu_ms, '
            'qs.total_logical_reads AS letture_logiche, qs.total_rows AS righe, '
            'SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1, ((CASE qs.statement_end_offset '
            'WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) '
            'AS query '
            'FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st '
            'ORDER BY qs.total_elapsed_time DESC',
        'SELECT TOP 50 qs.execution_count AS esecuzioni, qs.total_elapsed_time / 1000 AS totale_ms, '
            'qs.total_elapsed_time / qs.execution_count / 1000.0 AS medio_ms, qs.total_worker_time / 1000 AS cpu_ms, '
            'qs.total_logical_reads AS letture_logiche, st.text AS query '
            'FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st '
            'ORDER BY qs.total_elapsed_time DESC',
      ],
    ),
    const TableSpec(
      id: 'tables',
      title: 'Tabelle più grandi',
      sqls: [
        'SELECT TOP 50 sc.name AS schema_name, t.name AS tabella, '
            'SUM(CASE WHEN p.index_id IN (0, 1) THEN p.row_count ELSE 0 END) AS righe, '
            'SUM(CAST(p.reserved_page_count AS bigint)) * 8192 AS totale_b, '
            'SUM(CASE WHEN p.index_id IN (0, 1) THEN CAST(p.used_page_count AS bigint) ELSE 0 END) * 8192 AS dati_b, '
            'SUM(CASE WHEN p.index_id > 1 THEN CAST(p.used_page_count AS bigint) ELSE 0 END) * 8192 AS indici_b '
            'FROM sys.dm_db_partition_stats p JOIN sys.tables t ON t.object_id = p.object_id '
            'JOIN sys.schemas sc ON sc.schema_id = t.schema_id GROUP BY sc.name, t.name '
            'ORDER BY SUM(CAST(p.reserved_page_count AS bigint)) DESC',
      ],
    ),
    const TableSpec(
      id: 'unused',
      title: 'Indici inutilizzati',
      emptyTitle: 'Nessun indice inutilizzato',
      help: 'Indici non univoci mai letti dall\'avvio del server (ma aggiornati a ogni scrittura).',
      sqls: [
        'SELECT TOP 50 OBJECT_SCHEMA_NAME(i.object_id) AS schema_name, OBJECT_NAME(i.object_id) AS tabella, '
            'i.name AS indice, COALESCE(u.user_updates, 0) AS aggiornamenti '
            'FROM sys.indexes i LEFT JOIN sys.dm_db_index_usage_stats u ON u.object_id = i.object_id '
            'AND u.index_id = i.index_id AND u.database_id = DB_ID() '
            "WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1 AND i.index_id > 1 AND i.is_primary_key = 0 "
            'AND i.is_unique = 0 AND COALESCE(u.user_seeks, 0) + COALESCE(u.user_scans, 0) '
            '+ COALESCE(u.user_lookups, 0) = 0 ORDER BY aggiornamenti DESC',
      ],
    ),
    const TableSpec(
      id: 'missing',
      title: 'Indici mancanti',
      emptyTitle: 'Nessun indice mancante suggerito',
      help: 'Suggerimenti dell\'ottimizzatore (sys.dm_db_missing_index_*): valutali prima di crearli.',
      sqls: [
        'SELECT TOP 50 d.statement AS tabella, d.equality_columns AS uguaglianza, '
            'd.inequality_columns AS disuguaglianza, d.included_columns AS incluse, s.user_seeks AS seek, '
            'CAST(s.avg_user_impact AS decimal(5, 1)) AS impatto_pct, '
            'CAST(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans) AS decimal(18, 1)) '
            'AS punteggio '
            'FROM sys.dm_db_missing_index_details d '
            'JOIN sys.dm_db_missing_index_groups g ON g.index_handle = d.index_handle '
            'JOIN sys.dm_db_missing_index_group_stats s ON s.group_handle = g.index_group_handle '
            'WHERE d.database_id = DB_ID() ORDER BY punteggio DESC',
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// MySQL / MariaDB
// ---------------------------------------------------------------------------

double? _myHit(CounterSnapshot c, CounterSnapshot? p) {
  final req = c['innodb_buffer_pool_read_requests'], miss = c['innodb_buffer_pool_reads'];
  if (req == null || miss == null) return null;
  if (p != null) {
    final pr = p['innodb_buffer_pool_read_requests'], pm = p['innodb_buffer_pool_reads'];
    if (pr != null && pm != null) {
      final dr = req - pr, dm = miss - pm;
      if (dr > 0 && dm >= 0) return (1 - dm / dr) * 100;
    }
  }
  return req > 0 ? (1 - miss / req) * 100 : null;
}

final _mysql = PerfProvider(
  label: 'MySQL / MariaDB',
  counters: const [
    CounterQuery.pairs([
      "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected', 'Threads_running', 'Questions', "
          "'Com_commit', 'Com_rollback', 'Innodb_buffer_pool_read_requests', 'Innodb_buffer_pool_reads', "
          "'Innodb_row_lock_current_waits', 'Innodb_rows_read', 'Innodb_rows_inserted', 'Innodb_rows_updated', "
          "'Innodb_rows_deleted', 'Slow_queries')",
    ]),
    CounterQuery.row([
      'SELECT SUM(data_length + index_length) AS db_size FROM information_schema.tables '
          'WHERE table_schema = DATABASE()',
    ], everyTicks: 12),
  ],
  kpis: [
    KpiSpec('active', 'Thread in esecuzione', KpiUnit.count, (c, p) => _g(c, 'threads_running')),
    KpiSpec('total', 'Connessioni', KpiUnit.count, (c, p) => _g(c, 'threads_connected')),
    _rate('qps', 'Query/s', ['questions']),
    _rate('tps', 'Transazioni/s', ['com_commit', 'com_rollback']),
    KpiSpec('hit', 'Buffer pool hit', KpiUnit.percent, _myHit, warnBelow: 95),
    KpiSpec(
      'blocked',
      'Attese lock riga',
      KpiUnit.count,
      (c, p) => _g(c, 'innodb_row_lock_current_waits'),
      warnAbove: 0,
    ),
    _rate('read', 'Righe lette/s', ['innodb_rows_read']),
    _rate('write', 'Righe scritte/s', ['innodb_rows_inserted', 'innodb_rows_updated', 'innodb_rows_deleted']),
    KpiSpec('size', 'Dimensione database', KpiUnit.bytes, (c, p) => _g(c, 'db_size')),
  ],
  tables: [
    TableSpec(
      id: 'sessions',
      title: 'Sessioni attive',
      live: true,
      sqls: const [
        'SELECT ID AS id, USER AS utente, HOST AS host, DB AS database_name, COMMAND AS comando, '
            'STATE AS stato, TIME AS durata_s, INFO AS query '
            'FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() ORDER BY TIME DESC',
      ],
      idleColumn: 'comando',
      idleValues: const {'Sleep', 'Daemon', 'Binlog Dump'},
      actions: SessionActions(
        terminate: (r) => 'KILL ${toDouble(r['id'])!.round()}',
        cancel: (r) => 'KILL QUERY ${toDouble(r['id'])!.round()}',
        idLabel: (r) => 'thread ${toDouble(r['id'])?.round()}',
      ),
    ),
    const TableSpec(
      id: 'locks',
      title: 'Blocchi',
      live: true,
      idColumn: 'id',
      blockedByColumn: 'bloccata_da',
      emptyTitle: 'Nessuna attesa di lock',
      sqls: [
        'SELECT waiting_pid AS id, blocking_pid AS bloccata_da, locked_table AS tabella, '
            'locked_type AS tipo_lock, wait_age_secs AS durata_s, waiting_query AS query, '
            'blocking_query AS query_bloccante FROM sys.innodb_lock_waits',
        'SELECT r.trx_mysql_thread_id AS id, b.trx_mysql_thread_id AS bloccata_da, w.requested_lock_id AS lock_id, '
            'TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()) AS durata_s, r.trx_query AS query, '
            'b.trx_query AS query_bloccante FROM information_schema.innodb_lock_waits w '
            'JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id '
            'JOIN information_schema.innodb_trx r ON r.trx_id = w.requesting_trx_id',
      ],
    ),
    const TableSpec(
      id: 'top',
      title: 'Query più costose',
      sqls: [
        'SELECT COUNT_STAR AS esecuzioni, ROUND(SUM_TIMER_WAIT / 1000000000, 1) AS totale_ms, '
            'ROUND(AVG_TIMER_WAIT / 1000000000, 2) AS medio_ms, SUM_ROWS_EXAMINED AS righe_esaminate, '
            'SUM_ROWS_SENT AS righe_inviate, SUM_NO_INDEX_USED AS senza_indice, SCHEMA_NAME AS schema_name, '
            'DIGEST_TEXT AS query FROM performance_schema.events_statements_summary_by_digest '
            'ORDER BY SUM_TIMER_WAIT DESC LIMIT 50',
      ],
    ),
    const TableSpec(
      id: 'tables',
      title: 'Tabelle più grandi',
      sqls: [
        'SELECT table_schema AS schema_name, table_name AS tabella, table_rows AS righe_stimate, '
            'data_length + index_length AS totale_b, data_length AS dati_b, index_length AS indici_b, '
            'engine AS motore FROM information_schema.tables '
            "WHERE table_type = 'BASE TABLE' AND table_schema NOT IN "
            "('mysql', 'sys', 'performance_schema', 'information_schema') "
            'ORDER BY data_length + index_length DESC LIMIT 50',
      ],
    ),
    const TableSpec(
      id: 'unused',
      title: 'Indici inutilizzati',
      emptyTitle: 'Nessun indice inutilizzato',
      help: 'Da sys.schema_unused_indexes (richiede performance_schema).',
      sqls: [
        'SELECT object_schema AS schema_name, object_name AS tabella, index_name AS indice '
            'FROM sys.schema_unused_indexes LIMIT 100',
      ],
    ),
    const TableSpec(
      id: 'seq',
      title: 'Scansioni complete',
      help: 'Tabelle lette senza indice (sys.schema_tables_with_full_table_scans).',
      sqls: [
        'SELECT object_schema AS schema_name, object_name AS tabella, rows_full_scanned AS righe_scansionate, '
            'latency AS latenza FROM sys.schema_tables_with_full_table_scans LIMIT 50',
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// Oracle
// ---------------------------------------------------------------------------

double? _oraHit(CounterSnapshot c, CounterSnapshot? p) {
  final logical = c['session logical reads'], physical = c['physical reads'];
  if (logical == null || physical == null) return null;
  if (p != null) {
    final pl = p['session logical reads'], pp = p['physical reads'];
    if (pl != null && pp != null) {
      final dl = logical - pl, dp = physical - pp;
      if (dl > 0 && dp >= 0) return (1 - dp / dl) * 100;
    }
  }
  return logical > 0 ? (1 - physical / logical) * 100 : null;
}

String _oraSid(Map<String, Object?> r) => "'${toDouble(r['sid'])!.round()},${toDouble(r['serial'])!.round()}'";

final _oracle = PerfProvider(
  label: 'Oracle',
  counters: const [
    CounterQuery.pairs([
      'SELECT name, value FROM v\$sysstat WHERE name IN '
          "('user commits', 'user rollbacks', 'session logical reads', 'physical reads', 'execute count', "
          "'db block changes')",
    ]),
    CounterQuery.row([
      "SELECT COUNT(*) AS total, SUM(CASE WHEN status = 'ACTIVE' THEN 1 ELSE 0 END) AS active, "
          'SUM(CASE WHEN blocking_session IS NOT NULL THEN 1 ELSE 0 END) AS blocked '
          "FROM v\$session WHERE type = 'USER'",
    ]),
    CounterQuery.row([
      'SELECT SUM(bytes) AS db_size FROM dba_data_files',
      'SELECT SUM(bytes) AS db_size FROM user_segments',
    ], everyTicks: 12),
  ],
  kpis: [
    KpiSpec('active', 'Sessioni attive', KpiUnit.count, (c, p) => _g(c, 'active')),
    KpiSpec('total', 'Sessioni utente', KpiUnit.count, (c, p) => _g(c, 'total')),
    _rate('tps', 'Transazioni/s', ['user commits', 'user rollbacks']),
    _rate('exec', 'Esecuzioni/s', ['execute count']),
    KpiSpec('hit', 'Buffer cache hit', KpiUnit.percent, _oraHit, warnBelow: 90),
    KpiSpec('blocked', 'Sessioni bloccate', KpiUnit.count, (c, p) => _g(c, 'blocked'), warnAbove: 0),
    _rate('read', 'Letture logiche/s', ['session logical reads']),
    _rate('write', 'Blocchi modificati/s', ['db block changes']),
    KpiSpec('size', 'Dimensione database', KpiUnit.bytes, (c, p) => _g(c, 'db_size')),
  ],
  tables: [
    TableSpec(
      id: 'sessions',
      title: 'Sessioni attive',
      live: true,
      sqls: const [
        'SELECT s.sid, s.serial# AS serial, s.username AS utente, s.machine AS host, s.program AS applicazione, '
            's.status AS stato, s.event AS attesa, s.last_call_et AS durata_s, q.sql_text AS query '
            'FROM v\$session s LEFT JOIN v\$sql q ON q.sql_id = s.sql_id AND q.child_number = s.sql_child_number '
            "WHERE s.type = 'USER' AND s.sid <> SYS_CONTEXT('USERENV', 'SID') "
            "ORDER BY CASE WHEN s.status = 'ACTIVE' THEN 0 ELSE 1 END, s.last_call_et DESC",
      ],
      idleColumn: 'stato',
      idleValues: const {'INACTIVE'},
      actions: SessionActions(
        terminate: (r) => 'ALTER SYSTEM KILL SESSION ${_oraSid(r)} IMMEDIATE',
        cancel: (r) => 'ALTER SYSTEM CANCEL SQL ${_oraSid(r)}',
        idLabel: (r) => 'SID ${toDouble(r['sid'])?.round()}',
      ),
    ),
    const TableSpec(
      id: 'locks',
      title: 'Blocchi',
      live: true,
      idColumn: 'sid',
      blockedByColumn: 'bloccata_da',
      emptyTitle: 'Nessuna sessione bloccata',
      sqls: [
        'SELECT s.sid, s.blocking_session AS bloccata_da, s.username AS utente, s.status AS stato, '
            's.event AS attesa, s.seconds_in_wait AS durata_s, q.sql_text AS query '
            'FROM v\$session s LEFT JOIN v\$sql q ON q.sql_id = s.sql_id AND q.child_number = s.sql_child_number '
            'WHERE s.blocking_session IS NOT NULL '
            'OR s.sid IN (SELECT blocking_session FROM v\$session WHERE blocking_session IS NOT NULL)',
      ],
    ),
    const TableSpec(
      id: 'top',
      title: 'Query più costose',
      sqls: [
        'SELECT * FROM (SELECT sql_id, executions AS esecuzioni, ROUND(elapsed_time / 1000) AS totale_ms, '
            'ROUND(elapsed_time / GREATEST(executions, 1) / 1000, 2) AS medio_ms, buffer_gets AS letture_logiche, '
            'disk_reads AS letture_disco, rows_processed AS righe, sql_text AS query '
            'FROM v\$sqlarea ORDER BY elapsed_time DESC) WHERE ROWNUM <= 50',
      ],
    ),
    const TableSpec(
      id: 'tables',
      title: 'Tabelle più grandi',
      sqls: [
        "SELECT * FROM (SELECT owner AS schema_name, segment_name AS segmento, segment_type AS tipo, "
            "bytes AS totale_b FROM dba_segments WHERE segment_type LIKE 'TABLE%' "
            "AND owner NOT IN ('SYS', 'SYSTEM') ORDER BY bytes DESC) WHERE ROWNUM <= 50",
        "SELECT * FROM (SELECT segment_name AS segmento, segment_type AS tipo, bytes AS totale_b "
            "FROM user_segments WHERE segment_type LIKE 'TABLE%' ORDER BY bytes DESC) WHERE ROWNUM <= 50",
      ],
    ),
  ],
);
