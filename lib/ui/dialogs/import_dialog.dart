import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../model/db_objects.dart';
import '../../odbc/odbc_ffi.dart';
import '../../services/data_transfer.dart';
import '../../state/db_connection.dart';
import '../widgets/common.dart';

/// CSV → table import wizard (DBeaver "Import data").
Future<void> showImportDialog(BuildContext context, DbConnection dc, DbTable t, {String? initialPath}) async {
  final cols = await dc.metadata!.columns(t);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ImportDialog(dc: dc, table: t, columns: cols, initialPath: initialPath),
  );
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.dc, required this.table, required this.columns, this.initialPath});
  final DbConnection dc;
  final String? initialPath;
  final DbTable table;
  final List<DbColumn> columns;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  String? _path;
  String _raw = '';
  String _delimiter = ',';
  bool _header = true;
  bool _emptyIsNull = true;
  bool _truncate = false;
  List<List<String>> _data = [];
  late List<int?> _mapping = List.filled(widget.columns.length, null);
  bool _running = false;
  int _done = 0;

  List<String> get _csvHeader => _data.isEmpty
      ? []
      : _header
      ? _data.first
      : List.generate(_data.first.length, (i) => 'Colonna ${i + 1}');

  List<List<String>> get _rows => _header && _data.isNotEmpty ? _data.sublist(1) : _data;

  @override
  void initState() {
    super.initState();
    final p = widget.initialPath;
    if (p != null) _load(XFile(p));
  }

  Future<void> _pick() async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv', 'tsv', 'txt']),
      ],
    );
    if (f == null) return;
    await _load(f);
  }

  Future<void> _load(XFile f) async {
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    _raw = utf8.decode(bytes, allowMalformed: true);
    final firstLine = _raw.split('\n').first;
    _delimiter = firstLine.contains('\t')
        ? '\t'
        : firstLine.split(';').length > firstLine.split(',').length
        ? ';'
        : ',';
    setState(() => _path = f.path);
    _parse();
  }

  void _parse() {
    _data = parseCsv(_raw, delimiter: _delimiter);
    final h = _csvHeader.map((e) => e.trim().toLowerCase()).toList();
    _mapping = [
      for (var i = 0; i < widget.columns.length; i++)
        _header
            ? (h.contains(widget.columns[i].name.toLowerCase())
                  ? h.indexOf(widget.columns[i].name.toLowerCase())
                  : null)
            : (i < h.length ? i : null),
    ];
    setState(() {});
  }

  Object? _convert(DbColumn c, String v) {
    if (v.isEmpty && _emptyIsNull) return null;
    switch (c.dataType) {
      case SQL_INTEGER:
      case SQL_SMALLINT:
      case SQL_TINYINT:
      case SQL_BIGINT:
        return int.tryParse(v.trim()) ?? v;
      case SQL_REAL:
      case SQL_FLOAT:
      case SQL_DOUBLE:
        return double.tryParse(v.trim().replaceAll(',', '.')) ?? v;
      default:
        return v;
    }
  }

  Future<void> _import() async {
    final mapped = [
      for (var i = 0; i < widget.columns.length; i++)
        if (_mapping[i] != null) i,
    ];
    if (mapped.isEmpty) {
      showToast(context, 'Associa almeno una colonna', error: true);
      return;
    }
    final d = widget.dc.dialect;
    final tn = d.tableName(widget.table);
    final sql =
        'INSERT INTO $tn (${mapped.map((i) => d.quoteIdent(widget.columns[i].name)).join(', ')}) '
        'VALUES (${mapped.map((_) => '?').join(', ')})';
    setState(() {
      _running = true;
      _done = 0;
    });
    final session = await widget.dc.openSession();
    try {
      await session.setAutoCommit(false);
      if (_truncate) await session.execute(d.truncateSql(widget.table));
      for (final r in _rows) {
        if (r.length == 1 && r.first.isEmpty) continue;
        final params = [
          for (final i in mapped) _convert(widget.columns[i], _mapping[i]! < r.length ? r[_mapping[i]!] : ''),
        ];
        await session.execute(sql, params: params);
        _done++;
        if (_done % 100 == 0 && mounted) setState(() {});
      }
      await session.commit();
      widget.dc.metadata?.clearCache();
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, 'Importate $_done righe in ${widget.table.name}');
    } catch (e) {
      try {
        await session.rollback();
      } catch (_) {}
      if (mounted) {
        showErrorDialog(context, e, title: 'Importazione annullata alla riga ${_done + 1}');
      }
    } finally {
      await session.close();
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final header = _csvHeader;
    return AlertDialog(
      title: Text('Importa CSV in ${widget.table.name}'),
      content: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _running ? null : _pick,
                  icon: const Icon(AppIcons.folderOpen),
                  label: const Text('Scegli file…'),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_path ?? 'Nessun file selezionato', overflow: TextOverflow.ellipsis)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String>(
                  value: _delimiter,
                  items: const [
                    DropdownMenuItem(value: ',', child: Text('Virgola ,')),
                    DropdownMenuItem(value: ';', child: Text('Punto e virgola ;')),
                    DropdownMenuItem(value: '\t', child: Text('Tab')),
                    DropdownMenuItem(value: '|', child: Text('Pipe |')),
                  ],
                  onChanged: (v) {
                    _delimiter = v!;
                    _parse();
                  },
                ),
                FilterChip(
                  label: const Text('Prima riga = intestazione'),
                  selected: _header,
                  onSelected: (v) {
                    _header = v;
                    _parse();
                  },
                ),
                FilterChip(
                  label: const Text('Vuoto = NULL'),
                  selected: _emptyIsNull,
                  onSelected: (v) => setState(() => _emptyIsNull = v),
                ),
                FilterChip(
                  label: const Text('Svuota tabella prima'),
                  selected: _truncate,
                  onSelected: (v) => setState(() => _truncate = v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${_rows.length} righe nel file · associazione colonne:',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < widget.columns.length; i++)
                    Row(
                      children: [
                        SizedBox(
                          width: 260,
                          child: Text(
                            '${widget.columns[i].name}  (${widget.columns[i].fullType})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(AppIcons.arrowLeft, size: 16),
                        const SizedBox(width: 8),
                        DropdownButton<int?>(
                          value: _mapping[i],
                          hint: const Text('— ignora —'),
                          items: [
                            const DropdownMenuItem<int?>(value: null, child: Text('— ignora —')),
                            for (var j = 0; j < header.length; j++)
                              DropdownMenuItem<int?>(value: j, child: Text(header[j])),
                          ],
                          onChanged: (v) => setState(() => _mapping[i] = v),
                        ),
                        const SizedBox(width: 12),
                        if (_rows.isNotEmpty && _mapping[i] != null && _mapping[i]! < _rows.first.length)
                          Expanded(
                            child: Text(
                              'es. ${_rows.first[_mapping[i]!]}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Theme.of(context).hintColor),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            if (_running) ...[
              LinearProgressIndicator(value: _rows.isEmpty ? null : _done / _rows.length),
              Text('$_done / ${_rows.length}'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _running ? null : () => Navigator.pop(context), child: const Text('Annulla')),
        FilledButton(onPressed: _running || _rows.isEmpty ? null : _import, child: const Text('Importa')),
      ],
    );
  }
}
