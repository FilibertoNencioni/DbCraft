import 'package:flutter/material.dart';

import '../../features/design/capabilities.dart';
import '../../features/design/catalog/design_catalog.dart';
import '../../features/schema/schema_model.dart';
import '../../model/db_objects.dart';
import '../../state/db_connection.dart';
import '../theme/app_icons.dart';

/// A node of the database navigator tree. Children are loaded lazily.
abstract class NavNode {
  NavNode(this.connection);
  final DbConnection? connection;

  List<NavNode>? children;
  bool expanded = false;
  bool loading = false;
  String? error;

  String get label;
  String? get detail => null;
  IconData get icon;
  bool get expandable => true;
  String get key;

  /// Filtering applies to "leaf objects" (tables, procedures).
  bool get filterable => false;

  Future<List<NavNode>> load();

  void reset() {
    children = null;
    expanded = false;
    error = null;
  }
}

class FolderNode extends NavNode {
  FolderNode(this.name, this.items) : super(null);
  final String name;
  final List<NavNode> items;

  @override
  String get label => name;
  @override
  IconData get icon => AppIcons.folder;
  @override
  String get key => 'folder:$name';
  @override
  Future<List<NavNode>> load() async => items;
}

class ConnectionNode extends NavNode {
  ConnectionNode(DbConnection super.connection);

  DbConnection get dc => connection!;

  @override
  String get label => dc.config.name;
  @override
  String? get detail => dc.isConnected ? dc.serverLabel : null;
  @override
  IconData get icon => dc.config.template.icon;
  @override
  String get key => 'conn:${dc.config.id}';

  @override
  Future<List<NavNode>> load() async {
    final md = dc.metadata!;
    if (md.supportsCatalogs) {
      final cats = await md.catalogs();
      if (cats.isNotEmpty) {
        return [for (final c in cats) CatalogNode(dc, c, current: c == (dc.defaultCatalog ?? md.currentCatalog))];
      }
    }
    if (md.supportsSchemas) {
      final schemas = await listSchemas(dc, null);
      if (schemas.isNotEmpty) return [for (final s in schemas) SchemaNode(dc, null, s)];
    }
    return objectFolders(dc, null, null);
  }
}

List<NavNode> objectFolders(DbConnection dc, String? catalog, String? schema) => [
  ObjectFolderNode(dc, catalog, schema, ObjectKind.tables),
  ObjectFolderNode(dc, catalog, schema, ObjectKind.views),
  ObjectFolderNode(dc, catalog, schema, ObjectKind.system),
  if (dc.metadata?.supportsProcedures ?? true) ObjectFolderNode(dc, catalog, schema, ObjectKind.procedures),
];

/// Schemas of [catalog]: the ODBC list plus, where the design catalog
/// reads them, the empty ones ODBC leaves out (SQL Server lists only the
/// schemas that contain objects).
Future<List<String>> listSchemas(DbConnection dc, String? catalog) async {
  final odbc = await dc.metadata!.schemas(catalog);
  final cat = DesignCatalog.of(dc);
  if (cat == null || !DesignCapabilities.of(dc.dialect).has(DesignFeature.schemas)) return odbc;
  try {
    final extra = [
      for (final s in await cat.schemaDefs(catalog))
        if (!odbc.any((o) => o.toLowerCase() == s.name.toLowerCase())) s.name,
    ];
    if (extra.isEmpty) return odbc;
    return [...odbc, ...extra]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  } catch (_) {
    return odbc;
  }
}

class CatalogNode extends NavNode {
  CatalogNode(DbConnection super.connection, this.catalog, {this.current = false});
  final String catalog;
  final bool current;

  @override
  String get label => catalog;
  @override
  String? get detail => current ? 'predefinito' : null;
  @override
  IconData get icon => AppIcons.database;
  @override
  String get key => 'cat:${connection!.config.id}:$catalog';

  @override
  Future<List<NavNode>> load() async {
    final md = connection!.metadata!;
    if (md.supportsSchemas) {
      final schemas = await listSchemas(connection!, catalog);
      if (schemas.isNotEmpty) return [for (final s in schemas) SchemaNode(connection!, catalog, s)];
    }
    return objectFolders(connection!, catalog, null);
  }
}

class SchemaNode extends NavNode {
  SchemaNode(DbConnection super.connection, this.catalog, this.schema);
  final String? catalog;
  final String schema;

  @override
  String get label => schema;
  @override
  IconData get icon => AppIcons.schema;
  @override
  String get key => 'sch:${connection!.config.id}:${catalog ?? ''}:$schema';

  @override
  Future<List<NavNode>> load() async => objectFolders(connection!, catalog, schema);
}

enum ObjectKind {
  tables('Tabelle', AppIcons.table),
  views('Viste', AppIcons.erDiagram),
  system('Altri oggetti', AppIcons.settings),
  procedures('Procedure e funzioni', AppIcons.function);

  const ObjectKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

class ObjectFolderNode extends NavNode {
  ObjectFolderNode(DbConnection super.connection, this.catalog, this.schema, this.kind);
  final String? catalog;
  final String? schema;
  final ObjectKind kind;

  @override
  String get label => kind.label;
  @override
  String? get detail => children == null ? null : '${children!.length}';
  @override
  IconData get icon => AppIcons.folder;
  @override
  String get key => 'objs:${connection!.config.id}:${catalog ?? ''}:${schema ?? ''}:${kind.name}';

  @override
  Future<List<NavNode>> load() async {
    final md = connection!.metadata!;
    if (kind == ObjectKind.procedures) {
      final procs = await md.procedures(catalog, schema);
      return [for (final p in procs) ProcedureNode(connection!, p)];
    }
    final tables = await md.tables(catalog, schema);
    bool match(DbTable t) {
      final type = t.type.toUpperCase();
      switch (kind) {
        case ObjectKind.tables:
          return type == 'TABLE' || type == 'BASE TABLE';
        case ObjectKind.views:
          return type.contains('VIEW');
        case ObjectKind.system:
          return !(type == 'TABLE' || type == 'BASE TABLE' || type.contains('VIEW'));
        case ObjectKind.procedures:
          return false;
      }
    }

    return [for (final t in tables.where(match)) TableNode(connection!, t)];
  }
}

class TableNode extends NavNode {
  TableNode(DbConnection super.connection, this.table);
  final DbTable table;

  @override
  String get label => table.name;
  @override
  String? get detail {
    final t = table.type.toUpperCase();
    return t == 'TABLE' || t == 'VIEW' || t == 'BASE TABLE' ? null : table.type;
  }

  @override
  IconData get icon => table.isView
      ? AppIcons.erDiagram
      : table.type.toUpperCase().contains('SYSTEM')
      ? AppIcons.table
      : AppIcons.table;
  @override
  bool get filterable => true;
  @override
  String get key => 'tbl:${connection!.config.id}:${table.key}';

  @override
  Future<List<NavNode>> load() async => [
    TablePartNode(connection!, table, TablePart.columns),
    if (!table.isView) TablePartNode(connection!, table, TablePart.keys),
    if (!table.isView) TablePartNode(connection!, table, TablePart.checks),
    if (!table.isView) TablePartNode(connection!, table, TablePart.foreignKeys),
    if (!table.isView) TablePartNode(connection!, table, TablePart.references),
    if (!table.isView) TablePartNode(connection!, table, TablePart.indexes),
  ];
}

enum TablePart {
  columns('Colonne', AppIcons.column),
  keys('Chiavi', AppIcons.key),
  checks('Vincoli CHECK', AppIcons.check),
  foreignKeys('Chiavi esterne', AppIcons.link),
  references('Riferimenti', AppIcons.incoming),
  indexes('Indici', AppIcons.sort);

  const TablePart(this.label, this.icon);
  final String label;
  final IconData icon;
}

class TablePartNode extends NavNode {
  TablePartNode(DbConnection super.connection, this.table, this.part);
  final DbTable table;
  final TablePart part;

  @override
  String get label => part.label;
  @override
  IconData get icon => AppIcons.folder;
  @override
  String get key => 'part:${connection!.config.id}:${table.key}:${part.name}';

  @override
  Future<List<NavNode>> load() async {
    final md = connection!.metadata!;
    switch (part) {
      case TablePart.columns:
        final pk = table.isView ? null : await md.primaryKey(table);
        final cols = await md.columns(table);
        return [
          for (final c in cols)
            LeafNode(
              connection!,
              c.name,
              detail: '${c.fullType}${c.nullable ? '' : ' NOT NULL'}',
              icon: pk?.columns.contains(c.name) ?? false ? AppIcons.key : AppIcons.column,
              isKey: pk?.columns.contains(c.name) ?? false,
              id: '${table.key}:${c.name}',
            ),
        ];
      case TablePart.keys:
        final t = await _definition();
        return [
          if (t.primaryKey != null) ConstraintNode(connection!, table, t.primaryKey!),
          for (final u in t.uniques) ConstraintNode(connection!, table, u),
        ];
      case TablePart.checks:
        final t = await _definition();
        return [for (final c in t.checks) ConstraintNode(connection!, table, c)];
      case TablePart.foreignKeys:
        final t = await _definition();
        return [for (final f in t.foreignKeys) ConstraintNode(connection!, table, f)];
      case TablePart.references:
        final refs = await md.referencedBy(table);
        return [
          for (final f in refs)
            ConstraintNode(
              connection!,
              DbTable(catalog: f.fkCatalog, schema: f.fkSchema, name: f.fkTable, type: 'TABLE'),
              ForeignKeyDef.fromDb(f),
              referencing: true,
            ),
        ];
      case TablePart.indexes:
        final t = await _definition();
        return [for (final i in t.indexes) ConstraintNode(connection!, table, i)];
    }
  }

  /// The table with constraints and index attributes from the DBMS catalog
  /// (the ODBC metadata when the catalog cannot be read).
  Future<TableDef> _definition() async {
    final cat = DesignCatalog.of(connection!);
    if (cat != null) return cat.loadTable(table);
    return TableDef.fromDetails(await connection!.metadata!.tableDetails(table));
  }
}

/// A key, constraint or index of [table] ([definition] is a
/// [PrimaryKeyDef], [UniqueDef], [CheckDef], [ForeignKeyDef] or [IndexDef]).
/// [referencing]: a foreign key of [table] that references the table the
/// node is listed under ("Riferimenti").
class ConstraintNode extends NavNode {
  ConstraintNode(DbConnection super.connection, this.table, this.definition, {this.referencing = false});
  final DbTable table;
  final Object definition;
  final bool referencing;

  String? get name => switch (definition) {
    PrimaryKeyDef p => p.name,
    UniqueDef u => u.name,
    CheckDef c => c.name,
    ForeignKeyDef f => f.name,
    IndexDef i => i.name,
    _ => null,
  };

  ConstraintState? get state => switch (definition) {
    PrimaryKeyDef p => p.state,
    UniqueDef u => u.state,
    CheckDef c => c.state,
    ForeignKeyDef f => f.state,
    _ => null,
  };

  bool get enabled => definition is IndexDef ? (definition as IndexDef).enabled : (state?.enabled ?? true);
  bool get validated => state?.validated ?? true;

  bool get isKey => definition is PrimaryKeyDef;

  @override
  String get label => switch (definition) {
    PrimaryKeyDef p => p.name ?? 'PRIMARY KEY',
    UniqueDef u => u.name ?? 'UNIQUE',
    CheckDef c => c.name ?? 'CHECK',
    ForeignKeyDef f => referencing ? table.name : (f.name ?? '${table.name}_${f.refTable}_fk'),
    IndexDef i => i.name,
    _ => '',
  };

  @override
  String? get detail {
    final base = switch (definition) {
      PrimaryKeyDef p => p.columns.join(', '),
      UniqueDef u => 'UNIQUE (${u.columns.join(', ')})',
      CheckDef c => c.expression,
      ForeignKeyDef f when referencing => '${f.name == null ? '' : '${f.name} '}(${f.columns.join(', ')})',
      ForeignKeyDef f => '(${f.columns.join(', ')}) → ${f.refTable}(${f.refColumns.join(', ')})',
      IndexDef i => '${i.unique ? 'UNIQUE ' : ''}(${i.columns.map((c) => i.isDescending(c) ? '$c DESC' : c).join(', ')})',
      _ => '',
    };
    final marks = [if (!enabled) 'disabilitato', if (enabled && !validated) 'non validato'];
    return marks.isEmpty ? base : '$base · ${marks.join(', ')}';
  }

  @override
  IconData get icon => switch (definition) {
    PrimaryKeyDef _ => AppIcons.key,
    UniqueDef _ => AppIcons.key,
    CheckDef _ => AppIcons.check,
    ForeignKeyDef _ => referencing ? AppIcons.incoming : AppIcons.link,
    _ => AppIcons.sort,
  };

  @override
  bool get expandable => false;
  @override
  String get key => 'con:${connection!.config.id}:${table.key}:${definition.runtimeType}:${referencing ? 'ref:' : ''}$label';
  @override
  Future<List<NavNode>> load() async => [];
}

class ProcedureNode extends NavNode {
  ProcedureNode(DbConnection super.connection, this.procedure);
  final DbProcedure procedure;

  @override
  String get label => procedure.cleanName;
  @override
  String? get detail => procedure.type == 2 ? 'funzione' : null;
  @override
  IconData get icon => procedure.type == 2 ? AppIcons.function : AppIcons.procedure;
  @override
  bool get expandable => false;
  @override
  bool get filterable => true;
  @override
  String get key => 'proc:${connection!.config.id}:${procedure.key}';
  @override
  Future<List<NavNode>> load() async => [];
}

class LeafNode extends NavNode {
  LeafNode(
    DbConnection super.connection,
    this.name, {
    String? detail,
    required IconData icon,
    this.isKey = false,
    required this.id,
  })
    // ignore: prefer_initializing_formals
    : _detail = detail,
       // ignore: prefer_initializing_formals
       _icon = icon;
  final String name;
  final String? _detail;
  final IconData _icon;
  /// Primary key column or constraint (drawn with the key color).
  final bool isKey;
  final String id;

  @override
  String get label => name;
  @override
  String? get detail => _detail;
  @override
  IconData get icon => _icon;
  @override
  bool get expandable => false;
  @override
  String get key => 'leaf:${connection!.config.id}:$id';
  @override
  Future<List<NavNode>> load() async => [];
}

/// Group connection nodes by their folder.
List<NavNode> buildRoots(List<DbConnection> conns, Map<String, NavNode> cache) {
  final roots = <NavNode>[];
  final folders = <String, List<NavNode>>{};
  for (final c in conns) {
    final key = 'conn:${c.config.id}';
    final node = cache.putIfAbsent(key, () => ConnectionNode(c));
    final f = c.config.folder.trim();
    if (f.isEmpty) {
      roots.add(node);
    } else {
      folders.putIfAbsent(f, () => []).add(node);
    }
  }
  final folderNodes = <NavNode>[];
  for (final e in folders.entries) {
    final key = 'folder:${e.key}';
    final existing = cache[key] as FolderNode?;
    final node = FolderNode(e.key, e.value)..expanded = existing?.expanded ?? true;
    node.children = e.value;
    cache[key] = node;
    folderNodes.add(node);
  }
  folderNodes.sort((a, b) => a.label.compareTo(b.label));
  return [...folderNodes, ...roots];
}

/// Loaded nodes under the connection node [root] to reload after the schema
/// changes [scopes]: the connection itself, the catalogs whose schemas
/// changed, the object folders whose objects changed.
List<NavNode> nodesForSchemaChanges(NavNode root, List<SchemaScope> scopes) {
  if (scopes.isEmpty) return const [];
  if (scopes.any((s) => s.level == SchemaLevel.connection)) return [root];
  final catalogs = scopes.where((s) => s.level == SchemaLevel.catalog).toList();
  final objects = scopes.where((s) => s.level.index >= SchemaLevel.schema.index).toList();
  final out = <NavNode>[];
  var catalogNodes = false;
  void walk(NavNode n) {
    for (final ch in n.children ?? const <NavNode>[]) {
      final hit = switch (ch) {
        CatalogNode c => catalogs.any((s) => s.covers(c.catalog, null)),
        ObjectFolderNode f => objects.any((s) => s.covers(f.catalog, f.schema)),
        _ => false,
      };
      if (ch is CatalogNode) catalogNodes = true;
      if (hit && ch.children != null) {
        out.add(ch);
      } else {
        walk(ch);
      }
    }
  }

  walk(root);
  // Schemas listed right under the connection (no catalogs).
  if (catalogs.isNotEmpty && !catalogNodes) return [root];
  return out;
}
