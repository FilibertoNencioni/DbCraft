import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../drivers/db_session.dart';
import '../../model/db_objects.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../ui/widgets/common.dart';
import 'compare_engine.dart';
import 'sync_script.dart';

/// Statements shown in the preview (the full script is used by the actions).
const _previewStatements = 300;

/// Synchronization script of a comparison (target ← source).
Future<void> showSyncScriptDialog(
  BuildContext context, {
  required DbConnection target,
  required DbTable targetTable,
  required CompareResult result,
  required List<String> targetColumns,
  required List<int?> targetTypes,
  VoidCallback? onExecuted,
}) => showSheet<void>(
  context,
  size: SheetSize.xlarge,
  builder: (_) => _SyncScriptDialog(
    target: target,
    table: targetTable,
    result: result,
    columns: targetColumns,
    types: targetTypes,
    onExecuted: onExecuted,
  ),
);

class _SyncScriptDialog extends StatefulWidget {
  const _SyncScriptDialog({
    required this.target,
    required this.table,
    required this.result,
    required this.columns,
    required this.types,
    this.onExecuted,
  });

  final DbConnection target;
  final DbTable table;
  final CompareResult result;
  final List<String> columns;
  final List<int?> types;
  final VoidCallback? onExecuted;

  @override
  State<_SyncScriptDialog> createState() => _SyncScriptDialogState();
}

class _SyncScriptDialogState extends State<_SyncScriptDialog> {
  final _o = SyncScriptOptions();
  late final _builder = SyncScriptBuilder(
    dialect: widget.target.dialect,
    tableName: widget.target.dialect.tableName(widget.table),
    columns: widget.columns,
    keyCount: widget.result.keyCount,
    sqlTypes: widget.types,
  );
  late List<SyncStatement> _statements = _builder.build(widget.result, _o);
  bool _running = false;
  bool _cancel = false;
  int _done = 0;

  CompareResult get r => widget.result;

  void _rebuild() => setState(() => _statements = _builder.build(r, _o));

  String get _header =>
      'Sincronizzazione di ${widget.target.dialect.tableName(widget.table)} su "${widget.target.config.name}"\n'
      'Generato da DbCraft il ${DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ')}'
      '${r.truncated ? '\nATTENZIONE: il confronto è stato limitato, lo script copre solo una parte dei dati.' : ''}';

  String _script() => _builder.script(_statements, header: _header);

  String _preview() {
    if (_statements.length <= _previewStatements) return _script();
    final head = _builder.script(_statements.take(_previewStatements).toList(), header: _header);
    return '$head\n-- … altre ${_statements.length - _previewStatements} istruzioni '
        '(incluse in Copia, Salva ed editor SQL)';
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _script()));
    if (mounted) showToast(context, '${_statements.length} istruzioni copiate negli appunti');
  }

  Future<void> _save() async {
    final loc = await getSaveLocation(
      suggestedName: 'sync_${widget.table.name}.sql',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SQL', extensions: ['sql']),
      ],
    );
    if (loc == null) return;
    await File(loc.path).writeAsString(_script());
    if (mounted) showToast(context, 'Script salvato in ${loc.path}');
  }

  Future<void> _openEditor() async {
    final app = AppScope.read(context);
    final sql = _script();
    Navigator.pop(context);
    await app.openSqlEditor(widget.target, initialSql: sql, catalog: widget.table.catalog);
  }

  Future<void> _execute() async {
    final dc = widget.target;
    final n = _statements.length;
    final deletes = _statements.where((s) => s.kind == RowDiff.onlyTarget).length;
    final prod = dc.config.type.confirmExecute;
    final ok = await confirmDialog(
      context,
      prod ? 'Connessione di produzione' : 'Eseguire la sincronizzazione?',
      'Verranno eseguite $n istruzioni su ${dc.dialect.tableName(widget.table)} ("${dc.config.name}") '
      'in un\'unica transazione${deletes > 0 ? ', incluse $deletes DELETE' : ''}.',
      ok: 'Esegui',
      destructive: prod || deletes > 0,
    );
    if (!ok || !mounted) return;
    setState(() {
      _running = true;
      _cancel = false;
      _done = 0;
    });
    DbSession? s;
    var noMatch = 0;
    try {
      s = await dc.openSession(catalog: widget.table.catalog);
      await s.setAutoCommit(false);
      for (final st in _statements) {
        if (_cancel) break;
        final res = await s.execute(st.sql, params: st.params);
        if (st.kind != RowDiff.onlySource && res.rowsAffected == 0) noMatch++;
        _done++;
        if (_done % 50 == 0 && mounted) setState(() {});
      }
      if (_cancel) {
        await s.rollback();
        if (mounted) showToast(context, 'Sincronizzazione annullata: nessuna modifica applicata');
        return;
      }
      await s.commit();
      widget.onExecuted?.call();
      if (!mounted) return;
      Navigator.pop(context);
      showToast(
        context,
        'Sincronizzazione completata: $n istruzioni'
        '${noMatch > 0 ? ' ($noMatch senza righe corrispondenti)' : ''}',
      );
    } catch (e) {
      try {
        await s?.rollback();
      } catch (_) {}
      if (mounted) {
        showErrorDialog(
          context,
          e,
          title: 'Sincronizzazione annullata all\'istruzione ${_done + 1} (rollback eseguito)',
        );
      }
    } finally {
      await s?.close();
      if (mounted) setState(() => _running = false);
    }
  }

  Widget _option(
    String label,
    int count,
    bool value,
    ValueChanged<bool> onChanged, {
    String? help,
    bool danger = false,
  }) {
    return FormRow(
      label: label,
      help: help,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          CountBadge(count, prominent: danger && value && count > 0),
          const SizedBox(width: Gap.sm),
          DbSwitch(
            value: value,
            onChanged: _running
                ? null
                : (v) {
                    onChanged(v);
                    _rebuild();
                  },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final dc = widget.target;
    final readOnly = dc.config.readOnly;
    final empty = _statements.isEmpty;
    return PopScope(
      canPop: !_running,
      child: SheetScaffold(
        title: 'Script di sincronizzazione · ${widget.table.name}',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormGroup(
              children: [
                _option(
                  'INSERT delle righe presenti solo nell\'origine',
                  r.count(RowDiff.onlySource),
                  _o.insert,
                  (v) => _o.insert = v,
                ),
                _option(
                  'UPDATE delle righe diverse',
                  r.count(RowDiff.different),
                  _o.update,
                  (v) => _o.update = v,
                  help: 'Solo le colonne con valori diversi',
                ),
                _option(
                  'DELETE delle righe presenti solo nella destinazione',
                  r.count(RowDiff.onlyTarget),
                  _o.delete,
                  (v) => _o.delete = v,
                  help: 'Elimina dati dalla destinazione',
                  danger: true,
                ),
              ],
            ),
            if (r.truncated)
              const Padding(
                padding: EdgeInsets.only(bottom: Gap.sm),
                child: Notice(
                  message: 'Il confronto è stato limitato dal numero massimo di righe: lo script non copre tutta la tabella.',
                ),
              ),
            Expanded(
              child: empty
                  ? const EmptyState(
                      icon: AppIcons.checkCircle,
                      title: 'Nessuna istruzione',
                      message: 'Attiva almeno un tipo di modifica con righe da sincronizzare.',
                    )
                  : SingleChildScrollView(child: CodeBox(_preview(), copy: false)),
            ),
            if (_running) ...[
              const SizedBox(height: Gap.md),
              ProgressBar(value: _statements.isEmpty ? null : _done / _statements.length),
              const SizedBox(height: Gap.xs),
              Text(
                '$_done / ${_statements.length} istruzioni',
                style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular),
              ),
            ],
          ],
        ),
        leading: [
          PushButton(label: 'Copia', onPressed: _running || empty ? null : _copy),
          PushButton(label: 'Salva…', onPressed: _running || empty ? null : _save),
          PushButton(label: 'Apri nell\'editor SQL', onPressed: _running || empty ? null : _openEditor),
        ],
        actions: [
          if (_running)
            PushButton(label: 'Interrompi', onPressed: () => setState(() => _cancel = true))
          else
            PushButton(label: 'Chiudi', onPressed: () => Navigator.pop(context)),
          PushButton(
            label: 'Esegui sulla destinazione',
            kind: _o.delete ? PushButtonKind.destructive : PushButtonKind.defaultAction,
            tooltip: readOnly
                ? 'La connessione di destinazione è in sola lettura'
                : 'Esegue lo script in una transazione',
            onPressed: _running || empty || readOnly ? null : _execute,
          ),
        ],
      ),
    );
  }
}
