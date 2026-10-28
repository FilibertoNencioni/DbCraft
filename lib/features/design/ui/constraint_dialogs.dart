// Sheets that create or edit a primary key, UNIQUE / CHECK constraint,
// foreign key or index of a table. They return the definition only: the
// caller turns it into DDL (design_actions.dart runs it at once, the table
// designer collects it in its pending changes).

import 'package:flutter/material.dart';

import '../../../model/db_objects.dart';
import '../../../services/sql_dialect.dart';
import '../../../state/app_state.dart';
import '../../../state/db_connection.dart';
import '../../../ui/widgets/common.dart';
import '../../schema/ddl_builder.dart';
import '../../schema/schema_diff.dart';
import '../../schema/schema_model.dart';
import '../capabilities.dart';
import '../catalog/design_catalog.dart';
import '../data_checks.dart';

/// Definition returned by the sheets; [online] asks for an index built
/// without blocking writes.
class ConstraintEdit<T> {
  const ConstraintEdit(this.value, {this.online = false});
  final T value;
  final bool online;
}

/// What the sheets need to know about the table.
class ConstraintContext {
  const ConstraintContext({required this.dialect, required this.table, this.connection, this.isNew = false});

  final SqlDialect dialect;
  final TableDef table;

  /// Connection used to check the existing data (null: no check).
  final DbConnection? connection;

  /// The table does not exist yet (no data to check).
  final bool isNew;

  DesignCapabilities get caps => DesignCapabilities.of(dialect);
  DdlBuilder get ddl => DdlBuilder(dialect);

  /// Names already used by the constraints and indexes of the table.
  Set<String> get takenNames => {
    if (table.primaryKey?.name != null) table.primaryKey!.name!.toLowerCase(),
    for (final u in table.uniques)
      if (u.name != null) u.name!.toLowerCase(),
    for (final c in table.checks)
      if (c.name != null) c.name!.toLowerCase(),
    for (final f in table.foreignKeys)
      if (f.name != null) f.name!.toLowerCase(),
    for (final i in table.indexes) i.name.toLowerCase(),
  };

  /// [base] made unique among [takenNames] (except [keep], the current name).
  String freeName(String base, {String? keep}) {
    final taken = takenNames..remove(keep?.toLowerCase());
    var n = base;
    for (var i = 2; taken.contains(n.toLowerCase()); i++) {
      n = '${base}_$i';
    }
    return n;
  }
}

Future<ConstraintEdit<PrimaryKeyDef>?> showPrimaryKeyDialog(
  BuildContext context,
  ConstraintContext ctx, {
  PrimaryKeyDef? initial,
  List<String> referencedBy = const [],
}) => showSheet(
  context,
  size: SheetSize.large,
  builder: (_) => _KeyDialog(ctx: ctx, kind: ConstraintKind.primaryKey, initial: initial, referencedBy: referencedBy),
);

Future<ConstraintEdit<UniqueDef>?> showUniqueDialog(
  BuildContext context,
  ConstraintContext ctx, {
  UniqueDef? initial,
  List<String> referencedBy = const [],
}) => showSheet(
  context,
  size: SheetSize.large,
  builder: (_) => _KeyDialog(ctx: ctx, kind: ConstraintKind.unique, initial: initial, referencedBy: referencedBy),
);

Future<ConstraintEdit<CheckDef>?> showCheckDialog(BuildContext context, ConstraintContext ctx, {CheckDef? initial}) =>
    showSheet(
      context,
      size: SheetSize.large,
      builder: (_) => _CheckDialog(ctx: ctx, initial: initial),
    );

/// [tables] are offered as referenced tables; [loadTable] reads one.
/// [initial] edits an existing foreign key; [prefill] fills the form of a
/// new one (the ER diagram, after dragging a column onto another).
Future<ConstraintEdit<ForeignKeyDef>?> showForeignKeyDialog(
  BuildContext context,
  ConstraintContext ctx, {
  ForeignKeyDef? initial,
  ForeignKeyDef? prefill,
  required List<DbTable> tables,
  required Future<TableDef?> Function(DbTable t) loadTable,
}) => showSheet(
  context,
  size: SheetSize.large,
  builder: (_) => _ForeignKeyDialog(ctx: ctx, initial: initial, prefill: prefill, tables: tables, loadTable: loadTable),
);

Future<ConstraintEdit<IndexDef>?> showIndexDialog(BuildContext context, ConstraintContext ctx, {IndexDef? initial}) =>
    showSheet(
      context,
      size: SheetSize.large,
      builder: (_) => _IndexDialog(ctx: ctx, initial: initial),
    );

// ---------------------------------------------------------------------------
// Shared parts
// ---------------------------------------------------------------------------

/// Ordered list of columns (or index expressions) with add, remove, move
/// and, when [descending] is given, ASC / DESC.
class _ColumnList extends StatelessWidget {
  const _ColumnList({
    required this.columns,
    required this.selected,
    required this.onChanged,
    this.descending,
    this.onDescending,
    this.expressions = false,
    this.emptyText = 'Nessuna colonna',
  });

  final List<ColumnDef> columns;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final Set<String>? descending;
  final ValueChanged<Set<String>>? onDescending;
  final bool expressions;
  final String emptyText;

  static const _expression = '\u0000expr';

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final remaining = [
      for (final col in columns)
        if (!selected.contains(col.name)) col,
    ];
    void move(int i, int d) {
      final l = List.of(selected);
      final x = l[i];
      l[i] = l[i + d];
      l[i + d] = x;
      onChanged(l);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InsetBox(
          child: selected.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Text(emptyText, style: uiText(TypeSize.small, color: c.textTertiary)),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, s) in selected.indexed)
                      ListRow(
                        key: ValueKey(s),
                        index: i,
                        zebra: true,
                        icon: IndexDef.isExpression(s) ? AppIcons.function : AppIcons.column,
                        title: s,
                        mono: IndexDef.isExpression(s),
                        subtitle: columns.where((x) => x.name == s).map((x) => x.fullType).firstOrNull,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (descending != null)
                              Segmented<bool>(
                                small: true,
                                value: descending!.contains(s),
                                items: const [(false, 'ASC', null), (true, 'DESC', null)],
                                onChanged: (v) =>
                                    onDescending!(v ? ({...descending!, s}) : ({...descending!}..remove(s))),
                              ),
                            ToolButton(
                              icon: AppIcons.arrowUp,
                              extent: 18,
                              tooltip: 'Sposta su',
                              onPressed: i == 0 ? null : () => move(i, -1),
                            ),
                            ToolButton(
                              icon: AppIcons.arrowDown,
                              extent: 18,
                              tooltip: 'Sposta giù',
                              onPressed: i == selected.length - 1 ? null : () => move(i, 1),
                            ),
                            ToolButton(
                              icon: AppIcons.removeCircle,
                              extent: 18,
                              color: c.danger,
                              tooltip: 'Togli $s',
                              onPressed: () => onChanged(List.of(selected)..removeAt(i)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: Gap.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: PulldownButton(
            icon: AppIcons.add,
            label: 'Aggiungi colonna',
            tooltip: 'Aggiungi una colonna',
            entries: () => [
              for (final col in remaining)
                MenuEntry<Object?>(col.name, onSelected: () => onChanged([...selected, col.name])),
              if (remaining.isEmpty && !expressions) const MenuEntry<Object?>('Nessun\'altra colonna', enabled: false),
              if (expressions) ...[
                if (remaining.isNotEmpty) const MenuEntry<Object?>.divider(),
                MenuEntry<Object?>(
                  'Espressione…',
                  value: _expression,
                  onSelected: () async {
                    final e = await promptText(context, 'Espressione dell\'indice', label: 'Ad esempio lower(email)');
                    if (e != null && e.trim().isNotEmpty) onChanged([...selected, '(${e.trim()})']);
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// "Verifica dati" button and its result, for constraints added to a table
/// with rows.
class _DataCheckBar extends StatefulWidget {
  const _DataCheckBar({required this.ctx, required this.constraint});
  final ConstraintContext ctx;

  /// Current definition from the form (null while incomplete).
  final Object? Function() constraint;

  @override
  State<_DataCheckBar> createState() => _DataCheckBarState();
}

class _DataCheckBarState extends State<_DataCheckBar> {
  bool _running = false;
  String? _result;
  StatusKind _kind = StatusKind.info;
  DataCheck? _failed;

  Future<void> _run() async {
    final dc = widget.ctx.connection, c = widget.constraint();
    if (dc == null || c == null) return;
    final checks = DataChecks(widget.ctx.dialect).forConstraint(widget.ctx.table, c);
    setState(() {
      _running = true;
      _result = null;
      _failed = null;
    });
    try {
      final session = dc.meta!;
      for (final check in checks) {
        final n = await countViolations(session, check);
        if (n > 0) {
          _failed = check;
          _kind = StatusKind.warning;
          _result = '${check.label}: $n';
          return;
        }
      }
      _kind = StatusKind.success;
      _result = 'I dati esistenti rispettano il vincolo';
    } catch (e) {
      _kind = StatusKind.danger;
      _result = 'Verifica non riuscita: ${describeError(e).split('\n').first}';
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.ctx.connection == null || widget.ctx.isNew) return const SizedBox();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PushButton(label: 'Verifica dati', onPressed: _running ? null : _run),
        const SizedBox(width: Gap.sm),
        if (_running) const Flexible(child: StatusLine.busy('Verifica in corso…')),
        if (_result != null)
          Flexible(
            child: StatusLine(
              _result!,
              kind: _kind,
              maxLines: 1,
              detailsLabel: 'Apri le righe',
              onDetails: _failed == null
                  ? null
                  : () => AppScope.read(context).sqlEditorWith(widget.ctx.connection!, _failed!.rowsSql),
            ),
          ),
      ],
    );
  }
}

/// Deferrable / initially deferred options, when the DBMS has them.
List<Widget> _deferrableRows(ConstraintContext ctx, ConstraintState st, ValueChanged<ConstraintState> on) {
  if (!ctx.caps.has(DesignFeature.deferrableConstraints)) return const [];
  return [
    FormRow(
      label: 'Verifica',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxRow(
            value: st.deferrable,
            label: 'Differibile (DEFERRABLE)',
            onChanged: (v) => on(st.copyWith(deferrable: v, initiallyDeferred: v && st.initiallyDeferred)),
          ),
          CheckboxRow(
            value: st.initiallyDeferred,
            label: 'Verificato alla fine della transazione (INITIALLY DEFERRED)',
            onChanged: st.deferrable ? (v) => on(st.copyWith(initiallyDeferred: v)) : null,
          ),
        ],
      ),
    ),
  ];
}

/// "Do not check the existing rows" option.
Widget? _noValidateRow(
  ConstraintContext ctx,
  ConstraintState st,
  ValueChanged<ConstraintState> on, {
  bool existing = false,
}) {
  if (ctx.isNew || existing || !ctx.caps.has(DesignFeature.addNotValidated)) return null;
  return FormRow(
    label: 'Dati esistenti',
    help: 'Il vincolo vale per le nuove righe; le esistenti si validano in seguito.',
    child: CheckboxRow(
      value: !st.validated,
      label: 'Non verificare le righe già presenti',
      onChanged: (v) => on(st.copyWith(validated: !v)),
    ),
  );
}

Widget _errorLine(String? error) =>
    error == null ? const SizedBox() : Flexible(child: StatusLine(error, kind: StatusKind.danger));

// ---------------------------------------------------------------------------
// Primary key and UNIQUE
// ---------------------------------------------------------------------------

class _KeyDialog extends StatefulWidget {
  const _KeyDialog({required this.ctx, required this.kind, this.initial, this.referencedBy = const []});
  final ConstraintContext ctx;
  final ConstraintKind kind;
  final Object? initial;

  /// Foreign keys of other tables referencing this key (dropped and added
  /// back around the change).
  final List<String> referencedBy;

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  late final TextEditingController _name;
  late List<String> _columns;
  late ConstraintState _state;
  bool? _clustered;
  String? _error;

  bool get _pk => widget.kind == ConstraintKind.primaryKey;
  ConstraintContext get ctx => widget.ctx;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    final t = ctx.table;
    switch (init) {
      case PrimaryKeyDef p:
        _name = TextEditingController(text: p.name ?? '');
        _columns = List.of(p.columns);
        _state = p.state;
        _clustered = p.clustered;
      case UniqueDef u:
        _name = TextEditingController(text: u.name ?? '');
        _columns = List.of(u.columns);
        _state = u.state;
      default:
        _columns = _pk ? [for (final c in t.columns.take(1)) c.name] : [];
        _state = ConstraintState.standard;
        _name = TextEditingController(
          text: ctx.dialect.family == DbFamily.mysql && _pk
              ? 'PRIMARY'
              : ctx.freeName(ctx.ddl.autoName(t, widget.kind, columns: _columns)),
        );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Object? _current() {
    if (_columns.isEmpty) return null;
    final n = _name.text.trim().isEmpty ? null : _name.text.trim();
    return _pk
        ? PrimaryKeyDef(name: n, columns: _columns, clustered: _clustered, state: _state)
        : UniqueDef(name: n, columns: _columns, state: _state);
  }

  void _save() {
    final c = _current();
    String? err;
    if (c == null) err = 'Scegli almeno una colonna';
    final n = _name.text.trim();
    final initialName = switch (widget.initial) {
      PrimaryKeyDef p => p.name,
      UniqueDef u => u.name,
      _ => null,
    };
    if (err == null &&
        n.isNotEmpty &&
        n.toLowerCase() != initialName?.toLowerCase() &&
        ctx.takenNames.contains(n.toLowerCase())) {
      err = 'Il nome "$n" è già usato nella tabella';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop<Object>(
      context,
      c is PrimaryKeyDef ? ConstraintEdit<PrimaryKeyDef>(c) : ConstraintEdit<UniqueDef>(c as UniqueDef),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nullable = [
      for (final col in _columns)
        if (ctx.table.column(col)?.nullable ?? false) col,
    ];
    final existing = widget.initial != null;
    return SheetScaffold(
      title: _pk
          ? (existing ? 'Modifica chiave primaria' : 'Nuova chiave primaria')
          : (existing ? 'Modifica vincolo UNIQUE' : 'Nuovo vincolo UNIQUE'),
      subtitle: ctx.table.name,
      onSubmit: _save,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormGroup(
              children: [
                FormRow(
                  label: 'Nome',
                  child: MacTextField(
                    controller: _name,
                    autofocus: !existing,
                    enabled: !(_pk && ctx.dialect.family == DbFamily.mysql),
                  ),
                ),
                if (_pk && ctx.dialect.family == DbFamily.sqlServer)
                  FormRow(
                    label: 'Indice',
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: PopUpButton<bool?>(
                        value: _clustered,
                        items: const [
                          (null, 'Predefinito del server', null),
                          (true, 'CLUSTERED', null),
                          (false, 'NONCLUSTERED', null),
                        ],
                        onChanged: (v) => setState(() => _clustered = v),
                      ),
                    ),
                  ),
                ..._deferrableRows(ctx, _state, (s) => setState(() => _state = s)),
              ],
            ),
            const SectionLabel(
              'Colonne',
              padding: EdgeInsets.only(top: Gap.md, bottom: Gap.xs),
            ),
            _ColumnList(columns: ctx.table.columns, selected: _columns, onChanged: (v) => setState(() => _columns = v)),
            if (_pk && nullable.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Notice(message: 'Le colonne ${nullable.join(', ')} ammettono NULL: diventeranno NOT NULL.'),
              ),
            if (_pk && ctx.table.primaryKey != null && !existing)
              const Padding(
                padding: EdgeInsets.only(top: Gap.sm),
                child: Notice(message: 'La tabella ha già una chiave primaria: verrà sostituita.'),
              ),
            if (widget.referencedBy.isNotEmpty && existing)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Notice(
                  message:
                      'Le chiavi esterne ${widget.referencedBy.join(', ')} fanno riferimento a questa chiave: verranno '
                      'eliminate e ricreate.',
                ),
              ),
          ],
        ),
      ),
      leading: [
        Flexible(
          child: _DataCheckBar(ctx: ctx, constraint: _current),
        ),
        _errorLine(_error),
      ],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: existing ? 'Applica' : 'Crea', onPressed: _save),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// CHECK
// ---------------------------------------------------------------------------

class _CheckDialog extends StatefulWidget {
  const _CheckDialog({required this.ctx, this.initial});
  final ConstraintContext ctx;
  final CheckDef? initial;

  @override
  State<_CheckDialog> createState() => _CheckDialogState();
}

class _CheckDialogState extends State<_CheckDialog> {
  late final TextEditingController _name;
  late final TextEditingController _expr = TextEditingController(text: widget.initial?.expression ?? '');
  late ConstraintState _state = widget.initial?.state ?? ConstraintState.standard;
  String? _error;

  ConstraintContext get ctx => widget.ctx;

  @override
  void initState() {
    super.initState();
    final n =
        widget.initial?.name ??
        ctx.freeName(ctx.ddl.autoName(ctx.table, ConstraintKind.check, n: ctx.table.checks.length + 1));
    _name = TextEditingController(text: n);
  }

  @override
  void dispose() {
    _name.dispose();
    _expr.dispose();
    super.dispose();
  }

  CheckDef? _current() {
    final e = _expr.text.trim();
    if (e.isEmpty) return null;
    final n = _name.text.trim();
    return CheckDef(name: n.isEmpty ? null : n, expression: e, state: _state);
  }

  void _save() {
    final c = _current();
    final n = _name.text.trim();
    String? err;
    if (c == null) err = 'Scrivi la condizione da verificare';
    if (err == null &&
        n.isNotEmpty &&
        n.toLowerCase() != widget.initial?.name?.toLowerCase() &&
        ctx.takenNames.contains(n.toLowerCase())) {
      err = 'Il nome "$n" è già usato nella tabella';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, ConstraintEdit(c!));
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final noValidate = _noValidateRow(ctx, _state, (s) => setState(() => _state = s), existing: widget.initial != null);
    return SheetScaffold(
      title: widget.initial == null ? 'Nuovo vincolo CHECK' : 'Modifica vincolo CHECK',
      subtitle: ctx.table.name,
      onSubmit: _save,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            children: [
              FormRow(
                label: 'Nome',
                child: MacTextField(controller: _name),
              ),
              FormRow(
                label: 'Condizione',
                help: 'Espressione SQL che ogni riga deve rispettare',
                child: MacTextField(controller: _expr, mono: true, maxLines: 4, autofocus: true, hint: 'qty > 0'),
              ),
              ?noValidate,
            ],
          ),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              Text('Colonne:', style: uiText(TypeSize.small, color: c.textSecondary)),
              for (final col in ctx.table.columns)
                LinkButton(
                  label: col.name,
                  onPressed: () {
                    final q = ctx.dialect.quoteIdent(col.name);
                    final sel = _expr.selection;
                    final text = _expr.text;
                    final at = sel.isValid ? sel.start : text.length;
                    _expr.value = TextEditingValue(
                      text: text.replaceRange(at, sel.isValid ? sel.end : at, q),
                      selection: TextSelection.collapsed(offset: at + q.length),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
      leading: [
        Flexible(
          child: _DataCheckBar(ctx: ctx, constraint: _current),
        ),
        _errorLine(_error),
      ],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: widget.initial == null ? 'Crea' : 'Applica', onPressed: _save),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Foreign key
// ---------------------------------------------------------------------------

class _ForeignKeyDialog extends StatefulWidget {
  const _ForeignKeyDialog({
    required this.ctx,
    required this.tables,
    required this.loadTable,
    this.initial,
    this.prefill,
  });
  final ConstraintContext ctx;
  final ForeignKeyDef? initial;
  final ForeignKeyDef? prefill;
  final List<DbTable> tables;
  final Future<TableDef?> Function(DbTable t) loadTable;

  @override
  State<_ForeignKeyDialog> createState() => _ForeignKeyDialogState();
}

class _ForeignKeyDialogState extends State<_ForeignKeyDialog> {
  late final ForeignKeyDef? _seed = widget.initial ?? widget.prefill;
  late final TextEditingController _name = TextEditingController(text: _seed?.name ?? '');
  DbTable? _refTable;
  TableDef? _ref;
  bool _loading = false;
  final List<(String?, String?)> _pairs = [];
  late FkRule _onDelete = _seed?.onDelete ?? FkRule.noAction;
  late FkRule _onUpdate = _seed?.onUpdate ?? FkRule.noAction;
  late FkMatch _match = _seed?.match ?? FkMatch.simple;
  late ConstraintState _state = _seed?.state ?? ConstraintState.standard;
  String? _error;

  ConstraintContext get ctx => widget.ctx;

  @override
  void initState() {
    super.initState();
    final init = _seed;
    if (init != null) {
      if (widget.initial == null && init.name == null) {
        _name.text = ctx.freeName(ctx.ddl.autoName(ctx.table, ConstraintKind.foreignKey, refTable: init.refTable));
      }
      for (var i = 0; i < init.columns.length; i++) {
        _pairs.add((init.columns[i], i < init.refColumns.length ? init.refColumns[i] : null));
      }
      final match = widget.tables.where((t) => t.name.toLowerCase() == init.refTable.toLowerCase());
      _select(
        match.firstOrNull ??
            DbTable(catalog: init.refCatalog, schema: init.refSchema, name: init.refTable, type: 'TABLE'),
        keepPairs: true,
      );
    } else {
      _pairs.add((null, null));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _select(DbTable t, {bool keepPairs = false}) async {
    setState(() {
      _refTable = t;
      _ref = null;
      _loading = true;
    });
    final def = await widget.loadTable(t);
    if (!mounted || _refTable != t) return;
    setState(() {
      _ref = def;
      _loading = false;
      if (!keepPairs && def != null) {
        // Propose the primary key (or the first UNIQUE) of the referenced table.
        final key = def.primaryKey?.columns ?? def.uniques.firstOrNull?.columns ?? const [];
        _pairs
          ..clear()
          ..addAll([for (final k in key) (_proposeColumn(t.name, k), k)]);
        if (_pairs.isEmpty) _pairs.add((null, null));
        if (_name.text.trim().isEmpty || widget.initial == null) {
          _name.text = ctx.freeName(ctx.ddl.autoName(ctx.table, ConstraintKind.foreignKey, refTable: t.name));
        }
      }
    });
  }

  /// Column of the table likely to reference [key] of [table]:
  /// customers.id ← customers_id, customer_id, customerid, id (not a key).
  String? _proposeColumn(String table, String key) {
    final singular = table.length > 1 && table.toLowerCase().endsWith('s')
        ? table.substring(0, table.length - 1)
        : table;
    final names = ['${table}_$key', '${singular}_$key', '$singular$key', '$table$key'].map((e) => e.toLowerCase());
    for (final n in names) {
      final c = ctx.table.columns.where((c) => c.name.toLowerCase() == n).firstOrNull;
      if (c != null) return c.name;
    }
    return ctx.table.columns
        .where((c) => c.name.toLowerCase() == key.toLowerCase() && !ctx.table.isPk(c.name))
        .firstOrNull
        ?.name;
  }

  ForeignKeyDef? _current() {
    final t = _refTable;
    if (t == null || _pairs.isEmpty || _pairs.any((p) => p.$1 == null || p.$2 == null)) return null;
    final n = _name.text.trim();
    return ForeignKeyDef(
      name: n.isEmpty ? null : n,
      columns: [for (final p in _pairs) p.$1!],
      refCatalog: t.catalog,
      refSchema: t.schema,
      refTable: t.name,
      refColumns: [for (final p in _pairs) p.$2!],
      onDelete: _onDelete,
      onUpdate: _onUpdate,
      match: _match,
      state: _state,
    );
  }

  List<String> get _warnings {
    final f = _current();
    final ref = _ref;
    if (f == null || ref == null) return const [];
    final w = <String>[];
    final refCols = f.refColumns.map((e) => e.toLowerCase()).join(',');
    bool same(List<String> cols) => cols.map((e) => e.toLowerCase()).join(',') == refCols;
    final keyed =
        same(ref.primaryKey?.columns ?? const []) ||
        ref.uniques.any((u) => same(u.columns)) ||
        ref.indexes.any((i) => i.unique && same(i.columns));
    if (!keyed) {
      w.add(
        'Le colonne ${f.refColumns.join(', ')} di ${ref.name} non sono chiave primaria né univoche: il database rifiuterà la chiave esterna.',
      );
    }
    for (var i = 0; i < f.columns.length; i++) {
      final a = ctx.table.column(f.columns[i]), b = ref.column(f.refColumns[i]);
      if (a != null && b != null && !sameType(a, b)) {
        w.add('Tipi diversi: ${a.name} ${a.fullType} → ${b.name} ${b.fullType}.');
      }
      if (a != null && !a.nullable && (_onDelete == FkRule.setNull || _onUpdate == FkRule.setNull)) {
        w.add('SET NULL richiede che ${a.name} ammetta valori NULL.');
      }
    }
    final indexed = ctx.table.indexes.any(
      (i) =>
          i.columns.take(f.columns.length).map((e) => e.toLowerCase()).join(',') ==
          f.columns.map((e) => e.toLowerCase()).join(','),
    );
    final pkFirst =
        (ctx.table.primaryKey?.columns ?? const []).take(f.columns.length).map((e) => e.toLowerCase()).join(',') ==
        f.columns.map((e) => e.toLowerCase()).join(',');
    if (!indexed && !pkFirst && ctx.dialect.family != DbFamily.mysql && ctx.caps.has(DesignFeature.indexes)) {
      w.add('Nessun indice su ${f.columns.join(', ')}: conviene crearne uno, rende veloci join ed eliminazioni.');
    }
    return w;
  }

  List<FkRule> get _deleteRules => [
    for (final r in FkRule.values)
      if (r != FkRule.setDefault || ctx.caps.has(DesignFeature.fkSetDefault))
        if (ctx.dialect.family != DbFamily.oracle || r != FkRule.restrict) r,
  ];

  List<FkRule> get _updateRules => ctx.caps.has(DesignFeature.fkOnUpdate)
      ? _deleteRules
      : [FkRule.noAction, if (ctx.dialect.family == DbFamily.db2) FkRule.restrict];

  void _save() {
    final f = _current();
    final n = _name.text.trim();
    String? err;
    if (_refTable == null) err = 'Scegli la tabella a cui fare riferimento';
    if (err == null && f == null) err = 'Completa le coppie di colonne';
    if (err == null &&
        n.isNotEmpty &&
        n.toLowerCase() != widget.initial?.name?.toLowerCase() &&
        ctx.takenNames.contains(n.toLowerCase())) {
      err = 'Il nome "$n" è già usato nella tabella';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, ConstraintEdit(f!));
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final head = uiText(TypeSize.caption, weight: FontWeight.w600, color: c.textSecondary);
    Widget rule(FkRule v, List<FkRule> options, ValueChanged<FkRule> on) => Align(
      alignment: Alignment.centerLeft,
      child: PopUpButton<FkRule>(
        value: options.contains(v) ? v : FkRule.noAction,
        items: [for (final r in options) (r, r.sql, null)],
        onChanged: (x) => setState(() => on(x)),
      ),
    );
    final refCols = _ref?.columns ?? const <ColumnDef>[];
    final noValidate = _noValidateRow(ctx, _state, (s) => setState(() => _state = s), existing: widget.initial != null);
    return SheetScaffold(
      title: widget.initial == null ? 'Nuova chiave esterna' : 'Modifica chiave esterna',
      subtitle: ctx.table.name,
      onSubmit: _save,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormGroup(
              children: [
                FormRow(
                  label: 'Nome',
                  child: MacTextField(controller: _name),
                ),
                FormRow(
                  label: 'Tabella riferita',
                  child: Row(
                    children: [
                      Expanded(
                        child: PopUpButton<DbTable?>(
                          value: _refTable == null
                              ? null
                              : widget.tables.where((t) => t.key == _refTable!.key).firstOrNull ?? _refTable,
                          expand: true,
                          placeholder: 'Scegli una tabella',
                          items: [
                            for (final t in {...widget.tables, ?_refTable})
                              (t, t.schema == null ? t.name : '${t.schema}.${t.name}', null),
                          ],
                          onChanged: (t) {
                            if (t != null) _select(t);
                          },
                        ),
                      ),
                      if (_loading) ...[const SizedBox(width: Gap.sm), const Spinner()],
                    ],
                  ),
                ),
                FormRow(label: 'In eliminazione', child: rule(_onDelete, _deleteRules, (r) => _onDelete = r)),
                FormRow(
                  label: 'In aggiornamento',
                  help: ctx.caps.reason(DesignFeature.fkOnUpdate),
                  child: rule(_onUpdate, _updateRules, (r) => _onUpdate = r),
                ),
                if (ctx.dialect.family == DbFamily.postgres)
                  FormRow(
                    label: 'Corrispondenza',
                    help: 'FULL: tutte le colonne NULL oppure nessuna',
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: PopUpButton<FkMatch>(
                        value: _match,
                        items: [for (final m in FkMatch.values) (m, 'MATCH ${m.sql}', null)],
                        onChanged: (m) => setState(() => _match = m),
                      ),
                    ),
                  ),
                ..._deferrableRows(ctx, _state, (s) => setState(() => _state = s)),
                ?noValidate,
              ],
            ),
            const SizedBox(height: Gap.md),
            Row(
              children: [
                Expanded(child: Text('Colonna di ${ctx.table.name}', style: head)),
                const SizedBox(width: 24),
                Expanded(child: Text('Colonna di ${_refTable?.name ?? 'riferimento'}', style: head)),
                const SizedBox(width: 26),
              ],
            ),
            const SizedBox(height: Gap.xs),
            for (final (i, p) in _pairs.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: PopUpButton<String?>(
                        value: p.$1,
                        expand: true,
                        placeholder: 'colonna',
                        items: [for (final col in ctx.table.columns) (col.name, col.name, null)],
                        onChanged: (v) => setState(() => _pairs[i] = (v, p.$2)),
                      ),
                    ),
                    SizedBox(width: 24, child: Icon(AppIcons.arrowLeft, size: 14, color: c.textTertiary)),
                    Expanded(
                      child: PopUpButton<String?>(
                        value: p.$2,
                        expand: true,
                        placeholder: 'colonna',
                        items: [for (final col in refCols) (col.name, col.name, null)],
                        onChanged: refCols.isEmpty ? null : (v) => setState(() => _pairs[i] = (p.$1, v)),
                      ),
                    ),
                    ToolButton(
                      icon: AppIcons.removeCircle,
                      extent: 18,
                      color: c.danger,
                      tooltip: 'Togli la coppia',
                      onPressed: _pairs.length == 1 ? null : () => setState(() => _pairs.removeAt(i)),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: ToolButton(
                icon: AppIcons.add,
                label: 'Aggiungi colonna',
                tooltip: 'Aggiungi una coppia di colonne (chiave composta)',
                onPressed: () => setState(() => _pairs.add((null, null))),
              ),
            ),
            for (final w in _warnings)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Notice(message: w),
              ),
          ],
        ),
      ),
      leading: [
        Flexible(
          child: _DataCheckBar(ctx: ctx, constraint: _current),
        ),
        _errorLine(_error),
      ],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: widget.initial == null ? 'Crea' : 'Applica', onPressed: _save),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Index
// ---------------------------------------------------------------------------

/// Access methods offered for [family] (null: the default).
List<(String?, String)> indexMethods(DbFamily family) => switch (family) {
  DbFamily.postgres => const [
    (null, 'B-tree (predefinito)'),
    ('hash', 'Hash'),
    ('gin', 'GIN'),
    ('gist', 'GiST'),
    ('brin', 'BRIN'),
    ('spgist', 'SP-GiST'),
  ],
  DbFamily.mysql => const [
    (null, 'B-tree (predefinito)'),
    ('hash', 'Hash'),
    ('fulltext', 'Full-text'),
    ('spatial', 'Spaziale'),
  ],
  DbFamily.oracle => const [(null, 'B-tree (predefinito)'), ('bitmap', 'Bitmap')],
  _ => const [],
};

class _IndexDialog extends StatefulWidget {
  const _IndexDialog({required this.ctx, this.initial});
  final ConstraintContext ctx;
  final IndexDef? initial;

  @override
  State<_IndexDialog> createState() => _IndexDialogState();
}

class _IndexDialogState extends State<_IndexDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initial?.name ?? '');
  late final TextEditingController _where = TextEditingController(text: widget.initial?.where ?? '');
  late List<String> _columns = List.of(widget.initial?.columns ?? const []);
  late Set<String> _desc = {...?widget.initial?.descending};
  late List<String> _include = List.of(widget.initial?.include ?? const []);
  late bool _unique = widget.initial?.unique ?? false;
  late bool _clustered = widget.initial?.clustered ?? false;
  late String? _method = widget.initial?.method;
  bool _online = false;

  /// Last name given automatically: the name follows the columns until the
  /// user types another one.
  String _lastAuto = '';
  String? _error;

  ConstraintContext get ctx => widget.ctx;

  String get _autoName => ctx.freeName(
    ctx.ddl.autoName(ctx.table, null, columns: [for (final c in _columns) IndexDef.isExpression(c) ? 'expr' : c]),
    keep: widget.initial?.name,
  );

  void _setColumns(List<String> v) {
    setState(() {
      _columns = v;
      _desc = _desc.where(v.contains).toSet();
      final automatic = widget.initial == null && (_name.text.isEmpty || _name.text == _lastAuto);
      if (automatic) _name.text = _lastAuto = _autoName;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _where.dispose();
    super.dispose();
  }

  IndexDef? _current() {
    final n = _name.text.trim();
    if (_columns.isEmpty || n.isEmpty) return null;
    final w = _where.text.trim();
    return IndexDef(
      name: n,
      columns: _columns,
      unique: _unique,
      descending: _desc,
      include: _include,
      where: w.isEmpty ? null : w,
      method: _method,
      clustered: _clustered,
      enabled: widget.initial?.enabled ?? true,
    );
  }

  void _save() {
    final i = _current();
    final n = _name.text.trim();
    String? err;
    if (n.isEmpty) err = 'Inserisci il nome dell\'indice';
    if (err == null && _columns.isEmpty) err = 'Scegli almeno una colonna';
    if (err == null &&
        n.toLowerCase() != widget.initial?.name.toLowerCase() &&
        ctx.takenNames.contains(n.toLowerCase())) {
      err = 'Il nome "$n" è già usato nella tabella';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, ConstraintEdit(i!, online: _online));
  }

  @override
  Widget build(BuildContext context) {
    final caps = ctx.caps;
    final methods = indexMethods(ctx.dialect.family);
    final includeOk = caps.has(DesignFeature.indexInclude) && (ctx.dialect.family != DbFamily.db2 || _unique);
    return SheetScaffold(
      title: widget.initial == null ? 'Nuovo indice' : 'Modifica indice',
      subtitle: ctx.table.name,
      onSubmit: _save,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormGroup(
              children: [
                FormRow(
                  label: 'Nome',
                  child: MacTextField(controller: _name, autofocus: widget.initial == null),
                ),
                FormRow(
                  label: 'Tipo',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxRow(
                        value: _unique,
                        label: 'Univoco (UNIQUE)',
                        onChanged: (v) => setState(() => _unique = v),
                      ),
                      if (ctx.dialect.family == DbFamily.sqlServer)
                        CheckboxRow(
                          value: _clustered,
                          label: 'Clustered (ordina fisicamente la tabella)',
                          onChanged: (v) => setState(() => _clustered = v),
                        ),
                    ],
                  ),
                ),
                if (methods.isNotEmpty)
                  FormRow(
                    label: 'Metodo',
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: PopUpButton<String?>(
                        value: methods.any((m) => m.$1 == _method) ? _method : null,
                        items: [for (final m in methods) (m.$1, m.$2, null)],
                        onChanged: (v) => setState(() => _method = v),
                      ),
                    ),
                  ),
                if (caps.has(DesignFeature.indexFilter))
                  FormRow(
                    label: 'Filtro',
                    help: 'Indicizza solo le righe che rispettano la condizione',
                    child: MacTextField(controller: _where, mono: true, token: 'WHERE', hint: 'deleted_at IS NULL'),
                  ),
                if (caps.has(DesignFeature.onlineIndex) && widget.initial == null)
                  FormRow(
                    label: 'Creazione',
                    child: CheckboxRow(
                      value: _online,
                      label: ctx.dialect.family == DbFamily.postgres
                          ? 'Senza bloccare le scritture (CONCURRENTLY)'
                          : 'Online, senza bloccare le scritture',
                      onChanged: (v) => setState(() => _online = v),
                    ),
                  ),
              ],
            ),
            const SectionLabel(
              'Colonne',
              padding: EdgeInsets.only(top: Gap.md, bottom: Gap.xs),
            ),
            _ColumnList(
              columns: ctx.table.columns,
              selected: _columns,
              onChanged: _setColumns,
              descending: caps.has(DesignFeature.indexDescending) ? _desc : null,
              onDescending: (v) => setState(() => _desc = v),
              expressions: ctx.dialect.family != DbFamily.sqlServer,
            ),
            if (includeOk) ...[
              const SectionLabel(
                'Colonne incluse (INCLUDE)',
                padding: EdgeInsets.only(top: Gap.md, bottom: Gap.xs),
              ),
              _ColumnList(
                columns: [
                  for (final c in ctx.table.columns)
                    if (!_columns.contains(c.name)) c,
                ],
                selected: _include,
                onChanged: (v) => setState(() => _include = v),
                emptyText: 'Nessuna: le colonne incluse rendono l\'indice "coprente" per le query che le leggono',
              ),
            ],
          ],
        ),
      ),
      leading: [
        Flexible(
          child: _DataCheckBar(ctx: ctx, constraint: _current),
        ),
        _errorLine(_error),
      ],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: widget.initial == null ? 'Crea' : 'Applica', onPressed: _save),
      ],
    );
  }
}

/// Definitions of the tables a foreign key can reference: the tables of the
/// same catalog / schema of [dc].
Future<List<DbTable>> referenceCandidates(DbConnection dc, TableDef t) async {
  final md = dc.metadata;
  if (md == null) return const [];
  final all = await md.tables(t.catalog, t.schema);
  return [
    for (final x in all)
      if (!x.isView && x.type.toUpperCase().contains('TABLE') && !x.type.toUpperCase().contains('SYSTEM')) x,
  ];
}

/// Loads [t] through the design catalog of [dc].
Future<TableDef?> loadDesignTable(DbConnection dc, DbTable t) async {
  final cat = DesignCatalog.of(dc);
  if (cat == null) return null;
  try {
    return await cat.loadTable(t);
  } catch (_) {
    return null;
  }
}
