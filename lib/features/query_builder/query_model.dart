// Pure-Dart model of the visual query builder and its SQL generator.
//
// The model is UI agnostic (positions are plain doubles) so that the SQL
// generation can be unit tested without widgets.

import '../../model/db_objects.dart';
import '../../services/sql_dialect.dart';

// ---------------------------------------------------------------------------
// Value kinds, operators and literals (shared with the visual filter bar)
// ---------------------------------------------------------------------------

/// Broad value category of a column, used to pick operators and literals.
enum ValueKind { number, text, date, time, timestamp, boolean, binary, other }

/// Classifies an ODBC SQL type (+ type name) into a [ValueKind].
ValueKind valueKindOf(int sqlType, String typeName) {
  final t = typeName.toLowerCase();
  switch (sqlType) {
    case 2: // NUMERIC
    case 3: // DECIMAL
    case 4: // INTEGER
    case 5: // SMALLINT
    case 6: // FLOAT
    case 7: // REAL
    case 8: // DOUBLE
    case -5: // BIGINT
    case -6: // TINYINT
      return ValueKind.number;
    case -7: // BIT
    case 16: // BOOLEAN
      return ValueKind.boolean;
    case 9: // DATETIME (ODBC 2) / DATE
    case 91:
      return t.contains('time') ? ValueKind.timestamp : ValueKind.date;
    case 10: // TIME
    case 92:
      return ValueKind.time;
    case 11: // TIMESTAMP (ODBC 2)
    case 93:
      return ValueKind.timestamp;
    case -2: // BINARY
    case -3: // VARBINARY
    case -4: // LONGVARBINARY
      return ValueKind.binary;
    case 1: // CHAR
    case 12: // VARCHAR
    case -1: // LONGVARCHAR
    case -8: // WCHAR
    case -9: // WVARCHAR
    case -10: // WLONGVARCHAR
      // SQLite reports declared types loosely: trust the declared name.
      return _kindFromName(t) ?? ValueKind.text;
  }
  return _kindFromName(t) ?? ValueKind.other;
}

ValueKind? _kindFromName(String t) {
  if (t.isEmpty) return null;
  if (t.contains('timestamp') || t.contains('datetime')) return ValueKind.timestamp;
  if (t == 'date') return ValueKind.date;
  if (t == 'time') return ValueKind.time;
  if (t.contains('bool')) return ValueKind.boolean;
  if (RegExp(r'^(int|integer|bigint|smallint|tinyint|real|double|float|numeric|decimal|number|money)').hasMatch(t)) {
    return ValueKind.number;
  }
  if (t.contains('char') || t.contains('text') || t.contains('clob') || t.contains('string')) {
    return ValueKind.text;
  }
  if (t.contains('blob') || t.contains('binary') || t.contains('bytea')) return ValueKind.binary;
  return null;
}

/// Filter operators available in the builder grid and the visual filter bar.
enum FilterOp {
  eq('=', '='),
  ne('<>', '≠'),
  gt('>', '>'),
  ge('>=', '≥'),
  lt('<', '<'),
  le('<=', '≤'),
  like('LIKE', 'contiene / LIKE'),
  notLike('NOT LIKE', 'non LIKE'),
  inList('IN', 'in elenco'),
  between('BETWEEN', 'tra'),
  isNull('IS NULL', 'è vuoto'),
  isNotNull('IS NOT NULL', 'non è vuoto');

  const FilterOp(this.sql, this.label);

  /// SQL token(s).
  final String sql;

  /// Short label for menus (Italian).
  final String label;

  /// Number of values the operator needs (IN takes a comma separated list).
  int get arity => switch (this) {
    FilterOp.isNull || FilterOp.isNotNull => 0,
    FilterOp.between => 2,
    _ => 1,
  };

  /// Operators that make sense for a [ValueKind].
  static List<FilterOp> forKind(ValueKind k) => switch (k) {
    ValueKind.text => FilterOp.values,
    ValueKind.boolean => const [FilterOp.eq, FilterOp.ne, FilterOp.isNull, FilterOp.isNotNull],
    ValueKind.binary => const [FilterOp.isNull, FilterOp.isNotNull],
    _ => FilterOp.values.where((o) => o != FilterOp.like && o != FilterOp.notLike).toList(),
  };
}

final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _isoTimestamp = RegExp(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$');

/// Literal for a value typed by the user. A value starting with `=` is used
/// verbatim as an SQL expression (e.g. `=CURRENT_DATE`).
String typedLiteral(SqlDialect d, String raw, ValueKind kind) {
  final v = raw.trim();
  if (v.startsWith('=') && v.length > 1) return v.substring(1).trim();
  if (v.toUpperCase() == 'NULL') return 'NULL';
  switch (kind) {
    case ValueKind.number:
      final n = num.tryParse(v.replaceAll(',', '.'));
      if (n != null) return v.replaceAll(',', '.');
      return d.literal(v);
    case ValueKind.boolean:
      final l = v.toLowerCase();
      if (const {'true', 'vero', 'sì', 'si', '1'}.contains(l)) {
        return d.family == DbFamily.postgres ? 'TRUE' : '1';
      }
      if (const {'false', 'falso', 'no', '0'}.contains(l)) {
        return d.family == DbFamily.postgres ? 'FALSE' : '0';
      }
      return d.literal(v);
    case ValueKind.date:
      if (_isoDate.hasMatch(v) && _typedDateLiterals(d)) return 'DATE ${d.stringLiteral(v)}';
      return d.literal(v);
    case ValueKind.timestamp:
      if (_typedDateLiterals(d)) {
        if (_isoTimestamp.hasMatch(v)) return 'TIMESTAMP ${d.stringLiteral(v.replaceFirst('T', ' '))}';
        if (_isoDate.hasMatch(v)) return 'TIMESTAMP ${d.stringLiteral('$v 00:00:00')}';
      }
      return d.literal(v);
    default:
      return d.literal(v);
  }
}

/// Oracle and Db2 do not convert ISO strings to dates reliably (NLS
/// settings): they get ANSI typed literals.
bool _typedDateLiterals(SqlDialect d) => d.family == DbFamily.oracle || d.family == DbFamily.db2;

/// Splits a comma separated list honouring single quotes.
List<String> splitValues(String s) {
  final out = <String>[];
  final sb = StringBuffer();
  var quoted = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == "'") {
      if (quoted && i + 1 < s.length && s[i + 1] == "'") {
        sb.write("'");
        i++;
        continue;
      }
      quoted = !quoted;
      continue;
    }
    if (ch == ',' && !quoted) {
      out.add(sb.toString().trim());
      sb.clear();
      continue;
    }
    sb.write(ch);
  }
  if (sb.toString().trim().isNotEmpty || out.isNotEmpty) out.add(sb.toString().trim());
  return out.where((e) => e.isNotEmpty).toList();
}

/// Builds `expr op value(s)`; returns null when a required value is missing.
String? buildCondition(SqlDialect d, String expr, FilterOp op, ValueKind kind, String value, [String value2 = '']) {
  String lit(String v) => typedLiteral(d, v, kind);
  switch (op) {
    case FilterOp.isNull:
    case FilterOp.isNotNull:
      return '$expr ${op.sql}';
    case FilterOp.between:
      if (value.trim().isEmpty || value2.trim().isEmpty) return null;
      return '$expr BETWEEN ${lit(value)} AND ${lit(value2)}';
    case FilterOp.inList:
      final items = splitValues(value);
      if (items.isEmpty) return null;
      return '$expr IN (${items.map(lit).join(', ')})';
    case FilterOp.like:
    case FilterOp.notLike:
      if (value.isEmpty) return null;
      // Without wildcards LIKE means "contains" (friendlier for analysts).
      final v = value.contains('%') || value.contains('_') || value.startsWith('=') ? value : '%$value%';
      return '$expr ${op.sql} ${typedLiteral(d, v, ValueKind.text)}';
    default:
      if (value.trim().isEmpty && kind != ValueKind.text) return null;
      return '$expr ${op.sql} ${lit(value)}';
  }
}

// ---------------------------------------------------------------------------
// Query model
// ---------------------------------------------------------------------------

enum JoinType {
  inner('INNER JOIN', 'Inner'),
  left('LEFT JOIN', 'Left outer'),
  right('RIGHT JOIN', 'Right outer'),
  full('FULL OUTER JOIN', 'Full outer');

  const JoinType(this.sql, this.label);
  final String sql;
  final String label;

  /// Same join seen from the other side.
  JoinType get flipped => switch (this) {
    JoinType.left => JoinType.right,
    JoinType.right => JoinType.left,
    _ => this,
  };
}

enum Aggregate {
  none('', 'Nessuna'),
  count('COUNT', 'COUNT'),
  countDistinct('COUNT DISTINCT', 'COUNT DISTINCT'),
  sum('SUM', 'SUM'),
  avg('AVG', 'AVG'),
  min('MIN', 'MIN'),
  max('MAX', 'MAX');

  const Aggregate(this.sql, this.label);
  final String sql;
  final String label;

  String apply(String expr) => switch (this) {
    Aggregate.none => expr,
    Aggregate.countDistinct => 'COUNT(DISTINCT $expr)',
    _ => '$sql($expr)',
  };
}

enum SortDir { none, asc, desc }

/// Column of a table box.
class QbColumn {
  QbColumn({required this.name, this.sqlType = 0, this.typeName = '', this.isKey = false});

  factory QbColumn.fromDb(DbColumn c, {bool isKey = false}) =>
      QbColumn(name: c.name, sqlType: c.dataType, typeName: c.fullType, isKey: isKey);

  final String name;
  final int sqlType;
  final String typeName;
  final bool isKey;

  ValueKind get kind => valueKindOf(sqlType, typeName);
}

/// A table placed on the canvas (the same table may appear more than once).
class QbTable {
  QbTable({
    required this.id,
    required this.table,
    required this.alias,
    required this.columns,
    this.x = 0,
    this.y = 0,
    this.foreignKeys = const [],
  });

  final String id;
  final DbTable table;
  String alias;
  final List<QbColumn> columns;

  /// Canvas position.
  double x, y;

  /// Outgoing foreign keys (used to propose joins automatically).
  final List<DbForeignKey> foreignKeys;

  QbColumn? column(String name) {
    for (final c in columns) {
      if (c.name == name) return c;
    }
    return null;
  }
}

/// Join condition between two columns of two boxes.
class QbJoin {
  QbJoin({
    required this.leftId,
    required this.leftColumn,
    required this.rightId,
    required this.rightColumn,
    this.type = JoinType.inner,
    this.op = '=',
  });

  final String leftId;
  final String leftColumn;
  final String rightId;
  final String rightColumn;
  JoinType type;
  String op;

  static const operators = ['=', '<>', '<', '<=', '>', '>='];

  bool involves(String tableId) => leftId == tableId || rightId == tableId;
}

/// Row of the "Colonne" grid: an output column and/or a condition.
class QbField {
  QbField({
    this.tableId,
    this.column,
    this.expression = '',
    this.alias = '',
    this.output = true,
    this.aggregate = Aggregate.none,
    this.sort = SortDir.none,
    this.sortOrder = 0,
    this.filterOp,
    this.value = '',
    this.value2 = '',
  });

  /// Source box and column; null for a custom expression.
  String? tableId;
  String? column;

  /// Custom SQL expression (used when [tableId] is null).
  String expression;
  String alias;
  bool output;
  Aggregate aggregate;
  SortDir sort;

  /// Position in ORDER BY (lower first).
  int sortOrder;
  FilterOp? filterOp;
  String value;
  String value2;

  bool get isCustom => tableId == null;
}

/// Complete state of a visual query.
class QueryModel {
  final List<QbTable> tables = [];
  final List<QbJoin> joins = [];
  final List<QbField> fields = [];
  bool distinct = false;
  int? limit;
  int _seq = 0;

  bool get isEmpty => tables.isEmpty && fields.every((f) => f.isCustom && f.expression.trim().isEmpty);

  QbTable? byId(String? id) {
    for (final t in tables) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Next free alias (t1, t2, …).
  String nextAlias() {
    var n = 1;
    final used = tables.map((t) => t.alias.toLowerCase()).toSet();
    while (used.contains('t$n')) {
      n++;
    }
    return 't$n';
  }

  /// Adds a table box and, when [autoJoin] is set, the joins implied by the
  /// foreign keys between the new table and the boxes already present.
  QbTable addTable(
    DbTable table,
    List<QbColumn> columns, {
    List<DbForeignKey> foreignKeys = const [],
    double x = 0,
    double y = 0,
    bool autoJoin = true,
  }) {
    final t = QbTable(
      id: 'q${_seq++}',
      table: table,
      alias: nextAlias(),
      columns: columns,
      x: x,
      y: y,
      foreignKeys: foreignKeys,
    );
    if (autoJoin) {
      for (final other in tables) {
        _joinByForeignKeys(t, other);
        _joinByForeignKeys(other, t);
      }
    }
    tables.add(t);
    return t;
  }

  static bool _sameTable(DbForeignKey fk, DbTable target) {
    if (fk.pkTable.toLowerCase() != target.name.toLowerCase()) return false;
    final s = fk.pkSchema, ts = target.schema;
    if (s != null && s.isNotEmpty && ts != null && ts.isNotEmpty && s.toLowerCase() != ts.toLowerCase()) {
      return false;
    }
    return true;
  }

  /// Joins [from] (owner of the FK) to [to] (referenced table).
  void _joinByForeignKeys(QbTable from, QbTable to) {
    if (from == to) return;
    for (final fk in from.foreignKeys) {
      if (!_sameTable(fk, to.table)) continue;
      // Self-references are not joined automatically (ambiguous direction).
      if (from.table == to.table) continue;
      // Only one FK path per pair of boxes.
      if (joins.any(
        (j) => (j.leftId == from.id && j.rightId == to.id) || (j.leftId == to.id && j.rightId == from.id),
      )) {
        return;
      }
      for (var i = 0; i < fk.columns.length && i < fk.refColumns.length; i++) {
        joins.add(QbJoin(leftId: to.id, leftColumn: fk.refColumns[i], rightId: from.id, rightColumn: fk.columns[i]));
      }
      return;
    }
  }

  void removeTable(String id) {
    tables.removeWhere((t) => t.id == id);
    joins.removeWhere((j) => j.involves(id));
    fields.removeWhere((f) => f.tableId == id);
  }

  /// Toggles a column as output field.
  void toggleColumn(String tableId, String column) {
    final i = fields.indexWhere((f) => f.tableId == tableId && f.column == column);
    if (i < 0) {
      fields.add(QbField(tableId: tableId, column: column));
    } else if (fields[i].filterOp != null || fields[i].sort != SortDir.none) {
      // Keep the condition, just drop it from the output.
      fields[i].output = !fields[i].output;
    } else {
      fields.removeAt(i);
    }
  }

  bool isSelected(String tableId, String column) =>
      fields.any((f) => f.tableId == tableId && f.column == column && f.output);

  void clear() {
    tables.clear();
    joins.clear();
    fields.clear();
    distinct = false;
    limit = null;
  }
}

// ---------------------------------------------------------------------------
// SQL generation
// ---------------------------------------------------------------------------

/// Turns a [QueryModel] into a SELECT statement for a dialect.
class QuerySqlGenerator {
  QuerySqlGenerator(this.dialect);
  final SqlDialect dialect;

  String _q(String id) => dialect.quoteIdent(id);

  /// Column expression of a field (alias-qualified) without aggregation.
  String fieldExpression(QueryModel m, QbField f) {
    if (f.isCustom) return f.expression.trim();
    final t = m.byId(f.tableId);
    if (t == null || f.column == null) return '';
    return '${_q(t.alias)}.${_q(f.column!)}';
  }

  String _aggregated(QueryModel m, QbField f) {
    final e = fieldExpression(m, f);
    if (f.aggregate == Aggregate.count && e == '*') return 'COUNT(*)';
    return f.aggregate.apply(e);
  }

  ValueKind _kindOf(QueryModel m, QbField f) {
    if (f.aggregate == Aggregate.count || f.aggregate == Aggregate.countDistinct) return ValueKind.number;
    if (f.isCustom) return ValueKind.other;
    return m.byId(f.tableId)?.column(f.column ?? '')?.kind ?? ValueKind.other;
  }

  /// FROM clause with the joins, ordering the boxes so that every JOIN
  /// references only tables already introduced.
  List<String> _from(QueryModel m) {
    if (m.tables.isEmpty) return const [];
    final placed = <String>{};
    final sb = <String>[];
    String ref(QbTable t) => '${dialect.tableName(t.table)} ${_q(t.alias)}';
    final pending = List.of(m.tables);
    final first = pending.removeAt(0);
    sb.add(ref(first));
    placed.add(first.id);
    while (pending.isNotEmpty) {
      var progress = false;
      for (final t in List.of(pending)) {
        final js = m.joins
            .where(
              (j) =>
                  (j.leftId == t.id && placed.contains(j.rightId)) || (j.rightId == t.id && placed.contains(j.leftId)),
            )
            .toList();
        if (js.isEmpty) continue;
        final j0 = js.first;
        // The stored type is "left box <type> right box": flip it when the
        // new table is the left one.
        final type = j0.rightId == t.id ? j0.type : j0.type.flipped;
        final conds = [
          for (final j in js)
            '${_q(m.byId(j.leftId)!.alias)}.${_q(j.leftColumn)} ${j.op} ${_q(m.byId(j.rightId)!.alias)}.${_q(j.rightColumn)}',
        ];
        sb.add('${type.sql} ${ref(t)} ON ${conds.join(' AND ')}');
        placed.add(t.id);
        pending.remove(t);
        progress = true;
      }
      if (!progress) {
        // Disconnected box: cartesian product, made explicit.
        final t = pending.removeAt(0);
        sb.add('CROSS JOIN ${ref(t)}');
        placed.add(t.id);
      }
    }
    return sb;
  }

  /// Generates the SQL: a single line, or one clause per line with one
  /// select item per line when [pretty] is set. (The pretty layout is built
  /// here instead of with SqlFormatter, which writes `COUNT (x)` and that
  /// breaks MySQL's default parser.)
  String generate(QueryModel m, {bool pretty = false}) {
    if (m.tables.isEmpty && m.fields.every((f) => !f.isCustom || f.expression.trim().isEmpty)) return '';
    final fields = m.fields.where((f) => fieldExpression(m, f).isNotEmpty).toList();
    final outputs = fields.where((f) => f.output).toList();
    final select = <String>[];
    for (final f in outputs) {
      final e = _aggregated(m, f);
      select.add(f.alias.trim().isEmpty ? e : '$e AS ${_q(f.alias.trim())}');
    }
    final hasAggregates = outputs.any((f) => f.aggregate != Aggregate.none);

    final where = <String>[];
    final having = <String>[];
    for (final f in fields) {
      final op = f.filterOp;
      if (op == null) continue;
      final cond = buildCondition(dialect, _aggregated(m, f), op, _kindOf(m, f), f.value, f.value2);
      if (cond == null) continue;
      (f.aggregate == Aggregate.none ? where : having).add(cond);
    }

    final groupBy = <String>[];
    if (hasAggregates) {
      for (final f in outputs) {
        if (f.aggregate != Aggregate.none) continue;
        final e = fieldExpression(m, f);
        if (!groupBy.contains(e)) groupBy.add(e);
      }
    }

    final sorted = fields.where((f) => f.sort != SortDir.none).toList();
    final order = [for (var i = 0; i < sorted.length; i++) (i, sorted[i])]
      ..sort((a, b) {
        final c = a.$2.sortOrder.compareTo(b.$2.sortOrder);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    final orderBy = [for (final (_, f) in order) '${_aggregated(m, f)}${f.sort == SortDir.desc ? ' DESC' : ''}'];

    final limit = m.limit != null && m.limit! > 0 ? m.limit : null;
    final nl = pretty ? '\n' : ' ';
    final itemSep = pretty ? ',\n    ' : ', ';
    final andSep = pretty ? '\n    AND ' : ' AND ';
    final sb = StringBuffer('SELECT');
    // Firebird: SELECT FIRST n DISTINCT; SQL Server: SELECT DISTINCT TOP n.
    if (limit != null && dialect.family == DbFamily.firebird) sb.write(' FIRST $limit');
    if (m.distinct) sb.write(' DISTINCT');
    if (limit != null && dialect.family == DbFamily.sqlServer) sb.write(' TOP $limit');
    sb.write(pretty && select.length > 1 ? '\n    ' : ' ');
    sb.write(select.isEmpty ? '*' : select.join(itemSep));
    final from = _from(m);
    if (from.isNotEmpty) sb.write('${nl}FROM ${from.join(nl)}');
    if (where.isNotEmpty) sb.write('${nl}WHERE ${where.join(andSep)}');
    if (groupBy.isNotEmpty) sb.write('${nl}GROUP BY ${groupBy.join(', ')}');
    if (having.isNotEmpty) sb.write('${nl}HAVING ${having.join(andSep)}');
    if (orderBy.isNotEmpty) sb.write('${nl}ORDER BY ${orderBy.join(', ')}');
    if (limit != null) {
      switch (dialect.family) {
        case DbFamily.sqlServer:
        case DbFamily.firebird:
          break;
        case DbFamily.oracle:
        case DbFamily.db2:
          sb.write('${nl}FETCH FIRST $limit ROWS ONLY');
        default:
          sb.write('${nl}LIMIT $limit');
      }
    }
    return sb.toString();
  }
}
