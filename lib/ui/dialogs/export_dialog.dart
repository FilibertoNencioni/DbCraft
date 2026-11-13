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
  final s = _ExportSource.result(m);
  return showSheet<void>(context, builder: (_) => _ExportDialog(connection: m.connection, sources: [s]));
}

/// Export of several result sets at once (the result tabs of a SQL editor),
/// one file per result. [results] pairs each tab title with its model.
Future<void> showResultsExportDialog(BuildContext context, List<(String, ResultSetModel)> results) {
  assert(results.isNotEmpty);
  return showSheet<void>(
    context,
    builder: (_) => _ExportDialog(
      connection: results.first.$2.connection,
      sources: [for (final (title, m) in results) _ExportSource.result(m, title: title)],
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
      sources: [
        _ExportSource(
          title: t.name,
          columns: cols.map((c) => c.name).toList(),
          qualifiedName: dc.dialect.tableName(t),
          loadedRows: null,
          hasMore: true,
          sql: 'SELECT * FROM ${dc.dialect.tableName(t)}',
          params: const [],
          catalog: t.catalog,
        ),
      ],
    ),
  );
}

/// Streams every row of [sql] page by page using a dedicated session (on
/// [catalog] when known), so the export never interferes with the editor
/// transaction. [resultSetIndex] selects which result set of [sql] to read
/// (0 = first), for statements that return more than one.
Stream<List<List<Object?>>> streamQuery(
  DbConnection dc,
  String sql,
  List<Object?> params, {
  int pageSize = 2000,
  String? catalog,
  int resultSetIndex = 0,
}) async* {
  final session = await dc.openSession(readOnly: true, catalog: catalog);
  try {
    var page = await session.execute(sql, params: params, fetchSize: pageSize);
    for (var i = 0; i < resultSetIndex; i++) {
      final id = page.cursorId;
      final next = id == null ? null : await session.nextResultSet(id, pageSize);
      if (next == null || !next.isResultSet) {
        throw Exception('Rieseguendo la query il result set ${resultSetIndex + 1} non è più presente.');
      }
      page = next;
    }
    yield page.rows;
    while (page.hasMore && page.cursorId != null) {
      page = await session.fetchMore(page.cursorId!, pageSize);
      yield page.rows;
    }
  } finally {
    await session.close();
  }
}

/// One result set or table offered by the export dialog.
class _ExportSource {
  _ExportSource({
    required this.title,
    required this.columns,
    required this.qualifiedName,
    required this.loadedRows,
    this.loadedCount = 0,
    required this.hasMore,
    required this.sql,
    required this.params,
    this.catalog,
    this.resultSetIndex = 0,
    this.dataFilter,
  });

  factory _ExportSource.result(ResultSetModel m, {String? title}) {
    final table = m.table;
    return _ExportSource(
      title: title ?? table?.name ?? 'export',
      columns: m.columns.map((c) => c.name).toList(),
      qualifiedName: table == null ? 'table_name' : m.connection.dialect.tableName(table),
      loadedRows: () => m.view.map((i) => m.rows[i].values).toList(),
      loadedCount: m.view.length,
      hasMore: m.hasMore,
      sql: m.sql,
      params: m.params,
      catalog: table?.catalog ?? m.catalog,
      resultSetIndex: m.resultSetIndex,
      dataFilter: m.dataFilter,
    );
  }

  /// Tab title or table name: names the file.
  final String title;
  final List<String> columns;
  final String qualifiedName;

  /// Rows already in the grid (filters applied), or null for a table that
  /// was never loaded.
  final List<List<Object?>> Function()? loadedRows;
  final int loadedCount;
  final bool hasMore;
  final String sql;
  final List<Object?> params;
  final String? catalog;
  final int resultSetIndex;

  /// WHERE / ORDER BY of the table data page, shown so it is clear which
  /// rows are exported.
  final String? dataFilter;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.connection, required this.sources});

  final DbConnection connection;
  final List<_ExportSource> sources;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final bool _multi = widget.sources.length > 1;
  _ExportSource get _single => widget.sources.first;

  late final ExportOptions _o = ExportOptions(
    tableName: _single.qualifiedName,
    dialect: widget.connection.dialect,
  );
  late bool _allRows = widget.sources.any((s) => s.loadedRows == null || s.hasMore);
  late final Set<int> _selected = {for (var i = 0; i < widget.sources.length; i++) i};
  late final _delimiter = TextEditingController(text: _o.delimiter);
  late final _nullText = TextEditingController(text: _o.nullText);
  late final _table = TextEditingController(text: _o.tableName);
  late final _batch = TextEditingController(text: '${_o.insertBatch}');
  bool _running = false;
  int _exported = 0;

  /// 1-based position of the result being written, in multi export.
  int _current = 0;

  @override
  void dispose() {
    _delimiter.dispose();
    _nullText.dispose();
    _table.dispose();
    _batch.dispose();
    super.dispose();
  }

  void _sync() {
    _o
      ..delimiter = _delimiter.text.isEmpty ? ',' : _delimiter.text.replaceAll(r'\t', '\t')
      ..nullText = _nullText.text
      ..tableName = _table.text
      ..insertBatch = int.tryParse(_batch.text) ?? 1;
  }

  Stream<List<List<Object?>>> _source(_ExportSource s) {
    if (!_allRows && s.loadedRows != null) {
      return Stream.value(s.loadedRows!());
    }
    return streamQuery(
      widget.connection,
      s.sql,
      s.params,
      catalog: s.catalog,
      resultSetIndex: s.resultSetIndex,
    ).map((p) {
      _exported += p.length;
      if (mounted) setState(() {});
      return p;
    });
  }

  Future<void> _toFile() => _multi ? _toFolder() : _toSingleFile();

  Future<void> _toSingleFile() async {
    _sync();
    final s = _single;
    final loc = await getSaveLocation(
      suggestedName: '${s.title}.${_o.format.extension}',
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
      final n = await DataExporter.exportToFile(File(loc.path), s.columns, _source(s), _o);
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, 'Esportate $n righe in ${loc.path}');
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Esportazione fallita');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// One file per selected result, named after its tab.
  Future<void> _toFolder() async {
    _sync();
    final sources = [for (final i in _selected.toList()..sort()) widget.sources[i]];
    if (sources.isEmpty) return;
    final dir = await getDirectoryPath(confirmButtonText: 'Esporta qui');
    if (dir == null || !mounted) return;
    final names = exportFileNames([for (final s in sources) s.title], _o.format.extension);
    final files = [for (final n in names) File('$dir${Platform.pathSeparator}$n')];
    final existing = [for (final f in files) if (f.existsSync()) f.uri.pathSegments.last];
    if (existing.isNotEmpty) {
      final ok = await confirmDialog(
        context,
        existing.length == 1 ? 'File già esistente' : 'File già esistenti',
        'Nella cartella ci sono già:\n${existing.join('\n')}\n\nSovrascriverli?',
        ok: 'Sovrascrivi',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _running = true;
      _exported = 0;
    });
    var rows = 0;
    var i = 0;
    try {
      for (; i < sources.length; i++) {
        final s = sources[i];
        setState(() => _current = i + 1);
        _o.tableName = s.qualifiedName;
        rows += await DataExporter.exportToFile(files[i], s.columns, _source(s), _o);
      }
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, 'Esportati ${sources.length} risultati ($rows righe) in $dir');
    } catch (e) {
      if (mounted) {
        final failed = sources[i.clamp(0, sources.length - 1)].title;
        final done = switch (i) {
          0 => '',
          1 => ' (il precedente è stato salvato)',
          _ => ' (i $i precedenti sono stati salvati)',
        };
        showErrorDialog(context, e, title: 'Esportazione di "$failed" fallita$done');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _toClipboard() async {
    _sync();
    setState(() => _running = true);
    try {
      final s = _single;
      final rows = <List<Object?>>[];
      await for (final p in _source(s)) {
        rows.addAll(p);
      }
      await Clipboard.setData(ClipboardData(text: DataExporter.exportAll(s.columns, rows, _o)));
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, '${rows.length} righe copiate negli appunti');
    } catch (e) {
      if (mounted) showErrorDialog(context, e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Widget _resultsGroup() {
    return FormGroup(
      children: [
        for (final (i, s) in widget.sources.indexed)
          CheckboxRow(
            label: s.title,
            help: '${s.columns.length} ${s.columns.length == 1 ? 'colonna' : 'colonne'} · '
                '${s.loadedCount}${s.hasMore ? '+' : ''} ${s.loadedCount == 1 ? 'riga caricata' : 'righe caricate'}',
            value: _selected.contains(i),
            onChanged: _running
                ? null
                : (v) => setState(() => v ? _selected.add(i) : _selected.remove(i)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = _o.format;
    final c = DbColors.of(context);
    final csv = f == ExportFormat.csv || f == ExportFormat.tsv;
    final canRun = !_running && (!_multi || _selected.isNotEmpty);
    final filter = _multi ? null : _single.dataFilter;
    final count = _selected.length;
    return PopScope(
      canPop: !_running,
      child: SheetScaffold(
      title: _multi ? 'Esporta ${widget.sources.length} risultati' : 'Esporta dati · ${_single.title}',
      subtitle: _multi ? 'Un file per risultato, nella cartella che sceglierai.' : null,
      onSubmit: canRun ? _toFile : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_multi) _resultsGroup(),
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
              if (filter != null)
                FormRow(
                  label: 'Filtro',
                  child: filter.isEmpty
                      ? Text('Nessuno · tutta la tabella', style: uiText(TypeSize.body, color: c.textSecondary))
                      : SelectableText(
                          filter,
                          maxLines: 3,
                          textAlign: TextAlign.end,
                          style: monoStyle(context, size: TypeSize.mono, color: c.text),
                        ),
                ),
              if (widget.sources.any((s) => s.loadedRows != null))
                FormRow(
                  label: 'Righe',
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: MacRadioGroup<bool>(
                      value: _allRows,
                      items: [
                        (false, 'Solo righe caricate / filtrate', null),
                        (true, _multi ? 'Tutte le righe (riesegue le query)' : 'Tutte le righe (riesegue la query)', null),
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
              // In multi export each file uses the table of its own result.
              if (!_multi && (f == ExportFormat.sql || f == ExportFormat.xml || f == ExportFormat.html))
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
              _multi
                  ? 'Risultato $_current di $count · $_exported righe lette…'
                  : '$_exported righe lette…',
              style: uiText(TypeSize.caption, color: c.textSecondary, features: kTabular),
            ),
          ],
        ],
      ),
      actions: [
        PushButton(label: 'Annulla', onPressed: _running ? null : () => Navigator.pop(context)),
        if (!_multi) PushButton(label: 'Copia negli appunti', onPressed: _running ? null : _toClipboard),
        PushButton.primary(
          label: _multi ? 'Salva in una cartella…' : 'Salva su file…',
          onPressed: canRun ? _toFile : null,
        ),
      ],
    ),
    );
  }
}

/// File names for [titles] (one per exported result): characters not
/// allowed in file names become '_', duplicates get " (2)", " (3)"…
@visibleForTesting
List<String> exportFileNames(List<String> titles, String extension) {
  final used = <String>{};
  final out = <String>[];
  for (final t in titles) {
    var base = t
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (base.isEmpty) base = 'risultato';
    var name = '$base.$extension';
    for (var n = 2; used.contains(name.toLowerCase()); n++) {
      name = '$base ($n).$extension';
    }
    used.add(name.toLowerCase());
    out.add(name);
  }
  return out;
}
