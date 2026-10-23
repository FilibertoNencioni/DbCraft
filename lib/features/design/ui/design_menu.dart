// Navigator menu entries of the design tools: "Crea ▸ …" on tables and
// table parts, and the actions on a key, constraint or index.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../model/db_objects.dart';
import '../../../services/sql_dialect.dart';
import '../../../state/app_state.dart';
import '../../../state/db_connection.dart';
import '../../../ui/navigator/nav_nodes.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_builder.dart';
import '../../schema/schema_model.dart';
import '../capabilities.dart';
import 'design_actions.dart' as actions;
import 'object_actions.dart' as objects;

MenuEntry<void> _item(String label, VoidCallback? action, {bool destructive = false}) =>
    MenuEntry(label, onSelected: action, enabled: action != null, destructive: destructive);

/// Whether the design tools apply to [dc] (SQL, connected).
bool designAvailable(DbConnection dc) => dc.isConnected && dc.dialect.isSql;

/// "Crea ▸" submenu for [table]; [only] limits it to some kinds (null in
/// the set: an index).
MenuEntry<void> createConstraintMenu(
  BuildContext context,
  DbConnection dc,
  DbTable table, {
  Set<ConstraintKind?>? only,
}) {
  final caps = DesignCapabilities.of(dc.dialect);
  final ro = dc.config.readOnly;
  bool want(ConstraintKind? k) => only == null || only.contains(k);
  VoidCallback? create(ConstraintKind? k) => ro ? null : () => actions.createConstraint(context, dc, table, k);
  return MenuEntry.submenu(
    'Crea',
    enabled: !ro,
    children: [
      if (want(ConstraintKind.primaryKey)) _item('Chiave primaria…', create(ConstraintKind.primaryKey)),
      if (want(ConstraintKind.unique)) _item('Vincolo UNIQUE…', create(ConstraintKind.unique)),
      if (want(ConstraintKind.check))
        _item('Vincolo CHECK…', caps.has(DesignFeature.checkConstraints) ? create(ConstraintKind.check) : null),
      if (want(ConstraintKind.foreignKey)) _item('Chiave esterna…', create(ConstraintKind.foreignKey)),
      if (want(null)) _item('Indice…', caps.has(DesignFeature.indexes) ? create(null) : null),
    ],
  );
}

/// Kinds created from a table part folder.
Set<ConstraintKind?> partKinds(TablePart part) => switch (part) {
  TablePart.keys => {ConstraintKind.primaryKey, ConstraintKind.unique},
  TablePart.checks => {ConstraintKind.check},
  TablePart.foreignKeys => {ConstraintKind.foreignKey},
  TablePart.indexes => {null},
  _ => const {},
};

/// Actions on a key, constraint or index node.
List<MenuEntry<void>> constraintMenu(BuildContext context, ConstraintNode n, {required VoidCallback refresh}) {
  final dc = n.connection!;
  final app = AppScope.read(context);
  final caps = DesignCapabilities.of(dc.dialect);
  final def = n.definition;
  final ro = dc.config.readOnly;
  VoidCallback? act(Future<bool> Function() f) => ro ? null : () => f();
  final isIndex = def is IndexDef;
  final canDisable = isIndex ? caps.has(DesignFeature.disableIndex) : caps.has(DesignFeature.disableConstraints);
  final canValidate =
      !isIndex &&
      !n.validated &&
      n.enabled &&
      (dc.dialect.family == DbFamily.postgres ||
          dc.dialect.family == DbFamily.sqlServer ||
          dc.dialect.family == DbFamily.oracle);
  final tableDef = TableDef(catalog: n.table.catalog, schema: n.table.schema, name: n.table.name, columns: const []);
  return [
    if (n.referencing) _item('Apri tabella referenziante', () => app.openTable(dc, n.table)),
    if (def is ForeignKeyDef && !n.referencing)
      _item(
        'Apri tabella riferita',
        () => app.openTable(
          dc,
          DbTable(catalog: def.refCatalog, schema: def.refSchema, name: def.refTable, type: 'TABLE'),
        ),
      ),
    if (n.referencing || def is ForeignKeyDef) const MenuEntry.divider(),
    _item('Modifica…', act(() => actions.editConstraint(context, dc, n.table, def))),
    _item('Rinomina…', n.name == null ? null : act(() => actions.renameConstraint(context, dc, n.table, def))),
    if (canDisable)
      _item(
        n.enabled ? 'Disabilita' : 'Abilita',
        act(() => actions.setConstraintEnabled(context, dc, n.table, def, !n.enabled)),
      ),
    if (canValidate) _item('Valida i dati esistenti', act(() => actions.validateConstraint(context, dc, n.table, def))),
    if (def is IndexDef && caps.has(DesignFeature.rebuildIndex))
      _item('Ricostruisci', act(() => actions.rebuildIndex(context, dc, n.table, def))),
    const MenuEntry.divider(),
    _item('Genera DDL', () {
      final b = DdlBuilder(dc.dialect);
      final sql = def is IndexDef ? b.createIndex(tableDef, def) : b.addConstraint(tableDef, def);
      app.sqlEditorWith(dc, b.render(sql));
    }),
    if (n.name != null) _item('Copia nome', () => Clipboard.setData(ClipboardData(text: n.name!))),
    const MenuEntry.divider(),
    _item('Elimina…', act(() => actions.dropConstraint(context, dc, n.table, def)), destructive: true),
    _item('Aggiorna', refresh),
  ];
}

/// "Nuovo database…" (and, where schemas sit right under the connection,
/// "Nuovo schema…") on a connection node.
List<MenuEntry<void>> connectionDesignMenu(BuildContext context, DbConnection dc, {required bool schemasAtRoot}) {
  final caps = DesignCapabilities.of(dc.dialect);
  final ro = dc.config.readOnly;
  return [
    if (caps.has(DesignFeature.createDatabase))
      _item('Nuovo database…', ro ? null : () => objects.createDatabase(context, dc)),
    if (schemasAtRoot && caps.has(DesignFeature.schemas))
      _item('Nuovo schema…', ro ? null : () => objects.createSchema(context, dc, null)),
  ];
}

/// Actions on a database (catalog node).
List<MenuEntry<void>> databaseMenu(BuildContext context, DbConnection dc, String catalog) {
  final caps = DesignCapabilities.of(dc.dialect);
  final ro = dc.config.readOnly;
  VoidCallback? act(Future<bool> Function() f) => ro ? null : () => f();
  // SQLite databases are files: created from the connection, not altered.
  final managed = caps.has(DesignFeature.createDatabase) && dc.dialect.family != DbFamily.sqlite;
  return [
    if (caps.has(DesignFeature.schemas)) _item('Nuovo schema…', act(() => objects.createSchema(context, dc, catalog))),
    if (managed) _item('Proprietà del database…', act(() => objects.editDatabase(context, dc, catalog))),
    if (caps.has(DesignFeature.renameDatabase))
      _item('Rinomina database…', act(() => objects.renameDatabase(context, dc, catalog))),
    if (managed) _item('Elimina database…', act(() => objects.dropDatabase(context, dc, catalog)), destructive: true),
  ];
}

/// Actions on a schema node.
List<MenuEntry<void>> schemaMenu(BuildContext context, DbConnection dc, String? catalog, String schema) {
  final caps = DesignCapabilities.of(dc.dialect);
  if (!caps.has(DesignFeature.schemas)) return const [];
  final ro = dc.config.readOnly;
  VoidCallback? act(Future<bool> Function() f) => ro ? null : () => f();
  final family = dc.dialect.family;
  return [
    _item('Proprietà dello schema…', act(() => objects.editSchema(context, dc, catalog, schema))),
    if (family == DbFamily.postgres || family == DbFamily.snowflake)
      _item('Rinomina schema…', act(() => objects.renameSchema(context, dc, catalog, schema))),
    _item('Elimina schema…', act(() => objects.dropSchema(context, dc, catalog, schema)), destructive: true),
  ];
}
