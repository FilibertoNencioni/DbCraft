// "Definizione" page of the object editor of a view: name, options of the
// DBMS, the query in a SQL editor with completion, and "Verifica" that runs
// it on a few rows.

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../../model/db_objects.dart';
import '../../../odbc/odbc_types.dart';
import '../../../services/sql_dialect.dart';
import '../../../state/app_state.dart';
import '../../../state/db_connection.dart';
import '../../../state/editor_tabs.dart';
import '../../../ui/editors/sql_code_editor.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_builder.dart';
import '../../schema/ddl_execution.dart';
import '../capabilities.dart';
import '../catalog/design_catalog.dart';
import '../ddl/object_ddl.dart';
import '../ddl_script.dart';
import '../model/object_defs.dart';
import '../view_design.dart';

class ViewDefinitionPage extends StatefulWidget {
  const ViewDefinitionPage({super.key, required this.design, required this.connection, this.readOnly = false});
  final ViewDesign design;
  final DbConnection connection;
  final bool readOnly;

  @override
  State<ViewDefinitionPage> createState() => _ViewDefinitionPageState();
}

class _ViewDefinitionPageState extends State<ViewDefinitionPage> {
  late final _name = TextEditingController(text: d.working.name);
  late final _comment = TextEditingController(text: d.working.comment ?? '');
  late final CodeLineEditingController _code = CodeLineEditingController.fromText(d.working.definition);
  late final CodeFindController _find = CodeFindController(_code);
  late final CodePromptsBuilderHolder _prompts = CodePromptsBuilderHolder(
    SqlPromptsBuilder(
      () => widget.connection,
      () => _code.text,
      enabled: () => AppScope.read(context).settings.autoComplete,
      catalog: () => d.working.catalog,
    ),
  );

  bool _checking = false;
  String? _checkError;
  ResultPage? _checkResult;

  ViewDesign get d => widget.design;
  DbConnection get dc => widget.connection;

  @override
  void initState() {
    super.initState();
    _code.addListener(_onCode);
    d.addListener(_onDesign);
  }

  @override
  void dispose() {
    d.removeListener(_onDesign);
    _code.removeListener(_onCode);
    _find.dispose();
    _code.dispose();
    _name.dispose();
    _comment.dispose();
    super.dispose();
  }

  void _onCode() {
    if (_code.text != d.working.definition) d.update(d.working.copyWith(definition: _code.text));
  }

  /// Discard / save from the header: the fields follow the model.
  void _onDesign() {
    final w = d.working;
    if (_code.text != w.definition) _code.text = w.definition;
    if (_name.text != w.name) _name.text = w.name;
    if (_comment.text != (w.comment ?? '')) _comment.text = w.comment ?? '';
    if (mounted) setState(() {});
  }

  /// Runs the query on a few rows (separate from the view: it need not exist).
  Future<void> _check() async {
    final q = d.working.definition.trim().replaceFirst(RegExp(r';\s*$'), '');
    if (q.isEmpty) return;
    setState(() {
      _checking = true;
      _checkError = null;
      _checkResult = null;
    });
    try {
      final session = dc.meta!;
      final sql = dc.dialect.limit('SELECT * FROM ($q) dbc_check', 20);
      final r = await session.execute(sql, fetchSize: 20, queryTimeoutSec: 30);
      if (r.cursorId != null) await session.closeCursor(r.cursorId!);
      _checkResult = r;
    } catch (e) {
      _checkError = e is OdbcException ? e.message : e.toString();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = d.working;
    final caps = DesignCapabilities.of(dc.dialect);
    final family = dc.dialect.family;
    final app = AppScope.of(context);
    final c = DbColors.of(context);
    final ro = widget.readOnly;
    void set(ViewDef v) => d.update(v);
    final checkOk = !w.materialized && family != DbFamily.sqlite && family != DbFamily.snowflake;
    final options = <Widget>[
      if (caps.has(DesignFeature.materializedViews))
        CheckboxRow(
          small: true,
          value: w.materialized,
          label: 'Materializzata',
          tooltip: 'I risultati sono salvati e si aggiornano a richiesta',
          onChanged: ro ? null : (v) => set(w.copyWith(materialized: v)),
        ),
      if (checkOk)
        PopUpButton<ViewCheckOption>(
          small: true,
          value: w.checkOption,
          items: [
            (ViewCheckOption.none, 'Senza CHECK OPTION', null),
            if (family == DbFamily.postgres || family == DbFamily.mysql || family == DbFamily.db2)
              (ViewCheckOption.local, 'WITH LOCAL CHECK OPTION', null),
            (
              ViewCheckOption.cascaded,
              family == DbFamily.postgres || family == DbFamily.mysql || family == DbFamily.db2
                  ? 'WITH CASCADED CHECK OPTION'
                  : 'WITH CHECK OPTION',
              null,
            ),
          ],
          onChanged: ro ? null : (v) => set(w.copyWith(checkOption: v)),
        ),
      if (family == DbFamily.postgres && !w.materialized)
        CheckboxRow(
          small: true,
          value: w.securityBarrier,
          label: 'security_barrier',
          onChanged: ro ? null : (v) => set(w.copyWith(securityBarrier: v)),
        ),
      if (family == DbFamily.sqlServer)
        CheckboxRow(
          small: true,
          value: w.schemaBinding,
          label: 'WITH SCHEMABINDING',
          onChanged: ro ? null : (v) => set(w.copyWith(schemaBinding: v)),
        ),
      if (family == DbFamily.oracle && !w.materialized)
        CheckboxRow(
          small: true,
          value: w.force,
          label: 'FORCE',
          onChanged: ro ? null : (v) => set(w.copyWith(force: v)),
        ),
      if (family == DbFamily.snowflake)
        CheckboxRow(
          small: true,
          value: w.secure,
          label: 'SECURE',
          onChanged: ro ? null : (v) => set(w.copyWith(secure: v)),
        ),
      if (family == DbFamily.mysql) ...[
        PopUpButton<String?>(
          small: true,
          value: w.algorithm,
          items: const [
            (null, 'ALGORITHM predefinito', null),
            ('MERGE', 'MERGE', null),
            ('TEMPTABLE', 'TEMPTABLE', null),
            ('UNDEFINED', 'UNDEFINED', null),
          ],
          onChanged: ro ? null : (v) => set(w.copyWith(algorithm: v)),
        ),
        PopUpButton<String?>(
          small: true,
          value: w.sqlSecurity,
          items: const [
            (null, 'SQL SECURITY predefinita', null),
            ('DEFINER', 'DEFINER', null),
            ('INVOKER', 'INVOKER', null),
          ],
          onChanged: ro ? null : (v) => set(w.copyWith(sqlSecurity: v)),
        ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
          child: Row(
            children: [
              Text('Nome', style: uiText(TypeSize.body, color: c.text)),
              const SizedBox(width: Gap.sm),
              SizedBox(
                width: 240,
                child: MacTextField(
                  controller: _name,
                  small: true,
                  autofocus: d.isNew,
                  readOnly: ro,
                  hint: 'nome della vista',
                  onChanged: (v) => set(w.copyWith(name: v.trim())),
                ),
              ),
              if (family != DbFamily.mysql && family != DbFamily.sqlite) ...[
                const SizedBox(width: Gap.lg),
                Text('Commento', style: uiText(TypeSize.body, color: c.text)),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: MacTextField(
                    controller: _comment,
                    small: true,
                    readOnly: ro,
                    onChanged: (v) => set(w.copyWith(comment: v.trim().isEmpty ? null : v)),
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
        ),
        if (options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Wrap(
              spacing: Gap.md,
              runSpacing: Gap.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: options,
            ),
          ),
        PaneBar(
          children: [
            Text(
              'Query',
              style: uiText(TypeSize.small, weight: FontWeight.w600, color: c.textSecondary),
            ),
            const Spacer(),
            if (_checking) const StatusLine.busy('Esecuzione…'),
            if (_checkError != null) Flexible(child: StatusLine(_checkError!, kind: StatusKind.danger)),
            if (_checkResult != null)
              StatusLine(
                '${_checkResult!.columns.length} colonne${_checkResult!.rows.isEmpty ? ', nessuna riga' : ''}',
                kind: StatusKind.success,
              ),
            const SizedBox(width: Gap.sm),
            ToolButton(
              icon: AppIcons.run,
              label: 'Verifica',
              tooltip: 'Esegue la query su poche righe senza modificare la vista',
              onPressed: _checking ? null : _check,
            ),
          ],
        ),
        Expanded(
          child: SqlCodeEditor(
            controller: _code,
            findController: _find,
            promptsBuilder: _prompts,
            fontSize: app.settings.editorFontSize,
          ),
        ),
        if (_checkResult != null && _checkResult!.columns.isNotEmpty)
          SizedBox(
            height: 160,
            child: SimpleGrid(
              headers: [for (final col in _checkResult!.columns) col.name],
              rows: [
                for (final r in _checkResult!.rows) [for (final v in r) v == null ? 'NULL' : '$v'],
              ],
            ),
          ),
      ],
    );
  }
}

/// Applies the view design of [tab]: script, then the view is read again
/// (it may have been created or renamed).
Future<bool> saveViewDesign(BuildContext context, TableEditorTab tab) async {
  final d = tab.viewDesign;
  final dc = tab.connection;
  if (d == null || !d.isDirty) return false;
  if (d.errors.isNotEmpty) {
    await showErrorDialog(context, d.errors.join('\n'), title: 'Impossibile salvare la vista');
    return false;
  }
  final w = d.working;
  final ok = await showDdlScriptDialog(
    context,
    dc: dc,
    title: d.isNew ? 'Crea la vista ${w.name}' : 'Modifiche alla vista ${d.original!.name}',
    script: DdlScript(
      d.statements,
      transactional: true,
      scope: SchemaScope.schema(w.catalog, w.schema),
      catalog: ObjectDdl(dc.dialect).scriptCatalog(w.catalog),
    ),
  );
  if (!ok) return false;
  final found = await dc.metadata?.findTable(w.catalog, w.schema, w.name);
  final cat = DesignCatalog.of(dc);
  if (found != null) {
    tab.table = found;
    final def = await cat?.viewDef(found);
    d.saved(def ?? w.copyWith(originalName: null));
  }
  tab.refresh();
  return true;
}

/// CREATE script of a view for the DDL page and "Genera DDL".
String viewScript(SqlDialect dialect, ViewDef v) => DdlBuilder(dialect).render(ObjectDdl(dialect).createView(v));

/// Definition of the view [t] of [dc] (null when it cannot be read).
Future<ViewDef?> loadViewDef(DbConnection dc, DbTable t) async {
  try {
    return await DesignCatalog.of(dc)?.viewDef(t);
  } catch (_) {
    return null;
  }
}
