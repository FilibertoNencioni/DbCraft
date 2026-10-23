// Sheets of databases and schemas, and the confirmation sheet of every DROP.

import 'package:flutter/material.dart';

import '../../../services/sql_dialect.dart';
import '../../../ui/widgets/common.dart';
import '../catalog/databases.dart';
import '../ddl/object_ddl.dart';
import '../model/object_defs.dart';

String? _text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

/// Live script preview under the form of a sheet.
class _ScriptPreview extends StatelessWidget {
  const _ScriptPreview(this.statements);
  final List<String> statements;

  @override
  Widget build(BuildContext context) {
    final script = [for (final s in statements) s.trimLeft().startsWith('--') ? s : '$s;'].join('\n');
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: CodeBox(script.isEmpty ? '-- Nessuna modifica' : script, copy: false),
    );
  }
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

/// Creates ([initial] null) or edits a database. [taken] are the names in
/// use; [choices] are offered in the fields.
Future<DatabaseDef?> showDatabaseDialog(
  BuildContext context, {
  required SqlDialect dialect,
  DatabaseDef? initial,
  DatabaseChoices choices = DatabaseChoices.none,
  Set<String> taken = const {},
}) => showSheet<DatabaseDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _DatabaseDialog(dialect: dialect, initial: initial, choices: choices, taken: taken),
);

class _DatabaseDialog extends StatefulWidget {
  const _DatabaseDialog({required this.dialect, required this.initial, required this.choices, required this.taken});
  final SqlDialect dialect;
  final DatabaseDef? initial;
  final DatabaseChoices choices;
  final Set<String> taken;

  @override
  State<_DatabaseDialog> createState() => _DatabaseDialogState();
}

class _DatabaseDialogState extends State<_DatabaseDialog> {
  late final DatabaseDef? i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _owner = TextEditingController(text: i?.owner ?? '');
  late final _encoding = TextEditingController(text: i?.encoding ?? '');
  late final _collation = TextEditingController(text: i?.collation ?? '');
  late final _ctype = TextEditingController(text: i?.ctype ?? '');
  late final _template = TextEditingController(text: i?.template ?? '');
  late final _tablespace = TextEditingController(text: i?.tablespace ?? '');
  late final _limit = TextEditingController(
    text: i?.connectionLimit == null || i!.connectionLimit! < 0 ? '' : '${i!.connectionLimit}',
  );
  late final _retention = TextEditingController(text: i?.retentionDays == null ? '' : '${i!.retentionDays}');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late String? _recovery = i?.recoveryModel;
  late bool _transient = i?.transient ?? false;
  String? _error;

  bool get _new => i == null;
  DbFamily get family => widget.dialect.family;

  @override
  void dispose() {
    for (final c in [
      _name,
      _owner,
      _encoding,
      _collation,
      _ctype,
      _template,
      _tablespace,
      _limit,
      _retention,
      _comment,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  DatabaseDef get _current => DatabaseDef(
    name: _name.text.trim(),
    owner: _text(_owner),
    encoding: _text(_encoding),
    collation: _text(_collation),
    ctype: _text(_ctype),
    template: _text(_template),
    tablespace: _text(_tablespace),
    connectionLimit: int.tryParse(_limit.text.trim()),
    recoveryModel: _recovery,
    transient: _transient,
    retentionDays: int.tryParse(_retention.text.trim()),
    comment: _text(_comment),
  );

  List<String> get _statements {
    final ddl = ObjectDdl(widget.dialect);
    if (_name.text.trim().isEmpty) return const [];
    return _new ? ddl.createDatabase(_current) : ddl.alterDatabase(i!, _current);
  }

  void _save() {
    final n = _name.text.trim();
    String? err;
    if (n.isEmpty) err = 'Inserisci il nome del database';
    if (err == null && n.toLowerCase() != i?.name.toLowerCase() && widget.taken.contains(n.toLowerCase())) {
      err = 'Esiste già un database "$n"';
    }
    if (err == null && _limit.text.trim().isNotEmpty && int.tryParse(_limit.text.trim()) == null) {
      err = 'Il limite di connessioni deve essere un numero';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, _current);
  }

  Widget _combo(TextEditingController c, List<String> options, {String? hint, bool enabled = true}) => ComboField(
    controller: c,
    hint: hint,
    enabled: enabled,
    options: () => options,
    onChanged: (_) => setState(() {}),
    onSelected: (_) => setState(() {}),
  );

  @override
  Widget build(BuildContext context) {
    final ch = widget.choices;
    final mysqlCollations = _encoding.text.trim().isEmpty
        ? ch.collations
        : ch.collations.where((x) => x.toLowerCase().startsWith('${_encoding.text.trim().toLowerCase()}_')).toList();
    return SheetScaffold(
      title: _new ? 'Nuovo database' : 'Proprietà del database ${i!.name}',
      subtitle: widget.dialect.dbmsName,
      onSubmit: _save,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormGroup(
              children: [
                FormRow(
                  label: 'Nome',
                  child: MacTextField(controller: _name, autofocus: _new, onChanged: (_) => setState(() {})),
                ),
                if (family == DbFamily.postgres) ...[
                  FormRow(
                    label: 'Proprietario',
                    child: _combo(_owner, ch.owners, hint: 'utente corrente'),
                  ),
                  if (_new)
                    FormRow(
                      label: 'Modello',
                      child: _combo(_template, ch.templates, hint: 'template1'),
                    ),
                  FormRow(
                    label: 'Codifica',
                    help: _new ? null : 'Non modificabile dopo la creazione',
                    child: _combo(_encoding, ch.encodings, hint: 'predefinita', enabled: _new),
                  ),
                  FormRow(
                    label: 'Collation',
                    child: _combo(_collation, ch.collations, hint: 'predefinita', enabled: _new),
                  ),
                  FormRow(
                    label: 'Classificazione (CTYPE)',
                    child: _combo(_ctype, ch.collations, hint: 'predefinita', enabled: _new),
                  ),
                  FormRow(
                    label: 'Tablespace',
                    child: _combo(_tablespace, ch.tablespaces, hint: 'pg_default'),
                  ),
                  FormRow(
                    label: 'Limite connessioni',
                    child: MacTextField(
                      controller: _limit,
                      tabular: true,
                      hint: 'nessuno',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
                if (family == DbFamily.sqlServer) ...[
                  FormRow(
                    label: 'Collation',
                    child: _combo(_collation, ch.collations, hint: 'predefinita del server'),
                  ),
                  FormRow(
                    label: 'Modello di recupero',
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: PopUpButton<String?>(
                        value: _recovery,
                        items: const [
                          (null, 'Predefinito (dal database model)', null),
                          ('FULL', 'Completo (FULL)', null),
                          ('SIMPLE', 'Semplice (SIMPLE)', null),
                          ('BULK_LOGGED', 'Registrazione minima (BULK_LOGGED)', null),
                        ],
                        onChanged: (v) => setState(() => _recovery = v),
                      ),
                    ),
                  ),
                  FormRow(
                    label: 'Proprietario',
                    child: _combo(_owner, ch.owners, hint: 'login corrente'),
                  ),
                ],
                if (family == DbFamily.mysql) ...[
                  FormRow(
                    label: 'Set di caratteri',
                    child: _combo(_encoding, ch.encodings, hint: 'utf8mb4'),
                  ),
                  FormRow(
                    label: 'Collation',
                    child: _combo(_collation, mysqlCollations, hint: 'predefinita del set'),
                  ),
                ],
                if (family == DbFamily.snowflake) ...[
                  if (_new)
                    FormRow(
                      label: 'Tipo',
                      help: 'Senza fail-safe: costa meno, i dati non sono recuperabili dopo la Time Travel',
                      child: CheckboxRow(
                        value: _transient,
                        label: 'Database transient',
                        onChanged: (v) => setState(() => _transient = v),
                      ),
                    ),
                  FormRow(
                    label: 'Time Travel (giorni)',
                    child: MacTextField(
                      controller: _retention,
                      tabular: true,
                      hint: '1',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
                if (family == DbFamily.postgres || family == DbFamily.snowflake || widget.dialect.isMariaDb)
                  FormRow(
                    label: 'Commento',
                    child: MacTextField(controller: _comment, maxLines: 2, onChanged: (_) => setState(() {})),
                  ),
              ],
            ),
            _ScriptPreview(_statements),
          ],
        ),
      ),
      leading: [if (_error != null) Flexible(child: StatusLine(_error!, kind: StatusKind.danger))],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: _new ? 'Crea' : 'Applica', onPressed: _save),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

Future<SchemaDef?> showSchemaDialog(
  BuildContext context, {
  required SqlDialect dialect,
  String? catalog,
  SchemaDef? initial,
  List<String> owners = const [],
  Set<String> taken = const {},
}) => showSheet<SchemaDef>(
  context,
  builder: (_) => _SchemaDialog(dialect: dialect, catalog: catalog, initial: initial, owners: owners, taken: taken),
);

class _SchemaDialog extends StatefulWidget {
  const _SchemaDialog({
    required this.dialect,
    required this.catalog,
    required this.initial,
    required this.owners,
    required this.taken,
  });
  final SqlDialect dialect;
  final String? catalog;
  final SchemaDef? initial;
  final List<String> owners;
  final Set<String> taken;

  @override
  State<_SchemaDialog> createState() => _SchemaDialogState();
}

class _SchemaDialogState extends State<_SchemaDialog> {
  late final SchemaDef? i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _owner = TextEditingController(text: i?.owner ?? '');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late final _retention = TextEditingController(text: i?.retentionDays == null ? '' : '${i!.retentionDays}');
  late bool _transient = i?.transient ?? false;
  String? _error;

  bool get _new => i == null;
  DbFamily get family => widget.dialect.family;

  @override
  void dispose() {
    for (final c in [_name, _owner, _comment, _retention]) {
      c.dispose();
    }
    super.dispose();
  }

  SchemaDef get _current => SchemaDef(
    name: _name.text.trim(),
    catalog: widget.catalog,
    owner: _text(_owner),
    comment: _text(_comment),
    transient: _transient,
    retentionDays: int.tryParse(_retention.text.trim()),
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    final ddl = ObjectDdl(widget.dialect);
    return _new ? ddl.createSchema(_current) : ddl.alterSchema(i!, _current);
  }

  void _save() {
    final n = _name.text.trim();
    String? err;
    if (n.isEmpty) err = 'Inserisci il nome dello schema';
    if (err == null && n.toLowerCase() != i?.name.toLowerCase() && widget.taken.contains(n.toLowerCase())) {
      err = 'Esiste già uno schema "$n"';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, _current);
  }

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: _new ? 'Nuovo schema' : 'Proprietà dello schema ${i!.name}',
      subtitle: widget.catalog == null ? widget.dialect.dbmsName : 'Database ${widget.catalog}',
      onSubmit: _save,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FormGroup(
            children: [
              FormRow(
                label: 'Nome',
                child: MacTextField(controller: _name, autofocus: _new, onChanged: (_) => setState(() {})),
              ),
              if (family != DbFamily.snowflake)
                FormRow(
                  label: 'Proprietario',
                  child: ComboField(
                    controller: _owner,
                    hint: 'utente corrente',
                    options: () => widget.owners,
                    onChanged: (_) => setState(() {}),
                    onSelected: (_) => setState(() {}),
                  ),
                ),
              if (family == DbFamily.snowflake) ...[
                if (_new)
                  FormRow(
                    label: 'Tipo',
                    child: CheckboxRow(
                      value: _transient,
                      label: 'Schema transient',
                      onChanged: (v) => setState(() => _transient = v),
                    ),
                  ),
                FormRow(
                  label: 'Time Travel (giorni)',
                  child: MacTextField(
                    controller: _retention,
                    tabular: true,
                    hint: '1',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
              FormRow(
                label: 'Commento',
                child: MacTextField(controller: _comment, maxLines: 2, onChanged: (_) => setState(() {})),
              ),
            ],
          ),
          _ScriptPreview(_statements),
        ],
      ),
      leading: [if (_error != null) Flexible(child: StatusLine(_error!, kind: StatusKind.danger))],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: _new ? 'Crea' : 'Applica', onPressed: _save),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Drop
// ---------------------------------------------------------------------------

/// Option of [showDropDialog] (CASCADE, close the sessions…).
class DropOption {
  const DropOption(this.id, this.label, {this.help, this.initial = false});
  final String id;
  final String label;
  final String? help;
  final bool initial;
}

/// Confirms the drop of [objectLabel] (e.g. "il database vendite"). With
/// [confirmName] the user must type it; [details] lists what goes with it.
/// Returns the chosen [options] ids, or null when cancelled.
Future<Set<String>?> showDropDialog(
  BuildContext context, {
  required String title,
  required String objectLabel,
  String? confirmName,
  List<String> details = const [],
  List<DropOption> options = const [],
}) => showSheet<Set<String>>(
  context,
  builder: (_) =>
      _DropDialog(title: title, objectLabel: objectLabel, confirmName: confirmName, details: details, options: options),
);

class _DropDialog extends StatefulWidget {
  const _DropDialog({
    required this.title,
    required this.objectLabel,
    this.confirmName,
    required this.details,
    required this.options,
  });
  final String title;
  final String objectLabel;
  final String? confirmName;
  final List<String> details;
  final List<DropOption> options;

  @override
  State<_DropDialog> createState() => _DropDialogState();
}

class _DropDialogState extends State<_DropDialog> {
  final _typed = TextEditingController();
  late final Set<String> _on = {
    for (final o in widget.options)
      if (o.initial) o.id,
  };

  bool get _ready => widget.confirmName == null || _typed.text.trim() == widget.confirmName;

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  void _drop() {
    if (_ready) Navigator.pop(context, _on);
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return SheetScaffold(
      title: widget.title,
      onSubmit: _drop,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Notice(
            kind: NoticeKind.danger,
            message: 'Stai per eliminare ${widget.objectLabel}. L\'operazione non si può annullare.',
          ),
          if (widget.details.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            for (final d in widget.details)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('• $d', style: uiText(TypeSize.small, color: c.textSecondary)),
              ),
          ],
          if (widget.options.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            for (final o in widget.options)
              CheckboxRow(
                value: _on.contains(o.id),
                label: o.label,
                help: o.help,
                onChanged: (v) => setState(() => v ? _on.add(o.id) : _on.remove(o.id)),
              ),
          ],
          if (widget.confirmName != null) ...[
            const SizedBox(height: Gap.md),
            Text('Per confermare scrivi ${widget.confirmName}', style: uiText(TypeSize.small, color: c.text)),
            const SizedBox(height: Gap.xs),
            MacTextField(controller: _typed, autofocus: true, mono: true, onChanged: (_) => setState(() {})),
          ],
        ],
      ),
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton(label: 'Elimina', kind: PushButtonKind.destructive, onPressed: _ready ? _drop : null),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sequence
// ---------------------------------------------------------------------------

Future<SequenceDef?> showSequenceDialog(
  BuildContext context, {
  required SqlDialect dialect,
  String? catalog,
  String? schema,
  SequenceDef? initial,
  Set<String> taken = const {},
}) => showSheet<SequenceDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _SequenceDialog(dialect: dialect, catalog: catalog, schema: schema, initial: initial, taken: taken),
);

class _SequenceDialog extends StatefulWidget {
  const _SequenceDialog({
    required this.dialect,
    required this.catalog,
    required this.schema,
    required this.initial,
    required this.taken,
  });
  final SqlDialect dialect;
  final String? catalog;
  final String? schema;
  final SequenceDef? initial;
  final Set<String> taken;

  @override
  State<_SequenceDialog> createState() => _SequenceDialogState();
}

class _SequenceDialogState extends State<_SequenceDialog> {
  late final SequenceDef? i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _type = TextEditingController(text: i?.dataType ?? '');
  late final _start = TextEditingController(text: '${i?.start ?? 1}');
  late final _inc = TextEditingController(text: '${i?.increment ?? 1}');
  late final _min = TextEditingController(text: i?.minValue == null ? '' : '${i!.minValue}');
  late final _max = TextEditingController(text: i?.maxValue == null ? '' : '${i!.maxValue}');
  late final _cache = TextEditingController(text: i?.cache == null ? '' : '${i!.cache}');
  late final _owned = TextEditingController(text: i?.ownedBy ?? '');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late bool _cycle = i?.cycle ?? false;
  String? _error;

  bool get _new => i == null;
  DbFamily get family => widget.dialect.family;

  @override
  void dispose() {
    for (final c in [_name, _type, _start, _inc, _min, _max, _cache, _owned, _comment]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _int(TextEditingController c) => int.tryParse(c.text.trim());

  SequenceDef get _current => SequenceDef(
    catalog: widget.catalog,
    schema: widget.schema,
    name: _name.text.trim(),
    dataType: _text(_type),
    start: _int(_start),
    increment: _int(_inc),
    minValue: _int(_min),
    maxValue: _int(_max),
    cycle: _cycle,
    cache: _int(_cache),
    ownedBy: _text(_owned),
    comment: _text(_comment),
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    final ddl = ObjectDdl(widget.dialect);
    return _new ? ddl.createSequence(_current) : ddl.alterSequence(i!, _current);
  }

  void _save() {
    final n = _name.text.trim();
    String? err;
    if (n.isEmpty) err = 'Inserisci il nome della sequenza';
    if (err == null && n.toLowerCase() != i?.name.toLowerCase() && widget.taken.contains(n.toLowerCase())) {
      err = 'Esiste già una sequenza "$n"';
    }
    for (final (label, c) in [
      ('Inizio', _start),
      ('Incremento', _inc),
      ('Minimo', _min),
      ('Massimo', _max),
      ('Cache', _cache),
    ]) {
      if (err == null && c.text.trim().isNotEmpty && _int(c) == null) err = '$label deve essere un numero intero';
    }
    if (err == null && _int(_inc) == 0) err = 'L\'incremento non può essere 0';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, _current);
  }

  Widget _num(TextEditingController c, String hint, {bool enabled = true}) =>
      MacTextField(controller: c, tabular: true, hint: hint, enabled: enabled, onChanged: (_) => setState(() {}));

  @override
  Widget build(BuildContext context) {
    final limits = family != DbFamily.firebird && family != DbFamily.snowflake;
    return SheetScaffold(
      title: _new ? 'Nuova sequenza' : 'Sequenza ${i!.name}',
      subtitle: [?widget.schema, if (i?.currentValue != null) 'valore attuale ${i!.currentValue}'].join(' · '),
      onSubmit: _save,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormGroup(
              children: [
                FormRow(
                  label: 'Nome',
                  child: MacTextField(controller: _name, autofocus: _new, onChanged: (_) => setState(() {})),
                ),
                if (family == DbFamily.postgres || family == DbFamily.sqlServer || family == DbFamily.db2)
                  FormRow(
                    label: 'Tipo',
                    child: ComboField(
                      controller: _type,
                      hint: 'bigint',
                      enabled: _new,
                      options: () => const ['smallint', 'integer', 'bigint'],
                      onChanged: (_) => setState(() {}),
                      onSelected: (_) => setState(() {}),
                    ),
                  ),
                FormRow(
                  label: 'Valore iniziale',
                  help: _new ? null : 'Per cambiare il prossimo valore usa "Imposta valore…"',
                  child: _num(_start, '1', enabled: _new),
                ),
                FormRow(label: 'Incremento', child: _num(_inc, '1')),
                if (limits) ...[
                  FormRow(label: 'Minimo', child: _num(_min, 'predefinito')),
                  FormRow(label: 'Massimo', child: _num(_max, 'predefinito')),
                  FormRow(
                    label: 'Cache',
                    help: 'Valori preallocati in memoria (1: nessuna)',
                    child: _num(_cache, 'predefinita'),
                  ),
                  FormRow(
                    label: 'Al massimo',
                    child: CheckboxRow(
                      value: _cycle,
                      label: 'Ricomincia dal minimo (CYCLE)',
                      onChanged: (v) => setState(() => _cycle = v),
                    ),
                  ),
                ],
                if (family == DbFamily.postgres)
                  FormRow(
                    label: 'Appartiene a',
                    help: 'Colonna tabella.colonna: la sequenza viene eliminata con essa',
                    child: MacTextField(controller: _owned, hint: 'nessuna', onChanged: (_) => setState(() {})),
                  ),
                if (family == DbFamily.postgres || family == DbFamily.oracle || family == DbFamily.db2)
                  FormRow(
                    label: 'Commento',
                    child: MacTextField(controller: _comment, onChanged: (_) => setState(() {})),
                  ),
              ],
            ),
            _ScriptPreview(_statements),
          ],
        ),
      ),
      leading: [if (_error != null) Flexible(child: StatusLine(_error!, kind: StatusKind.danger))],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: _new ? 'Crea' : 'Applica', onPressed: _save),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// New trigger header
// ---------------------------------------------------------------------------

/// Name, timing, events and level of a new trigger on [table]; the editor
/// opens with a template built from them.
Future<TriggerDef?> showNewTriggerDialog(
  BuildContext context, {
  required SqlDialect dialect,
  required TriggerDef template,
}) => showSheet<TriggerDef>(
  context,
  builder: (_) => _NewTriggerDialog(dialect: dialect, template: template),
);

class _NewTriggerDialog extends StatefulWidget {
  const _NewTriggerDialog({required this.dialect, required this.template});
  final SqlDialect dialect;
  final TriggerDef template;

  @override
  State<_NewTriggerDialog> createState() => _NewTriggerDialogState();
}

class _NewTriggerDialogState extends State<_NewTriggerDialog> {
  late final _name = TextEditingController(text: widget.template.name);
  late TriggerTiming _timing = widget.template.timing;
  late final Set<TriggerEvent> _events = {...widget.template.events};
  late bool _row = widget.template.forEachRow;

  DbFamily get family => widget.dialect.family;

  /// MySQL, SQLite: one event per trigger.
  bool get _single => family == DbFamily.mysql || family == DbFamily.sqlite;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _ok() {
    if (_name.text.trim().isEmpty || _events.isEmpty) return;
    final t = widget.template;
    Navigator.pop(
      context,
      TriggerDef(
        catalog: t.catalog,
        schema: t.schema,
        table: t.table,
        name: _name.text.trim(),
        timing: _timing,
        events: _events,
        forEachRow: _row,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timings = [
      if (family != DbFamily.sqlServer) TriggerTiming.before,
      TriggerTiming.after,
      if (family != DbFamily.mysql && family != DbFamily.firebird) TriggerTiming.insteadOf,
    ];
    return SheetScaffold(
      title: 'Nuovo trigger',
      subtitle: 'Tabella ${widget.template.table}',
      onSubmit: _ok,
      body: FormGroup(
        children: [
          FormRow(
            label: 'Nome',
            child: MacTextField(controller: _name, autofocus: true),
          ),
          FormRow(
            label: 'Momento',
            child: Align(
              alignment: Alignment.centerLeft,
              child: Segmented<TriggerTiming>(
                value: timings.contains(_timing) ? _timing : timings.first,
                items: [for (final t in timings) (t, t.sql, null)],
                onChanged: (v) => setState(() => _timing = v),
              ),
            ),
          ),
          FormRow(
            label: 'Eventi',
            child: Row(
              children: [
                for (final e in TriggerEvent.values)
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.md),
                    child: CheckboxRow(
                      value: _events.contains(e),
                      label: e.sql,
                      onChanged: (v) => setState(() {
                        if (_single) _events.clear();
                        v ? _events.add(e) : _events.remove(e);
                      }),
                    ),
                  ),
              ],
            ),
          ),
          if (family == DbFamily.postgres || family == DbFamily.oracle || family == DbFamily.db2)
            FormRow(
              label: 'Livello',
              child: Align(
                alignment: Alignment.centerLeft,
                child: Segmented<bool>(
                  value: _row,
                  items: const [(true, 'Per ogni riga', null), (false, 'Per istruzione', null)],
                  onChanged: (v) => setState(() => _row = v),
                ),
              ),
            ),
        ],
      ),
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: 'Continua', onPressed: _events.isEmpty ? null : _ok),
      ],
    );
  }
}
