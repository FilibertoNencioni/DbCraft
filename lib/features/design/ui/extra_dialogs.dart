// Sheets of the DBMS specific objects: extensions, enum types, domains,
// row security policies, exclusion constraints, synonyms, events,
// warehouses, stages and file formats. Each returns the edited definition;
// the caller turns it into a script (ExtraDdl).

import 'package:flutter/material.dart';

import '../../../services/sql_dialect.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/schema_model.dart';
import '../ddl/extra_ddl.dart';
import '../model/extra_defs.dart';
import 'object_dialogs.dart' show ScriptPreview;

String? _text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

/// Rows of text fields edited in an [EditableGrid] (enum values, domain
/// checks, exclusion elements), with stable keys.
class FieldRows {
  FieldRows(this.width, Iterable<List<String>> initial) {
    for (final r in initial) {
      add(r);
    }
  }

  final int width;
  final List<(int, List<TextEditingController>)> rows = [];
  var _seq = 0;

  void add([List<String> values = const []]) => rows.add((
    _seq++,
    [for (var i = 0; i < width; i++) TextEditingController(text: i < values.length ? values[i] : '')],
  ));

  void remove(int i) {
    for (final c in rows[i].$2) {
      c.dispose();
    }
    rows.removeAt(i);
  }

  void move(int from, int to) => rows.insert(to, rows.removeAt(from));

  List<List<String>> get values => [
    for (final r in rows)
      if (r.$2.any((c) => c.text.trim().isNotEmpty)) [for (final c in r.$2) c.text.trim()],
  ];

  void dispose() {
    for (final r in rows) {
      for (final c in r.$2) {
        c.dispose();
      }
    }
  }
}

/// Height of an EditableGrid of [rows] rows: header, rows, "Aggiungi".
double gridHeight(int rows) => (24 + rows.clamp(1, 8) * 28 + 44).toDouble();

/// Common frame of the sheets: form, live script, error, buttons.
class ExtraSheet extends StatelessWidget {
  const ExtraSheet({
    super.key,
    required this.title,
    required this.isNew,
    required this.children,
    required this.statements,
    required this.onSave,
    this.subtitle,
    this.error,
    this.notice,
  });
  final String title;
  final String? subtitle;
  final bool isNew;
  final List<Widget> children;
  final List<String> statements;
  final VoidCallback onSave;
  final String? error;
  final Widget? notice;

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: title,
      subtitle: subtitle,
      onSubmit: onSave,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (notice != null) ...[notice!, const SizedBox(height: Gap.md)],
            ...children,
            ScriptPreview(statements),
          ],
        ),
      ),
      leading: [if (error != null) Flexible(child: StatusLine(error!, kind: StatusKind.danger))],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: isNew ? 'Crea' : 'Applica', onPressed: onSave),
      ],
    );
  }
}

Widget monoField(
  TextEditingController c, {
  String? hint,
  int lines = 3,
  VoidCallback? changed,
  bool autofocus = false,
}) => MacTextField(
  controller: c,
  mono: true,
  maxLines: lines,
  hint: hint,
  autofocus: autofocus,
  onChanged: (_) => changed?.call(),
);

// ---------------------------------------------------------------------------
// Extension
// ---------------------------------------------------------------------------

/// Installs (initial null) or changes an extension; returns it with the
/// CASCADE choice of a new one.
Future<(ExtensionDef, bool)?> showExtensionDialog(
  BuildContext context, {
  required SqlDialect dialect,
  ExtensionDef? initial,
  List<ExtensionDef> available = const [],
  List<String> schemas = const [],
}) => showSheet<(ExtensionDef, bool)>(
  context,
  builder: (_) => _ExtensionDialog(dialect: dialect, initial: initial, available: available, schemas: schemas),
);

class _ExtensionDialog extends StatefulWidget {
  const _ExtensionDialog({required this.dialect, this.initial, required this.available, required this.schemas});
  final SqlDialect dialect;
  final ExtensionDef? initial;
  final List<ExtensionDef> available;
  final List<String> schemas;

  @override
  State<_ExtensionDialog> createState() => _ExtensionDialogState();
}

class _ExtensionDialogState extends State<_ExtensionDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _schema = TextEditingController(text: i?.schema ?? '');
  late final _version = TextEditingController(text: i?.version ?? '');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  bool _cascade = true;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _schema, _version, _comment]) {
      c.dispose();
    }
    super.dispose();
  }

  ExtensionDef? get _known => widget.available.where((e) => e.name == _name.text.trim()).firstOrNull;

  ExtensionDef get _current => ExtensionDef(
    name: _name.text.trim(),
    schema: _text(_schema),
    version: _text(_version),
    comment: i == null ? null : _text(_comment),
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return i == null ? ddl.createExtension(_current, cascade: _cascade) : ddl.alterExtension(i!, _current);
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Scegli l\'estensione');
      return;
    }
    if (i == null && widget.available.any((e) => e.name == _name.text.trim() && e.installed)) {
      setState(() => _error = 'L\'estensione è già installata');
      return;
    }
    Navigator.pop(context, (_current, _cascade));
  }

  @override
  Widget build(BuildContext context) {
    final known = _known;
    final versions = {?known?.defaultVersion, ?i?.defaultVersion, ?i?.version}.toList();
    return ExtraSheet(
      title: i == null ? 'Nuova estensione' : 'Estensione ${i!.name}',
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Estensione',
              help: known?.comment,
              child: ComboField(
                controller: _name,
                enabled: i == null,
                hint: 'pg_trgm',
                options: () => [
                  for (final e in widget.available)
                    if (!e.installed) e.name,
                ],
                optionDetail: (n) => widget.available.where((e) => e.name == n).firstOrNull?.defaultVersion,
                onChanged: (_) => setState(() {}),
                onSelected: (_) => setState(() {}),
              ),
            ),
            FormRow(
              label: 'Schema',
              help: 'Dove vengono creati i suoi oggetti (vuoto: il primo del search_path)',
              child: ComboField(
                controller: _schema,
                options: () => widget.schemas,
                onChanged: (_) => setState(() {}),
                onSelected: (_) => setState(() {}),
              ),
            ),
            FormRow(
              label: 'Versione',
              help: i?.updatable ?? false ? 'Disponibile la versione ${i!.defaultVersion}' : 'Vuoto: la predefinita',
              child: ComboField(
                controller: _version,
                options: () => versions,
                onChanged: (_) => setState(() {}),
                onSelected: (_) => setState(() {}),
              ),
            ),
            if (i == null)
              FormRow(
                label: 'Dipendenze',
                child: CheckboxRow(
                  value: _cascade,
                  label: 'Installa anche le estensioni richieste (CASCADE)',
                  onChanged: (v) => setState(() => _cascade = v),
                ),
              )
            else
              FormRow(
                label: 'Commento',
                child: MacTextField(controller: _comment, onChanged: (_) => setState(() {})),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Enum type
// ---------------------------------------------------------------------------

Future<EnumTypeDef?> showEnumDialog(
  BuildContext context, {
  required SqlDialect dialect,
  String? catalog,
  String? schema,
  EnumTypeDef? initial,
}) => showSheet<EnumTypeDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _EnumDialog(dialect: dialect, catalog: catalog, schema: schema, initial: initial),
);

class _EnumDialog extends StatefulWidget {
  const _EnumDialog({required this.dialect, this.catalog, this.schema, this.initial});
  final SqlDialect dialect;
  final String? catalog;
  final String? schema;
  final EnumTypeDef? initial;

  @override
  State<_EnumDialog> createState() => _EnumDialogState();
}

class _EnumDialogState extends State<_EnumDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late final _values = FieldRows(1, [
    for (final v in i?.values ?? const <String>[]) [v],
  ]);
  int? _selected;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_values.rows.isEmpty) _values.add();
  }

  @override
  void dispose() {
    _name.dispose();
    _comment.dispose();
    _values.dispose();
    super.dispose();
  }

  EnumTypeDef get _current => EnumTypeDef(
    name: _name.text.trim(),
    catalog: widget.catalog,
    schema: widget.schema,
    values: [for (final r in _values.values) r.first],
    comment: _text(_comment),
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return i == null ? ddl.createEnum(_current) : ddl.alterEnum(i!, _current);
  }

  void _save() {
    final c = _current;
    String? err;
    if (c.name.isEmpty) err = 'Inserisci il nome del tipo';
    if (err == null && c.values.isEmpty) err = 'Aggiungi almeno un valore';
    if (err == null && c.values.toSet().length != c.values.length) err = 'Ci sono valori ripetuti';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    final old = i?.values.toSet() ?? const <String>{};
    return ExtraSheet(
      title: i == null ? 'Nuovo tipo enumerato' : 'Tipo ${i!.name}',
      subtitle: widget.schema,
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      notice: i == null
          ? null
          : const Notice(
              kind: NoticeKind.info,
              message:
                  'PostgreSQL aggiunge e rinomina i valori ma non li elimina né li riordina. '
                  'Per rinominare un valore modificalo senza cambiare il numero dei valori.',
            ),
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: i == null, onChanged: (_) => setState(() {})),
            ),
            FormRow(
              label: 'Commento',
              child: MacTextField(controller: _comment, onChanged: (_) => setState(() {})),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          height: gridHeight(_values.rows.length),
          child: EditableGrid(
            columns: const [EditableGridColumn('Valori')],
            rowCount: _values.rows.length,
            rowKey: (r) => ValueKey(_values.rows[r].$1),
            selected: _selected,
            onSelect: (r) => setState(() => _selected = r),
            mark: (r) => i != null && !old.contains(_values.rows[r].$2.first.text.trim())
                ? EditableRowMark.added
                : EditableRowMark.none,
            onAdd: () => setState(() => _values.add()),
            addLabel: 'Aggiungi valore',
            onRemove: (r) => setState(() => _values.remove(r)),
            onMove: (a, b) => setState(() => _values.move(a, b)),
            cellBuilder: (context, r, c) =>
                MacTextField(controller: _values.rows[r].$2.first, small: true, onChanged: (_) => setState(() {})),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Domain
// ---------------------------------------------------------------------------

Future<DomainDef?> showDomainDialog(
  BuildContext context, {
  required SqlDialect dialect,
  String? catalog,
  String? schema,
  DomainDef? initial,
}) => showSheet<DomainDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _DomainDialog(dialect: dialect, catalog: catalog, schema: schema, initial: initial),
);

class _DomainDialog extends StatefulWidget {
  const _DomainDialog({required this.dialect, this.catalog, this.schema, this.initial});
  final SqlDialect dialect;
  final String? catalog;
  final String? schema;
  final DomainDef? initial;

  @override
  State<_DomainDialog> createState() => _DomainDialogState();
}

class _DomainDialogState extends State<_DomainDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _type = TextEditingController(text: i?.baseType ?? '');
  late final _default = TextEditingController(text: i?.defaultValue ?? '');
  late final _collation = TextEditingController(text: i?.collation ?? '');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late final _check = TextEditingController(text: i?.checks.firstOrNull?.expression ?? '');
  late final _checks = FieldRows(2, [
    for (final c in i?.checks ?? const <DomainCheck>[]) [c.name ?? '', c.expression],
  ]);
  late bool _notNull = i?.notNull ?? false;
  String? _error;

  bool get _fb => widget.dialect.family == DbFamily.firebird;

  @override
  void dispose() {
    for (final c in [_name, _type, _default, _collation, _comment, _check]) {
      c.dispose();
    }
    _checks.dispose();
    super.dispose();
  }

  DomainDef get _current => DomainDef(
    name: _name.text.trim(),
    catalog: widget.catalog,
    schema: widget.schema,
    baseType: _type.text.trim(),
    notNull: _notNull,
    defaultValue: _text(_default),
    collation: _text(_collation),
    comment: _text(_comment),
    checks: _fb
        ? [if (_text(_check) case final e?) DomainCheck(e)]
        : [
            for (final r in _checks.values)
              if (r[1].isNotEmpty) DomainCheck(r[1], name: r[0].isEmpty ? null : r[0]),
          ],
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty || _type.text.trim().isEmpty) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return i == null ? ddl.createDomain(_current) : ddl.alterDomain(i!, _current);
  }

  void _save() {
    final c = _current;
    final err = c.name.isEmpty
        ? 'Inserisci il nome del dominio'
        : c.baseType.isEmpty
        ? 'Scegli il tipo di base'
        : null;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    return ExtraSheet(
      title: i == null ? 'Nuovo dominio' : 'Dominio ${i!.name}',
      subtitle: widget.schema,
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: i == null, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Tipo di base',
              child: ComboField(
                controller: _type,
                mono: true,
                options: () => commonTypes(widget.dialect.family),
                onChanged: (_) => changed(),
                onSelected: (_) => changed(),
              ),
            ),
            FormRow(
              label: 'Valori',
              child: CheckboxRow(
                value: _notNull,
                label: 'Obbligatorio (NOT NULL)',
                onChanged: (v) => setState(() => _notNull = v),
              ),
            ),
            FormRow(
              label: 'Predefinito',
              help: 'Espressione SQL',
              child: monoField(_default, lines: 1, changed: changed),
            ),
            if (_fb)
              FormRow(
                label: 'Condizione',
                help: 'VALUE è il valore da controllare: VALUE > 0',
                child: monoField(_check, hint: 'VALUE > 0', changed: changed),
              ),
            FormRow(
              label: 'Collation',
              child: MacTextField(controller: _collation, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Commento',
              child: MacTextField(controller: _comment, onChanged: (_) => changed()),
            ),
          ],
        ),
        if (!_fb) ...[
          const SizedBox(height: Gap.md),
          SectionLabel('Vincoli CHECK'),
          SizedBox(
            height: gridHeight(_checks.rows.length),
            child: EditableGrid(
              columns: const [EditableGridColumn('Nome', width: 160), EditableGridColumn('Condizione (VALUE > 0)')],
              rowCount: _checks.rows.length,
              rowKey: (r) => ValueKey(_checks.rows[r].$1),
              onAdd: () => setState(() => _checks.add()),
              addLabel: 'Aggiungi vincolo',
              onRemove: (r) => setState(() => _checks.remove(r)),
              emptyText: 'Nessun vincolo',
              cellBuilder: (context, r, c) => MacTextField(
                controller: _checks.rows[r].$2[c],
                small: true,
                mono: c == 1,
                onChanged: (_) => changed(),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Row security policy
// ---------------------------------------------------------------------------

/// A policy of [table]; returns it and whether to turn row security on
/// ([rowSecurityOn] false: it is off on the table).
Future<(PolicyDef, bool)?> showPolicyDialog(
  BuildContext context, {
  required SqlDialect dialect,
  required String table,
  String? catalog,
  String? schema,
  PolicyDef? initial,
  List<String> roles = const [],
  bool rowSecurityOn = true,
}) => showSheet<(PolicyDef, bool)>(
  context,
  size: SheetSize.large,
  builder: (_) => _PolicyDialog(
    dialect: dialect,
    table: table,
    catalog: catalog,
    schema: schema,
    initial: initial,
    roles: roles,
    rowSecurityOn: rowSecurityOn,
  ),
);

class _PolicyDialog extends StatefulWidget {
  const _PolicyDialog({
    required this.dialect,
    required this.table,
    this.catalog,
    this.schema,
    this.initial,
    required this.roles,
    required this.rowSecurityOn,
  });
  final SqlDialect dialect;
  final String table;
  final String? catalog;
  final String? schema;
  final PolicyDef? initial;
  final List<String> roles;
  final bool rowSecurityOn;

  @override
  State<_PolicyDialog> createState() => _PolicyDialogState();
}

class _PolicyDialogState extends State<_PolicyDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _using = TextEditingController(text: i?.using ?? '');
  late final _check = TextEditingController(text: i?.withCheck ?? '');
  late PolicyCommand _command = i?.command ?? PolicyCommand.all;
  late bool _permissive = i?.permissive ?? true;
  late final Set<String> _roles = {...?i?.roles};
  late bool _enable = !widget.rowSecurityOn;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _using, _check]) {
      c.dispose();
    }
    super.dispose();
  }

  PolicyDef get _current => PolicyDef(
    name: _name.text.trim(),
    table: widget.table,
    catalog: widget.catalog,
    schema: widget.schema,
    command: _command,
    permissive: _permissive,
    roles: [
      for (final r in {...widget.roles, ...?i?.roles})
        if (_roles.contains(r)) r,
    ],
    using: _command.hasUsing ? _text(_using) : null,
    withCheck: _command.hasCheck ? _text(_check) : null,
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return [
      ...(i == null ? ddl.createPolicy(_current) : ddl.alterPolicy(i!, _current)),
      if (_enable)
        ...ddl.setRowSecurity(
          widget.catalog,
          widget.schema,
          widget.table,
          const RowSecurity(),
          const RowSecurity(enabled: true),
        ),
    ];
  }

  void _save() {
    final c = _current;
    String? err;
    if (c.name.isEmpty) err = 'Inserisci il nome della policy';
    if (err == null && c.using == null && c.withCheck == null) err = 'Inserisci almeno una condizione';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, (c, _enable));
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    final roles = {...widget.roles, ...?i?.roles}.toList();
    return ExtraSheet(
      title: i == null ? 'Nuova policy' : 'Policy ${i!.name}',
      subtitle: [?widget.schema, widget.table].join('.'),
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      notice: widget.rowSecurityOn
          ? null
          : Notice(
              kind: NoticeKind.warning,
              message: 'La sicurezza a livello di riga è disattivata su ${widget.table}: le policy non hanno effetto.',
              child: CheckboxRow(
                value: _enable,
                label: 'Attivala insieme alla policy',
                onChanged: (v) => setState(() => _enable = v),
              ),
            ),
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: i == null, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Operazioni',
              child: PopUpButton<PolicyCommand>(
                value: _command,
                expand: true,
                items: [for (final c in PolicyCommand.values) (c, c.label, null)],
                onChanged: (c) => setState(() => _command = c),
              ),
            ),
            FormRow(
              label: 'Tipo',
              help: _permissive
                  ? 'Le policy permissive si sommano: basta che una ammetta la riga'
                  : 'Le policy restrittive devono essere tutte soddisfatte',
              child: Segmented<bool>(
                value: _permissive,
                items: const [(true, 'Permissiva', null), (false, 'Restrittiva', null)],
                onChanged: (v) => setState(() => _permissive = v),
              ),
            ),
            if (_command.hasUsing)
              FormRow(
                label: 'Righe visibili (USING)',
                help: 'Le righe esistenti a cui si applica',
                child: monoField(_using, hint: 'owner = current_user', changed: changed),
              ),
            if (_command.hasCheck)
              FormRow(
                label: 'Righe ammesse (WITH CHECK)',
                help: 'Le righe nuove o modificate devono rispettarla',
                child: monoField(_check, hint: 'owner = current_user', changed: changed),
              ),
          ],
        ),
        const SizedBox(height: Gap.md),
        SectionLabel('Ruoli (nessuno: tutti, PUBLIC)'),
        InsetBox(
          height: 130,
          child: roles.isEmpty
              ? Center(
                  child: Text(
                    'Nessun ruolo leggibile',
                    style: uiText(TypeSize.small, color: DbColors.of(context).textSecondary),
                  ),
                )
              : ListView(
                  children: [
                    for (final r in roles)
                      CheckboxRow(
                        small: true,
                        value: _roles.contains(r),
                        label: r,
                        onChanged: (v) => setState(() => v ? _roles.add(r) : _roles.remove(r)),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Exclusion constraint
// ---------------------------------------------------------------------------

Future<ExclusionDef?> showExclusionDialog(
  BuildContext context, {
  required SqlDialect dialect,
  required String table,
  String? catalog,
  String? schema,
  List<String> columns = const [],
  ExclusionDef? initial,
}) => showSheet<ExclusionDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _ExclusionDialog(
    dialect: dialect,
    table: table,
    catalog: catalog,
    schema: schema,
    columns: columns,
    initial: initial,
  ),
);

class _ExclusionDialog extends StatefulWidget {
  const _ExclusionDialog({
    required this.dialect,
    required this.table,
    this.catalog,
    this.schema,
    required this.columns,
    this.initial,
  });
  final SqlDialect dialect;
  final String table;
  final String? catalog;
  final String? schema;
  final List<String> columns;
  final ExclusionDef? initial;

  @override
  State<_ExclusionDialog> createState() => _ExclusionDialogState();
}

class _ExclusionDialogState extends State<_ExclusionDialog> {
  static const _operators = ['=', '&&', '<>', '-|-', '@>', '<@'];
  static const _methods = ['gist', 'spgist', 'btree', 'hash'];

  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? 'ex_${widget.table}');
  late final _where = TextEditingController(text: i?.where ?? '');
  late String _method = i?.method ?? 'gist';
  late bool _deferrable = i?.deferrable ?? false;
  late bool _deferred = i?.initiallyDeferred ?? false;
  late final _elements = FieldRows(2, [
    for (final e in i?.elements ?? const <ExclusionElement>[]) [e.expression, e.operator],
  ]);
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_elements.rows.isEmpty) _elements.add(['', '=']);
  }

  @override
  void dispose() {
    _name.dispose();
    _where.dispose();
    _elements.dispose();
    super.dispose();
  }

  ExclusionDef get _current => ExclusionDef(
    name: _name.text.trim(),
    table: widget.table,
    catalog: widget.catalog,
    schema: widget.schema,
    method: _method,
    elements: [
      for (final r in _elements.values)
        if (r[0].isNotEmpty) ExclusionElement(r[0], r[1].isEmpty ? '=' : r[1]),
    ],
    where: _text(_where),
    deferrable: _deferrable,
    initiallyDeferred: _deferrable && _deferred,
  );

  List<String> get _statements {
    final c = _current;
    if (c.name.isEmpty || c.elements.isEmpty) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return i == null ? ddl.addExclusion(c) : ddl.alterExclusion(i!, c);
  }

  void _save() {
    final c = _current;
    final err = c.name.isEmpty
        ? 'Inserisci il nome del vincolo'
        : c.elements.isEmpty
        ? 'Aggiungi almeno una colonna o espressione'
        : null;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    return ExtraSheet(
      title: i == null ? 'Nuovo vincolo di esclusione' : 'Vincolo ${i!.name}',
      subtitle: [?widget.schema, widget.table].join('.'),
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      notice: const Notice(
        kind: NoticeKind.info,
        message:
            'Due righe sono in conflitto quando tutti gli operatori risultano veri: sala = e periodo && vieta le '
            'prenotazioni sovrapposte. Con GiST, = su colonne semplici richiede l\'estensione btree_gist.',
      ),
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Metodo',
              child: PopUpButton<String>(
                value: _method,
                items: [for (final m in _methods) (m, m, null)],
                onChanged: (m) => setState(() => _method = m),
              ),
            ),
            FormRow(
              label: 'Solo le righe (WHERE)',
              child: monoField(_where, hint: 'not annullata', lines: 1, changed: changed),
            ),
            FormRow(
              label: 'Verifica',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CheckboxRow(
                    value: _deferrable,
                    label: 'Rimandabile (DEFERRABLE)',
                    onChanged: (v) => setState(() => _deferrable = v),
                  ),
                  CheckboxRow(
                    value: _deferred,
                    label: 'Alla fine della transazione (INITIALLY DEFERRED)',
                    onChanged: _deferrable ? (v) => setState(() => _deferred = v) : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        SectionLabel('Elementi'),
        SizedBox(
          height: gridHeight(_elements.rows.length),
          child: EditableGrid(
            columns: const [EditableGridColumn('Colonna o espressione'), EditableGridColumn('Operatore', width: 140)],
            rowCount: _elements.rows.length,
            rowKey: (r) => ValueKey(_elements.rows[r].$1),
            onAdd: () => setState(() => _elements.add(['', '='])),
            addLabel: 'Aggiungi elemento',
            onRemove: (r) => setState(() => _elements.remove(r)),
            onMove: (a, b) => setState(() => _elements.move(a, b)),
            cellBuilder: (context, r, c) => ComboField(
              controller: _elements.rows[r].$2[c],
              small: true,
              mono: true,
              options: () => c == 0 ? widget.columns : _operators,
              onChanged: (_) => changed(),
              onSelected: (_) => changed(),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Synonym
// ---------------------------------------------------------------------------

/// [pickTarget] lists the objects of a (catalog, schema) for "Scegli…".
Future<SynonymDef?> showSynonymDialog(
  BuildContext context, {
  required SqlDialect dialect,
  String? catalog,
  String? schema,
  SynonymDef? initial,
  Future<String?> Function(String? catalog, String? schema)? pickTarget,
}) => showSheet<SynonymDef>(
  context,
  builder: (_) =>
      _SynonymDialog(dialect: dialect, catalog: catalog, schema: schema, initial: initial, pickTarget: pickTarget),
);

class _SynonymDialog extends StatefulWidget {
  const _SynonymDialog({required this.dialect, this.catalog, this.schema, this.initial, this.pickTarget});
  final SqlDialect dialect;
  final String? catalog;
  final String? schema;
  final SynonymDef? initial;
  final Future<String?> Function(String? catalog, String? schema)? pickTarget;

  @override
  State<_SynonymDialog> createState() => _SynonymDialogState();
}

class _SynonymDialogState extends State<_SynonymDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _catalog = TextEditingController(text: i?.targetCatalog ?? '');
  late final _schema = TextEditingController(text: i?.targetSchema ?? widget.schema ?? '');
  late final _object = TextEditingController(text: i?.targetObject ?? '');
  late final _link = TextEditingController(text: i?.dbLink ?? '');
  late bool _public = i?.isPublic ?? false;
  String? _error;

  bool get _oracle => widget.dialect.family == DbFamily.oracle;

  @override
  void dispose() {
    for (final c in [_name, _catalog, _schema, _object, _link]) {
      c.dispose();
    }
    super.dispose();
  }

  SynonymDef get _current => SynonymDef(
    name: _name.text.trim(),
    catalog: widget.catalog,
    schema: _public ? null : widget.schema,
    targetCatalog: _oracle ? null : _text(_catalog),
    targetSchema: _text(_schema),
    targetObject: _object.text.trim(),
    dbLink: _oracle ? _text(_link) : null,
    isPublic: _oracle && _public,
  );

  List<String> get _statements {
    final c = _current;
    if (c.name.isEmpty || c.targetObject.isEmpty) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return i == null ? ddl.createSynonym(c) : ddl.alterSynonym(i!, c);
  }

  void _save() {
    final c = _current;
    final err = c.name.isEmpty
        ? 'Inserisci il nome del sinonimo'
        : c.targetObject.isEmpty
        ? 'Indica l\'oggetto a cui punta'
        : null;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    return ExtraSheet(
      title: i == null ? 'Nuovo sinonimo' : 'Sinonimo ${i!.name}',
      subtitle: widget.schema,
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: i == null, onChanged: (_) => changed()),
            ),
            if (_oracle)
              FormRow(
                label: 'Visibilità',
                child: CheckboxRow(
                  value: _public,
                  label: 'Pubblico: valido per tutti gli utenti (PUBLIC)',
                  onChanged: (v) => setState(() => _public = v),
                ),
              ),
          ],
        ),
        const SizedBox(height: Gap.md),
        FormGroup(
          title: 'Oggetto',
          children: [
            if (!_oracle)
              FormRow(
                label: 'Database',
                help: 'Vuoto: lo stesso del sinonimo',
                child: MacTextField(controller: _catalog, onChanged: (_) => changed()),
              ),
            FormRow(
              label: 'Schema',
              child: MacTextField(controller: _schema, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Nome',
              child: Row(
                children: [
                  Expanded(
                    child: MacTextField(controller: _object, onChanged: (_) => changed()),
                  ),
                  if (widget.pickTarget != null) ...[
                    const SizedBox(width: Gap.sm),
                    PushButton(
                      label: 'Scegli…',
                      size: ControlScale.small,
                      onPressed: () async {
                        final o = await widget.pickTarget!(_text(_catalog) ?? widget.catalog, _text(_schema));
                        if (o != null) setState(() => _object.text = o);
                      },
                    ),
                  ],
                ],
              ),
            ),
            if (_oracle)
              FormRow(
                label: 'Database link',
                help: 'Per un oggetto di un altro database',
                child: MacTextField(controller: _link, onChanged: (_) => changed()),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Event
// ---------------------------------------------------------------------------

/// [schedulerOn] false: the event scheduler is off and the event would not
/// run.
Future<EventDef?> showEventDialog(
  BuildContext context, {
  required SqlDialect dialect,
  String? catalog,
  EventDef? initial,
  bool? schedulerOn,
}) => showSheet<EventDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _EventDialog(dialect: dialect, catalog: catalog, initial: initial, schedulerOn: schedulerOn),
);

class _EventDialog extends StatefulWidget {
  const _EventDialog({required this.dialect, this.catalog, this.initial, this.schedulerOn});
  final SqlDialect dialect;
  final String? catalog;
  final EventDef? initial;
  final bool? schedulerOn;

  @override
  State<_EventDialog> createState() => _EventDialogState();
}

class _EventDialogState extends State<_EventDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _at = TextEditingController(text: i?.at ?? '');
  late final _every = TextEditingController(text: '${i?.every ?? 1}');
  late final _starts = TextEditingController(text: i?.starts ?? '');
  late final _ends = TextEditingController(text: i?.ends ?? '');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late final _body = TextEditingController(text: i?.body ?? '');
  late bool _recurring = i?.recurring ?? true;
  late String _unit = i?.unit ?? 'DAY';
  late bool _preserve = i?.preserve ?? false;
  late EventStatus _status = i?.status ?? EventStatus.enabled;
  String? _error;

  static const _units = {
    'SECOND': 'secondi',
    'MINUTE': 'minuti',
    'HOUR': 'ore',
    'DAY': 'giorni',
    'WEEK': 'settimane',
    'MONTH': 'mesi',
    'QUARTER': 'trimestri',
    'YEAR': 'anni',
  };

  @override
  void dispose() {
    for (final c in [_name, _at, _every, _starts, _ends, _comment, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  EventDef get _current => EventDef(
    name: _name.text.trim(),
    catalog: widget.catalog,
    at: _recurring ? null : _text(_at),
    every: _recurring ? int.tryParse(_every.text.trim()) : null,
    unit: _unit,
    starts: _recurring ? _text(_starts) : null,
    ends: _recurring ? _text(_ends) : null,
    preserve: _preserve,
    status: _status,
    comment: _text(_comment),
    body: _body.text,
  );

  List<String> get _statements {
    final c = _current;
    if (c.name.isEmpty || c.body.trim().isEmpty || (!_recurring && c.at == null)) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return i == null ? ddl.createEvent(c) : ddl.alterEvent(i!, c);
  }

  static final _ts = RegExp(r'^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$');

  void _save() {
    final c = _current;
    String? err;
    if (c.name.isEmpty) err = 'Inserisci il nome dell\'evento';
    if (err == null && !_recurring && (c.at == null || !_ts.hasMatch(c.at!))) {
      err = 'Indica quando: AAAA-MM-GG hh:mm:ss';
    }
    if (err == null && _recurring && (c.every == null || c.every! <= 0)) err = 'L\'intervallo deve essere positivo';
    for (final t in [c.starts, c.ends]) {
      if (err == null && t != null && !_ts.hasMatch(t)) err = 'Data non valida: $t (AAAA-MM-GG hh:mm:ss)';
    }
    if (err == null && c.body.trim().isEmpty) err = 'Scrivi l\'istruzione da eseguire';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    return ExtraSheet(
      title: i == null ? 'Nuovo evento' : 'Evento ${i!.name}',
      subtitle: widget.catalog,
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      notice: widget.schedulerOn == false
          ? const Notice(
              kind: NoticeKind.warning,
              message: 'Lo scheduler degli eventi è spento (event_scheduler = OFF): l\'evento non verrà eseguito.',
            )
          : null,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: i == null, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Esecuzione',
              child: Segmented<bool>(
                value: _recurring,
                items: const [(false, 'Una volta', null), (true, 'Ricorrente', null)],
                onChanged: (v) => setState(() => _recurring = v),
              ),
            ),
            if (!_recurring)
              FormRow(
                label: 'Quando',
                child: MacTextField(
                  controller: _at,
                  hint: 'AAAA-MM-GG hh:mm:ss',
                  tabular: true,
                  onChanged: (_) => changed(),
                ),
              )
            else ...[
              FormRow(
                label: 'Ogni',
                child: Row(
                  children: [
                    NumberField(controller: _every, min: 1, onChanged: (_) => changed()),
                    const SizedBox(width: Gap.sm),
                    PopUpButton<String>(
                      value: _unit,
                      items: [for (final e in _units.entries) (e.key, e.value, null)],
                      onChanged: (u) => setState(() => _unit = u),
                    ),
                  ],
                ),
              ),
              FormRow(
                label: 'Dal',
                help: 'Vuoto: da subito',
                child: MacTextField(
                  controller: _starts,
                  hint: 'AAAA-MM-GG hh:mm:ss',
                  tabular: true,
                  onChanged: (_) => changed(),
                ),
              ),
              FormRow(
                label: 'Al',
                help: 'Vuoto: senza fine',
                child: MacTextField(
                  controller: _ends,
                  hint: 'AAAA-MM-GG hh:mm:ss',
                  tabular: true,
                  onChanged: (_) => changed(),
                ),
              ),
            ],
            FormRow(
              label: 'Stato',
              child: PopUpButton<EventStatus>(
                value: _status,
                items: [for (final s in EventStatus.values) (s, s.label, null)],
                onChanged: (s) => setState(() => _status = s),
              ),
            ),
            FormRow(
              label: 'Al termine',
              child: CheckboxRow(
                value: _preserve,
                label: 'Conserva l\'evento dopo l\'ultima esecuzione',
                onChanged: (v) => setState(() => _preserve = v),
              ),
            ),
            FormRow(
              label: 'Commento',
              child: MacTextField(controller: _comment, onChanged: (_) => changed()),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        SectionLabel('Istruzione (una istruzione o BEGIN … END)'),
        monoField(_body, hint: 'DELETE FROM log WHERE creato < NOW() - INTERVAL 30 DAY', lines: 7, changed: changed),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Snowflake warehouse
// ---------------------------------------------------------------------------

Future<WarehouseDef?> showWarehouseDialog(BuildContext context, {required SqlDialect dialect, WarehouseDef? initial}) =>
    showSheet<WarehouseDef>(
      context,
      builder: (_) => _WarehouseDialog(dialect: dialect, initial: initial),
    );

class _WarehouseDialog extends StatefulWidget {
  const _WarehouseDialog({required this.dialect, this.initial});
  final SqlDialect dialect;
  final WarehouseDef? initial;

  @override
  State<_WarehouseDialog> createState() => _WarehouseDialogState();
}

class _WarehouseDialogState extends State<_WarehouseDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _suspend = TextEditingController(text: '${i?.autoSuspend ?? 600}');
  late final _min = TextEditingController(text: '${i?.minClusters ?? 1}');
  late final _max = TextEditingController(text: '${i?.maxClusters ?? 1}');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late String _size = i?.size ?? 'XSMALL';
  late String _type = i?.type ?? 'STANDARD';
  late String _policy = i?.scalingPolicy ?? 'STANDARD';
  late bool _resume = i?.autoResume ?? true;
  late bool _initiallySuspended = true;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _suspend, _min, _max, _comment]) {
      c.dispose();
    }
    super.dispose();
  }

  WarehouseDef get _current => WarehouseDef(
    name: _name.text.trim(),
    size: _size,
    type: i == null && _type == 'STANDARD' ? null : _type,
    autoSuspend: int.tryParse(_suspend.text.trim()),
    autoResume: _resume,
    minClusters: int.tryParse(_min.text.trim()),
    maxClusters: int.tryParse(_max.text.trim()),
    scalingPolicy: _policy,
    initiallySuspended: _initiallySuspended,
    comment: _text(_comment),
  );

  /// Values left at the Snowflake defaults are not written in a new one.
  WarehouseDef get _forCreate {
    final c = _current;
    return WarehouseDef(
      name: c.name,
      size: c.size,
      type: c.type,
      autoSuspend: c.autoSuspend == 600 ? null : c.autoSuspend,
      autoResume: c.autoResume,
      minClusters: c.minClusters == 1 ? null : c.minClusters,
      maxClusters: c.maxClusters == 1 ? null : c.maxClusters,
      scalingPolicy: c.scalingPolicy == 'STANDARD' ? null : c.scalingPolicy,
      initiallySuspended: c.initiallySuspended,
      comment: c.comment,
    );
  }

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return i == null ? ddl.createWarehouse(_forCreate) : ddl.alterWarehouse(i!, _current);
  }

  void _save() {
    final c = _current;
    String? err;
    if (c.name.isEmpty) err = 'Inserisci il nome del warehouse';
    if (err == null && (c.minClusters ?? 1) > (c.maxClusters ?? 1)) err = 'Il minimo di cluster supera il massimo';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, i == null ? _forCreate : c);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    return ExtraSheet(
      title: i == null ? 'Nuovo warehouse' : 'Warehouse ${i!.name}',
      subtitle: i?.state?.toLowerCase(),
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: i == null, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Dimensione',
              child: PopUpButton<String>(
                value: _size,
                items: [for (final s in warehouseSizes) (s, s, null)],
                onChanged: (s) => setState(() => _size = s),
              ),
            ),
            FormRow(
              label: 'Tipo',
              child: PopUpButton<String>(
                value: _type,
                items: const [('STANDARD', 'Standard', null), ('SNOWPARK-OPTIMIZED', 'Ottimizzato per Snowpark', null)],
                onChanged: i == null ? (t) => setState(() => _type = t) : null,
              ),
            ),
            FormRow(
              label: 'Sospensione automatica',
              help: 'Secondi di inattività (0: mai)',
              child: Align(
                alignment: Alignment.centerLeft,
                child: NumberField(controller: _suspend, min: 0, unit: 's', onChanged: (_) => changed()),
              ),
            ),
            FormRow(
              label: 'Ripresa',
              child: CheckboxRow(
                value: _resume,
                label: 'Riprendi da solo alla prima query',
                onChanged: (v) => setState(() => _resume = v),
              ),
            ),
            if (i == null)
              FormRow(
                label: 'Creazione',
                child: CheckboxRow(
                  value: _initiallySuspended,
                  label: 'Crealo sospeso (nessun costo finché non serve)',
                  onChanged: (v) => setState(() => _initiallySuspended = v),
                ),
              ),
          ],
        ),
        const SizedBox(height: Gap.md),
        FormGroup(
          title: 'Multi-cluster',
          children: [
            FormRow(
              label: 'Cluster',
              child: Row(
                children: [
                  NumberField(controller: _min, min: 1, max: 300, onChanged: (_) => changed()),
                  const SizedBox(width: Gap.sm),
                  Text('–', style: uiText(TypeSize.body, color: DbColors.of(context).textSecondary)),
                  const SizedBox(width: Gap.sm),
                  NumberField(controller: _max, min: 1, max: 300, onChanged: (_) => changed()),
                ],
              ),
            ),
            FormRow(
              label: 'Politica',
              child: PopUpButton<String>(
                value: _policy,
                items: const [('STANDARD', 'Standard (prestazioni)', null), ('ECONOMY', 'Economy (costi)', null)],
                onChanged: (p) => setState(() => _policy = p),
              ),
            ),
            FormRow(
              label: 'Commento',
              child: MacTextField(controller: _comment, onChanged: (_) => changed()),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Snowflake stage
// ---------------------------------------------------------------------------

Future<StageDef?> showStageDialog(
  BuildContext context, {
  required SqlDialect dialect,
  String? catalog,
  String? schema,
  StageDef? initial,
  List<String> fileFormats = const [],
}) => showSheet<StageDef>(
  context,
  builder: (_) =>
      _StageDialog(dialect: dialect, catalog: catalog, schema: schema, initial: initial, fileFormats: fileFormats),
);

class _StageDialog extends StatefulWidget {
  const _StageDialog({required this.dialect, this.catalog, this.schema, this.initial, required this.fileFormats});
  final SqlDialect dialect;
  final String? catalog;
  final String? schema;
  final StageDef? initial;
  final List<String> fileFormats;

  @override
  State<_StageDialog> createState() => _StageDialogState();
}

class _StageDialogState extends State<_StageDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _url = TextEditingController(text: i?.url ?? '');
  late final _integration = TextEditingController(text: i?.storageIntegration ?? '');
  late final _format = TextEditingController(text: i?.fileFormat ?? '');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late bool _external = i?.external ?? false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _url, _integration, _format, _comment]) {
      c.dispose();
    }
    super.dispose();
  }

  StageDef get _current => StageDef(
    name: _name.text.trim(),
    catalog: widget.catalog,
    schema: widget.schema,
    url: _external ? _text(_url) : null,
    storageIntegration: _external ? _text(_integration) : null,
    fileFormat: _text(_format),
    comment: _text(_comment),
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return i == null ? ddl.createStage(_current) : ddl.alterStage(i!, _current);
  }

  void _save() {
    final c = _current;
    String? err;
    if (c.name.isEmpty) err = 'Inserisci il nome dello stage';
    if (err == null && _external && c.url == null) err = 'Indica l\'indirizzo dello stage esterno';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    return ExtraSheet(
      title: i == null ? 'Nuovo stage' : 'Stage ${i!.name}',
      subtitle: [?widget.catalog, ?widget.schema].join('.'),
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: i == null, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Tipo',
              child: Segmented<bool>(
                value: _external,
                items: const [(false, 'Interno', null), (true, 'Esterno', null)],
                onChanged: i == null ? (v) => setState(() => _external = v) : null,
              ),
            ),
            if (_external) ...[
              FormRow(
                label: 'Indirizzo',
                child: MacTextField(controller: _url, hint: 's3://bucket/cartella/', onChanged: (_) => changed()),
              ),
              FormRow(
                label: 'Integrazione',
                help: 'Storage integration con le credenziali del cloud',
                child: MacTextField(controller: _integration, onChanged: (_) => changed()),
              ),
            ],
            FormRow(
              label: 'Formato di file',
              child: ComboField(
                controller: _format,
                options: () => widget.fileFormats,
                onChanged: (_) => changed(),
                onSelected: (_) => changed(),
              ),
            ),
            FormRow(
              label: 'Commento',
              child: MacTextField(controller: _comment, onChanged: (_) => changed()),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Snowflake file format
// ---------------------------------------------------------------------------

Future<FileFormatDef?> showFileFormatDialog(
  BuildContext context, {
  required SqlDialect dialect,
  String? catalog,
  String? schema,
  FileFormatDef? initial,
}) => showSheet<FileFormatDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _FileFormatDialog(dialect: dialect, catalog: catalog, schema: schema, initial: initial),
);

class _FileFormatDialog extends StatefulWidget {
  const _FileFormatDialog({required this.dialect, this.catalog, this.schema, this.initial});
  final SqlDialect dialect;
  final String? catalog;
  final String? schema;
  final FileFormatDef? initial;

  @override
  State<_FileFormatDialog> createState() => _FileFormatDialogState();
}

class _FileFormatDialogState extends State<_FileFormatDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late String _type = i?.type ?? 'CSV';
  late final Map<String, String> _options = {...?i?.options};
  final Map<String, TextEditingController> _fields = {};
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _comment.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(String key) =>
      _fields.putIfAbsent(key, () => TextEditingController(text: _options[key] ?? ''));

  void _set(String key, String? v) => setState(() => v == null || v.isEmpty ? _options.remove(key) : _options[key] = v);

  FileFormatDef get _current => FileFormatDef(
    name: _name.text.trim(),
    catalog: widget.catalog,
    schema: widget.schema,
    type: _type,
    options: {
      for (final o in fileFormatOptions(_type))
        if (_options[o.key] != null) o.key: _options[o.key]!,
    },
    comment: _text(_comment),
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    final ddl = ExtraDdl(widget.dialect);
    return i == null ? ddl.createFileFormat(_current) : ddl.alterFileFormat(i!, _current);
  }

  void _save() {
    final c = _current;
    String? err;
    if (c.name.isEmpty) err = 'Inserisci il nome del formato';
    for (final o in fileFormatOptions(_type)) {
      final v = c.options[o.key];
      if (err == null && o.kind == FileOptionKind.number && v != null && int.tryParse(v) == null) {
        err = '${o.label} deve essere un numero';
      }
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  Widget _option(FileFormatOption o) => switch (o.kind) {
    FileOptionKind.boolean => PopUpButton<String?>(
      value: _options[o.key],
      items: const [(null, 'Predefinito', null), ('TRUE', 'Sì', null), ('FALSE', 'No', null)],
      onChanged: (v) => _set(o.key, v),
    ),
    FileOptionKind.choice => PopUpButton<String?>(
      value: _options[o.key],
      items: [(null, 'Predefinita', null), for (final c in o.choices) (c, c, null)],
      onChanged: (v) => _set(o.key, v),
    ),
    _ => MacTextField(
      controller: _field(o.key),
      hint: o.hint,
      mono: o.kind == FileOptionKind.text,
      tabular: o.kind == FileOptionKind.number,
      onChanged: (v) => _set(o.key, v.trim().isEmpty ? null : (o.kind == FileOptionKind.number ? v.trim() : v)),
    ),
  };

  @override
  Widget build(BuildContext context) {
    return ExtraSheet(
      title: i == null ? 'Nuovo formato di file' : 'Formato ${i!.name}',
      subtitle: [?widget.catalog, ?widget.schema].join('.'),
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: i == null, onChanged: (_) => setState(() {})),
            ),
            FormRow(
              label: 'Tipo',
              help: i != null ? 'Cambiando tipo il formato viene ricreato' : null,
              child: PopUpButton<String>(
                value: _type,
                items: [for (final t in fileFormatTypes) (t, t, null)],
                onChanged: (t) => setState(() => _type = t),
              ),
            ),
            FormRow(
              label: 'Commento',
              child: MacTextField(controller: _comment, onChanged: (_) => setState(() {})),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        FormGroup(
          title: 'Opzioni',
          children: [for (final o in fileFormatOptions(_type)) FormRow(label: o.label, child: _option(o))],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Row level security switches
// ---------------------------------------------------------------------------

Future<RowSecurity?> showRowSecurityDialog(
  BuildContext context, {
  required SqlDialect dialect,
  required String table,
  String? catalog,
  String? schema,
  required RowSecurity initial,
}) => showSheet<RowSecurity>(
  context,
  builder: (_) =>
      _RowSecurityDialog(dialect: dialect, table: table, catalog: catalog, schema: schema, initial: initial),
);

class _RowSecurityDialog extends StatefulWidget {
  const _RowSecurityDialog({
    required this.dialect,
    required this.table,
    this.catalog,
    this.schema,
    required this.initial,
  });
  final SqlDialect dialect;
  final String table;
  final String? catalog;
  final String? schema;
  final RowSecurity initial;

  @override
  State<_RowSecurityDialog> createState() => _RowSecurityDialogState();
}

class _RowSecurityDialogState extends State<_RowSecurityDialog> {
  late bool _enabled = widget.initial.enabled;
  late bool _forced = widget.initial.forced;

  RowSecurity get _current => RowSecurity(enabled: _enabled, forced: _forced);

  @override
  Widget build(BuildContext context) {
    return ExtraSheet(
      title: 'Sicurezza a livello di riga',
      subtitle: [?widget.schema, widget.table].join('.'),
      isNew: false,
      statements: ExtraDdl(widget.dialect)
          .setRowSecurity(widget.catalog, widget.schema, widget.table, widget.initial, _current),
      onSave: () => Navigator.pop(context, _current),
      children: [
        FormGroup(
          footer: 'Senza policy, con la sicurezza attiva nessuna riga è visibile agli utenti diversi dal proprietario.',
          children: [
            CheckboxRow(
              value: _enabled,
              label: 'Attiva (ENABLE ROW LEVEL SECURITY)',
              onChanged: (v) => setState(() => _enabled = v),
            ),
            CheckboxRow(
              value: _forced,
              label: 'Applica anche al proprietario (FORCE)',
              onChanged: (v) => setState(() => _forced = v),
            ),
          ],
        ),
      ],
    );
  }
}
