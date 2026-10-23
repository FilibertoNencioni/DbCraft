// Privilege pages of the security manager: a grid of objects × privileges
// (per object type, database and schema) and the list of system
// privileges. Both edit a PrincipalDesign; nothing runs until Salva.

import 'package:flutter/material.dart';

import '../../../services/sql_dialect.dart';
import '../../../state/db_connection.dart';
import '../../../ui/navigator/nav_nodes.dart' show listSchemas;
import '../../../ui/widgets/common.dart';
import '../catalog/design_catalog.dart';
import '../ddl/security/security_ddl.dart';
import '../model/security_defs.dart';
import '../security_design.dart';

/// Objects of type [target] in [catalog].[schema] as privilege templates
/// (GrantDef with an empty privilege).
Future<List<GrantDef>> grantObjects(DbConnection dc, GrantTarget target, {String? catalog, String? schema}) async {
  final md = dc.metadata!;
  final ddl = SecurityDdl.forFamily(dc.dialect);
  final cat = ddl.catalogInGrants ? catalog : null;
  GrantDef make({String? catalog, String? schema, String? object, bool function = false}) =>
      GrantDef(privilege: '', target: target, catalog: catalog, schema: schema, object: object, isFunction: function);
  switch (target) {
    case GrantTarget.database:
      if (dc.dialect.family == DbFamily.db2) return [make()];
      List<String> names;
      if (dc.dialect.family == DbFamily.postgres) {
        try {
          names = [for (final d in await DesignCatalog.of(dc)!.databases()) d.name];
        } catch (_) {
          names = await md.catalogs();
        }
      } else {
        names = await md.catalogs();
      }
      return [for (final n in names) make(catalog: n)];
    case GrantTarget.schema:
      return [for (final s in await listSchemas(dc, catalog)) make(catalog: cat, schema: s)];
    case GrantTarget.table || GrantTarget.view:
      final tables = await md.tables(catalog, schema);
      return [
        for (final t in tables)
          if (target == GrantTarget.view
              ? t.isView
              : (t.type.toUpperCase() == 'TABLE' || t.type.toUpperCase() == 'BASE TABLE'))
            make(catalog: cat, schema: t.schema, object: t.name),
      ];
    case GrantTarget.sequence:
      final seqs = await DesignCatalog.of(dc)!.sequences(catalog, schema);
      return [for (final s in seqs) make(catalog: cat, schema: s.schema, object: s.name)];
    case GrantTarget.routine:
      final procs = await md.procedures(catalog, schema);
      return [for (final p in procs) make(catalog: cat, schema: p.schema, object: p.cleanName, function: p.type == 2)];
    case GrantTarget.system:
      return const [];
  }
}

String _plural(GrantTarget t) => switch (t) {
  GrantTarget.table => 'Tabelle',
  GrantTarget.view => 'Viste',
  GrantTarget.sequence => 'Sequenze',
  GrantTarget.routine => 'Procedure e funzioni',
  GrantTarget.schema => 'Schemi',
  GrantTarget.database => 'Database',
  GrantTarget.system => 'Sistema',
};

/// Privileges on objects of a principal.
class GrantsPage extends StatefulWidget {
  const GrantsPage({super.key, required this.dc, required this.design, this.catalog, this.enabled = true});
  final DbConnection dc;
  final PrincipalDesign design;

  /// SQL Server database of the principal.
  final String? catalog;
  final bool enabled;

  @override
  State<GrantsPage> createState() => _GrantsPageState();
}

class _GrantsPageState extends State<GrantsPage> {
  late final SecurityDdl _ddl = SecurityDdl.forFamily(widget.dc.dialect);
  late GrantTarget _target = _targets.first;
  String? _catalog;
  String? _schema;
  List<String> _catalogs = const [];
  List<String> _schemas = const [];
  Future<List<GrantDef>>? _objects;
  final _filter = TextEditingController();
  bool _onlyGranted = false;

  List<GrantTarget> get _targets => _ddl.objectTargets(widget.design.working.kind);
  PrincipalDesign get d => widget.design;

  @override
  void initState() {
    super.initState();
    final md = widget.dc.metadata!;
    _catalog = md.supportsCatalogs ? (widget.catalog ?? widget.dc.defaultCatalog ?? md.currentCatalog) : null;
    _init();
  }

  Future<void> _init() async {
    final md = widget.dc.metadata!;
    try {
      if (_ddl.catalogInGrants && widget.catalog == null && md.supportsCatalogs) {
        final cats = await md.catalogs();
        if (mounted) setState(() => _catalogs = cats);
      }
      await _loadSchemas();
    } catch (_) {}
    _reload();
  }

  Future<void> _loadSchemas() async {
    final md = widget.dc.metadata!;
    if (!md.supportsSchemas) return;
    final schemas = await listSchemas(widget.dc, _catalog);
    if (!mounted) return;
    setState(() {
      _schemas = schemas;
      if (_schema == null || !schemas.contains(_schema)) {
        const usual = ['public', 'dbo', 'PUBLIC'];
        _schema = schemas.where(usual.contains).firstOrNull ?? schemas.firstOrNull;
      }
    });
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _objects = grantObjects(widget.dc, _target, catalog: _catalog, schema: _schema);
    });
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  bool get _scoped => _target != GrantTarget.database && _target != GrantTarget.schema;

  @override
  Widget build(BuildContext context) {
    if (_targets.isEmpty) {
      return EmptyState(
        icon: AppIcons.security,
        title: 'Nessun permesso sugli oggetti',
        message: widget.dc.dialect.family == DbFamily.snowflake
            ? 'In Snowflake i privilegi si assegnano ai ruoli: aggiungi l\'utente a un ruolo.'
            : 'Questo principal riceve solo privilegi di sistema.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneBar(
          children: [
            PopUpButton<GrantTarget>(
              value: _target,
              small: true,
              items: [for (final t in _targets) (t, _plural(t), null)],
              onChanged: (t) {
                _target = t;
                _reload();
              },
            ),
            if (_catalogs.isNotEmpty && _target != GrantTarget.database) ...[
              const SizedBox(width: Gap.sm),
              PopUpButton<String?>(
                value: _catalog,
                small: true,
                tooltip: 'Database',
                items: [for (final c in _catalogs) (c, c, (AppIcons.database, DbColors.of(context).textSecondary))],
                onChanged: (c) async {
                  _catalog = c;
                  await _loadSchemas();
                  _reload();
                },
              ),
            ],
            if (_schemas.isNotEmpty && _scoped) ...[
              const SizedBox(width: Gap.sm),
              PopUpButton<String?>(
                value: _schema,
                small: true,
                tooltip: 'Schema',
                items: [for (final s in _schemas) (s, s, (AppIcons.schema, DbColors.of(context).textSecondary))],
                onChanged: (s) {
                  _schema = s;
                  _reload();
                },
              ),
            ],
            const SizedBox(width: Gap.sm),
            SearchField(controller: _filter, hint: 'Filtra', width: 180, onChanged: (_) => setState(() {})),
            const SizedBox(width: Gap.sm),
            CheckboxRow(
              small: true,
              value: _onlyGranted,
              label: 'Solo con permessi',
              onChanged: (v) => setState(() => _onlyGranted = v),
            ),
            const Spacer(),
            ToolButton(icon: AppIcons.refresh, tooltip: 'Ricarica gli oggetti', onPressed: _reload),
          ],
        ),
        Expanded(
          child: FutureBuilder<List<GrantDef>>(
            future: _objects,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const Center(child: Spinner());
              if (snap.hasError) return EmptyState.error(snap.error!);
              return ListenableBuilder(listenable: d, builder: (context, _) => _grid(context, snap.data!));
            },
          ),
        ),
      ],
    );
  }

  Widget _grid(BuildContext context, List<GrantDef> all) {
    final f = _filter.text.trim().toLowerCase();
    final objects = [
      for (final o in all)
        if ((f.isEmpty || o.objectLabel.toLowerCase().contains(f)) &&
            (!_onlyGranted || d.grants.any((g) => g.objectKey == o.objectKey)))
          o,
    ];
    if (objects.isEmpty) {
      return EmptyState(
        icon: AppIcons.security,
        title: all.isEmpty ? 'Nessun oggetto' : 'Nessun oggetto corrisponde',
        message: all.isEmpty ? 'Non ci sono ${_plural(_target).toLowerCase()} qui.' : 'Cambia il filtro.',
      );
    }
    final privileges = _ddl.privileges(_target);
    final option = _ddl.grantOption(_target);
    final enabled = widget.enabled;
    // Row 0 applies to every listed object.
    bool? all0(String p) {
      final n = objects.where((o) => d.grantOf(o, p) != null).length;
      return n == 0 ? false : (n == objects.length ? true : null);
    }

    bool? allOption() {
      final held = [
        for (final o in objects)
          if (d.grants.any((g) => g.objectKey == o.objectKey)) d.grantOptionOf(o),
      ];
      if (held.isEmpty || held.every((v) => v == false)) return false;
      if (held.every((v) => v == true)) return true;
      return null;
    }

    final cols = 1 + privileges.length + (option ? 1 : 0);
    return MacTable(
      headers: ['Oggetto', ...privileges, if (option) 'Concessione'],
      rowCount: objects.length + 1,
      emphasis: 0,
      flex: (col) => col == 0 ? 1 : null,
      width: (col) => col == 0 ? 200 : null,
      tooltip: (row, col) =>
          col == cols - 1 && option ? 'Può concedere ad altri i privilegi (WITH GRANT OPTION)' : null,
      cell: (row, col) {
        if (col == 0) return row == 0 ? 'Tutti (${objects.length})' : objects[row - 1].objectLabel;
        if (row == 0) return '';
        final o = objects[row - 1];
        if (col <= privileges.length) return d.grantOf(o, privileges[col - 1]) == null ? '' : '✓';
        return d.grantOptionOf(o) == true ? '✓' : '';
      },
      cellBuilder: (context, row, col) {
        if (col == 0) return null;
        if (col <= privileges.length) {
          final p = privileges[col - 1];
          if (row == 0) {
            return Center(
              child: MacCheckbox(
                value: all0(p),
                semanticLabel: '$p su tutti',
                onChanged: enabled ? (v) => d.setGrants(objects, [p], v) : null,
              ),
            );
          }
          final o = objects[row - 1];
          return Center(
            child: MacCheckbox(
              value: d.grantOf(o, p) != null,
              semanticLabel: '$p su ${o.objectLabel}',
              onChanged: enabled ? (v) => d.setGrant(o, p, v) : null,
            ),
          );
        }
        if (row == 0) {
          return Center(
            child: MacCheckbox(
              value: allOption(),
              onChanged: enabled
                  ? (v) {
                      for (final o in objects) {
                        d.setGrantOption(o, v);
                      }
                    }
                  : null,
            ),
          );
        }
        final o = objects[row - 1];
        final held = d.grants.any((g) => g.objectKey == o.objectKey);
        return Center(
          child: MacCheckbox(
            value: d.grantOptionOf(o),
            onChanged: enabled && held ? (v) => d.setGrantOption(o, v) : null,
          ),
        );
      },
    );
  }
}

/// Privileges not tied to an object (Oracle system privileges, SQL Server
/// database and server permissions, MySQL global privileges, Snowflake
/// account privileges).
class SystemPrivilegesPage extends StatelessWidget {
  const SystemPrivilegesPage({super.key, required this.dialect, required this.design, this.enabled = true});
  final SqlDialect dialect;
  final PrincipalDesign design;
  final bool enabled;

  static const _system = GrantDef(privilege: '', target: GrantTarget.system);

  @override
  Widget build(BuildContext context) {
    final ddl = SecurityDdl.forFamily(dialect);
    final listed = ddl.systemPrivileges(design.working.kind);
    final optionLabel = dialect.family == DbFamily.oracle ? 'Con ADMIN OPTION' : 'Con GRANT OPTION';
    return ListenableBuilder(
      listenable: design,
      builder: (context, _) {
        // Privileges held but not in the list stay visible (and revocable).
        final extra = [
          for (final g in design.grants)
            if (g.target == GrantTarget.system && !listed.contains(g.privilege)) g.privilege,
        ];
        final all = [...listed, ...extra];
        return MacTable(
          headers: ['Privilegio', 'Assegnato', optionLabel],
          rowCount: all.length,
          emphasis: 0,
          flex: (col) => col == 0 ? 1 : null,
          cell: (row, col) => switch (col) {
            0 => all[row],
            1 => design.grantOf(_system, all[row]) == null ? '' : '✓',
            _ => design.grantOf(_system, all[row])?.withGrantOption == true ? '✓' : '',
          },
          cellBuilder: (context, row, col) {
            if (col == 0) return null;
            final p = all[row];
            final g = design.grantOf(_system, p);
            if (col == 1) {
              return Center(
                child: MacCheckbox(
                  value: g != null,
                  semanticLabel: p,
                  onChanged: enabled ? (v) => design.setGrant(_system, p, v) : null,
                ),
              );
            }
            return Center(
              child: MacCheckbox(
                value: g?.withGrantOption ?? false,
                onChanged: enabled && g != null ? (v) => design.setGrantOption(_system, v, privilege: p) : null,
              ),
            );
          },
        );
      },
    );
  }
}
