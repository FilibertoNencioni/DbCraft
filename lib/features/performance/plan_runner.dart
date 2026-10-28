// Runs the structured execution plan of a statement on a dedicated session.
import '../../drivers/db_session.dart';
import '../../odbc/odbc_types.dart';
import '../../services/sql_dialect.dart';
import '../../state/db_connection.dart';
import 'plan_model.dart';

bool visualPlanSupported(DbFamily f) =>
    const {DbFamily.postgres, DbFamily.mysql, DbFamily.sqlServer, DbFamily.sqlite, DbFamily.oracle}.contains(f);

/// Dialects whose plan can include actual values (the statement is run).
bool planAnalyzeSupported(DbFamily f) => f == DbFamily.postgres || f == DbFamily.sqlServer;

/// Removes trailing semicolons / delimiters from [sql].
String cleanPlanSql(String sql) {
  var s = sql.trim();
  while (s.endsWith(';') || s.endsWith('/')) {
    s = s.substring(0, s.length - 1).trimRight();
  }
  return s;
}

/// PostgreSQL EXPLAIN options for the visual plan.
String postgresExplainSql(String sql, {bool analyze = false}) =>
    'EXPLAIN (${analyze ? 'ANALYZE, BUFFERS, ' : ''}FORMAT JSON) ${cleanPlanSql(sql)}';

String _text(ResultPage p) => p.rows.map((r) => r.isEmpty ? '' : (r.first?.toString() ?? '')).join('\n');

Future<ResultPage> _all(DbSession s, String sql) async {
  final p = await s.execute(sql, fetchSize: 5000, queryTimeoutSec: 0);
  if (p.cursorId != null) {
    try {
      await s.closeCursor(p.cursorId!);
    } catch (_) {}
  }
  return p;
}

/// Runs the plan of [sql] on a new session of [dc] (closed afterwards).
/// With [analyze] the statement is executed inside a transaction that is
/// rolled back.
Future<PlanTree> runVisualPlan(DbConnection dc, String sql, {bool analyze = false, String? catalog}) async {
  final family = dc.dialect.family;
  if (!visualPlanSupported(family)) {
    throw UnsupportedError('Il piano visuale non è disponibile per ${dc.serverLabel}: usa "Piano" nell\'editor SQL.');
  }
  final stmt = cleanPlanSql(sql);
  if (stmt.isEmpty) throw ArgumentError('Nessuna istruzione da analizzare');
  final s = await dc.openSession(catalog: catalog);
  try {
    switch (family) {
      case DbFamily.postgres:
        if (analyze) await s.setAutoCommit(false);
        try {
          final p = await _all(s, postgresExplainSql(stmt, analyze: analyze));
          return parsePostgresJsonPlan(_text(p));
        } finally {
          if (analyze) {
            try {
              await s.rollback();
            } catch (_) {}
          }
        }
      case DbFamily.mysql:
        final p = await _all(s, 'EXPLAIN FORMAT=JSON $stmt');
        return parseMySqlJsonPlan(_text(p));
      case DbFamily.sqlServer:
        return analyze ? await _sqlServerActual(s, stmt) : await _sqlServerEstimated(s, stmt);
      case DbFamily.sqlite:
        final p = await _all(s, 'EXPLAIN QUERY PLAN $stmt');
        return parseSqlitePlan(p.columns.map((e) => e.name).toList(), p.rows);
      case DbFamily.oracle:
        return await _oracle(s, stmt);
      default:
        throw UnsupportedError('Dialetto non supportato');
    }
  } finally {
    await s.close();
  }
}

Future<PlanTree> _sqlServerEstimated(DbSession s, String stmt) async {
  await _all(s, 'SET SHOWPLAN_XML ON');
  try {
    final p = await _all(s, stmt);
    final xml = _text(p);
    if (!xml.contains('ShowPlanXML')) throw const FormatException('Il server non ha restituito un piano XML');
    return parseSqlServerShowplan(xml);
  } finally {
    try {
      await _all(s, 'SET SHOWPLAN_XML OFF');
    } catch (_) {}
  }
}

Future<PlanTree> _sqlServerActual(DbSession s, String stmt) async {
  await s.setAutoCommit(false);
  await _all(s, 'SET STATISTICS XML ON');
  try {
    String? xml;
    var page = await s.execute(stmt, fetchSize: 1000);
    while (true) {
      if (page.columns.length == 1 && page.columns.first.name.toLowerCase().contains('showplan')) {
        xml = _text(page);
      }
      final id = page.cursorId;
      if (id == null) break;
      final next = await s.nextResultSet(id, 1000);
      if (next == null) break;
      page = next;
    }
    if (xml == null || xml.isEmpty) throw const FormatException('Il server non ha restituito il piano effettivo');
    return parseSqlServerShowplan(xml);
  } finally {
    try {
      await _all(s, 'SET STATISTICS XML OFF');
    } catch (_) {}
    try {
      await s.rollback();
    } catch (_) {}
  }
}

Future<PlanTree> _oracle(DbSession s, String stmt) async {
  final id = 'DBC${DateTime.now().microsecondsSinceEpoch % 100000000000}';
  await _all(s, "EXPLAIN PLAN SET STATEMENT_ID = '$id' FOR $stmt");
  try {
    final rows = await _all(
      s,
      'SELECT id, parent_id, operation, options, object_owner, object_name, cost, cardinality, bytes, cpu_cost, '
      "io_cost, time, access_predicates, filter_predicates FROM plan_table WHERE statement_id = '$id' ORDER BY id",
    );
    String? text;
    try {
      final x = await _all(
        s,
        "SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', '$id', 'TYPICAL'))",
      );
      text = _text(x);
    } catch (_) {}
    return parseOraclePlan(rows.columns.map((e) => e.name).toList(), rows.rows, xplanText: text);
  } finally {
    try {
      await _all(s, "DELETE FROM plan_table WHERE statement_id = '$id'");
      await s.commit();
    } catch (_) {}
  }
}
