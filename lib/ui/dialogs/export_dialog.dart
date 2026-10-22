import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/db_objects.dart';
import '../../services/data_transfer.dart';
import '../../state/db_connection.dart';
import '../../state/result_set_model.dart';
import '../widgets/common.dart';

/// Export of a result set shown in a grid.
Future<void> showResultExportDialog(BuildContext context, ResultSetModel m) {
  final table = m.table;
  return showSheet<void>(
    context,
    builder: (_) => _ExportDialog(
      connection: m.connection,
      columns: m.columns.map((c) => c.name).toList(),
      tableName: table == null ? 'export' : table.name,
      qualifiedName: table == null ? 'table_name' : m.connection.dialect.tableName(table),
      loadedRows: () => m.view.map((i) => m.rows[i].values).toList(),
      hasMore: m.hasMore,
      sql: m.sql,
      params: m.params,
    ),
  );
}

/// Export of a whole table (navigator "Export data").
Future<void> showTableExportDialog(BuildContext context, DbConnection dc, DbTable t) async {
  final cols = await dc.metadata!.columns(t);
  if (!context.mounted) return;
  return showSheet<void>(
    context,
    builder: (_) => _ExportDialog(
      connection: dc,
      columns: cols.map((c) => c.name).toList(),
      tableName: t.name,
      qualifiedName: dc.dialect.tableName(t),
      loadedRows: null,
      hasMore: true,
      sql: 'SELECT * FROM ${dc.dialect.tableName(t)}',
      params: const [],
    ),
  );
}

/// Streams every row of [sql] page by page using a dedicated session, so the
/// export never interferes with the editor transaction.
Stream<List<List<Object?>>> streamQuery(
  DbConnection dc,
  String sql,
  List<Object?> params, {
  int pageSize = 2000,
}) async* {
  final session = await dc.openSession(readOnly: true);
  try {
    var page = await session.execute(sql, params: params, fetchSize: pageSize);
    yield page.rows;
    while (page.hasMore && page.cursorId != null) {
      page = await session.fetchMore(page.cursorId!, pageSize);
      yield page.rows;
    }
  } finally {
    await session.close();
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({
    required this.connection,
    required this.columns,
    required this.tableName,
    required this.qualifiedName,
    required this.loadedRows,
    required this.hasMore,
    required this.sql,
    required this.params,
  });

  final DbConnection connection;
  final List<String> columns;
  final String tableName;
  final String qualifiedName;
  final List<List<Object?>> Function()? loadedRows;
  final bool hasMore;
  final String sql;
  final List<Object?> params;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final ExportOptions _o = ExportOptions(
    tableName: widget.qualifiedName,
    dialect: widget.connection.dialect,
  );
  late bool _allRows = widget.loadedRows == null || widget.hasMore;
  late final _delimiter = TextEditingController(text: _o.delimiter);
  late final _nullText = TextEditingController(text: _o.nullText);
  late final _table = TextEditingController(text: _o.tableName);
  late final _batch = TextEditingController(text: '${_o.insertBatch}');
  bool _running = false;
  int _exported = 0;

  void _sync() {
    _o
      ..delimiter = _delimiter.text.isEmpty ? ',' : _delimiter.text.replaceAll(r'\t', '\t')
      ..nullText = _nullText.text
      ..tableName = _table.text
      ..insertBatch = int.tryParse(_batch.text) ?? 1;
  }

  Stream<List<List<Object?>>> _source() {
    if (!_allRows && widget.loadedRows != null) {
      return Stream.value(widget.loadedRows!());
    }
    return streamQuery(widget.connection, widget.sql, widget.params).map((p) {
      _exported += p.length;
      if (mounted) setState(() {});
      return p;
    });
  }

  Future<void> _toFile() async {
    _sync();
    final loc = await getSaveLocation(
      suggestedName: '${widget.tableName}.${_o.format.extension}',
      acceptedTypeGroups: [
        XTypeGroup(label: _o.format.label, extensions: [_o.format.extension]),
      ],
    );
    if (loc == null) return;
    setState(() {
      _running = true;
      _exported = 0;
    });
    try {
      final n = await DataExporter.exportToFile(File(loc.path), widget.columns, _source(), _o);
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, 'Esportate $n righe in ${loc.path}');
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Esportazione fallita');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _toClipboard() async {
    _sync();
    setState(() => _running = true);
    try {
      final rows = <List<Object?>>[];
      await for (final p in _source()) {
        rows.addAll(p);
      }
      await Clipboard.setData(ClipboardData(text: DataExporter.exportAll(widget.columns, rows, _o)));
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, '${rows.length} righe copiate negli appunti');
    } catch (e) {
      if (mounted) showErrorDialog(context, e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _o.format;
    final c = DbColors.of(context);
    final csv = f == ExportFormat.csv || f == ExportFormat.tsv;
    return PopScope(
      canPop: !_running,
      child: SheetScaffold(
      title: 'Esporta dati · ${widget.tableName}',
      onSubmit: _running ? null : _toFile,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            children: [
              FormRow(
                label: 'Formato',
                child: PopUpButton<ExportFormat>(
                  value: f,
                  items: [for (final x in ExportFormat.values) (x, x.label, null)],
                  onChanged: _running ? null : (x) => setState(() => _o.format = x),
                ),
              ),
              if (widget.loadedRows != null)
                FormRow(
                  label: 'Righe',
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: MacRadioGroup<bool>(
                      value: _allRows,
                      items: const [
                        (false, 'Solo righe caricate / filtrate', null),
                        (true, 'Tutte le righe (riesegue la query)', null),
                      ],
                      onChanged: _running ? null : (v) => setState(() => _allRows = v),
                    ),
                  ),
                ),
            ],
          ),
          FormGroup(
            children: [
              if (f == ExportFormat.csv)
                FormRow(
                  label: 'Delimitatore',
                  help: r'\t = tab',
                  child: MacTextField(controller: _delimiter, mono: true, width: 80),
                ),
              if (csv)
                FormRow(
                  label: 'Intestazione',
                  child: CheckboxRow(
                    label: 'Nomi di colonna nella prima riga',
                    value: _o.header,
                    onChanged: (v) => setState(() => _o.header = v),
                  ),
                ),
              if (csv)
                FormRow(
                  label: 'Virgolette',
                  child: CheckboxRow(
                    label: 'Racchiudi sempre i valori',
                    value: _o.quoteAll,
                    onChanged: (v) => setState(() => _o.quoteAll = v),
                  ),
                ),
              if (f != ExportFormat.json && f != ExportFormat.xml && f != ExportFormat.sql)
                FormRow(
                  label: 'Testo per NULL',
                  child: MacTextField(controller: _nullText, mono: true),
                ),
              if (f == ExportFormat.sql || f == ExportFormat.xml || f == ExportFormat.html)
                FormRow(
                  label: 'Nome tabella',
                  child: MacTextField(controller: _table, mono: true),
                ),
              if (f == ExportFormat.sql)
                FormRow(
                  label: 'Righe per INSERT',
                  help: 'INSERT multi-riga',
                  child: NumberField(controller: _batch, min: 1, max: 10000),
                ),
            ],
          ),
          if (_running) ...[
            const ProgressBar(),
            const SizedBox(height: Gap.xs),
            Text(
              '$_exported righe lette…',
              style: uiText(TypeSize.caption, color: c.textSecondary, features: kTabular),
            ),
          ],
        ],
      ),
      actions: [
        PushButton(label: 'Annulla', onPressed: _running ? null : () => Navigator.pop(context)),
        PushButton(label: 'Copia negli appunti', onPressed: _running ? null : _toClipboard),
        PushButton.primary(label: 'Salva su file…', onPressed: _running ? null : _toFile),
      ],
    ),
    );
  }
}
