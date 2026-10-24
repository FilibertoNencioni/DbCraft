// Editor tab of an Oracle package: specification and body on two pages,
// saved together through the script sheet; compilation errors are read
// back from ALL_ERRORS.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../../../state/app_state.dart';
import '../../../state/db_connection.dart';
import '../../../state/editor_tabs.dart';
import '../../../ui/editors/sql_code_editor.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_execution.dart';
import '../catalog/design_catalog.dart';
import '../ddl/extra_ddl.dart';
import '../ddl_script.dart';
import '../model/extra_defs.dart';

class PackageEditorTab extends FeatureTab {
  /// [package] with its [source] when it exists, else a new package [name]
  /// of [schema].
  PackageEditorTab(this.dc, {this.package, PackageSource? source, String? schema, String name = 'NUOVO_PACKAGE'})
    : schema = package?.schema ?? schema,
      _name = package?.name ?? name {
    final src = source ?? ExtraDdl(dc.dialect).packageTemplate(this.schema, _name);
    _savedSpec = src.spec;
    _savedBody = src.body;
    spec = CodeLineEditingController.fromText(src.spec)..addListener(_onChanged);
    body = CodeLineEditingController.fromText(src.body)..addListener(_onChanged);
  }

  final DbConnection dc;
  PackageDef? package;
  final String? schema;
  String _name;
  late final CodeLineEditingController spec;
  late final CodeLineEditingController body;
  late String _savedSpec;
  late String _savedBody;
  bool _dirty = false;

  /// 0: specification, 1: body.
  int page = 0;

  /// Compilation errors of the last save.
  List<String> errors = const [];

  bool get isNew => package == null;
  String get name => _name;

  @override
  DbConnection get connection => dc;
  @override
  String get title => isNew ? '$_name (nuovo)' : _name;
  @override
  String get tooltip => '${dc.config.name}: package ${[?schema, _name].join('.')}';
  @override
  IconData get icon => AppIcons.archive;
  @override
  bool get isDirty => isNew || _dirty;

  void _onChanged() {
    final d = spec.text != _savedSpec || body.text != _savedBody;
    if (d != _dirty) {
      _dirty = d;
      notifyListeners();
    }
  }

  static final _nameRe = RegExp(
    r'^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(?:(?:NON)?EDITIONABLE\s+)?PACKAGE\s+(?:("?[\w$#]+"?)\s*\.\s*)?("?[\w$#]+"?)',
    caseSensitive: false,
  );

  /// Name declared by the specification.
  String get declaredName {
    final m = _nameRe.firstMatch(spec.text);
    if (m == null) return _name;
    final n = m.group(2)!;
    return n.startsWith('"') ? n.substring(1, n.length - 1) : n.toUpperCase();
  }

  List<String> get statements =>
      ExtraDdl(dc.dialect)
          .savePackage(schema, declaredName, PackageSource(spec.text, body.text), hadBody: package?.hasBody ?? false);

  @override
  String? get saveLabel =>
      isDirty && !dc.config.readOnly ? (isNew ? 'Crea il package $_name' : 'Salva il package $_name') : null;

  @override
  Future<void> save(BuildContext context) async {
    final ok = await showDdlScriptDialog(
      context,
      dc: dc,
      title: isNew ? 'Crea $_name' : 'Salva $_name',
      script: DdlScript(statements, scope: SchemaScope.schema(null, schema)),
    );
    if (!ok) return;
    _savedSpec = spec.text;
    _savedBody = body.text;
    _dirty = false;
    _name = declaredName;
    errors = await _errors();
    final cat = DesignCatalog.of(dc);
    try {
      final all = await cat?.extras(ExtraKind.packages, schema: schema);
      package = all?.whereType<PackageDef>().where((p) => p.name == _name).firstOrNull ?? package;
    } catch (_) {}
    notifyListeners();
  }

  Future<List<String>> _errors() async {
    try {
      final owner = schema == null ? 'USER' : dc.dialect.stringLiteral(schema!);
      final r = await dc.meta!.execute(
        'SELECT type, line, position, text FROM all_errors WHERE owner = $owner '
        "AND name = ${dc.dialect.stringLiteral(_name)} AND type IN ('PACKAGE', 'PACKAGE BODY') ORDER BY type, sequence",
      );
      if (r.cursorId != null) await dc.meta!.closeCursor(r.cursorId!);
      return [
        for (final row in r.rows)
          '${row[0] == 'PACKAGE' ? 'Specifica' : 'Corpo'}, riga ${row[1]}, colonna ${row[2]}: ${row[3]}'.trim(),
      ];
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
          : 'Il package $_name ha modifiche non salvate. Chiudere comunque?',
      ok: 'Chiudi',
      destructive: true,
    );
  }

  @override
  void dispose() {
    spec.removeListener(_onChanged);
    body.removeListener(_onChanged);
    spec.dispose();
    body.dispose();
    super.dispose();
  }

  @override
  Widget buildView(BuildContext context) => _PackageView(tab: this);
}

class _PackageView extends StatefulWidget {
  const _PackageView({required this.tab});
  final PackageEditorTab tab;

  @override
  State<_PackageView> createState() => _PackageViewState();
}

class _PackageViewState extends State<_PackageView> {
  PackageEditorTab get tab => widget.tab;
  late final _specFind = CodeFindController(tab.spec);
  late final _bodyFind = CodeFindController(tab.body);
  late final _prompts = [
    for (final c in [tab.spec, tab.body])
      CodePromptsBuilderHolder(
        SqlPromptsBuilder(() => tab.dc, () => c.text, enabled: () => AppScope.read(context).settings.autoComplete),
      ),
  ];

  @override
  void initState() {
    super.initState();
    tab.addListener(_changed);
  }

  @override
  void dispose() {
    tab.removeListener(_changed);
    _specFind.dispose();
    _bodyFind.dispose();
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
    final mac = Theme.of(context).platform == TargetPlatform.macOS;
    final save = SingleActivator(LogicalKeyboardKey.keyS, meta: mac, control: !mac);
    return SizedBox.expand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: c.content,
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.md),
            child: Row(
              children: [
                Icon(tab.icon, size: 18, color: c.accent),
                const SizedBox(width: Gap.sm),
                Flexible(
                  child: Text(
                    tab.title,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(TypeSize.title, weight: FontWeight.w600, color: c.text),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                const Tag('package'),
                if (tab.package != null && !tab.package!.valid) ...[
                  const SizedBox(width: Gap.xs),
                  const Tag('non valido'),
                ],
                if (tab.isDirty) ...[const SizedBox(width: Gap.xs), const DirtyDot()],
                const Spacer(),
                PushButton.primary(
                  label: tab.isNew ? 'Crea' : 'Salva',
                  icon: AppIcons.save,
                  size: ControlScale.small,
                  tooltip: ro ? 'Connessione in sola lettura' : 'Compila specifica e corpo (${shortcutLabel(save)})',
                  onPressed: ro || !tab.isDirty ? null : () => tab.save(context),
                ),
              ],
            ),
          ),
          PageSwitcher<int>(
            value: tab.page,
            items: const [(0, 'Specifica', null), (1, 'Corpo', null)],
            onChanged: (p) => setState(() => tab.page = p),
          ),
          Expanded(
            child: IndexedStack(
              index: tab.page,
              children: [
                SqlCodeEditor(
                  controller: tab.spec,
                  findController: _specFind,
                  promptsBuilder: _prompts[0],
                  fontSize: app.settings.editorFontSize,
                ),
                SqlCodeEditor(
                  controller: tab.body,
                  findController: _bodyFind,
                  promptsBuilder: _prompts[1],
                  fontSize: app.settings.editorFontSize,
                ),
              ],
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
      ),
    );
  }
}
