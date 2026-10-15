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
  return showDialog<void>(
    context: context,
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
  return showDialog<void>(
    context: context,
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
    return AlertDialog(
      title: Text('Esporta dati · ${widget.tableName}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Formato', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final x in ExportFormat.values)
                    ChoiceChip(
                      label: Text(x.label),
                      selected: f == x,
                      onSelected: (_) => setState(() => _o.format = x),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (widget.loadedRows != null) ...[
                const Text('Righe', style: TextStyle(fontWeight: FontWeight.w600)),
                RadioGroup<bool>(
                  groupValue: _allRows,
                  onChanged: (v) => setState(() => _allRows = v ?? true),
                  child: const Column(
                    children: [
                      RadioListTile(dense: true, value: false, title: Text('Solo righe caricate / filtrate')),
                      RadioListTile(
                        dense: true,
                        value: true,
                        title: Text('Tutte le righe (riesegue la query)'),
                      ),
                    ],
                  ),
                ),
              ],
              if (f == ExportFormat.csv)
                TextField(
                  controller: _delimiter,
                  decoration: const InputDecoration(labelText: r'Delimitatore (\t = tab)'),
                ),
              if (f == ExportFormat.csv || f == ExportFormat.tsv)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Intestazione con i nomi di colonna'),
                  value: _o.header,
                  onChanged: (v) => setState(() => _o.header = v ?? true),
                ),
              if (f == ExportFormat.csv || f == ExportFormat.tsv)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Racchiudi sempre i valori tra virgolette'),
                  value: _o.quoteAll,
                  onChanged: (v) => setState(() => _o.quoteAll = v ?? false),
                ),
              if (f != ExportFormat.json && f != ExportFormat.xml && f != ExportFormat.sql)
                TextField(
                  controller: _nullText,
                  decoration: const InputDecoration(labelText: 'Testo per NULL'),
                ),
              if (f == ExportFormat.sql || f == ExportFormat.xml || f == ExportFormat.html)
                TextField(
                  controller: _table,
                  decoration: const InputDecoration(labelText: 'Nome tabella'),
                ),
              if (f == ExportFormat.sql)
                TextField(
                  controller: _batch,
                  decoration: const InputDecoration(labelText: 'Righe per INSERT (multi-row)'),
                ),
              if (_running) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 4),
                Text('$_exported righe lette…'),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _running ? null : () => Navigator.pop(context), child: const Text('Annulla')),
        OutlinedButton.icon(
          onPressed: _running ? null : _toClipboard,
          icon: const Icon(Icons.content_paste, size: 16),
          label: const Text('Copia negli appunti'),
        ),
        FilledButton.icon(
          onPressed: _running ? null : _toFile,
          icon: const Icon(Icons.save_alt, size: 16),
          label: const Text('Salva su file…'),
        ),
      ],
    );
  }
}
