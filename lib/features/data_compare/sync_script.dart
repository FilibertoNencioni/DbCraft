// Synchronization script of a data comparison: makes the target table equal
// to the source (INSERT missing rows, UPDATE differing columns, optionally
// DELETE rows that exist only in the target).
import '../../services/sql_dialect.dart';
import 'compare_engine.dart';
import 'sql_values.dart';

class SyncScriptOptions {
  SyncScriptOptions({this.insert = true, this.update = true, this.delete = false});
  bool insert;
  bool update;

  /// Dangerous: removes rows from the target. Off by default.
  bool delete;
}

/// A statement of the synchronization script, both parameterized (used to
/// execute it) and with literals (shown / saved / opened in the editor).
class SyncStatement {
  const SyncStatement(this.kind, this.sql, this.params, this.literal);
  final RowDiff kind;
  final String sql;
  final List<Object?> params;
  final String literal;
}

class SyncScriptBuilder {
  SyncScriptBuilder({
    required this.dialect,
    required this.tableName,
    required this.columns,
    required this.keyCount,
    List<int?>? sqlTypes,
  }) : sqlTypes = sqlTypes ?? List<int?>.filled(columns.length, null);

  /// Dialect of the TARGET connection.
  final SqlDialect dialect;

  /// Qualified (already quoted) target table name.
  final String tableName;

  /// Target column names in the row layout (keys first).
  final List<String> columns;
  final int keyCount;

  /// ODBC types of the target columns (drive literals and parameters).
  final List<int?> sqlTypes;

  String _q(int i) => dialect.quoteIdent(columns[i]);
  String _lit(int i, Object? v) => typedLiteral(dialect, sqlTypes[i], v);
  Object? _param(int i, Object? v) => bindValue(dialect, sqlTypes[i], v);

  (String, List<Object?>, String) _where(List<Object?> row) {
    final parts = <String>[], lits = <String>[];
    final params = <Object?>[];
    for (var i = 0; i < keyCount; i++) {
      final v = row[i];
      if (v == null) {
        parts.add('${_q(i)} IS NULL');
        lits.add('${_q(i)} IS NULL');
      } else {
        parts.add('${_q(i)} = ?');
        lits.add('${_q(i)} = ${_lit(i, v)}');
        params.add(_param(i, v));
      }
    }
    return (parts.join(' AND '), params, lits.join(' AND '));
  }

  SyncStatement insert(List<Object?> src) {
    final cols = List.generate(columns.length, _q).join(', ');
    return SyncStatement(
      RowDiff.onlySource,
      'INSERT INTO $tableName ($cols) VALUES (${List.filled(columns.length, '?').join(', ')})',
      [for (var i = 0; i < columns.length; i++) _param(i, src[i])],
      'INSERT INTO $tableName ($cols) VALUES (${[for (var i = 0; i < columns.length; i++) _lit(i, src[i])].join(', ')})',
    );
  }

  /// UPDATE of the [diff] columns, located by the TARGET key values (they
  /// may differ in blanks / case from the source ones).
  SyncStatement update(List<Object?> src, List<Object?> tgt, List<int> diff) {
    final (w, wp, wl) = _where(tgt);
    return SyncStatement(
      RowDiff.different,
      'UPDATE $tableName SET ${diff.map((i) => '${_q(i)} = ?').join(', ')} WHERE $w',
      [for (final i in diff) _param(i, src[i]), ...wp],
      'UPDATE $tableName SET ${diff.map((i) => '${_q(i)} = ${_lit(i, src[i])}').join(', ')} WHERE $wl',
    );
  }

  SyncStatement delete(List<Object?> tgt) {
    final (w, wp, wl) = _where(tgt);
    return SyncStatement(RowDiff.onlyTarget, 'DELETE FROM $tableName WHERE $w', wp, 'DELETE FROM $tableName WHERE $wl');
  }

  /// Statements in execution order: DELETE, UPDATE, INSERT (deleting first
  /// avoids conflicts on unique constraints).
  List<SyncStatement> build(CompareResult r, SyncScriptOptions o) {
    final del = <SyncStatement>[], upd = <SyncStatement>[], ins = <SyncStatement>[];
    for (final row in r.rows) {
      switch (row.kind) {
        case RowDiff.onlyTarget when o.delete:
          del.add(delete(row.target!));
        case RowDiff.different when o.update:
          upd.add(update(row.source!, row.target!, row.diffColumns));
        case RowDiff.onlySource when o.insert:
          ins.add(insert(row.source!));
        default:
          break;
      }
    }
    return [...del, ...upd, ...ins];
  }

  /// Full script text with literals.
  String script(List<SyncStatement> statements, {String? header}) {
    final sb = StringBuffer();
    if (header != null && header.isNotEmpty) {
      for (final l in header.split('\n')) {
        sb.writeln('-- $l');
      }
      sb.writeln();
    }
    RowDiff? last;
    for (final s in statements) {
      if (s.kind != last) {
        if (last != null) sb.writeln();
        sb.writeln(switch (s.kind) {
          RowDiff.onlyTarget => '-- Righe presenti solo nella destinazione',
          RowDiff.different => '-- Righe diverse',
          _ => '-- Righe presenti solo nell\'origine',
        });
        last = s.kind;
      }
      sb.writeln('${s.literal};');
    }
    return sb.toString();
  }
}
