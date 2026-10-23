// Editor tab of objects made of code (triggers, procedures, functions):
// the source in a SQL editor, saved through the script sheet. Oracle
// compilation errors are read back and shown under the editor.

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../../model/db_objects.dart';
import '../../../services/sql_dialect.dart';
import '../../../state/app_state.dart';
import '../../../state/db_connection.dart';
import '../../../state/editor_tabs.dart';
import '../../../ui/editors/sql_code_editor.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_execution.dart';
import '../catalog/code.dart';
import '../catalog/design_catalog.dart';
import '../ddl/code_ddl.dart';
import '../ddl/object_ddl.dart';
import '../ddl_script.dart';
import '../model/object_defs.dart';

final _nameAfter = RegExp(
  r'^\s*CREATE\s+(?:OR\s+(?:REPLACE|ALTER)\s+)?(?:(?:NO)?EDITIONABLE\s+)?(?:DEFINER\s*=\s*\S+\s+)?(TRIGGER|PROC|PROCEDURE|FUNCTION)\s+((?:"[^"]+"|`[^`]+`|\[[^\]]+\]|[\w$#]+)(?:\s*\.\s*(?:"[^"]+"|`[^`]+`|\[[^\]]+\]|[\w$#]+))*)',
  caseSensitive: false,
  multiLine: true,
);

/// Name of the trigger / routine created by [source] (without schema and
/// quotes); for PostgreSQL trigger sources, the trigger's (the second
/// CREATE).
String? createdName(String source, {String kind = 'TRIGGER'}) {
  for (final m in _nameAfter.allMatches(source)) {
    final k = m.group(1)!.toUpperCase();
    if ((kind == 'TRIGGER') != (k == 'TRIGGER')) continue;
    final last = m.group(2)!.split(RegExp(r'\s*\.\s*')).last.trim();
    final c = last.isEmpty ? '' : last[0];
    return c == '"' || c == '`' || c == '[' ? last.substring(1, last.length - 1) : last;
  }
  return null;
}

class CodeEditorTab extends FeatureTab {
  /// Trigger of [table]: [original] when it exists, else the [template]
  /// header of a new one.
  CodeEditorTab.trigger(this.dc, {required this.table, TriggerDef? original, TriggerDef? template})
    : trigger = original,
      routineKind = null,
      procedure = null,
      routine = null,
      _source = original?.source ?? CodeDdl(dc.dialect).triggerTemplate(template!),
      _name = original?.name ?? template!.name {
    controller = CodeLineEditingController.fromText(_saved);
    controller.addListener(_onChanged);
  }

  /// Procedure or function: [procedure] with its [source] when it exists,
  /// else a new one in [catalog].[schema].
  CodeEditorTab.routine(
    this.dc, {
    required RoutineKind kind,
    this.procedure,
    RoutineSource? source,
    String? catalog,
    String? schema,
    String name = 'nuova_routine',
  }) : trigger = null,
       table = null,
       routineKind = source?.kind ?? kind,
       routine = source,
       _catalog = procedure?.catalog ?? catalog,
       _schema = procedure?.schema ?? schema,
       _source = source?.source ?? CodeDdl(dc.dialect).routineTemplate(kind, catalog, schema, name),
       _name = procedure?.cleanName ?? name {
    controller = CodeLineEditingController.fromText(_saved);
    controller.addListener(_onChanged);
  }

  final DbConnection dc;
  final DbTable? table;
  TriggerDef? trigger;
  final RoutineKind? routineKind;
  DbProcedure? procedure;
  RoutineSource? routine;
  String? _catalog;
  String? _schema;
  final String _source;
  String _name;
  late final CodeLineEditingController controller;
  late String _saved = _source;
  bool _dirty = false;

  /// Oracle compilation errors of the last save.
  List<String> errors = const [];

  bool get isTrigger => table != null;
  bool get isNew => isTrigger ? trigger == null : procedure == null;
  String? get catalog => isTrigger ? table!.catalog : _catalog;
  String? get schema => isTrigger ? table!.schema : _schema;

  @override
  DbConnection get connection => dc;
  @override
  String get title => isNew ? '$_name (nuovo)' : _name;
  @override
  String get tooltip => '${dc.config.name}: ${isTrigger ? 'trigger di ${table!.name}' : routineKind!.label} $_name';
  @override
  IconData get icon =>
      isTrigger ? AppIcons.bolt : (routineKind == RoutineKind.function ? AppIcons.function : AppIcons.procedure);
  @override
  bool get isDirty => isNew || _dirty;

  void _onChanged() {
    final d = controller.text != _saved;
    if (d != _dirty) {
      _dirty = d;
      notifyListeners();
    }
  }

  /// Statements that apply the current source.
  List<String> get statements {
    final ddl = CodeDdl(dc.dialect);
    final text = controller.text;
    if (isTrigger) return ddl.saveTrigger(trigger, createdName(text) ?? _name, text);
    return ddl.saveRoutine(
      text,
      routineKind!,
      existing: isNew ? null : (catalog: catalog, schema: schema, name: procedure!.cleanName),
    );
  }

  Future<void> save(BuildContext context) async {
    final family = dc.dialect.family;
    final ok = await showDdlScriptDialog(
      context,
      dc: dc,
      title: isNew ? 'Crea $_name' : 'Salva $_name',
      script: DdlScript(
        statements,
        // Oracle and MySQL commit DDL anyway; PostgreSQL keeps function and trigger together.
        transactional: true,
        scope: isTrigger ? SchemaScope.object(catalog, schema, table!.name) : SchemaScope.schema(catalog, schema),
        catalog: ObjectDdl(dc.dialect).scriptCatalog(catalog),
      ),
    );
    if (!ok) return;
    _saved = controller.text;
    _dirty = false;
    _name = createdName(_saved, kind: isTrigger ? 'TRIGGER' : 'ROUTINE') ?? _name;
    errors = family == DbFamily.oracle ? await _oracleErrors() : const [];
    await _reload();
    notifyListeners();
  }

  /// Reads the object back: it now exists (and may have a new name).
  Future<void> _reload() async {
    final cat = DesignCatalog.of(dc);
    if (cat == null) return;
    try {
      if (isTrigger) {
        final all = await cat.triggers(table!);
        trigger = all.where((t) => t.name.toLowerCase() == _name.toLowerCase()).firstOrNull ?? trigger;
      } else {
        final procs = await dc.metadata!.procedures(catalog, schema);
        final p = procs.where((x) => x.cleanName.toLowerCase() == _name.toLowerCase()).firstOrNull;
        if (p != null) {
          procedure = p;
          routine = await cat.routineSource(p);
        }
      }
    } catch (_) {}
  }

  Future<List<String>> _oracleErrors() async {
    try {
      final owner = schema == null ? 'USER' : dc.dialect.stringLiteral(schema!);
      final r = await dc.meta!.execute(
        'SELECT line, position, text FROM all_errors WHERE owner = $owner AND name = ${dc.dialect.stringLiteral(_name)} '
        'ORDER BY sequence',
      );
      if (r.cursorId != null) await dc.meta!.closeCursor(r.cursorId!);
      return [for (final row in r.rows) 'Riga ${row[0]}, colonna ${row[1]}: ${row[2]}'.trim()];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> canClose(BuildContext context) async {
    if (!_dirty && !isNew) return true;
    return confirmDialog(
      context,
      'Modifiche non salvate',
      isNew
          ? '$_name non è ancora stato creato. Chiudere comunque?'
          : 'Il sorgente di $_name contiene modifiche non salvate. Chiudere comunque?',
      ok: 'Chiudi',
      destructive: true,
    );
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget buildView(BuildContext context) => _CodeEditorView(tab: this);
}

class _CodeEditorView extends StatefulWidget {
  const _CodeEditorView({required this.tab});
  final CodeEditorTab tab;

  @override
  State<_CodeEditorView> createState() => _CodeEditorViewState();
}

class _CodeEditorViewState extends State<_CodeEditorView> {
  late final CodeFindController _find = CodeFindController(widget.tab.controller);
  late final CodePromptsBuilderHolder _prompts = CodePromptsBuilderHolder(
    SqlPromptsBuilder(
      () => widget.tab.dc,
      () => widget.tab.controller.text,
      enabled: () => AppScope.read(context).settings.autoComplete,
      catalog: () => widget.tab.catalog,
    ),
  );

  CodeEditorTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    tab.addListener(_changed);
  }

  @override
  void dispose() {
    tab.removeListener(_changed);
    _find.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final app = AppScope.of(context);
    final ro = tab.dc.config.readOnly;
    final t = tab.trigger;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: c.content,
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.md),
          child: Row(
            children: [
              Icon(tab.icon, size: 18, color: c.accent),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            tab.title,
                            overflow: TextOverflow.ellipsis,
                            style: uiText(TypeSize.title, weight: FontWeight.w600, color: c.text),
                          ),
                        ),
                        const SizedBox(width: Gap.sm),
                        Tag(tab.isTrigger ? 'trigger' : tab.routineKind!.label),
                        if (t != null && !t.enabled) ...[const SizedBox(width: Gap.xs), const Tag('disabilitato')],
                        if (tab.isDirty) ...[const SizedBox(width: Gap.xs), const DirtyDot()],
                      ],
                    ),
                    Text(
                      [
                        tab.dc.config.name,
                        ?tab.catalog,
                        ?tab.schema,
                        if (tab.isTrigger) 'tabella ${tab.table!.name}',
                        if (t != null) t.summary,
                      ].join(' · '),
                      style: uiText(TypeSize.small, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              ToolButton(icon: AppIcons.search, tooltip: 'Trova e sostituisci', onPressed: _find.findMode),
              const SizedBox(width: Gap.sm),
              PushButton.primary(
                label: tab.isNew ? 'Crea' : 'Salva',
                icon: AppIcons.save,
                size: ControlScale.small,
                tooltip: ro ? 'Connessione in sola lettura' : 'Mostra lo script ed esegue il sorgente',
                onPressed: ro || !tab.isDirty ? null : () => tab.save(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: SqlCodeEditor(
            controller: tab.controller,
            findController: _find,
            promptsBuilder: _prompts,
            fontSize: app.settings.editorFontSize,
          ),
        ),
        if (tab.errors.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 140),
            color: c.chrome,
            padding: const EdgeInsets.all(Gap.sm),
            child: ListView(
              shrinkWrap: true,
              children: [
                const StatusLine('Compilato con errori', kind: StatusKind.danger),
                for (final e in tab.errors)
                  Text(
                    e,
                    style: monoStyle(context, size: TypeSize.monoSmall, color: c.danger),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
