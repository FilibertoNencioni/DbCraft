// "Permessi" page of the table editor: who holds which privileges on the
// table or view, editable. One row per grantee; "Salva" runs the GRANT and
// REVOKE through the script sheet.

import 'package:flutter/material.dart';

import '../../../model/db_objects.dart';
import '../../../state/db_connection.dart';
import '../../../ui/navigator/nav_nodes.dart' show principalIcon;
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_execution.dart';
import '../catalog/design_catalog.dart';
import '../catalog/security.dart';
import '../ddl/object_ddl.dart';
import '../ddl/security/security_ddl.dart';
import '../ddl_script.dart';
import '../model/security_defs.dart';
import '../security_design.dart';
import 'security_tab.dart' show openSecurity;

class TablePermissionsPage extends StatefulWidget {
  const TablePermissionsPage({super.key, required this.connection, required this.table, this.editable = true});
  final DbConnection connection;
  final DbTable table;
  final bool editable;

  @override
  State<TablePermissionsPage> createState() => _TablePermissionsPageState();
}

class _TablePermissionsPageState extends State<TablePermissionsPage> {
  late final SecurityDdl _ddl = SecurityDdl.forFamily(widget.connection.dialect);
  Future<void>? _load;
  Object? _error;
  List<PrincipalDef> _known = const [];

  /// One edit session per grantee, holding only the grants on this table.
  final List<PrincipalDesign> _rows = [];

  DbConnection get dc => widget.connection;
  DbTable get t => widget.table;
  GrantTarget get _target => t.isView ? GrantTarget.view : GrantTarget.table;

  GrantDef get _on => GrantDef(
    privilege: '',
    target: _target,
    catalog: _ddl.catalogInGrants ? t.catalog : null,
    schema: t.schema,
    object: t.name,
  );

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _reload() {
    setState(() {
      _load = _read();
    });
  }

  Future<void> _read() async {
    final cat = DesignCatalog.of(dc);
    if (cat == null) return;
    for (final r in _rows) {
      r.dispose();
    }
    _rows.clear();
    try {
      _known = await cat.principals(catalog: t.catalog);
    } catch (_) {
      _known = const [];
    }
    try {
      final grants = await cat.objectGrants(t);
      final by = <String, (PrincipalDef, List<GrantDef>)>{};
      for (final g in grants) {
        final e = by.putIfAbsent(g.grantee.key, () => (g.grantee, []));
        // Same object key as the templates of this page.
        e.$2.add(
          GrantDef(
            privilege: g.grant.privilege,
            target: _target,
            catalog: _on.catalog,
            schema: t.schema,
            object: t.name,
            withGrantOption: g.grant.withGrantOption,
          ),
        );
      }
      for (final e in by.values) {
        _rows.add(_session(e.$1, e.$2));
      }
      _error = null;
    } catch (e) {
      _error = e;
    }
  }

  PrincipalDesign _session(PrincipalDef p, List<GrantDef> grants) =>
      PrincipalDesign.existing(dc.dialect, p, PrincipalAccess(grants: grants), catalog: t.catalog)
        ..addListener(() => setState(() {}));

  List<String> get _statements => [for (final r in _rows) ...r.statements];

  Future<void> _add() async {
    final present = {for (final r in _rows) r.working.key};
    final p = await showListPicker<PrincipalDef>(
      context,
      title: 'Aggiungi un assegnatario',
      items: [
        for (final p in _known)
          if (p.kind != PrincipalKind.login && !present.contains(p.key) && _ddl.grantsTo(p)) p,
      ],
      label: (p) => p.display,
      detail: (p) => p.kind.label,
      icon: (p) => principalIcon(p.kind),
      empty: 'Nessun altro utente o ruolo',
    );
    if (p == null) return;
    setState(() => _rows.add(_session(p, const [])));
  }

  Future<void> _save() async {
    final ok = await showDdlScriptDialog(
      context,
      dc: dc,
      title: 'Permessi di ${t.name}',
      script: DdlScript(
        _statements,
        scope: SchemaScope.security(t.catalog),
        catalog: ObjectDdl(dc.dialect).scriptCatalog(t.catalog),
      ),
    );
    if (ok && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _load,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: Spinner());
        if (_error != null) return EmptyState.error(_error!, title: 'Impossibile leggere i permessi');
        final privileges = _ddl.privileges(_target);
        final option = _ddl.grantOption(_target);
        final ro = dc.config.readOnly || !widget.editable;
        final pending = _statements;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PaneBar(
              children: [
                PushButton(
                  label: 'Aggiungi…',
                  icon: AppIcons.add,
                  size: ControlScale.small,
                  onPressed: ro ? null : _add,
                ),
                const SizedBox(width: Gap.sm),
                LinkButton(
                  label: 'Utenti e ruoli…',
                  onPressed: () => openSecurity(context, dc, catalog: t.catalog),
                ),
                const Spacer(),
                if (pending.isNotEmpty) ...[
                  CountBadge(pending.length),
                  const SizedBox(width: Gap.sm),
                  PushButton(label: 'Annulla', size: ControlScale.small, onPressed: _reload),
                  const SizedBox(width: Gap.sm),
                ],
                PushButton.primary(
                  label: 'Salva',
                  icon: AppIcons.save,
                  size: ControlScale.small,
                  tooltip: 'Mostra lo script ed esegue GRANT e REVOKE',
                  onPressed: ro || pending.isEmpty ? null : _save,
                ),
              ],
            ),
            Expanded(
              child: _rows.isEmpty
                  ? EmptyState(
                      icon: AppIcons.security,
                      title: 'Nessun permesso assegnato',
                      message: 'Solo il proprietario accede a ${t.name}. Aggiungi un utente o un ruolo.',
                    )
                  : MacTable(
                      headers: ['Assegnatario', ...privileges, if (option) 'Concessione'],
                      rowCount: _rows.length,
                      emphasis: 0,
                      flex: (col) => col == 0 ? 1 : null,
                      width: (col) => col == 0 ? 200 : null,
                      leading: (row) => Padding(
                        padding: const EdgeInsets.only(right: Gap.xs),
                        child: Icon(
                          principalIcon(_rows[row].working.kind),
                          size: 14,
                          color: DbColors.of(context).textSecondary,
                        ),
                      ),
                      rowStatus: (row) => _rows[row].statements.isEmpty ? null : DbColors.of(context).diffChanged,
                      cell: (row, col) {
                        final r = _rows[row];
                        if (col == 0) return r.working.display;
                        if (col <= privileges.length) return r.grantOf(_on, privileges[col - 1]) == null ? '' : '✓';
                        return r.grantOptionOf(_on) == true ? '✓' : '';
                      },
                      cellBuilder: (context, row, col) {
                        if (col == 0) return null;
                        final r = _rows[row];
                        if (col <= privileges.length) {
                          final p = privileges[col - 1];
                          return Center(
                            child: MacCheckbox(
                              value: r.grantOf(_on, p) != null,
                              semanticLabel: '$p a ${r.working.display}',
                              onChanged: ro ? null : (v) => r.setGrant(_on, p, v),
                            ),
                          );
                        }
                        final held = r.grants.isNotEmpty;
                        return Center(
                          child: MacCheckbox(
                            value: r.grantOptionOf(_on),
                            onChanged: ro || !held ? null : (v) => r.setGrantOption(_on, v),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
