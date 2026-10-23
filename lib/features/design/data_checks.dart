// Checks run before adding a constraint to a table with data: the rows that
// would make the ALTER TABLE fail (orphans of a foreign key, duplicates of a
// key, NULLs, rows failing a CHECK).

import '../../drivers/db_session.dart';
import '../../services/sql_dialect.dart';
import '../schema/schema_model.dart';

/// One check: [countSql] counts the offending rows, [rowsSql] lists them.
class DataCheck {
  const DataCheck(this.label, this.countSql, this.rowsSql);
  final String label;
  final String countSql;
  final String rowsSql;
}

class DataChecks {
  DataChecks(this.dialect);
  final SqlDialect dialect;

  String _q(String c) => dialect.quoteIdent(c);
  String _t(TableDef t) => dialect.qualified(t.catalog, t.schema, t.dbName);

  /// Rows of [child] whose [fk] columns reference no row of the parent
  /// (rows with a NULL in the key are not checked by the DBMS either).
  DataCheck foreignKey(TableDef child, ForeignKeyDef fk) {
    final parent = dialect.qualified(fk.refCatalog, fk.refSchema, fk.refTable);
    final notNull = fk.columns.map((c) => 'c.${_q(c)} IS NOT NULL').join(' AND ');
    final join = [for (var i = 0; i < fk.columns.length; i++) 'p.${_q(fk.refColumns[i])} = c.${_q(fk.columns[i])}']
        .join(' AND ');
    final where = 'WHERE $notNull AND NOT EXISTS (SELECT 1 FROM $parent p WHERE $join)';
    return DataCheck(
      'Righe senza corrispondenza in ${fk.refTable}',
      'SELECT COUNT(*) FROM ${_t(child)} c $where',
      'SELECT c.* FROM ${_t(child)} c $where',
    );
  }

  /// Groups of rows with the same values in [columns] (NULLs never collide).
  DataCheck duplicates(TableDef t, List<String> columns) {
    final cols = columns.map(_q).join(', ');
    final notNull = columns.map((c) => '${_q(c)} IS NOT NULL').join(' AND ');
    final group = 'FROM ${_t(t)} WHERE $notNull GROUP BY $cols HAVING COUNT(*) > 1';
    return DataCheck(
      'Valori duplicati',
      'SELECT COUNT(*) FROM (SELECT $cols $group) d',
      'SELECT $cols, COUNT(*) AS ${_q('righe')} $group',
    );
  }

  /// Rows with a NULL in one of [columns] (primary keys, NOT NULL).
  DataCheck nulls(TableDef t, List<String> columns) {
    final where = 'WHERE ${columns.map((c) => '${_q(c)} IS NULL').join(' OR ')}';
    return DataCheck('Valori NULL', 'SELECT COUNT(*) FROM ${_t(t)} $where', 'SELECT * FROM ${_t(t)} $where');
  }

  /// Rows for which the CHECK expression is false (NULL passes, as in SQL).
  DataCheck check(TableDef t, CheckDef c) {
    final where = 'WHERE NOT (${c.expression.trim()})';
    return DataCheck(
      'Righe che non rispettano il vincolo',
      'SELECT COUNT(*) FROM ${_t(t)} $where',
      'SELECT * FROM ${_t(t)} $where',
    );
  }

  /// Every check needed before adding [constraint] to [t].
  List<DataCheck> forConstraint(TableDef t, Object constraint) => switch (constraint) {
    PrimaryKeyDef p => [nulls(t, p.columns), duplicates(t, p.columns)],
    UniqueDef u => [duplicates(t, u.columns)],
    CheckDef c => [check(t, c)],
    ForeignKeyDef f => [foreignKey(t, f)],
    IndexDef i when i.unique && !i.columns.any(IndexDef.isExpression) => [duplicates(t, i.columns)],
    _ => const [],
  };
}

/// Runs [check] and returns the number of offending rows.
Future<int> countViolations(DbSession session, DataCheck check) async {
  final r = await session.execute(check.countSql, queryTimeoutSec: 60);
  if (r.cursorId != null) await session.closeCursor(r.cursorId!);
  final v = r.rows.isEmpty || r.rows.first.isEmpty ? 0 : r.rows.first.first;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}
