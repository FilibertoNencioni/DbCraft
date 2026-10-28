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
  await showSheet<void>(
    context,
    size: SheetSize.large,
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
    final session = await widget.dc.openSession(catalog: widget.table.catalog);
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
    final c = DbColors.of(context);
    final header = _csvHeader;
    final rows = _rows;
    String sample(int i) {
      final m = _mapping[i];
      return rows.isNotEmpty && m != null && m < rows.first.length ? rows.first[m] : '';
    }

    return PopScope(
      canPop: !_running,
      child: SheetScaffold(
        title: 'Importa CSV in ${widget.table.name}',
        onSubmit: _running || rows.isEmpty ? null : _import,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormGroup(
              children: [
                FormRow(
                  label: 'File',
                  child: PathField(
                    path: _path,
                    hint: 'Nessun file selezionato',
                    chooseLabel: 'Scegli file…',
                    onChoose: _running ? null : _pick,
                  ),
                ),
                FormRow(
                  label: 'Delimitatore',
                  child: PopUpButton<String>(
                    value: _delimiter,
                    items: const [
                      (',', 'Virgola ,', null),
                      (';', 'Punto e virgola ;', null),
                      ('\t', 'Tab', null),
                      ('|', 'Pipe |', null),
                    ],
                    onChanged: _running
                        ? null
                        : (v) {
                            _delimiter = v;
                            _parse();
                          },
                  ),
                ),
                FormRow(
                  label: 'Opzioni',
                  child: Wrap(
                    spacing: Gap.lg,
                    runSpacing: Gap.xs,
                    children: [
                      CheckboxRow(
                        label: 'Prima riga = intestazione',
                        value: _header,
                        onChanged: (v) {
                          _header = v;
                          _parse();
                        },
                      ),
                      CheckboxRow(
                        label: 'Vuoto = NULL',
                        value: _emptyIsNull,
                        onChanged: (v) => setState(() => _emptyIsNull = v),
                      ),
                      CheckboxRow(
                        label: 'Svuota tabella prima',
                        value: _truncate,
                        onChanged: (v) => setState(() => _truncate = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SectionLabel(
              '${rows.length} righe nel file · associazione colonne',
              padding: const EdgeInsets.only(left: 2, bottom: 6),
            ),
            Expanded(
              child: MacTable(
                bordered: true,
                resizable: false,
                headers: const ['Colonna', 'Tipo', 'Dal file', 'Esempio'],
                rowCount: widget.columns.length,
                width: (col) => switch (col) {
                  0 => 200,
                  1 => 130,
                  2 => 180,
                  _ => null,
                },
                emphasis: 0,
                mono: (col) => col == 1,
                cell: (row, col) => switch (col) {
                  0 => widget.columns[row].name,
                  1 => widget.columns[row].fullType,
                  2 => _mapping[row] == null ? '— ignora —' : header[_mapping[row]!],
                  _ => sample(row),
                },
                cellBuilder: (context, row, col) => col != 2
                    ? null
                    : PopUpButton<int?>(
                        value: _mapping[row],
                        style: PopUpStyle.inline,
                        small: true,
                        items: [
                          (null, '— ignora —', null),
                          for (var j = 0; j < header.length; j++) (j, header[j], null),
                        ],
                        onChanged: _running ? null : (v) => setState(() => _mapping[row] = v),
                      ),
              ),
            ),
            if (_running) ...[
              const SizedBox(height: Gap.md),
              ProgressBar(value: rows.isEmpty ? null : _done / rows.length),
              const SizedBox(height: Gap.xs),
              Text(
                '$_done / ${rows.length}',
                style: uiText(TypeSize.caption, color: c.textSecondary, features: kTabular),
              ),
            ],
          ],
        ),
        actions: [
          PushButton(label: 'Annulla', onPressed: _running ? null : () => Navigator.pop(context)),
          PushButton.primary(label: 'Importa', onPressed: _running || rows.isEmpty ? null : _import),
        ],
      ),
    );
  }
}
