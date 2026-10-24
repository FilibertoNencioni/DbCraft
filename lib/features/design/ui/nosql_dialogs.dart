// Sheets of the NoSQL objects: MongoDB collections, indexes and views;
// Cassandra keyspaces, tables, indexes, user defined types and
// materialized views. Each returns the edited definition; the caller turns
// it into a script (MongoDdl / CassandraDdl).

import 'package:flutter/material.dart';

import '../../../drivers/mongodb/bson.dart';
import '../../../services/sql_dialect.dart';
import '../../../ui/widgets/common.dart';
import '../ddl/nosql_ddl.dart';
import '../model/nosql_defs.dart';
import 'extra_dialogs.dart' show ExtraSheet, FieldRows, gridHeight, monoField;

String? _text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
int? _int(TextEditingController c) => int.tryParse(c.text.trim());

/// Problem with a shell JSON value ([list]: an array is expected).
String? shellJsonError(String? text, String what, {bool list = false}) {
  if (text == null || text.trim().isEmpty) return null;
  try {
    final v = parseMongoValue(text);
    if (list ? v is! List : v is! Map) return '$what: ${list ? 'serve un array [ … ]' : 'serve un documento { … }'}';
    return null;
  } catch (e) {
    return '$what non valido: ${e.toString().split('\n').first}';
  }
}

// ---------------------------------------------------------------------------
// MongoDB collection
// ---------------------------------------------------------------------------

Future<MongoCollectionDef?> showMongoCollectionDialog(
  BuildContext context, {
  required String database,
  MongoCollectionDef? initial,
}) => showSheet<MongoCollectionDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _MongoCollectionDialog(database: database, initial: initial),
);

class _MongoCollectionDialog extends StatefulWidget {
  const _MongoCollectionDialog({required this.database, this.initial});
  final String database;
  final MongoCollectionDef? initial;

  @override
  State<_MongoCollectionDialog> createState() => _MongoCollectionDialogState();
}

class _MongoCollectionDialogState extends State<_MongoCollectionDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _size = TextEditingController(text: '${i?.cappedSize ?? 1048576}');
  late final _max = TextEditingController(text: i?.cappedMax == null ? '' : '${i!.cappedMax}');
  late final _time = TextEditingController(text: i?.timeField ?? 'timestamp');
  late final _meta = TextEditingController(text: i?.metaField ?? '');
  late final _expire = TextEditingController(text: i?.expireAfterSeconds == null ? '' : '${i!.expireAfterSeconds}');
  late final _collation = TextEditingController(text: i?.collation ?? '');
  late final _validator = TextEditingController(text: i?.validator ?? '');
  late MongoCollectionType _type = i?.type ?? MongoCollectionType.normal;
  late String? _granularity = i?.granularity;
  late String? _level = i?.validationLevel;
  late String? _action = i?.validationAction;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _size, _max, _time, _meta, _expire, _collation, _validator]) {
      c.dispose();
    }
    super.dispose();
  }

  MongoCollectionDef get _current => MongoCollectionDef(
    database: widget.database,
    name: _name.text.trim(),
    type: _type,
    cappedSize: _type == MongoCollectionType.capped ? _int(_size) : null,
    cappedMax: _type == MongoCollectionType.capped ? _int(_max) : null,
    timeField: _type == MongoCollectionType.timeseries ? _text(_time) : null,
    metaField: _type == MongoCollectionType.timeseries ? _text(_meta) : null,
    granularity: _type == MongoCollectionType.timeseries ? _granularity : null,
    expireAfterSeconds: _type == MongoCollectionType.timeseries ? _int(_expire) : null,
    collation: _text(_collation),
    validator: _text(_validator),
    validationLevel: _level,
    validationAction: _action,
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    const ddl = MongoDdl();
    return i == null ? ddl.createCollection(_current) : ddl.alterCollection(i!, _current);
  }

  void _save() {
    final c = _current;
    var err = c.name.isEmpty ? 'Inserisci il nome della collezione' : null;
    if (err == null && c.name.contains(r'$')) err = 'Il nome non può contenere \$';
    if (err == null && _type == MongoCollectionType.capped && (c.cappedSize ?? 0) <= 0) {
      err = 'Indica la dimensione massima in byte';
    }
    if (err == null && _type == MongoCollectionType.timeseries && c.timeField == null) {
      err = 'Indica il campo del tempo';
    }
    err ??= shellJsonError(c.validator, 'Validatore');
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    final isNew = i == null;
    return ExtraSheet(
      title: isNew ? 'Nuova collezione' : 'Collezione ${i!.name}',
      subtitle: widget.database,
      isNew: isNew,
      statements: _statements,
      error: _error,
      onSave: _save,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: isNew, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Tipo',
              child: PopUpButton<MongoCollectionType>(
                value: _type,
                items: [for (final t in MongoCollectionType.values) (t, t.label, null)],
                onChanged: isNew ? (t) => setState(() => _type = t) : null,
              ),
            ),
            if (_type == MongoCollectionType.capped) ...[
              FormRow(
                label: 'Dimensione massima',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: NumberField(
                    controller: _size,
                    min: 4096,
                    unit: 'byte',
                    width: 140,
                    onChanged: (_) => changed(),
                  ),
                ),
              ),
              FormRow(
                label: 'Documenti al massimo',
                help: 'Vuoto: nessun limite',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: NumberField(controller: _max, min: 1, width: 140, onChanged: (_) => changed()),
                ),
              ),
            ],
            if (_type == MongoCollectionType.timeseries) ...[
              FormRow(
                label: 'Campo del tempo',
                child: MacTextField(controller: _time, enabled: isNew, onChanged: (_) => changed()),
              ),
              FormRow(
                label: 'Campo dei metadati',
                help: 'Identifica la serie (es. il sensore)',
                child: MacTextField(controller: _meta, enabled: isNew, onChanged: (_) => changed()),
              ),
              FormRow(
                label: 'Granularità',
                child: PopUpButton<String?>(
                  value: _granularity,
                  items: [(null, 'Predefinita', null), for (final g in mongoGranularities) (g, g, null)],
                  onChanged: isNew ? (g) => setState(() => _granularity = g) : null,
                ),
              ),
              FormRow(
                label: 'Scadenza',
                help: 'Secondi dopo cui i documenti vengono eliminati',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: NumberField(controller: _expire, min: 1, unit: 's', width: 140, onChanged: (_) => changed()),
                ),
              ),
            ],
            FormRow(
              label: 'Collation',
              help: 'Lingua dei confronti tra stringhe (it, en…)',
              child: MacTextField(controller: _collation, enabled: isNew, hint: 'binaria', onChanged: (_) => changed()),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        FormGroup(
          title: 'Validazione',
          children: [
            FormRow(
              label: 'Validatore',
              help: r'Documento di query o {$jsonSchema: {…}}',
              child: monoField(
                _validator,
                hint: r'{$jsonSchema: {bsonType: "object", required: ["nome"]}}',
                lines: 6,
                changed: changed,
              ),
            ),
            FormRow(
              label: 'Livello',
              help: 'moderate: non controlla i documenti già non validi',
              child: PopUpButton<String?>(
                value: _level,
                items: [(null, 'Predefinito', null), for (final l in mongoValidationLevels) (l, l, null)],
                onChanged: (l) => setState(() => _level = l),
              ),
            ),
            FormRow(
              label: 'Azione',
              help: 'warn: registra un avviso invece di rifiutare',
              child: PopUpButton<String?>(
                value: _action,
                items: [(null, 'Predefinita', null), for (final a in mongoValidationActions) (a, a, null)],
                onChanged: (a) => setState(() => _action = a),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// MongoDB index
// ---------------------------------------------------------------------------

/// [fields] are the fields of the collection (sampled) offered as keys.
Future<MongoIndexDef?> showMongoIndexDialog(
  BuildContext context, {
  required String database,
  required String collection,
  List<String> fields = const [],
  MongoIndexDef? initial,
}) => showSheet<MongoIndexDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _MongoIndexDialog(database: database, collection: collection, fields: fields, initial: initial),
);

class _MongoIndexDialog extends StatefulWidget {
  const _MongoIndexDialog({required this.database, required this.collection, required this.fields, this.initial});
  final String database;
  final String collection;
  final List<String> fields;
  final MongoIndexDef? initial;

  @override
  State<_MongoIndexDialog> createState() => _MongoIndexDialogState();
}

class _MongoIndexDialogState extends State<_MongoIndexDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _ttl = TextEditingController(text: i?.ttlSeconds == null ? '' : '${i!.ttlSeconds}');
  late final _filter = TextEditingController(text: i?.partialFilter ?? '');
  late final _keys = FieldRows(2, [
    for (final k in i?.keys ?? const <MongoIndexKey>[]) [k.field, k.kind],
  ]);
  late bool _unique = i?.unique ?? false;
  late bool _sparse = i?.sparse ?? false;
  late bool _hidden = i?.hidden ?? false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_keys.rows.isEmpty) _keys.add(['', '1']);
  }

  @override
  void dispose() {
    for (final c in [_name, _ttl, _filter]) {
      c.dispose();
    }
    _keys.dispose();
    super.dispose();
  }

  MongoIndexDef get _current => MongoIndexDef(
    database: widget.database,
    collection: widget.collection,
    name: _text(_name),
    keys: [
      for (final r in _keys.values)
        if (r[0].isNotEmpty) MongoIndexKey(r[0], r[1].isEmpty ? '1' : r[1]),
    ],
    unique: _unique,
    sparse: _sparse,
    hidden: _hidden,
    ttlSeconds: _int(_ttl),
    partialFilter: _text(_filter),
  );

  List<String> get _statements {
    final c = _current;
    if (c.keys.isEmpty) return const [];
    const ddl = MongoDdl();
    return i == null ? ddl.createIndex(c) : ddl.alterIndex(i!, c);
  }

  void _save() {
    final c = _current;
    var err = c.keys.isEmpty ? 'Aggiungi almeno un campo' : null;
    if (err == null && c.ttlSeconds != null && c.keys.length != 1) err = 'Un indice TTL ha un solo campo (una data)';
    err ??= shellJsonError(c.partialFilter, 'Filtro');
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    final isNew = i == null;
    return ExtraSheet(
      title: isNew ? 'Nuovo indice' : 'Indice ${i!.effectiveName}',
      subtitle: '${widget.database}.${widget.collection}',
      isNew: isNew,
      statements: _statements,
      error: _error,
      onSave: _save,
      notice: isNew
          ? null
          : const Notice(
              kind: NoticeKind.info,
              message: 'Visibilità e scadenza cambiano sul posto; le altre modifiche ricreano l\'indice.',
            ),
      children: [
        SizedBox(
          height: gridHeight(_keys.rows.length),
          child: EditableGrid(
            columns: const [EditableGridColumn('Campo'), EditableGridColumn('Tipo', width: 140)],
            rowCount: _keys.rows.length,
            rowKey: (r) => ValueKey(_keys.rows[r].$1),
            onAdd: () => setState(() => _keys.add(['', '1'])),
            addLabel: 'Aggiungi campo',
            onRemove: (r) => setState(() => _keys.remove(r)),
            onMove: (a, b) => setState(() => _keys.move(a, b)),
            cellBuilder: (context, r, c) => ComboField(
              controller: _keys.rows[r].$2[c],
              small: true,
              mono: c == 0,
              options: () => c == 0 ? widget.fields : mongoIndexKinds,
              optionDetail: c == 1
                  ? (k) => switch (k) {
                      '1' => 'crescente',
                      '-1' => 'decrescente',
                      'text' => 'testo',
                      '2dsphere' => 'geografico',
                      _ => k,
                    }
                  : null,
              onChanged: (_) => changed(),
              onSelected: (_) => changed(),
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              help: 'Vuoto: campo_1_altro_-1',
              child: MacTextField(controller: _name, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Opzioni',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CheckboxRow(value: _unique, label: 'Valori univoci', onChanged: (v) => setState(() => _unique = v)),
                  CheckboxRow(
                    value: _sparse,
                    label: 'Solo i documenti con il campo (sparse)',
                    onChanged: (v) => setState(() => _sparse = v),
                  ),
                  CheckboxRow(
                    value: _hidden,
                    label: 'Nascosto al pianificatore',
                    onChanged: (v) => setState(() => _hidden = v),
                  ),
                ],
              ),
            ),
            FormRow(
              label: 'Scadenza (TTL)',
              help: 'Secondi dopo la data del campo: i documenti vengono eliminati',
              child: Align(
                alignment: Alignment.centerLeft,
                child: NumberField(controller: _ttl, min: 0, unit: 's', width: 140, onChanged: (_) => changed()),
              ),
            ),
            FormRow(
              label: 'Filtro parziale',
              help: 'Indicizza solo i documenti che lo soddisfano',
              child: monoField(_filter, hint: r'{stato: {$eq: "attivo"}}', lines: 2, changed: changed),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// MongoDB view
// ---------------------------------------------------------------------------

Future<MongoViewDef?> showMongoViewDialog(
  BuildContext context, {
  required String database,
  List<String> collections = const [],
  MongoViewDef? initial,
}) => showSheet<MongoViewDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _MongoViewDialog(database: database, collections: collections, initial: initial),
);

class _MongoViewDialog extends StatefulWidget {
  const _MongoViewDialog({required this.database, required this.collections, this.initial});
  final String database;
  final List<String> collections;
  final MongoViewDef? initial;

  @override
  State<_MongoViewDialog> createState() => _MongoViewDialogState();
}

class _MongoViewDialogState extends State<_MongoViewDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _source = TextEditingController(text: i?.viewOn ?? '');
  late final _pipeline = TextEditingController(text: i?.pipeline ?? '[\n  {\$match: {}}\n]');
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _source, _pipeline]) {
      c.dispose();
    }
    super.dispose();
  }

  MongoViewDef get _current => MongoViewDef(
    database: widget.database,
    name: _name.text.trim(),
    viewOn: _source.text.trim(),
    pipeline: _pipeline.text,
  );

  List<String> get _statements {
    final c = _current;
    if (c.name.isEmpty || c.viewOn.isEmpty) return const [];
    const ddl = MongoDdl();
    return i == null ? ddl.createView(c) : ddl.alterView(i!, c);
  }

  void _save() {
    final c = _current;
    var err = c.name.isEmpty
        ? 'Inserisci il nome della vista'
        : c.viewOn.isEmpty
        ? 'Scegli la collezione di origine'
        : null;
    err ??= shellJsonError(c.pipeline, 'Pipeline', list: true);
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
      title: i == null ? 'Nuova vista' : 'Vista ${i!.name}',
      subtitle: widget.database,
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
              label: 'Origine',
              child: ComboField(
                controller: _source,
                options: () => widget.collections,
                onChanged: (_) => changed(),
                onSelected: (_) => changed(),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        SectionLabel('Pipeline di aggregazione'),
        monoField(_pipeline, lines: 10, changed: changed),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Cassandra keyspace
// ---------------------------------------------------------------------------

Future<KeyspaceDef?> showKeyspaceDialog(BuildContext context, {required SqlDialect dialect, KeyspaceDef? initial}) =>
    showSheet<KeyspaceDef>(
      context,
      builder: (_) => _KeyspaceDialog(dialect: dialect, initial: initial),
    );

class _KeyspaceDialog extends StatefulWidget {
  const _KeyspaceDialog({required this.dialect, this.initial});
  final SqlDialect dialect;
  final KeyspaceDef? initial;

  @override
  State<_KeyspaceDialog> createState() => _KeyspaceDialogState();
}

class _KeyspaceDialogState extends State<_KeyspaceDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _rf = TextEditingController(text: '${i?.replicationFactor ?? 1}');
  late final _dcs = TextEditingController(
    text: [for (final e in i?.datacenters.entries ?? const <MapEntry<String, int>>[]) '${e.key}: ${e.value}']
        .join(', '),
  );
  late bool _nts = i?.networkTopology ?? false;
  late bool _durable = i?.durableWrites ?? true;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _rf, _dcs]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, int>? get _datacenters {
    final out = <String, int>{};
    for (final part in _dcs.text.split(',')) {
      if (part.trim().isEmpty) continue;
      final m = RegExp(r'^\s*([\w.-]+)\s*[:=]\s*(\d+)\s*$').firstMatch(part);
      if (m == null) return null;
      out[m.group(1)!] = int.parse(m.group(2)!);
    }
    return out;
  }

  KeyspaceDef get _current => KeyspaceDef(
    name: _name.text.trim(),
    strategy: _nts ? 'NetworkTopologyStrategy' : 'SimpleStrategy',
    replicationFactor: _int(_rf) ?? 1,
    datacenters: _datacenters ?? const {},
    durableWrites: _durable,
  );

  List<String> get _statements {
    if (_name.text.trim().isEmpty) return const [];
    final ddl = CassandraDdl(widget.dialect);
    return i == null ? ddl.createKeyspace(_current) : ddl.alterKeyspace(i!, _current);
  }

  void _save() {
    String? err;
    if (_name.text.trim().isEmpty) err = 'Inserisci il nome del keyspace';
    if (err == null && _nts && (_datacenters == null || _datacenters!.isEmpty)) {
      err = 'Indica i data center: dc1: 3, dc2: 2';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, _current);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    return ExtraSheet(
      title: i == null ? 'Nuovo keyspace' : 'Keyspace ${i!.name}',
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(
                controller: _name,
                autofocus: i == null,
                enabled: i == null,
                onChanged: (_) => changed(),
              ),
            ),
            FormRow(
              label: 'Replica',
              child: Segmented<bool>(
                value: _nts,
                items: const [(false, 'Semplice', null), (true, 'Per data center', null)],
                onChanged: (v) => setState(() => _nts = v),
              ),
            ),
            if (!_nts)
              FormRow(
                label: 'Copie',
                help: 'Fattore di replica (1 solo in sviluppo)',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: NumberField(controller: _rf, min: 1, max: 20, onChanged: (_) => changed()),
                ),
              )
            else
              FormRow(
                label: 'Data center',
                help: 'Nome: copie, separati da virgola',
                child: MacTextField(controller: _dcs, mono: true, hint: 'dc1: 3, dc2: 2', onChanged: (_) => changed()),
              ),
            FormRow(
              label: 'Scritture',
              child: CheckboxRow(
                value: _durable,
                label: 'Durevoli (commit log)',
                onChanged: (v) => setState(() => _durable = v),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Cassandra table
// ---------------------------------------------------------------------------

Future<CqlTableDef?> showCqlTableDialog(
  BuildContext context, {
  required SqlDialect dialect,
  required String keyspace,
  CqlTableDef? initial,
  List<String> userTypes = const [],
}) => showSheet<CqlTableDef>(
  context,
  size: SheetSize.xlarge,
  builder: (_) => _CqlTableDialog(dialect: dialect, keyspace: keyspace, initial: initial, userTypes: userTypes),
);

class _CqlTableDialog extends StatefulWidget {
  const _CqlTableDialog({required this.dialect, required this.keyspace, this.initial, required this.userTypes});
  final SqlDialect dialect;
  final String keyspace;
  final CqlTableDef? initial;
  final List<String> userTypes;

  @override
  State<_CqlTableDialog> createState() => _CqlTableDialogState();
}

class _CqlTableDialogState extends State<_CqlTableDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _comment = TextEditingController(text: i?.comment ?? '');
  late final _ttl = TextEditingController(text: i?.defaultTtl == null ? '' : '${i!.defaultTtl}');
  late final _gc = TextEditingController(text: i?.gcGraceSeconds == null ? '' : '${i!.gcGraceSeconds}');
  late String? _compaction = i?.compaction == null || i!.compaction!.isEmpty ? null : i!.compaction;

  /// Name and type fields; kind and order per row.
  late final _cols = FieldRows(2, [
    for (final c in i?.columns ?? const [CqlColumn('id', 'uuid', kind: CqlColumnKind.partition)]) [c.name, c.type],
  ]);
  late final List<CqlColumnKind> _kinds = [
    for (final c in i?.columns ?? const [CqlColumn('id', 'uuid', kind: CqlColumnKind.partition)]) c.kind,
  ];
  late final List<bool> _desc = [
    for (final c in i?.columns ?? const [CqlColumn('id', 'uuid', kind: CqlColumnKind.partition)]) c.descending,
  ];
  late final Set<String> _existing = {for (final c in i?.columns ?? const <CqlColumn>[]) c.name.toLowerCase()};
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _comment, _ttl, _gc]) {
      c.dispose();
    }
    _cols.dispose();
    super.dispose();
  }

  bool _locked(int r) {
    // Existing key columns cannot change.
    if (i == null) return false;
    final name = _cols.rows[r].$2[0].text.trim().toLowerCase();
    return _existing.contains(name) && _kinds[r].key;
  }

  CqlTableDef get _current {
    final cols = <CqlColumn>[];
    for (var r = 0; r < _cols.rows.length; r++) {
      final n = _cols.rows[r].$2[0].text.trim(), t = _cols.rows[r].$2[1].text.trim();
      if (n.isEmpty) continue;
      cols.add(CqlColumn(n, t.isEmpty ? 'text' : t, kind: _kinds[r], descending: _desc[r]));
    }
    // Keys first, in their order: partition, clustering, then the others.
    cols.sort((a, b) => a.kind.index.compareTo(b.kind.index));
    return CqlTableDef(
      keyspace: widget.keyspace,
      name: _name.text.trim(),
      columns: cols,
      comment: _text(_comment) ?? (i?.comment == null ? null : ''),
      defaultTtl: _int(_ttl) ?? i?.defaultTtl,
      gcGraceSeconds: _int(_gc) ?? i?.gcGraceSeconds,
      compaction: _compaction ?? i?.compaction,
    );
  }

  List<String> get _statements {
    final c = _current;
    if (c.name.isEmpty || c.of(CqlColumnKind.partition).isEmpty) return const [];
    final ddl = CassandraDdl(widget.dialect);
    return i == null ? ddl.createTable(c) : ddl.alterTable(i!, c);
  }

  void _add() => setState(() {
    _cols.add(['', 'text']);
    _kinds.add(CqlColumnKind.regular);
    _desc.add(false);
  });

  void _remove(int r) => setState(() {
    _cols.remove(r);
    _kinds.removeAt(r);
    _desc.removeAt(r);
  });

  void _save() {
    final c = _current;
    String? err;
    if (c.name.isEmpty) err = 'Inserisci il nome della tabella';
    if (err == null && c.of(CqlColumnKind.partition).isEmpty) err = 'Serve almeno una colonna di partizione';
    final names = [for (final x in c.columns) x.name.toLowerCase()];
    if (err == null && names.toSet().length != names.length) err = 'Ci sono colonne con lo stesso nome';
    if (err == null && c.of(CqlColumnKind.static).isNotEmpty && c.of(CqlColumnKind.clustering).isEmpty) {
      err = 'Le colonne statiche richiedono almeno una colonna di clustering';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    void changed() => setState(() {});
    final types = [...cqlTypes, for (final u in widget.userTypes) 'frozen<$u>'];
    return ExtraSheet(
      title: i == null ? 'Nuova tabella' : 'Tabella ${i!.name}',
      subtitle: widget.keyspace,
      isNew: i == null,
      statements: _statements,
      error: _error,
      onSave: _save,
      notice: i == null
          ? null
          : const Notice(
              kind: NoticeKind.info,
              message:
                  'In Cassandra la chiave primaria e i tipi delle colonne esistenti non si cambiano: '
                  'si aggiungono ed eliminano solo colonne normali e statiche.',
            ),
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(
                controller: _name,
                autofocus: i == null,
                enabled: i == null,
                onChanged: (_) => changed(),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          height: gridHeight(_cols.rows.length),
          child: EditableGrid(
            columns: const [
              EditableGridColumn('Colonna'),
              EditableGridColumn('Tipo'),
              EditableGridColumn('Ruolo', width: 130),
              EditableGridColumn('Decrescente', width: 90, center: true),
            ],
            rowCount: _cols.rows.length,
            rowKey: (r) => ValueKey(_cols.rows[r].$1),
            mark: (r) => i != null && !_existing.contains(_cols.rows[r].$2[0].text.trim().toLowerCase())
                ? EditableRowMark.added
                : EditableRowMark.none,
            onAdd: _add,
            addLabel: 'Aggiungi colonna',
            onRemove: (r) => _locked(r) ? null : _remove(r),
            cellBuilder: (context, r, c) {
              final locked =
                  _locked(r) ||
                  (i != null && _existing.contains(_cols.rows[r].$2[0].text.trim().toLowerCase()) && c != 0);
              switch (c) {
                case 0:
                  return MacTextField(
                    controller: _cols.rows[r].$2[0],
                    small: true,
                    enabled: !_locked(r),
                    onChanged: (_) => changed(),
                  );
                case 1:
                  return ComboField(
                    controller: _cols.rows[r].$2[1],
                    small: true,
                    mono: true,
                    enabled: !locked,
                    options: () => types,
                    onChanged: (_) => changed(),
                    onSelected: (_) => changed(),
                  );
                case 2:
                  return PopUpButton<CqlColumnKind>(
                    value: _kinds[r],
                    small: true,
                    items: [
                      for (final k in CqlColumnKind.values)
                        if (i == null || !k.key || _kinds[r] == k) (k, k.label, null),
                    ],
                    onChanged: locked ? null : (k) => setState(() => _kinds[r] = k),
                  );
                default:
                  return Center(
                    child: MacCheckbox(
                      value: _desc[r],
                      onChanged: _kinds[r] == CqlColumnKind.clustering && !locked
                          ? (v) => setState(() => _desc[r] = v)
                          : null,
                    ),
                  );
              }
            },
          ),
        ),
        const SizedBox(height: Gap.md),
        FormGroup(
          title: 'Opzioni',
          children: [
            FormRow(
              label: 'Commento',
              child: MacTextField(controller: _comment, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Scadenza dei dati',
              help: 'TTL predefinito in secondi (0: mai)',
              child: Align(
                alignment: Alignment.centerLeft,
                child: NumberField(controller: _ttl, min: 0, unit: 's', width: 140, onChanged: (_) => changed()),
              ),
            ),
            FormRow(
              label: 'gc_grace_seconds',
              help: 'Vuoto: predefinito (10 giorni)',
              child: Align(
                alignment: Alignment.centerLeft,
                child: NumberField(controller: _gc, min: 0, unit: 's', width: 140, onChanged: (_) => changed()),
              ),
            ),
            FormRow(
              label: 'Compattazione',
              child: PopUpButton<String?>(
                value: _compaction,
                items: [(null, 'Predefinita', null), for (final c in cqlCompactions) (c, c, null)],
                onChanged: (c) => setState(() => _compaction = c),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Cassandra index, type, materialized view
// ---------------------------------------------------------------------------

Future<CqlIndexDef?> showCqlIndexDialog(
  BuildContext context, {
  required SqlDialect dialect,
  required String keyspace,
  required String table,
  List<String> columns = const [],
}) => showSheet<CqlIndexDef>(
  context,
  builder: (_) => _CqlIndexDialog(dialect: dialect, keyspace: keyspace, table: table, columns: columns),
);

class _CqlIndexDialog extends StatefulWidget {
  const _CqlIndexDialog({required this.dialect, required this.keyspace, required this.table, required this.columns});
  final SqlDialect dialect;
  final String keyspace;
  final String table;
  final List<String> columns;

  @override
  State<_CqlIndexDialog> createState() => _CqlIndexDialogState();
}

class _CqlIndexDialogState extends State<_CqlIndexDialog> {
  late final _name = TextEditingController(text: 'ix_${widget.table}');
  final _column = TextEditingController();
  bool _sai = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _column.dispose();
    super.dispose();
  }

  CqlIndexDef get _current => CqlIndexDef(
    keyspace: widget.keyspace,
    table: widget.table,
    name: _name.text.trim(),
    column: _column.text.trim(),
    using: _sai ? 'sai' : null,
  );

  void _save() {
    final c = _current;
    final err = c.name.isEmpty
        ? 'Inserisci il nome dell\'indice'
        : c.column.isEmpty
        ? 'Scegli la colonna'
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
    final c = _current;
    return ExtraSheet(
      title: 'Nuovo indice',
      subtitle: '${widget.keyspace}.${widget.table}',
      isNew: true,
      statements: c.name.isEmpty || c.column.isEmpty ? const [] : CassandraDdl(widget.dialect).createIndex(c),
      error: _error,
      onSave: _save,
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Colonna',
              help: 'Una colonna, o keys(m) / values(m) / entries(m) per una mappa',
              child: ComboField(
                controller: _column,
                mono: true,
                options: () => widget.columns,
                onChanged: (_) => changed(),
                onSelected: (_) => changed(),
              ),
            ),
            FormRow(
              label: 'Tipo',
              child: CheckboxRow(
                value: _sai,
                label: 'Storage Attached Index (SAI)',
                help: 'Consigliato da Cassandra 5; senza, un indice secondario classico',
                onChanged: (v) => setState(() => _sai = v),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

Future<UdtDef?> showUdtDialog(
  BuildContext context, {
  required SqlDialect dialect,
  required String keyspace,
  UdtDef? initial,
}) => showSheet<UdtDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _UdtDialog(dialect: dialect, keyspace: keyspace, initial: initial),
);

class _UdtDialog extends StatefulWidget {
  const _UdtDialog({required this.dialect, required this.keyspace, this.initial});
  final SqlDialect dialect;
  final String keyspace;
  final UdtDef? initial;

  @override
  State<_UdtDialog> createState() => _UdtDialogState();
}

class _UdtDialogState extends State<_UdtDialog> {
  late final i = widget.initial;
  late final _name = TextEditingController(text: i?.name ?? '');
  late final _fields = FieldRows(2, [
    for (final (n, t) in i?.fields ?? const <(String, String)>[]) [n, t],
  ]);
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_fields.rows.isEmpty) _fields.add(['', 'text']);
  }

  @override
  void dispose() {
    _name.dispose();
    _fields.dispose();
    super.dispose();
  }

  UdtDef get _current => UdtDef(
    keyspace: widget.keyspace,
    name: _name.text.trim(),
    fields: [
      for (final r in _fields.values)
        if (r[0].isNotEmpty) (r[0], r[1].isEmpty ? 'text' : r[1]),
    ],
  );

  void _save() {
    final c = _current;
    final err = c.name.isEmpty
        ? 'Inserisci il nome del tipo'
        : c.fields.isEmpty
        ? 'Aggiungi almeno un campo'
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
    final c = _current;
    final ddl = CassandraDdl(widget.dialect);
    final old = i?.fields.length ?? 0;
    return ExtraSheet(
      title: i == null ? 'Nuovo tipo' : 'Tipo ${i!.name}',
      subtitle: widget.keyspace,
      isNew: i == null,
      statements: c.name.isEmpty || c.fields.isEmpty
          ? const []
          : (i == null ? ddl.createType(c) : ddl.alterType(i!, c)),
      error: _error,
      onSave: _save,
      notice: i == null
          ? null
          : const Notice(
              kind: NoticeKind.info,
              message: 'I campi di un tipo si aggiungono e si rinominano, ma non si eliminano né cambiano tipo.',
            ),
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(
                controller: _name,
                autofocus: i == null,
                enabled: i == null,
                onChanged: (_) => changed(),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          height: gridHeight(_fields.rows.length),
          child: EditableGrid(
            columns: const [EditableGridColumn('Campo'), EditableGridColumn('Tipo')],
            rowCount: _fields.rows.length,
            rowKey: (r) => ValueKey(_fields.rows[r].$1),
            mark: (r) => i != null && r >= old ? EditableRowMark.added : EditableRowMark.none,
            onAdd: () => setState(() => _fields.add(['', 'text'])),
            addLabel: 'Aggiungi campo',
            onRemove: (r) => r < old ? null : setState(() => _fields.remove(r)),
            cellBuilder: (context, r, col) => col == 0
                ? MacTextField(controller: _fields.rows[r].$2[0], small: true, onChanged: (_) => changed())
                : ComboField(
                    controller: _fields.rows[r].$2[1],
                    small: true,
                    mono: true,
                    enabled: r >= old,
                    options: () => cqlTypes,
                    onChanged: (_) => changed(),
                    onSelected: (_) => changed(),
                  ),
          ),
        ),
      ],
    );
  }
}

Future<CqlMaterializedViewDef?> showCqlViewDialog(
  BuildContext context, {
  required SqlDialect dialect,
  required String keyspace,
  List<String> tables = const [],
}) => showSheet<CqlMaterializedViewDef>(
  context,
  size: SheetSize.large,
  builder: (_) => _CqlViewDialog(dialect: dialect, keyspace: keyspace, tables: tables),
);

class _CqlViewDialog extends StatefulWidget {
  const _CqlViewDialog({required this.dialect, required this.keyspace, required this.tables});
  final SqlDialect dialect;
  final String keyspace;
  final List<String> tables;

  @override
  State<_CqlViewDialog> createState() => _CqlViewDialogState();
}

class _CqlViewDialogState extends State<_CqlViewDialog> {
  final _name = TextEditingController();
  final _base = TextEditingController();
  final _columns = TextEditingController(text: '*');
  final _where = TextEditingController();
  final _key = TextEditingController();
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _base, _columns, _where, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  CqlMaterializedViewDef get _current => CqlMaterializedViewDef(
    keyspace: widget.keyspace,
    name: _name.text.trim(),
    baseTable: _base.text.trim(),
    columns: _columns.text,
    where: _text(_where),
    primaryKey: _key.text.trim(),
  );

  void _save() {
    final c = _current;
    final err = c.name.isEmpty
        ? 'Inserisci il nome della vista'
        : c.baseTable.isEmpty
        ? 'Scegli la tabella di origine'
        : c.primaryKey.isEmpty
        ? 'Indica la chiave primaria della vista'
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
    final c = _current;
    return ExtraSheet(
      title: 'Nuova vista materializzata',
      subtitle: widget.keyspace,
      isNew: true,
      statements: c.name.isEmpty || c.baseTable.isEmpty || c.primaryKey.isEmpty
          ? const []
          : CassandraDdl(widget.dialect).createMaterializedView(c),
      error: _error,
      onSave: _save,
      notice: const Notice(
        kind: NoticeKind.warning,
        message:
            'Le viste materializzate sono sperimentali e vanno abilitate nel server '
            '(materialized_views_enabled: true). La chiave deve contenere tutta quella della tabella.',
      ),
      children: [
        FormGroup(
          children: [
            FormRow(
              label: 'Nome',
              child: MacTextField(controller: _name, autofocus: true, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Tabella',
              child: ComboField(
                controller: _base,
                options: () => widget.tables,
                onChanged: (_) => changed(),
                onSelected: (_) => changed(),
              ),
            ),
            FormRow(
              label: 'Colonne',
              child: MacTextField(controller: _columns, mono: true, onChanged: (_) => changed()),
            ),
            FormRow(
              label: 'Condizione',
              help: 'Ogni colonna della chiave: IS NOT NULL',
              child: monoField(_where, hint: 'a IS NOT NULL AND b IS NOT NULL', lines: 2, changed: changed),
            ),
            FormRow(
              label: 'Chiave primaria',
              child: MacTextField(controller: _key, mono: true, hint: '((b), a)', onChanged: (_) => changed()),
            ),
          ],
        ),
      ],
    );
  }
}
