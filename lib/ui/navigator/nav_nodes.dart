import 'package:flutter/material.dart';

import '../../features/design/capabilities.dart';
import '../../features/design/catalog/design_catalog.dart';
import '../../features/design/ddl/security/security_ddl.dart';
import '../../features/design/model/extra_defs.dart';
import '../../features/design/model/object_defs.dart';
import '../../features/design/model/security_defs.dart';
import '../../features/schema/schema_model.dart';
import '../../model/db_objects.dart';
import '../../services/sql_dialect.dart';
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
    final security = [
      for (final k in extraKinds(dc, ExtraLevel.connection)) ExtraFolderNode(dc, k),
      if (hasSecurity(dc)) SecurityNode(dc, server: dc.dialect.family == DbFamily.sqlServer),
    ];
    if (md.supportsCatalogs) {
      final cats = await md.catalogs();
      if (cats.isNotEmpty) {
        return [
          for (final c in cats) CatalogNode(dc, c, current: c == (dc.defaultCatalog ?? md.currentCatalog)),
          ...security,
        ];
      }
    }
    if (md.supportsSchemas) {
      final schemas = await listSchemas(dc, null);
      if (schemas.isNotEmpty) return [for (final s in schemas) SchemaNode(dc, null, s), ...security];
    }
    return [...objectFolders(dc, null, null), ...security];
  }
}

/// Whether [dc] has users and roles to manage.
bool hasSecurity(DbConnection dc) => dc.dialect.isSql && SecurityDdl.forFamily(dc.dialect).kinds.isNotEmpty;

List<NavNode> objectFolders(DbConnection dc, String? catalog, String? schema) => [
  ObjectFolderNode(dc, catalog, schema, ObjectKind.tables),
  ObjectFolderNode(dc, catalog, schema, ObjectKind.views),
  ObjectFolderNode(dc, catalog, schema, ObjectKind.system),
  if (dc.metadata?.supportsProcedures ?? true) ObjectFolderNode(dc, catalog, schema, ObjectKind.procedures),
  if (dc.dialect.isSql && DesignCapabilities.of(dc.dialect).has(DesignFeature.sequences))
    ObjectFolderNode(dc, catalog, schema, ObjectKind.sequences),
  for (final k in extraKinds(dc, ExtraLevel.schema)) ExtraFolderNode(dc, k, catalog: catalog, schema: schema),
];

/// DBMS specific object kinds of [dc] listed at [level].
List<ExtraKind> extraKinds(DbConnection dc, ExtraLevel level) {
  if (!dc.dialect.isSql) return const [];
  final caps = DesignCapabilities.of(dc.dialect);
  return [
    for (final k in ExtraKind.values)
      if (k.level == level && caps.has(extraFeature(k))) k,
  ];
}

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
      // SQL Server users and roles belong to a database.
      final security = [
        if (connection!.dialect.family == DbFamily.sqlServer && hasSecurity(connection!))
          SecurityNode(connection!, catalog: catalog),
      ];
      if (schemas.isNotEmpty) return [for (final s in schemas) SchemaNode(connection!, catalog, s), ...security];
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
  procedures('Procedure e funzioni', AppIcons.function),
  sequences('Sequenze', AppIcons.number);

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
    if (kind == ObjectKind.sequences) {
      final cat = DesignCatalog.of(connection!);
      final seqs = cat == null ? const <SequenceDef>[] : await cat.sequences(catalog, schema);
      return [for (final s in seqs) SequenceNode(connection!, s)];
    }
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
        case ObjectKind.procedures || ObjectKind.sequences:
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
    if (connection!.dialect.isSql && DesignCapabilities.of(connection!.dialect).has(DesignFeature.triggers))
      TablePartNode(connection!, table, TablePart.triggers),
    if (!table.isView)
      for (final k in extraKinds(connection!, ExtraLevel.table)) ExtraFolderNode(connection!, k, table: table),
  ];
}

enum TablePart {
  columns('Colonne', AppIcons.column),
  keys('Chiavi', AppIcons.key),
  checks('Vincoli CHECK', AppIcons.check),
  foreignKeys('Chiavi esterne', AppIcons.link),
  references('Riferimenti', AppIcons.incoming),
  indexes('Indici', AppIcons.sort),
  triggers('Trigger', AppIcons.bolt);

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
      case TablePart.triggers:
        final cat = DesignCatalog.of(connection!);
        final triggers = cat == null ? const <TriggerDef>[] : await cat.triggers(table);
        return [for (final t in triggers) TriggerNode(connection!, table, t)];
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

class SequenceNode extends NavNode {
  SequenceNode(DbConnection super.connection, this.sequence);
  final SequenceDef sequence;

  @override
  String get label => sequence.name;
  @override
  String? get detail => sequence.currentValue == null ? null : 'valore ${sequence.currentValue}';
  @override
  IconData get icon => AppIcons.number;
  @override
  bool get expandable => false;
  @override
  bool get filterable => true;
  @override
  String get key => 'seq:${connection!.config.id}:${sequence.catalog ?? ''}:${sequence.schema ?? ''}:${sequence.name}';
  @override
  Future<List<NavNode>> load() async => [];
}

class TriggerNode extends NavNode {
  TriggerNode(DbConnection super.connection, this.table, this.trigger);
  final DbTable table;
  final TriggerDef trigger;

  @override
  String get label => trigger.name;
  @override
  String? get detail => '${trigger.summary}${trigger.enabled ? '' : ' · disabilitato'}';
  @override
  IconData get icon => AppIcons.bolt;
  @override
  bool get expandable => false;
  @override
  String get key => 'trg:${connection!.config.id}:${table.key}:${trigger.name}';
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

/// "Sicurezza": users, roles and logins. For SQL Server the folder under
/// the connection ([server]) lists the logins, the one under each database
/// its users and roles.
class SecurityNode extends NavNode {
  SecurityNode(DbConnection super.connection, {this.catalog, this.server = false});
  final String? catalog;
  final bool server;

  @override
  String get label => 'Sicurezza';
  @override
  IconData get icon => AppIcons.security;
  @override
  String get key => 'sec:${connection!.config.id}:${catalog ?? ''}:$server';

  List<PrincipalKind> get kinds {
    final all = SecurityDdl.forFamily(connection!.dialect).kinds;
    if (connection!.dialect.family != DbFamily.sqlServer) return all;
    return [
      for (final k in all)
        if ((k == PrincipalKind.login) == server) k,
    ];
  }

  @override
  Future<List<NavNode>> load() async => [for (final k in kinds) PrincipalFolderNode(connection!, k, catalog: catalog)];
}

/// Plural label of a principal kind (navigator folders).
String principalKindPlural(PrincipalKind k) => switch (k) {
  PrincipalKind.user => 'Utenti',
  PrincipalKind.role => 'Ruoli',
  PrincipalKind.login => 'Login',
  PrincipalKind.group => 'Gruppi',
};

IconData principalIcon(PrincipalKind k) => switch (k) {
  PrincipalKind.user => AppIcons.user,
  PrincipalKind.role => AppIcons.role,
  PrincipalKind.login => AppIcons.login,
  PrincipalKind.group => AppIcons.group,
};

class PrincipalFolderNode extends NavNode {
  PrincipalFolderNode(DbConnection super.connection, this.kind, {this.catalog});
  final PrincipalKind kind;
  final String? catalog;

  @override
  String get label => principalKindPlural(kind);
  @override
  String? get detail => children == null ? null : '${children!.length}';
  @override
  IconData get icon => AppIcons.folder;
  @override
  String get key => 'principals:${connection!.config.id}:${catalog ?? ''}:${kind.name}';

  @override
  Future<List<NavNode>> load() async {
    final cat = DesignCatalog.of(connection!);
    if (cat == null) return const [];
    final all = await cat.principals(catalog: catalog);
    return [
      for (final p in all)
        if (p.kind == kind) PrincipalNode(connection!, p, catalog: catalog),
    ];
  }
}

class PrincipalNode extends NavNode {
  PrincipalNode(DbConnection super.connection, this.principal, {this.catalog});
  final PrincipalDef principal;
  final String? catalog;

  @override
  String get label => principal.display;
  @override
  String? get detail =>
      [if (principal.builtIn) 'di sistema', if (principal.locked) 'disabilitato'].join(' · ').nullIfEmpty;
  @override
  IconData get icon => principalIcon(principal.kind);
  @override
  bool get expandable => false;
  @override
  bool get filterable => true;
  @override
  String get key => 'principal:${connection!.config.id}:${catalog ?? ''}:${principal.key}';
  @override
  Future<List<NavNode>> load() async => [];
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

IconData extraIcon(ExtraKind k) => switch (k) {
  ExtraKind.extensions => AppIcons.extension,
  ExtraKind.enumTypes => AppIcons.category,
  ExtraKind.domains => AppIcons.shortText,
  ExtraKind.synonyms => AppIcons.link,
  ExtraKind.packages => AppIcons.archive,
  ExtraKind.events => AppIcons.timer,
  ExtraKind.warehouses => AppIcons.memory,
  ExtraKind.stages => AppIcons.upload,
  ExtraKind.fileFormats => AppIcons.document,
  ExtraKind.policies => AppIcons.security,
  ExtraKind.exclusions => AppIcons.block,
};

/// Folder of DBMS specific objects of [kind] (in a schema, at the
/// connection, or of [table]).
class ExtraFolderNode extends NavNode {
  ExtraFolderNode(DbConnection super.connection, this.kind, {this.catalog, this.schema, this.table});
  final ExtraKind kind;
  final String? catalog;
  final String? schema;
  final DbTable? table;

  String? get objectCatalog => table?.catalog ?? catalog;
  String? get objectSchema => table?.schema ?? schema;

  @override
  String get label => kind.label;
  @override
  String? get detail => children == null ? null : '${children!.length}';
  @override
  IconData get icon => AppIcons.folder;
  @override
  String get key =>
      'extra:${connection!.config.id}:${kind.name}:${catalog ?? ''}:${schema ?? ''}:${table?.key ?? ''}';

  @override
  Future<List<NavNode>> load() async {
    final cat = DesignCatalog.of(connection!);
    if (cat == null) return const [];
    final objects = await cat.extras(kind, catalog: catalog, schema: schema, table: table);
    return [for (final o in objects) ExtraObjectNode(connection!, kind, o, table: table)];
  }
}

class ExtraObjectNode extends NavNode {
  ExtraObjectNode(DbConnection super.connection, this.kind, this.object, {this.table});
  final ExtraKind kind;
  final ExtraObjectDef object;
  final DbTable? table;

  @override
  String get label => object.name;
  @override
  String? get detail {
    final d = object.detail;
    return d == null || d.isEmpty ? null : d;
  }

  @override
  IconData get icon => extraIcon(kind);
  @override
  bool get expandable => false;
  @override
  bool get filterable => true;
  @override
  String get key =>
      'xobj:${connection!.config.id}:${kind.name}:${object.catalog ?? ''}:${object.schema ?? ''}:'
      '${table?.key ?? ''}:${object.name}';
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
  final objects = scopes.where((s) => s.level == SchemaLevel.schema || s.level == SchemaLevel.object).toList();
  final security = scopes.where((s) => s.level == SchemaLevel.security).toList();
  final out = <NavNode>[];
  var catalogNodes = false;
  void walk(NavNode n) {
    for (final ch in n.children ?? const <NavNode>[]) {
      final hit = switch (ch) {
        CatalogNode c => catalogs.any((s) => s.covers(c.catalog, null)),
        ObjectFolderNode f => objects.any((s) => s.covers(f.catalog, f.schema)),
        ExtraFolderNode f when f.kind.level == ExtraLevel.connection => objects.any(
          (s) => s.catalog == null && s.schema == null,
        ),
        ExtraFolderNode f => objects.any(
          (s) => f.table == null
              ? s.covers(f.catalog, f.schema)
              : s.coversObject(f.objectCatalog, f.objectSchema, f.table!.name),
        ),
        SecurityNode f => security.any((s) => s.catalog == null || f.catalog == null || s.catalog == f.catalog),
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
