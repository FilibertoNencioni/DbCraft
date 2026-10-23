// What the ODBC metadata does not tell about a table and the system catalog
// of each DBMS does: UNIQUE and CHECK constraints, constraint states, index
// attributes (direction, INCLUDE, filter, method, expressions), collations,
// computed and identity columns. See the readers in this folder.

import '../../schema/schema_model.dart';
import 'design_catalog.dart';

class ColumnExtra {
  const ColumnExtra({
    this.collation,
    this.computed,
    this.computedStored = true,
    this.identitySeed,
    this.identityIncrement,
    this.defaultName,
  });
  final String? collation;
  final String? computed;
  final bool computedStored;
  final int? identitySeed;
  final int? identityIncrement;
  final String? defaultName;
}

/// Extra metadata of one table.
class TableExtras {
  const TableExtras({
    this.uniques = const [],
    this.checks = const [],
    this.primaryKeyName,
    this.primaryKeyState,
    this.primaryKeyClustered,
    this.foreignKeys = const {},
    this.indexes = const {},
    this.constraintIndexes = const {},
    this.columns = const {},
    this.options = const {},
    this.uniqueIndexesAreConstraints = false,
  });

  static const none = TableExtras();

  final List<UniqueDef> uniques;
  final List<CheckDef> checks;
  final String? primaryKeyName;
  final ConstraintState? primaryKeyState;
  final bool? primaryKeyClustered;

  /// Lower-case foreign key name → state and MATCH option.
  final Map<String, ({ConstraintState state, FkMatch match})> foreignKeys;

  /// Lower-case index name → full definition (replaces the ODBC one; indexes
  /// ODBC does not report, such as expression indexes, are added).
  final Map<String, IndexDef> indexes;

  /// Lower-case names of the indexes backing PRIMARY KEY and UNIQUE
  /// constraints: they are not listed as indexes.
  final Set<String> constraintIndexes;

  /// Lower-case column name → extras.
  final Map<String, ColumnExtra> columns;
  final Map<String, String> options;

  /// MySQL: a UNIQUE index is the UNIQUE constraint itself.
  final bool uniqueIndexesAreConstraints;
}

/// [t] completed with [x].
TableDef applyTableExtras(TableDef t, TableExtras x) {
  String k(String s) => s.toLowerCase();
  final columns = [
    for (final c in t.columns)
      switch (x.columns[k(c.name)]) {
        null => c,
        final e => c.copyWith(
          collation: e.collation,
          computed: e.computed,
          computedStored: e.computedStored,
          identitySeed: e.identitySeed,
          identityIncrement: e.identityIncrement,
          defaultName: e.defaultName,
          // A computed column has no default nor identity.
          defaultValue: e.computed != null ? null : c.defaultValue,
          autoIncrement: e.computed != null ? false : c.autoIncrement,
        ),
      },
  ];
  var pk = t.primaryKey;
  if (pk != null) {
    pk = pk.copyWith(
      name: pk.name ?? x.primaryKeyName,
      state: x.primaryKeyState ?? pk.state,
      clustered: x.primaryKeyClustered,
    );
  }
  final fks = [
    for (final f in t.foreignKeys)
      switch (f.name == null ? null : x.foreignKeys[k(f.name!)]) {
        null => f,
        final e => f.copyWith(state: e.state, match: e.match),
      },
  ];
  final uniques = [...x.uniques];
  final uniqueSigs = {for (final u in uniques) u.signature()};
  final constraintNames = {
    ...x.constraintIndexes,
    for (final u in uniques)
      if (u.name != null) k(u.name!),
    if (pk?.name != null) k(pk!.name!),
  };
  final indexes = <IndexDef>[];
  final seen = <String>{};
  for (final i in t.indexes) {
    final name = k(i.name);
    seen.add(name);
    if (constraintNames.contains(name)) continue;
    final full = x.indexes[name]?.copyWith(name: i.name) ?? i;
    if (full.unique && uniqueSigs.contains(full.columns.map(k).join(',')) && full.where == null) continue;
    if (x.uniqueIndexesAreConstraints &&
        full.unique &&
        full.where == null &&
        !full.columns.any(IndexDef.isExpression)) {
      uniques.add(UniqueDef(name: full.name, columns: full.columns));
      continue;
    }
    indexes.add(full);
  }
  for (final e in x.indexes.entries) {
    if (seen.contains(e.key) || constraintNames.contains(e.key)) continue;
    if (x.uniqueIndexesAreConstraints && e.value.unique && !e.value.columns.any(IndexDef.isExpression)) continue;
    indexes.add(e.value);
  }
  return t.copyWith(
    columns: columns,
    primaryKey: pk,
    foreignKeys: fks,
    indexes: indexes,
    uniques: uniques,
    checks: x.checks,
    options: {...t.options, ...x.options},
  );
}

// ---------------------------------------------------------------------------
// Row helpers shared by the readers
// ---------------------------------------------------------------------------

/// Trimmed text of [key] (Firebird pads CHAR columns); null when empty.
String? rowText(CatalogRow r, String key) {
  final v = r[key];
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

int? rowInt(CatalogRow r, String key) {
  final v = r[key];
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString().trim());
}

/// Booleans as the catalogs spell them: 1, 't', 'Y', 'YES', 'TRUE'.
bool rowBool(CatalogRow r, String key) {
  final v = r[key];
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v.toString().trim().toLowerCase();
  return s == '1' || s == 't' || s == 'y' || s == 'yes' || s == 'true';
}

/// Rows grouped by [key], keeping the order of the first appearance.
Map<String, List<CatalogRow>> groupRows(List<CatalogRow> rows, String key) {
  final out = <String, List<CatalogRow>>{};
  for (final r in rows) {
    final g = rowText(r, key);
    if (g == null) continue;
    out.putIfAbsent(g, () => []).add(r);
  }
  return out;
}

/// [s] without one pair of identifier quotes.
String unquoteIdent(String s) {
  final t = s.trim();
  if (t.length >= 2) {
    final a = t[0], b = t[t.length - 1];
    if ((a == '"' && b == '"') || (a == '`' && b == '`') || (a == '[' && b == ']')) {
      return t.substring(1, t.length - 1).replaceAll('$b$b', b);
    }
  }
  return t;
}

/// [s] without the parentheses that enclose all of it (`((a > 0))` →
/// `a > 0`; `(a) and (b)` stays).
String stripParens(String s) {
  var t = s.trim();
  while (t.startsWith('(') && t.endsWith(')')) {
    var depth = 0;
    var whole = true;
    for (var i = 0; i < t.length; i++) {
      if (t[i] == '(') depth++;
      if (t[i] == ')') depth--;
      if (depth == 0 && i < t.length - 1) {
        whole = false;
        break;
      }
    }
    if (!whole) break;
    t = t.substring(1, t.length - 1).trim();
  }
  return t;
}

/// SQL string literal of [s] (catalog queries use literals, not parameters:
/// some drivers do not bind parameters in catalog views).
String lit(String s) => "'${s.replaceAll("'", "''")}'";
