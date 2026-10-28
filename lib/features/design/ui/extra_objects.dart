// Actions and navigator menus of the DBMS specific objects (extensions,
// enum types, domains, policies, exclusion constraints, synonyms, packages,
// events, warehouses, stages, file formats).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../model/db_objects.dart';
import '../../../state/app_state.dart';
import '../../../state/db_connection.dart';
import '../../../ui/actions.dart';
import '../../../ui/navigator/nav_nodes.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_builder.dart';
import '../../schema/ddl_execution.dart';
import '../catalog/design_catalog.dart';
import '../catalog/extras.dart';
import '../ddl/extra_ddl.dart';
import '../ddl/object_ddl.dart';
import '../ddl_script.dart';
import '../model/extra_defs.dart';
import '../model/nosql_defs.dart';
import '../model/security_defs.dart';
import 'extra_dialogs.dart';
import 'nosql_dialogs.dart';
import 'object_dialogs.dart';
import 'package_editor.dart';

/// What a script on objects of [kind] changes.
SchemaScope extraScope(ExtraKind kind, {String? catalog, String? schema, DbTable? table}) => switch (kind.level) {
  // [catalog] with one session per database (PostgreSQL extensions).
  ExtraLevel.connection => SchemaScope.schema(catalog, null),
  ExtraLevel.schema => SchemaScope.schema(catalog, schema),
  ExtraLevel.table => SchemaScope.object(table!.catalog, table.schema, table.name),
};

Future<bool> _run(
  BuildContext context,
  DbConnection dc,
  List<String> statements,
  String title,
  SchemaScope scope, {
  String? catalog,
  bool transactional = true,
}) {
  if (statements.isEmpty) return Future.value(false);
  return showDdlScriptDialog(
    context,
    dc: dc,
    title: title,
    script: DdlScript(
      statements,
      scope: scope,
      catalog: ObjectDdl(dc.dialect).scriptCatalog(catalog),
      transactional: transactional,
    ),
  );
}

Future<T> _orElse<T>(Future<T> f, T fallback) async {
  try {
    return await f;
  } catch (_) {
    return fallback;
  }
}

Future<List<String>> _roles(DesignCatalog cat) async => [
  for (final p in await _orElse(cat.principals(), const <PrincipalDef>[]))
    if (!p.builtIn) p.name,
];

/// Lets the user pick a table or view of [catalog].[schema].
Future<String?> _pickObject(BuildContext context, DbConnection dc, String? catalog, String? schema) =>
    showListPicker<DbTable>(
      context,
      title: 'Oggetto del sinonimo',
      load: () => dc.metadata!.tables(catalog, schema),
      label: (t) => t.name,
      detail: (t) => t.type,
      icon: (t) => t.isView ? AppIcons.erDiagram : AppIcons.table,
      empty: 'Nessun oggetto in ${[?catalog, ?schema].join('.')}',
    ).then((t) => t?.name);

// ---------------------------------------------------------------------------
// Create / edit / drop
// ---------------------------------------------------------------------------

/// Creates an object of [kind] in [catalog].[schema] (or on [table]).
Future<bool> createExtra(
  BuildContext context,
  DbConnection dc,
  ExtraKind kind, {
  String? catalog,
  String? schema,
  DbTable? table,
}) async {
  if (!await ensureConnected(context, dc) || !context.mounted) return false;
  final cat = DesignCatalog.of(dc)!;
  final d = dc.dialect;
  final ddl = ExtraDdl(d);
  final scope = extraScope(kind, catalog: catalog, schema: schema, table: table);
  final title = 'Crea ${kind.singular}';
  switch (kind) {
    case ExtraKind.extensions:
      final available = await _orElse(readAvailableExtensions(cat.queriesFor(catalog)), const <ExtensionDef>[]);
      final schemas = await _orElse(listSchemas(dc, catalog), const <String>[]);
      if (!context.mounted) return false;
      final r = await showExtensionDialog(context, dialect: d, available: available, schemas: schemas);
      if (r == null || !context.mounted) return false;
      return _run(context, dc, ddl.createExtension(r.$1, cascade: r.$2), '$title ${r.$1.name}', scope);
    case ExtraKind.enumTypes:
      final t = await showEnumDialog(context, dialect: d, catalog: catalog, schema: schema);
      if (t == null || !context.mounted) return false;
      return _run(context, dc, ddl.createEnum(t), '$title ${t.name}', scope);
    case ExtraKind.domains:
      final t = await showDomainDialog(context, dialect: d, catalog: catalog, schema: schema);
      if (t == null || !context.mounted) return false;
      return _run(context, dc, ddl.createDomain(t), '$title ${t.name}', scope);
    case ExtraKind.policies:
      final roles = await _roles(cat);
      final rls = await _orElse(cat.rowSecurity(table!), const RowSecurity(enabled: true));
      if (!context.mounted) return false;
      final r = await showPolicyDialog(
        context,
        dialect: d,
        table: table.name,
        catalog: table.catalog,
        schema: table.schema,
        roles: roles,
        rowSecurityOn: rls.enabled,
      );
      if (r == null || !context.mounted) return false;
      return _run(
        context,
        dc,
        [
          ...ddl.createPolicy(r.$1),
          if (r.$2)
            ...ddl.setRowSecurity(
              table.catalog,
              table.schema,
              table.name,
              rls,
              RowSecurity(enabled: true, forced: rls.forced),
            ),
        ],
        '$title ${r.$1.name}',
        scope,
      );
    case ExtraKind.exclusions:
      final cols = await _orElse(dc.metadata!.columns(table!), const <DbColumn>[]);
      if (!context.mounted) return false;
      final x = await showExclusionDialog(
        context,
        dialect: d,
        table: table.name,
        catalog: table.catalog,
        schema: table.schema,
        columns: [for (final c in cols) d.quoteIdent(c.name)],
      );
      if (x == null || !context.mounted) return false;
      return _run(context, dc, ddl.addExclusion(x), '$title ${x.name}', scope);
    case ExtraKind.synonyms:
      final s = await showSynonymDialog(
        context,
        dialect: d,
        catalog: catalog,
        schema: schema,
        pickTarget: (c, s) => _pickObject(context, dc, c, s),
      );
      if (s == null || !context.mounted) return false;
      return _run(context, dc, ddl.createSynonym(s), '$title ${s.name}', scope, catalog: catalog);
    case ExtraKind.packages:
      final name = await promptText(context, 'Nuovo package', label: 'Nome', initial: 'NUOVO_PACKAGE');
      if (name == null || name.trim().isEmpty || !context.mounted) return false;
      AppScope.read(context).openFeatureTab(PackageEditorTab(dc, schema: schema, name: name.trim().toUpperCase()));
      return true;
    case ExtraKind.events:
      final on = await readEventScheduler(cat.queries);
      if (!context.mounted) return false;
      final e = await showEventDialog(context, dialect: d, catalog: catalog ?? schema, schedulerOn: on);
      if (e == null || !context.mounted) return false;
      return _run(context, dc, ddl.createEvent(e), '$title ${e.name}', scope);
    case ExtraKind.warehouses:
      final w = await showWarehouseDialog(context, dialect: d);
      if (w == null || !context.mounted) return false;
      return _run(context, dc, ddl.createWarehouse(w), '$title ${w.name}', scope);
    case ExtraKind.stages:
      final formats = await _orElse(
        cat.extras(ExtraKind.fileFormats, catalog: catalog, schema: schema),
        const <ExtraObjectDef>[],
      );
      if (!context.mounted) return false;
      final s = await showStageDialog(
        context,
        dialect: d,
        catalog: catalog,
        schema: schema,
        fileFormats: [for (final f in formats) f.name],
      );
      if (s == null || !context.mounted) return false;
      return _run(context, dc, ddl.createStage(s), '$title ${s.name}', scope);
    case ExtraKind.userTypes:
      final u = await showUdtDialog(context, dialect: d, keyspace: catalog ?? schema ?? '');
      if (u == null || !context.mounted) return false;
      return _run(context, dc, ddl.create(u), '$title ${u.name}', scope);
    case ExtraKind.fileFormats:
      final f = await showFileFormatDialog(context, dialect: d, catalog: catalog, schema: schema);
      if (f == null || !context.mounted) return false;
      return _run(context, dc, ddl.createFileFormat(f), '$title ${f.name}', scope);
  }
}

/// Edits [o] (an object of [kind], of [table] for the table level).
Future<bool> editExtra(
  BuildContext context,
  DbConnection dc,
  ExtraKind kind,
  ExtraObjectDef o, {
  DbTable? table,
}) async {
  if (!await ensureConnected(context, dc) || !context.mounted) return false;
  final cat = DesignCatalog.of(dc)!;
  final d = dc.dialect;
  final ddl = ExtraDdl(d);
  final scope = extraScope(kind, catalog: o.catalog, schema: o.schema, table: table);
  final title = '${kind.label} · ${o.name}';
  ExtraObjectDef? to;
  var transactional = true;
  switch (o) {
    case ExtensionDef e:
      final schemas = await _orElse(listSchemas(dc, e.catalog), const <String>[]);
      if (!context.mounted) return false;
      to = (await showExtensionDialog(context, dialect: d, initial: e, schemas: schemas))?.$1;
    case EnumTypeDef t:
      to = await showEnumDialog(context, dialect: d, catalog: t.catalog, schema: t.schema, initial: t);
      // ADD VALUE cannot run in a transaction block before PostgreSQL 12.
      transactional = false;
    case DomainDef t:
      to = await showDomainDialog(context, dialect: d, catalog: t.catalog, schema: t.schema, initial: t);
    case PolicyDef p:
      final roles = await _roles(cat);
      final rls = await _orElse(cat.rowSecurity(table!), const RowSecurity(enabled: true));
      if (!context.mounted) return false;
      final r = await showPolicyDialog(
        context,
        dialect: d,
        table: p.table,
        catalog: p.catalog,
        schema: p.schema,
        initial: p,
        roles: roles,
        rowSecurityOn: rls.enabled,
      );
      if (r == null || !context.mounted) return false;
      return _run(
        context,
        dc,
        [
          ...ddl.alterPolicy(p, r.$1),
          if (r.$2)
            ...ddl.setRowSecurity(p.catalog, p.schema, p.table, rls, RowSecurity(enabled: true, forced: rls.forced)),
        ],
        title,
        scope,
      );
    case ExclusionDef x:
      final cols = await _orElse(dc.metadata!.columns(table!), const <DbColumn>[]);
      if (!context.mounted) return false;
      to = await showExclusionDialog(
        context,
        dialect: d,
        table: x.table,
        catalog: x.catalog,
        schema: x.schema,
        columns: [for (final c in cols) d.quoteIdent(c.name)],
        initial: x,
      );
    case SynonymDef s:
      to = await showSynonymDialog(
        context,
        dialect: d,
        catalog: s.catalog,
        schema: s.schema,
        initial: s,
        pickTarget: (c, sc) => _pickObject(context, dc, c, sc),
      );
    case PackageDef p:
      await openPackage(context, dc, p);
      return false;
    case EventDef e:
      final on = await readEventScheduler(cat.queries);
      if (!context.mounted) return false;
      to = await showEventDialog(context, dialect: d, catalog: e.catalog, initial: e, schedulerOn: on);
    case WarehouseDef w:
      to = await showWarehouseDialog(context, dialect: d, initial: w);
    case StageDef s:
      final formats = await _orElse(
        cat.extras(ExtraKind.fileFormats, catalog: s.catalog, schema: s.schema),
        const <ExtraObjectDef>[],
      );
      if (!context.mounted) return false;
      to = await showStageDialog(
        context,
        dialect: d,
        catalog: s.catalog,
        schema: s.schema,
        initial: s,
        fileFormats: [for (final f in formats) f.name],
      );
    case FileFormatDef f:
      to = await showFileFormatDialog(context, dialect: d, catalog: f.catalog, schema: f.schema, initial: f);
    case UdtDef u:
      to = await showUdtDialog(context, dialect: d, keyspace: u.keyspace, initial: u);
  }
  if (to == null || !context.mounted) return false;
  return _run(context, dc, ddl.alter(o, to), title, scope, catalog: o.catalog, transactional: transactional);
}

/// Opens the editor of package [p] (or the one already open).
Future<void> openPackage(BuildContext context, DbConnection dc, PackageDef p) async {
  final app = AppScope.read(context);
  for (final t in app.tabs) {
    if (t is PackageEditorTab && t.dc == dc && t.package?.name == p.name && t.schema == p.schema) {
      app.activate(t);
      return;
    }
  }
  PackageSource? src;
  final ok = await guarded(context, () async => src = await DesignCatalog.of(dc)!.packageSource(p));
  if (!ok || !context.mounted) return;
  app.openFeatureTab(PackageEditorTab(dc, package: p, source: src));
}

Future<bool> dropExtra(
  BuildContext context,
  DbConnection dc,
  ExtraKind kind,
  ExtraObjectDef o, {
  DbTable? table,
}) async {
  final ddl = ExtraDdl(dc.dialect);
  final chosen = await showDropDialog(
    context,
    title: 'Elimina ${kind.singular}',
    objectLabel: '${kind.singular} ${o.name}',
    options: [if (ddl.canCascade(o)) const DropOption('cascade', 'Elimina anche gli oggetti che lo usano (CASCADE)')],
  );
  if (chosen == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    ddl.drop(o, cascade: chosen.contains('cascade')),
    'Elimina ${o.name}',
    extraScope(kind, catalog: o.catalog, schema: o.schema, table: table),
    catalog: o.catalog,
  );
}

/// The CREATE of [o] in a new SQL editor.
Future<void> extraDdlInEditor(BuildContext context, DbConnection dc, ExtraObjectDef o) async {
  final app = AppScope.read(context);
  List<String> statements;
  if (o is PackageDef) {
    PackageSource? src;
    await guarded(context, () async => src = await DesignCatalog.of(dc)!.packageSource(o));
    final s = src;
    if (s == null) return;
    statements = [s.spec, if (s.body.isNotEmpty) s.body];
    await app.sqlEditorWith(dc, statements.join('\n/\n\n'), catalog: o.catalog);
    return;
  }
  statements = ExtraDdl(dc.dialect).create(o);
  await app.sqlEditorWith(dc, DdlBuilder(dc.dialect).render(statements), catalog: o.catalog);
}

// ---------------------------------------------------------------------------
// Navigator menus
// ---------------------------------------------------------------------------

MenuEntry<void> _item(String label, VoidCallback? action, {bool destructive = false}) =>
    MenuEntry(label, onSelected: action, enabled: action != null, destructive: destructive);

/// Menu of a folder of DBMS specific objects.
List<MenuEntry<void>> extraFolderMenu(BuildContext context, ExtraFolderNode f) {
  final dc = f.connection!;
  final ro = dc.config.readOnly;
  return [
    _item(
      f.kind.newLabel,
      ro ? null : () => createExtra(context, dc, f.kind, catalog: f.catalog, schema: f.schema, table: f.table),
    ),
    if (f.kind == ExtraKind.policies)
      _item('Sicurezza a livello di riga…', ro ? null : () => editRowSecurity(context, dc, f.table!)),
    const MenuEntry.divider(),
  ];
}

/// Menu of a DBMS specific object.
List<MenuEntry<void>> extraObjectMenu(BuildContext context, ExtraObjectNode n) {
  final dc = n.connection!;
  final ro = dc.config.readOnly;
  final o = n.object;
  final ddl = ExtraDdl(dc.dialect);
  final scope = extraScope(n.kind, catalog: o.catalog, schema: o.schema, table: n.table);
  return [
    _item(o is PackageDef ? 'Modifica sorgente' : 'Modifica…', () => editExtra(context, dc, n.kind, o, table: n.table)),
    if (o is ExtensionDef && o.updatable)
      _item(
        'Aggiorna alla versione ${o.defaultVersion}',
        ro ? null : () => _run(context, dc, ddl.updateExtension(o), 'Aggiorna ${o.name}', scope),
      ),
    if (o is WarehouseDef)
      _item(
        o.suspended ? 'Riprendi' : 'Sospendi',
        ro ? null : () => _run(context, dc, ddl.suspendWarehouse(o, suspend: !o.suspended), o.name, scope),
      ),
    if (o is PolicyDef && n.table != null)
      _item('Sicurezza a livello di riga…', ro ? null : () => editRowSecurity(context, dc, n.table!)),
    _item('Genera DDL', () => extraDdlInEditor(context, dc, o)),
    _item('Copia nome', () => Clipboard.setData(ClipboardData(text: o.name))),
    const MenuEntry.divider(),
    _item('Elimina…', ro ? null : () => dropExtra(context, dc, n.kind, o, table: n.table), destructive: true),
  ];
}

/// Turns row level security of [table] on or off.
Future<bool> editRowSecurity(BuildContext context, DbConnection dc, DbTable table) async {
  final cat = DesignCatalog.of(dc);
  if (cat == null) return false;
  final now = await _orElse(cat.rowSecurity(table), const RowSecurity());
  if (!context.mounted) return false;
  final to = await showRowSecurityDialog(
    context,
    dialect: dc.dialect,
    table: table.name,
    catalog: table.catalog,
    schema: table.schema,
    initial: now,
  );
  if (to == null || !context.mounted) return false;
  return _run(
    context,
    dc,
    ExtraDdl(dc.dialect).setRowSecurity(table.catalog, table.schema, table.name, now, to),
    'Sicurezza di ${table.name}',
    SchemaScope.object(table.catalog, table.schema, table.name),
  );
}
