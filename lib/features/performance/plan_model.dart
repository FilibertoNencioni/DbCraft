// Execution plans: a dialect independent tree ([PlanNode]) built from the
// structured plans of PostgreSQL (JSON), MySQL/MariaDB (JSON), SQL Server
// (showplan XML), SQLite (EXPLAIN QUERY PLAN) and Oracle (PLAN_TABLE), plus
// the analysis used by the visual plan (cost share, warnings) and its layout.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:xml/xml.dart';

enum PlanWarningLevel { info, warning, danger }

class PlanWarning {
  const PlanWarning(this.message, {this.level = PlanWarningLevel.warning, this.suggestion});
  final String message;
  final PlanWarningLevel level;

  /// Optional SQL suggested to fix the problem (e.g. CREATE INDEX).
  final String? suggestion;

  @override
  String toString() => message;
}

/// One operator of an execution plan.
class PlanNode {
  PlanNode({
    required this.operation,
    this.object,
    this.detail,
    this.startupCost,
    this.cost,
    this.ownCost,
    this.rowsEstimated,
    this.rowsActual,
    this.timeMs,
    this.loops,
    this.buffers,
    this.fullScan = false,
    this.tableRows,
    Map<String, String>? props,
    List<PlanNode>? children,
    List<PlanWarning>? warnings,
  }) : props = props ?? {},
       children = children ?? [],
       warnings = warnings ?? [];

  /// Operator name (Seq Scan, Hash Match, TABLE ACCESS FULL…).
  String operation;

  /// Table / index the operator works on.
  String? object;

  /// Short condition shown under the title (index condition, filter…).
  String? detail;

  double? startupCost;

  /// Inclusive cost (the operator and its inputs) as reported by the server.
  double? cost;

  /// Exclusive cost when the server reports it directly (MySQL).
  double? ownCost;

  /// Estimated rows (per execution).
  double? rowsEstimated;

  /// Actual rows (per execution) when the plan was executed.
  double? rowsActual;

  /// Inclusive actual time in milliseconds (all loops).
  double? timeMs;
  int? loops;

  /// Pages / blocks touched (buffers, logical reads).
  double? buffers;

  /// Full table scan (used by the "big table scan" warning).
  bool fullScan;

  /// Rows of the scanned table when known (SQL Server TableCardinality).
  double? tableRows;

  final Map<String, String> props;
  final List<PlanNode> children;
  final List<PlanWarning> warnings;

  // Computed by [PlanTree.analyze].
  int id = 0;
  int depth = 0;
  double selfCost = 0;
  double? selfTimeMs;

  /// Share (0..1) of the whole plan attributed to this operator: actual time
  /// when available, otherwise cost.
  double share = 0;

  Iterable<PlanNode> get subtree sync* {
    yield this;
    for (final c in children) {
      yield* c.subtree;
    }
  }

  String get title => object == null || object!.isEmpty ? operation : '$operation · $object';

  @override
  String toString() => title;
}

/// A parsed plan with its source and the plan level information.
class PlanTree {
  PlanTree({
    required this.root,
    required this.format,
    this.source = '',
    this.text,
    Map<String, String>? summary,
    List<PlanWarning>? warnings,
    this.analyzed = false,
  }) : summary = summary ?? {},
       warnings = warnings ?? [];

  final PlanNode root;

  /// 'postgres-json', 'mysql-json', 'showplan-xml', 'sqlite', 'oracle'.
  final String format;

  /// Raw plan as returned by the server.
  String source;

  /// Server formatted text plan when available (DBMS_XPLAN).
  String? text;
  final Map<String, String> summary;

  /// Plan level warnings (e.g. missing indexes).
  final List<PlanWarning> warnings;
  bool analyzed;

  List<PlanNode> get nodes => root.subtree.toList();

  bool get hasActuals => root.subtree.any((n) => n.rowsActual != null || n.timeMs != null);

  /// Plan level and node warnings.
  List<(PlanNode?, PlanWarning)> get allWarnings => [
    for (final w in warnings) (null, w),
    for (final n in nodes)
      for (final w in n.warnings) (n, w),
  ];

  /// Computes ids, exclusive cost / time, shares and the generic warnings
  /// (row estimate mismatch, scans of big tables).
  PlanTree analyze({double bigTableRows = 10000}) {
    var seq = 0;
    void number(PlanNode n, int depth) {
      n.id = seq++;
      n.depth = depth;
      for (final c in n.children) {
        number(c, depth + 1);
      }
    }

    number(root, 0);

    // Exclusive cost; inclusive cost filled in when missing.
    double fill(PlanNode n) {
      var childSum = 0.0;
      for (final c in n.children) {
        childSum += fill(c);
      }
      if (n.ownCost != null) {
        n.selfCost = math.max(0, n.ownCost!);
        n.cost ??= n.selfCost + childSum;
      } else if (n.cost != null) {
        n.selfCost = math.max(0, n.cost! - childSum);
      } else {
        n.selfCost = 0;
        n.cost = childSum > 0 ? childSum : null;
      }
      return n.cost ?? childSum;
    }

    fill(root);

    final hasTime = root.subtree.any((n) => n.timeMs != null);
    if (hasTime) {
      for (final n in root.subtree) {
        if (n.timeMs == null) continue;
        var childTime = 0.0;
        for (final c in n.children) {
          childTime += c.timeMs ?? 0;
        }
        n.selfTimeMs = math.max(0, n.timeMs! - childTime);
      }
    }
    final totalTime = root.subtree.fold<double>(0, (a, n) => a + (n.selfTimeMs ?? 0));
    final totalCost = root.subtree.fold<double>(0, (a, n) => a + n.selfCost);
    for (final n in root.subtree) {
      if (hasTime && totalTime > 0) {
        n.share = (n.selfTimeMs ?? 0) / totalTime;
      } else if (totalCost > 0) {
        n.share = n.selfCost / totalCost;
      } else {
        n.share = 0;
      }
    }

    for (final n in root.subtree) {
      final est = n.rowsEstimated, act = n.rowsActual;
      if (est != null && act != null && (n.loops ?? 1) > 0) {
        final ratio = estimateRatio(est, act);
        if (ratio >= 10 && math.max(est, act) >= 50) {
          n.warnings.add(
            PlanWarning(
              'Stima delle righe errata: stimate ${formatCount(est)}, effettive ${formatCount(act)} '
              '(×${ratio.toStringAsFixed(ratio >= 100 ? 0 : 1)}). Aggiorna le statistiche (ANALYZE).',
            ),
          );
        }
      }
      if (n.fullScan) {
        final rows = n.tableRows ?? n.rowsActual ?? n.rowsEstimated;
        if (rows != null && rows >= bigTableRows) {
          n.warnings.add(
            PlanWarning(
              'Scansione completa su una tabella grande (${formatCount(rows)} righe): valuta un indice.',
              level: n.share >= 0.2 ? PlanWarningLevel.danger : PlanWarningLevel.warning,
            ),
          );
        }
      }
    }
    analyzed = hasActuals;
    return this;
  }
}

/// Ratio between the biggest and the smallest of estimated / actual rows.
double estimateRatio(double estimated, double actual) {
  final hi = math.max(estimated, actual), lo = math.min(estimated, actual);
  return (hi + 1) / (lo + 1);
}

String formatCount(double v) {
  if (v.isNaN) return '';
  if (v == v.roundToDouble() && v.abs() < 1e15) {
    final s = v.round().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0 && s[i - 1] != '-') b.write('.');
      b.write(s[i]);
    }
    return b.toString();
  }
  return v.toStringAsFixed(v.abs() < 10 ? 2 : 1).replaceAll('.', ',');
}

double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is bool) return v ? 1 : 0;
  return double.tryParse(v.toString().trim());
}

String _str(Object? v) {
  if (v == null) return '';
  if (v is List) return v.map(_str).join(', ');
  if (v is Map) return jsonEncode(v);
  if (v is double && v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
  return v.toString();
}

// ---------------------------------------------------------------------------
// PostgreSQL: EXPLAIN (FORMAT JSON [, ANALYZE, BUFFERS])
// ---------------------------------------------------------------------------

PlanTree parsePostgresJsonPlan(String text) {
  Object? data = jsonDecode(text.trim());
  if (data is List) {
    if (data.isEmpty) throw const FormatException('Piano vuoto');
    data = data.first;
  }
  if (data is! Map || data['Plan'] is! Map) throw const FormatException('Piano JSON PostgreSQL non valido');
  final root = _pgNode((data['Plan'] as Map).cast<String, Object?>());
  final summary = <String, String>{};
  for (final e in data.entries) {
    if (e.key == 'Plan') continue;
    final v = e.value;
    if (v is Map || (v is List && v.any((x) => x is Map))) {
      summary[e.key.toString()] = v is List ? '${v.length} elementi' : jsonEncode(v);
    } else {
      summary[e.key.toString()] = _str(v);
    }
  }
  final tree = PlanTree(root: root, format: 'postgres-json', source: text, summary: summary);
  return tree.analyze();
}

const _pgDetailKeys = [
  'Index Cond',
  'Hash Cond',
  'Merge Cond',
  'Join Filter',
  'Recheck Cond',
  'Filter',
  'Sort Key',
  'Group Key',
  'One-Time Filter',
];

PlanNode _pgNode(Map<String, Object?> m) {
  var op = m['Node Type']?.toString() ?? '?';
  final strategy = m['Strategy']?.toString();
  if (op == 'Aggregate' && strategy != null) {
    op = switch (strategy) {
      'Sorted' => 'GroupAggregate',
      'Hashed' => 'HashAggregate',
      'Mixed' => 'MixedAggregate',
      _ => 'Aggregate',
    };
  }
  final join = m['Join Type']?.toString();
  if (join != null && join != 'Inner') {
    op = op.endsWith('Join') ? op.replaceFirst(RegExp(r'Join$'), '$join Join') : '$op $join Join';
  }
  if (m['Parallel Aware'] == true) op = 'Parallel $op';

  String? object;
  final rel = m['Relation Name']?.toString();
  if (rel != null) {
    final schema = m['Schema']?.toString();
    final alias = m['Alias']?.toString();
    object = schema == null ? rel : '$schema.$rel';
    if (alias != null && alias != rel) object = '$object $alias';
  } else {
    object = (m['CTE Name'] ?? m['Function Name'] ?? m['Subplan Name'])?.toString();
  }
  final index = m['Index Name']?.toString();
  if (index != null) object = object == null ? index : '$object (indice $index)';

  String? detail;
  for (final k in _pgDetailKeys) {
    final v = m[k];
    if (v != null) {
      detail = '$k: ${_str(v)}';
      break;
    }
  }

  final loops = _num(m['Actual Loops'])?.round();
  final perLoopTime = _num(m['Actual Total Time']);
  final hit = _num(m['Shared Hit Blocks']), read = _num(m['Shared Read Blocks']);
  final props = <String, String>{};
  for (final e in m.entries) {
    if (e.key == 'Plans') continue;
    props[e.key] = _str(e.value);
  }
  final node = PlanNode(
    operation: op,
    object: object,
    detail: detail,
    startupCost: _num(m['Startup Cost']),
    cost: _num(m['Total Cost']),
    rowsEstimated: _num(m['Plan Rows']),
    rowsActual: _num(m['Actual Rows']),
    timeMs: perLoopTime == null ? null : perLoopTime * math.max(1, loops ?? 1),
    loops: loops,
    buffers: hit == null && read == null ? null : (hit ?? 0) + (read ?? 0),
    fullScan: m['Node Type'] == 'Seq Scan',
    props: props,
    children: [
      for (final c in (m['Plans'] as List?) ?? const [])
        if (c is Map) _pgNode(c.cast<String, Object?>()),
    ],
  );
  if (loops == 0) node.props['Nota'] = 'mai eseguito';

  final spaceType = m['Sort Space Type']?.toString();
  final method = m['Sort Method']?.toString() ?? '';
  if (spaceType == 'Disk' || method.contains('external')) {
    final used = m['Sort Space Used'];
    node.warnings.add(
      PlanWarning(
        'Ordinamento su disco${used == null ? '' : ' ($used kB)'}: aumenta work_mem o riduci le righe da ordinare.',
        level: PlanWarningLevel.danger,
      ),
    );
  }
  final batches = _num(m['Hash Batches']);
  if (batches != null && batches > 1) {
    node.warnings.add(PlanWarning('Hash suddiviso in ${batches.round()} batch (spill su disco): aumenta work_mem.'));
  }
  return node;
}

// ---------------------------------------------------------------------------
// MySQL / MariaDB: EXPLAIN FORMAT=JSON
// ---------------------------------------------------------------------------

PlanTree parseMySqlJsonPlan(String text) {
  final data = jsonDecode(text.trim());
  if (data is! Map) throw const FormatException('Piano JSON MySQL non valido');
  final m = data.cast<String, Object?>();
  PlanNode root;
  if (m['query_block'] is Map) {
    root = _myBlock((m['query_block'] as Map).cast());
  } else if (m.containsKey('operation')) {
    // explain_json_format_version = 2 (MySQL 8.3+).
    root = _myV2(m);
  } else {
    throw const FormatException('Piano JSON MySQL non riconosciuto');
  }
  return PlanTree(root: root, format: 'mysql-json', source: text).analyze();
}

PlanNode _myBlock(Map<String, Object?> m, [String label = 'Query block']) {
  final id = m['select_id'];
  final cost = m['cost_info'] is Map ? _num((m['cost_info'] as Map)['query_cost']) : null;
  final node = PlanNode(
    operation: id == null ? label : '$label #$id',
    props: {
      for (final e in m.entries)
        if (e.value is! Map && e.value is! List) e.key: _str(e.value),
      if (cost != null) 'query_cost': _str(cost),
    },
    children: _myChildren(m),
  );
  if (cost != null && node.children.isEmpty) node.cost = cost;
  if (m['message'] != null) node.detail = m['message'].toString();
  return node;
}

List<PlanNode> _myChildren(Map<String, Object?> m) {
  final out = <PlanNode>[];
  for (final e in m.entries) {
    final v = e.value;
    switch (e.key) {
      case 'table':
        if (v is Map) out.add(_myTable(v.cast()));
      case 'nested_loop':
        if (v is List) {
          out.add(
            PlanNode(
              operation: 'Nested loop',
              children: [
                for (final it in v)
                  if (it is Map) ..._myChildren(it.cast()),
              ],
            ),
          );
        }
      case 'ordering_operation' || 'grouping_operation' || 'duplicates_removal' || 'windowing' || 'buffer_result':
        if (v is Map) {
          final o = v.cast<String, Object?>();
          final filesort = o['using_filesort'] == true;
          final temp = o['using_temporary_table'] == true;
          final node = PlanNode(
            operation: switch (e.key) {
              'ordering_operation' => filesort ? 'Sort (filesort)' : 'Order',
              'grouping_operation' => 'Group',
              'duplicates_removal' => 'Distinct',
              'windowing' => 'Window',
              _ => 'Buffer',
            },
            ownCost: o['cost_info'] is Map ? _num((o['cost_info'] as Map)['sort_cost']) : null,
            props: {
              for (final p in o.entries)
                if (p.value is! Map && p.value is! List) p.key: _str(p.value),
            },
            children: _myChildren(o),
          );
          if (temp) {
            node.warnings.add(const PlanWarning('Usa una tabella temporanea.', level: PlanWarningLevel.info));
          }
          if (filesort) {
            node.warnings.add(
              const PlanWarning(
                'Ordinamento con filesort: un indice sulle colonne di ORDER BY/GROUP BY può evitarlo.',
                level: PlanWarningLevel.info,
              ),
            );
          }
          out.add(node);
        }
      case 'union_result':
        if (v is Map) {
          final u = v.cast<String, Object?>();
          out.add(
            PlanNode(
              operation: 'Union',
              object: u['table_name']?.toString(),
              children: [
                for (final q in (u['query_specifications'] as List?) ?? const [])
                  if (q is Map && q['query_block'] is Map) _myBlock((q['query_block'] as Map).cast()),
              ],
            ),
          );
        }
      case 'query_block':
        if (v is Map) out.add(_myBlock(v.cast()));
      case 'attached_subqueries' || 'optimized_away_subqueries' || 'order_by_subqueries' || 'group_by_subqueries':
        if (v is List) {
          for (final s in v) {
            if (s is Map && s['query_block'] is Map) {
              out.add(_myBlock((s['query_block'] as Map).cast(), 'Subquery'));
            }
          }
        }
      case 'materialized_from_subquery':
        if (v is Map && v['query_block'] is Map) {
          out.add(PlanNode(operation: 'Materialize', children: [_myBlock((v['query_block'] as Map).cast())]));
        }
    }
  }
  return out;
}

const _myAccess = {
  'ALL': 'Full table scan',
  'index': 'Full index scan',
  'range': 'Index range scan',
  'ref': 'Index lookup',
  'eq_ref': 'Unique key lookup',
  'const': 'Single row (const)',
  'system': 'Single row (system)',
  'ref_or_null': 'Index lookup or null',
  'index_merge': 'Index merge',
  'fulltext': 'Fulltext index',
  'unique_subquery': 'Unique subquery',
  'index_subquery': 'Index subquery',
};

PlanNode _myTable(Map<String, Object?> t) {
  final access = t['access_type']?.toString();
  final costInfo = t['cost_info'] is Map ? (t['cost_info'] as Map).cast<String, Object?>() : const <String, Object?>{};
  final read = _num(costInfo['read_cost']), eval = _num(costInfo['eval_cost']);
  final key = t['key']?.toString();
  final props = <String, String>{
    for (final e in t.entries)
      if (e.value is! Map && !(e.value is List && (e.value as List).any((x) => x is Map))) e.key: _str(e.value),
    for (final e in costInfo.entries) 'cost_info.${e.key}': _str(e.value),
  };
  final cond = t['attached_condition']?.toString();
  final node = PlanNode(
    operation: _myAccess[access] ?? (access ?? 'Table'),
    object: [t['table_name']?.toString() ?? '', if (key != null) '(indice $key)'].join(' ').trim(),
    detail: cond == null ? null : 'Condizione: $cond',
    ownCost: read == null && eval == null ? null : (read ?? 0) + (eval ?? 0),
    rowsEstimated: _num(t['rows_examined_per_scan']),
    rowsActual: _num(t['r_rows']),
    timeMs: _num(t['r_total_time_ms']),
    loops: _num(t['r_loops'])?.round(),
    fullScan: access == 'ALL',
    props: props,
    children: _myChildren(t),
  );
  if (access == 'ALL' && t['possible_keys'] == null && node.rowsEstimated != null && node.rowsEstimated! >= 1000) {
    node.warnings.add(const PlanWarning('Nessun indice utilizzabile per questa tabella.'));
  }
  if (t['using_join_buffer'] != null) {
    node.warnings.add(
      PlanWarning(
        'Join buffer (${t['using_join_buffer']}): manca un indice sulla colonna di join.',
        level: PlanWarningLevel.info,
      ),
    );
  }
  return node;
}

PlanNode _myV2(Map<String, Object?> m) {
  final inputs = <PlanNode>[];
  for (final k in const ['inputs', 'subqueries']) {
    final v = m[k];
    if (v is List) {
      for (final i in v) {
        if (i is Map) inputs.add(_myV2(i.cast()));
      }
    }
  }
  final access = m['access_type']?.toString();
  return PlanNode(
    operation: m['operation']?.toString() ?? '?',
    object: m['table_name']?.toString(),
    detail: m['condition']?.toString(),
    cost: _num(m['estimated_total_cost']),
    rowsEstimated: _num(m['estimated_rows']),
    rowsActual: _num(m['actual_rows']),
    timeMs: _num(m['actual_last_row_ms']),
    loops: _num(m['actual_loops'])?.round(),
    fullScan: access == 'table',
    props: {
      for (final e in m.entries)
        if (e.value is! Map && e.value is! List) e.key: _str(e.value),
    },
    children: inputs,
  );
}

// ---------------------------------------------------------------------------
// SQL Server: SHOWPLAN_XML / STATISTICS XML
// ---------------------------------------------------------------------------

PlanTree parseSqlServerShowplan(String xml) {
  final doc = XmlDocument.parse(xml.trim());
  final statements = <PlanNode>[];
  final planWarnings = <PlanWarning>[];
  final summary = <String, String>{};
  for (final st in doc.descendants.whereType<XmlElement>()) {
    if (st.name.local != 'StmtSimple' && st.name.local != 'StmtCursor') continue;
    final qp = st.childElements.where((e) => e.name.local == 'QueryPlan').firstOrNull;
    final type = st.getAttribute('StatementType') ?? 'Statement';
    final node = PlanNode(
      operation: type,
      detail: _oneLine(st.getAttribute('StatementText')),
      cost: _num(st.getAttribute('StatementSubTreeCost')),
      rowsEstimated: _num(st.getAttribute('StatementEstRows')),
      props: {
        for (final a in st.attributes) a.name.local: a.value,
        if (qp != null)
          for (final a in qp.attributes) 'QueryPlan.${a.name.local}': a.value,
      },
    );
    if (qp != null) {
      for (final rel in qp.childElements.where((e) => e.name.local == 'RelOp')) {
        node.children.add(_ssRelOp(rel));
      }
      for (final mi in qp.descendants.whereType<XmlElement>().where((e) => e.name.local == 'MissingIndexGroup')) {
        final w = _ssMissingIndex(mi);
        if (w != null) {
          node.warnings.add(w);
          planWarnings.add(w);
        }
      }
      for (final w in qp.childElements.where((e) => e.name.local == 'Warnings')) {
        node.warnings.addAll(_ssWarnings(w));
      }
      final mg = qp.childElements.where((e) => e.name.local == 'MemoryGrantInfo').firstOrNull;
      if (mg != null) {
        for (final a in mg.attributes) {
          node.props['MemoryGrantInfo.${a.name.local}'] = a.value;
        }
      }
    }
    statements.add(node);
  }
  if (statements.isEmpty) throw const FormatException('Nessuna istruzione nel piano XML');
  final root = statements.length == 1 ? statements.first : PlanNode(operation: 'Batch', children: statements);
  final build = doc.rootElement.getAttribute('Build');
  if (build != null) summary['Versione'] = build;
  return PlanTree(root: root, format: 'showplan-xml', source: xml, summary: summary, warnings: planWarnings).analyze();
}

String? _oneLine(String? s) => s?.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Elements of [relOp] that do not belong to a nested RelOp; nested RelOps
/// are collected in [children].
void _ssScope(XmlElement el, List<XmlElement> own, List<XmlElement> children) {
  for (final c in el.childElements) {
    if (c.name.local == 'RelOp') {
      children.add(c);
    } else {
      own.add(c);
      _ssScope(c, own, children);
    }
  }
}

PlanNode _ssRelOp(XmlElement rel) {
  final own = <XmlElement>[], kids = <XmlElement>[];
  _ssScope(rel, own, kids);
  final physical = rel.getAttribute('PhysicalOp') ?? '?';
  final logical = rel.getAttribute('LogicalOp');
  final op = logical != null && logical != physical ? '$physical ($logical)' : physical;

  String? object;
  final obj = own.where((e) => e.name.local == 'Object').firstOrNull;
  if (obj != null) {
    String u(String? s) => (s ?? '').replaceAll('[', '').replaceAll(']', '');
    final table = [u(obj.getAttribute('Schema')), u(obj.getAttribute('Table'))].where((e) => e.isNotEmpty).join('.');
    final index = u(obj.getAttribute('Index'));
    object = index.isEmpty ? table : '$table (indice $index)';
    if (object.isEmpty) object = null;
  }
  final scalar = own
      .where((e) => e.name.local == 'ScalarOperator' && e.getAttribute('ScalarString') != null)
      .map((e) => e.getAttribute('ScalarString')!)
      .firstOrNull;

  double? actualRows, actualExec, actualTime, logicalReads;
  for (final t in own.where((e) => e.name.local == 'RunTimeCountersPerThread')) {
    actualRows = (actualRows ?? 0) + (_num(t.getAttribute('ActualRows')) ?? 0);
    actualExec = (actualExec ?? 0) + (_num(t.getAttribute('ActualExecutions')) ?? 0);
    final el = _num(t.getAttribute('ActualElapsedms'));
    if (el != null) actualTime = math.max(actualTime ?? 0, el);
    final lr = _num(t.getAttribute('ActualLogicalReads'));
    if (lr != null) logicalReads = (logicalReads ?? 0) + lr;
  }
  final executions = actualExec == null ? null : math.max(1.0, actualExec);
  final props = <String, String>{for (final a in rel.attributes) a.name.local: a.value};
  if (scalar != null) props['Predicato'] = scalar;
  if (obj != null) {
    for (final a in obj.attributes) {
      props['Object.${a.name.local}'] = a.value;
    }
  }
  final node = PlanNode(
    operation: op,
    object: object,
    detail: scalar == null ? null : _oneLine(scalar),
    cost: _num(rel.getAttribute('EstimatedTotalSubtreeCost')),
    rowsEstimated: _num(rel.getAttribute('EstimateRows')),
    // Actual rows are the total over executions; normalize per execution
    // to compare them with EstimateRows.
    rowsActual: actualRows == null ? null : actualRows / executions!,
    timeMs: actualTime,
    loops: actualExec?.round(),
    buffers: logicalReads,
    fullScan: const {'Table Scan', 'Clustered Index Scan', 'Index Scan'}.contains(physical),
    tableRows: _num(rel.getAttribute('TableCardinality')),
    props: props,
    children: [for (final k in kids) _ssRelOp(k)],
  );
  for (final w in rel.childElements.where((e) => e.name.local == 'Warnings')) {
    node.warnings.addAll(_ssWarnings(w));
  }
  return node;
}

List<PlanWarning> _ssWarnings(XmlElement w) {
  final out = <PlanWarning>[];
  for (final a in w.attributes) {
    if (a.value == '1' || a.value == 'true') {
      out.add(
        PlanWarning(switch (a.name.local) {
          'NoJoinPredicate' => 'Join senza predicato (prodotto cartesiano).',
          'UnmatchedIndexes' => 'Indici filtrati non utilizzati per via della parametrizzazione.',
          'SpatialGuess' => 'Stima della selettività spaziale approssimata.',
          'FullUpdateForOnlineIndexBuild' => 'Aggiornamento completo per la creazione online di un indice.',
          _ => a.name.local,
        }, level: a.name.local == 'NoJoinPredicate' ? PlanWarningLevel.danger : PlanWarningLevel.warning),
      );
    }
  }
  for (final c in w.childElements) {
    final name = c.name.local;
    switch (name) {
      case 'SpillToTempDb' || 'SortSpillDetails' || 'HashSpillDetails' || 'ExchangeSpillDetails':
        out.add(
          PlanWarning(
            'Spill su tempdb${c.getAttribute('SpillLevel') == null ? '' : ' (livello ${c.getAttribute('SpillLevel')})'}: '
            'memoria concessa insufficiente per ordinamento/hash.',
            level: PlanWarningLevel.danger,
          ),
        );
      case 'ColumnsWithNoStatistics':
        final cols = c.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'ColumnReference')
            .map((e) => e.getAttribute('Column'))
            .whereType<String>()
            .join(', ');
        out.add(PlanWarning('Colonne senza statistiche: $cols'));
      case 'PlanAffectingConvert':
        out.add(
          PlanWarning(
            'Conversione implicita che influisce sul piano (${c.getAttribute('ConvertIssue') ?? ''}): '
            '${c.getAttribute('Expression') ?? ''}',
          ),
        );
      case 'MemoryGrantWarning':
        out.add(
          PlanWarning(
            'Memory grant: ${c.getAttribute('GrantWarningKind') ?? ''} '
            '(richiesta ${c.getAttribute('RequestedMemory') ?? '?'} KB, usata ${c.getAttribute('MaxUsedMemory') ?? '?'} KB)',
            level: PlanWarningLevel.info,
          ),
        );
      case 'Wait':
        break;
      default:
        out.add(PlanWarning(name, level: PlanWarningLevel.info));
    }
  }
  return out;
}

PlanWarning? _ssMissingIndex(XmlElement group) {
  final impact = group.getAttribute('Impact');
  final mi = group.childElements.where((e) => e.name.local == 'MissingIndex').firstOrNull;
  if (mi == null) return null;
  final table = [
    mi.getAttribute('Database'),
    mi.getAttribute('Schema'),
    mi.getAttribute('Table'),
  ].whereType<String>().join('.');
  final keys = <String>[], include = <String>[];
  for (final cg in mi.childElements.where((e) => e.name.local == 'ColumnGroup')) {
    final cols = cg.childElements.where((e) => e.name.local == 'Column').map((e) => e.getAttribute('Name') ?? '');
    if (cg.getAttribute('Usage') == 'INCLUDE') {
      include.addAll(cols);
    } else {
      keys.addAll(cols);
    }
  }
  final shortTable = [mi.getAttribute('Schema'), mi.getAttribute('Table')].whereType<String>().join('.');
  final sql =
      'CREATE NONCLUSTERED INDEX [IX_${(mi.getAttribute('Table') ?? 't').replaceAll(RegExp(r'[\[\]]'), '')}'
      '_${keys.map((e) => e.replaceAll(RegExp(r'[\[\]]'), '')).join('_')}]\n'
      'ON $shortTable (${keys.join(', ')})'
      '${include.isEmpty ? '' : '\nINCLUDE (${include.join(', ')})'};';
  return PlanWarning(
    'Indice mancante su $table (impatto stimato ${impact ?? '?'}%): ${keys.join(', ')}'
    '${include.isEmpty ? '' : ' INCLUDE ${include.join(', ')}'}',
    level: PlanWarningLevel.danger,
    suggestion: sql,
  );
}

// ---------------------------------------------------------------------------
// Plans returned as rows with id / parent id (SQLite, Oracle)
// ---------------------------------------------------------------------------

/// Builds a tree from (id, parentId, node) triples; nodes whose parent is
/// unknown become children of a synthetic root (or the root itself when
/// there is exactly one).
PlanNode treeFromRows(List<(int id, int? parent, PlanNode node)> rows, {String rootLabel = 'Query'}) {
  final byId = <int, PlanNode>{for (final r in rows) r.$1: r.$3};
  final tops = <PlanNode>[];
  for (final (id, parent, node) in rows) {
    final p = parent == null || parent == id ? null : byId[parent];
    if (p == null) {
      tops.add(node);
    } else {
      p.children.add(node);
    }
  }
  if (tops.length == 1) return tops.first;
  return PlanNode(operation: rootLabel, children: tops);
}

int _colIndex(List<String> columns, String name) => columns.indexWhere((c) => c.toLowerCase() == name.toLowerCase());

/// SQLite `EXPLAIN QUERY PLAN` (columns id, parent, notused, detail; older
/// versions: selectid, order, from, detail).
PlanTree parseSqlitePlan(List<String> columns, List<List<Object?>> rows) {
  final iId = _colIndex(columns, 'id'), iParent = _colIndex(columns, 'parent');
  var iDetail = _colIndex(columns, 'detail');
  if (iDetail < 0) iDetail = columns.length - 1;
  final triples = <(int, int?, PlanNode)>[];
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final detail = r[iDetail]?.toString() ?? '';
    final node = PlanNode(operation: detail, props: {for (var j = 0; j < columns.length; j++) columns[j]: _str(r[j])});
    final upper = detail.toUpperCase();
    if (RegExp(r'^SCAN\b').hasMatch(upper) && !upper.contains('USING') && !upper.contains('SUBQUERY')) {
      node.fullScan = true;
      node.warnings.add(
        const PlanWarning('Scansione completa della tabella: valuta un indice sulle colonne filtrate.'),
      );
    }
    if (upper.contains('USE TEMP B-TREE')) {
      node.warnings.add(
        const PlanWarning(
          'B-tree temporaneo per ordinamento/raggruppamento: un indice adatto può evitarlo.',
          level: PlanWarningLevel.info,
        ),
      );
    }
    final id = iId >= 0 ? (_num(r[iId])?.round() ?? i + 1) : i + 1;
    final parent = iParent >= 0 ? _num(r[iParent])?.round() : null;
    triples.add((id, parent == 0 ? null : parent, node));
  }
  final root = triples.isEmpty ? PlanNode(operation: 'Nessun passo') : treeFromRows(triples);
  final source = rows.map((r) => r.map(_str).join(' | ')).join('\n');
  return PlanTree(root: root, format: 'sqlite', source: source).analyze();
}

/// Oracle PLAN_TABLE rows (id, parent_id, operation, options, object_owner,
/// object_name, cost, cardinality, bytes, time, access_predicates,
/// filter_predicates, …).
PlanTree parseOraclePlan(List<String> columns, List<List<Object?>> rows, {String? xplanText}) {
  Object? v(List<Object?> r, String name) {
    final i = _colIndex(columns, name);
    return i < 0 ? null : r[i];
  }

  final triples = <(int, int?, PlanNode)>[];
  for (final r in rows) {
    final operation = v(r, 'operation')?.toString() ?? '?';
    final options = v(r, 'options')?.toString();
    final owner = v(r, 'object_owner')?.toString();
    final name = v(r, 'object_name')?.toString();
    final access = v(r, 'access_predicates')?.toString();
    final filter = v(r, 'filter_predicates')?.toString();
    final node = PlanNode(
      operation: options == null || options.isEmpty ? operation : '$operation $options',
      object: name == null ? null : (owner == null ? name : '$owner.$name'),
      detail: access != null ? 'Accesso: $access' : (filter != null ? 'Filtro: $filter' : null),
      cost: _num(v(r, 'cost')),
      rowsEstimated: _num(v(r, 'cardinality')),
      fullScan: operation == 'TABLE ACCESS' && options == 'FULL',
      props: {
        for (var j = 0; j < columns.length; j++)
          if (r[j] != null) columns[j].toLowerCase(): _str(r[j]),
      },
    );
    final id = _num(v(r, 'id'))?.round() ?? triples.length;
    triples.add((id, _num(v(r, 'parent_id'))?.round(), node));
  }
  final root = triples.isEmpty ? PlanNode(operation: 'Nessun passo') : treeFromRows(triples);
  return PlanTree(
    root: root,
    format: 'oracle',
    source: xplanText ?? rows.map((r) => r.map(_str).join(' | ')).join('\n'),
    text: xplanText,
  ).analyze();
}

// ---------------------------------------------------------------------------
// Text rendering and layout
// ---------------------------------------------------------------------------

/// Indented text representation of the plan (copy / text view).
String planToText(PlanTree t) {
  final b = StringBuffer();
  void walk(PlanNode n, String indent) {
    final parts = <String>[
      if (n.cost != null) 'costo=${n.cost!.toStringAsFixed(2)}',
      if (n.rowsEstimated != null) 'righe=${formatCount(n.rowsEstimated!)}',
      if (n.rowsActual != null) 'effettive=${formatCount(n.rowsActual!)}',
      if (n.timeMs != null) 'tempo=${n.timeMs!.toStringAsFixed(3)} ms',
      if (n.loops != null) 'loop=${n.loops}',
    ];
    b.write(indent.isEmpty ? '' : '$indent-> ');
    b.write(n.title);
    if (parts.isNotEmpty) b.write('  (${parts.join(' ')})');
    b.writeln();
    if (n.detail != null) b.writeln('$indent     ${n.detail}');
    for (final w in n.warnings) {
      b.writeln('$indent     ! ${w.message}');
    }
    for (final c in n.children) {
      walk(c, '$indent  ');
    }
  }

  walk(t.root, '');
  for (final w in t.warnings) {
    b.writeln('! ${w.message}');
  }
  return b.toString().trimRight();
}

/// Positions of the plan nodes for the graphical view (root at the top,
/// children below, leaves spread horizontally).
class PlanLayout {
  PlanLayout(this.rects, this.size);
  final Map<PlanNode, Rect> rects;
  final Size size;
}

PlanLayout layoutPlan(
  PlanNode root, {
  required double Function(PlanNode n) width,
  double height = 74,
  double hGap = 24,
  double vGap = 44,
  double margin = 24,
}) {
  final rects = <PlanNode, Rect>{};
  var cursor = margin;
  var maxDepth = 0;

  // Returns the horizontal center of [n].
  double place(PlanNode n, int depth) {
    maxDepth = math.max(maxDepth, depth);
    final w = width(n);
    final y = margin + depth * (height + vGap);
    if (n.children.isEmpty) {
      final x = cursor;
      cursor += w + hGap;
      rects[n] = Rect.fromLTWH(x, y, w, height);
      return x + w / 2;
    }
    final start = cursor;
    final centers = [for (final c in n.children) place(c, depth + 1)];
    var center = (centers.first + centers.last) / 2;
    // Parent wider than its children block: shift it right of the cursor.
    if (center - w / 2 < start) center = start + w / 2;
    final x = center - w / 2;
    rects[n] = Rect.fromLTWH(x, y, w, height);
    cursor = math.max(cursor, x + w + hGap);
    return center;
  }

  place(root, 0);
  var right = 0.0;
  for (final r in rects.values) {
    right = math.max(right, r.right);
  }
  return PlanLayout(rects, Size(right + margin, margin * 2 + (maxDepth + 1) * height + maxDepth * vGap));
}
