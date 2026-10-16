import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../drivers/db_session.dart';
import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../services/data_transfer.dart';
import '../../services/sql_dialect.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../ui/actions.dart';
import '../../ui/widgets/common.dart';
import '../data_compare/sql_values.dart';
import 'generators.dart';

/// Maximum number of distinct values sampled for a foreign key.
const _fkSampleSize = 1000;

/// Maximum number of rows written in a generated SQL script.
const _scriptRowCap = 10000;

const _maxRows = 1000000;

enum _TxMode { perBatch, single, none }

enum _OnError { stop, skip }

/// "Genera dati di test…" (DBeaver PRO mock data generator) for [table].
Future<void> showMockDataDialog(BuildContext context, DbConnection dc, DbTable table) async {
  if (!await ensureConnected(context, dc)) return;
  if (!dc.dialect.isSql) {
    if (context.mounted) showToast(context, 'La generazione di dati di test richiede un database SQL', error: true);
    return;
  }
  TableDetails details;
  try {
    details = await dc.metadata!.tableDetails(table);
  } catch (e) {
    if (context.mounted) showErrorDialog(context, e, title: 'Impossibile leggere la struttura di ${table.name}');
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MockDataDialog(dc: dc, details: details),
  );
}

class _MockDataDialog extends StatefulWidget {
  const _MockDataDialog({required this.dc, required this.details});
  final DbConnection dc;
  final TableDetails details;

  @override
  State<_MockDataDialog> createState() => _MockDataDialogState();
}

class _MockDataDialogState extends State<_MockDataDialog> {
  late final List<MockFkSample> _samples;
  late final List<MockColumnConfig> _configs;
  int _selected = 0;
  int _page = 0;

  final _rows = TextEditingController(text: '100');
  final _batch = TextEditingController(text: '1000');
  final _seed = TextEditingController(text: '${Random().nextInt(1 << 31)}');
  MockLocale _locale = MockLocale.it;
  bool _truncate = false;
  _TxMode _txMode = _TxMode.perBatch;
  _OnError _onError = _OnError.stop;

  bool _samplesLoading = false;
  bool _running = false;
  bool _cancel = false;
  String _status = '';
  int _done = 0;
  int _total = 0;
  int _skipped = 0;
  List<List<Object?>>? _preview;
  List<String> _previewHeaders = const [];
  String? _previewError;

  DbConnection get dc => widget.dc;
  DbTable get table => widget.details.table;
  SqlDialect get d => dc.dialect;

  @override
  void initState() {
    super.initState();
    final fkMap = <String, (MockFkSample, int)>{};
    _samples = [];
    for (final (i, fk) in widget.details.foreignKeys.indexed) {
      final s = MockFkSample(
        name: fk.name ?? 'fk$i',
        refTable: d.qualified(fk.pkCatalog, fk.pkSchema, fk.pkTable),
        refColumns: fk.refColumns,
      );
      _samples.add(s);
      for (final (p, col) in fk.columns.indexed) {
        fkMap.putIfAbsent(col.toLowerCase(), () => (s, p));
      }
    }
    _configs = mockConfigsFor(widget.details, foreignKeys: fkMap);
    if (_samples.isNotEmpty) _loadSamples();
  }

  @override
  void dispose() {
    _cancel = true;
    _rows.dispose();
    _batch.dispose();
    _seed.dispose();
    super.dispose();
  }

  /// Reads existing values of the referenced tables (dedicated session).
  Future<void> _loadSamples() async {
    setState(() => _samplesLoading = true);
    DbSession? s;
    try {
      s = await dc.openSession(readOnly: true);
      for (final sample in _samples) {
        final cols = sample.refColumns.map(d.quoteIdent).join(', ');
        final notNull = sample.refColumns.map((c) => '${d.quoteIdent(c)} IS NOT NULL').join(' AND ');
        final sql = d.limit(
          'SELECT $cols FROM (SELECT DISTINCT $cols FROM ${sample.refTable} WHERE $notNull) x',
          _fkSampleSize,
        );
        try {
          final page = await s.execute(sql, fetchSize: _fkSampleSize);
          if (page.cursorId != null) await s.closeCursor(page.cursorId!);
          sample.tuples = page.rows;
        } catch (e) {
          sample.error = e is OdbcException ? e.message : e.toString();
        }
        sample.loaded = true;
        if (!mounted) return;
        setState(() {});
      }
    } catch (e) {
      for (final sample in _samples) {
        sample.error ??= e.toString();
        sample.loaded = true;
      }
    } finally {
      await s?.close();
      if (mounted) setState(() => _samplesLoading = false);
    }
  }

  int get _rowCount => (int.tryParse(_rows.text.trim()) ?? 0).clamp(0, _maxRows);
  int get _batchSize => (int.tryParse(_batch.text.trim()) ?? 1000).clamp(1, 100000);

  MockDataGenerator _generator() =>
      MockDataGenerator(_configs, seed: int.tryParse(_seed.text.trim()) ?? 0, locale: _locale);

  void _buildPreview() {
    try {
      final g = _generator();
      _previewHeaders = g.columns.map((c) => c.name).toList();
      _preview = g.take(min(20, max(1, _rowCount))).toList();
      _previewError = null;
    } catch (e) {
      _preview = null;
      _previewError = e.toString();
    }
  }

  String? _validate() {
    if (_samplesLoading) return 'Attendi il caricamento dei valori delle chiavi esterne';
    if (_rowCount <= 0) return 'Indica un numero di righe tra 1 e $_maxRows';
    if (!_configs.any((c) => c.included)) return 'Tutte le colonne sono escluse';
    return null;
  }

  // -------------------------------------------------------------------------
  // Insert
  // -------------------------------------------------------------------------

  Future<void> _insert() async {
    final err = _validate();
    if (err != null) {
      showToast(context, err, error: true);
      return;
    }
    final n = _rowCount;
    final tn = d.tableName(table);
    if (_truncate) {
      final ok = await confirmDialog(
        context,
        'Svuotare ${table.name}?',
        'Tutte le righe esistenti di $tn verranno eliminate prima di inserire i dati di test.',
        ok: 'Svuota e genera',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    if (dc.config.type.confirmExecute) {
      final ok = await confirmDialog(
        context,
        'Connessione di produzione',
        'Inserire $n righe di dati di test in $tn su "${dc.config.name}"?',
        ok: 'Inserisci',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }

    final MockDataGenerator gen;
    try {
      gen = _generator();
    } catch (e) {
      showErrorDialog(context, e);
      return;
    }
    final cols = gen.columns;
    final names = cols.map((c) => c.name).toList();
    final perStatement = min(rowsPerInsert(d, cols.length), _batchSize);
    final transactional = _txMode != _TxMode.none;
    final savepoints = transactional && _onError == _OnError.skip && d.family == DbFamily.postgres;
    final batch = _batchSize;

    setState(() {
      _running = true;
      _cancel = false;
      _done = 0;
      _skipped = 0;
      _total = n;
      _status = 'Connessione…';
    });
    final sw = Stopwatch()..start();
    var committed = 0;
    var pending = 0;
    Object? lastRowError;
    DbSession? s;

    Future<bool> exec(List<List<Object?>> rows) async {
      final sql = parameterizedInsert(d, tn, names, rows.length);
      final params = [
        for (final r in rows)
          for (var i = 0; i < cols.length; i++) bindValue(d, cols[i].column.dataType, r[i]),
      ];
      if (savepoints) await s!.execute('SAVEPOINT dbcraft_mock');
      try {
        await s!.execute(sql, params: params);
        return true;
      } catch (e) {
        if (_onError == _OnError.stop) rethrow;
        lastRowError = e;
        if (savepoints) await s!.execute('ROLLBACK TO SAVEPOINT dbcraft_mock');
        return false;
      }
    }

    try {
      s = await dc.openSession();
      if (transactional) await s.setAutoCommit(false);
      if (_truncate) {
        setState(() => _status = 'Svuotamento della tabella…');
        // TRUNCATE is refused on tables referenced by foreign keys.
        await s.execute(widget.details.referencedBy.isNotEmpty ? 'DELETE FROM $tn' : d.truncateSql(table));
        if (_txMode == _TxMode.perBatch) await s.commit();
      }
      var produced = 0;
      while (produced < n && !_cancel) {
        final k = min(perStatement, min(n - produced, batch - pending));
        final rows = gen.take(k).toList();
        produced += k;
        if (!await exec(rows)) {
          // Retry the rows one by one to skip only the failing ones.
          if (rows.length == 1) {
            _skipped++;
          } else {
            for (final r in rows) {
              if (await exec([r])) {
                _done++;
              } else {
                _skipped++;
              }
            }
          }
          if (rows.length > 1) {
            pending += k;
            _afterChunk(sw);
            if (pending >= batch) {
              if (_txMode == _TxMode.perBatch) await s.commit();
              committed = _done;
              pending = 0;
            }
            continue;
          }
        } else {
          _done += k;
        }
        pending += k;
        if (pending >= batch) {
          if (_txMode == _TxMode.perBatch) await s.commit();
          committed = _done;
          pending = 0;
        }
        _afterChunk(sw);
      }
      if (_cancel) {
        if (transactional) await s.rollback();
        final kept = switch (_txMode) {
          _TxMode.perBatch => committed,
          _TxMode.single => 0,
          _TxMode.none => _done,
        };
        if (mounted) showToast(context, 'Generazione interrotta: $kept righe inserite in ${table.name}');
      } else {
        if (transactional) await s.commit();
        dc.metadata?.clearCache();
        if (!mounted) return;
        if (_skipped > 0) {
          showErrorDialog(
            context,
            '$_done righe inserite, $_skipped saltate per errore.\n\nUltimo errore:\n$lastRowError',
            title: 'Generazione completata con errori',
          );
        } else {
          showToast(context, '$_done righe inserite in ${table.name} in ${_secs(sw)}');
        }
      }
    } catch (e) {
      if (transactional && s != null) {
        try {
          await s.rollback();
        } catch (_) {}
      }
      if (mounted) {
        final kept = _txMode == _TxMode.perBatch ? committed : (_txMode == _TxMode.none ? _done : 0);
        showErrorDialog(context, e, title: 'Generazione interrotta ($kept righe inserite)');
      }
    } finally {
      await s?.close();
      if (mounted) {
        setState(() {
          _running = false;
          _status = '';
        });
      }
    }
  }

  static String _secs(Stopwatch sw) => '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';

  void _afterChunk(Stopwatch sw) {
    if (!mounted) return;
    final secs = sw.elapsedMilliseconds / 1000;
    final rate = secs > 0 ? (_done / secs).round() : 0;
    setState(() => _status = '$_done / $_total righe · $rate righe/s${_skipped > 0 ? ' · $_skipped saltate' : ''}');
  }

  // -------------------------------------------------------------------------
  // Script / CSV
  // -------------------------------------------------------------------------

  Future<void> _script() async {
    final err = _validate();
    if (err != null) {
      showToast(context, err, error: true);
      return;
    }
    final n = min(_rowCount, _scriptRowCap);
    final String body;
    final MockDataGenerator g;
    try {
      g = _generator();
      body = mockInsertScript(d, d.tableName(table), g.columns, g.take(n));
    } catch (e) {
      showErrorDialog(context, e);
      return;
    }
    final sb = StringBuffer()..writeln('-- Dati di test per ${d.tableName(table)}: $n righe (seme ${g.seed})');
    if (_rowCount > _scriptRowCap) {
      sb.writeln('-- Lo script è limitato a $_scriptRowCap righe: usa "Inserisci" per volumi maggiori.');
    }
    if (_truncate) {
      sb.writeln(
        '${widget.details.referencedBy.isNotEmpty ? 'DELETE FROM ${d.tableName(table)}' : d.truncateSql(table)};',
      );
    }
    sb.write(body);
    final app = AppScope.read(context);
    Navigator.pop(context);
    await app.openSqlEditor(dc, initialSql: sb.toString());
  }

  Future<void> _csv() async {
    final err = _validate();
    if (err != null) {
      showToast(context, err, error: true);
      return;
    }
    final loc = await getSaveLocation(
      suggestedName: '${table.name}_mock.csv',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (loc == null || !mounted) return;
    final n = _rowCount;
    setState(() {
      _running = true;
      _cancel = false;
      _done = 0;
      _total = n;
      _status = 'Scrittura del file…';
    });
    final sw = Stopwatch()..start();
    IOSink? sink;
    try {
      final g = _generator();
      final exporter = DataExporter(g.columns.map((c) => c.name).toList(), ExportOptions());
      sink = File(loc.path).openWrite(encoding: utf8);
      sink.write(exporter.begin());
      while (_done < n && !_cancel) {
        final k = min(5000, n - _done);
        sink.write(exporter.rows(g.take(k).toList()));
        _done += k;
        _afterChunk(sw);
        await Future<void>.delayed(Duration.zero);
      }
      sink.write(exporter.end());
      await sink.close();
      sink = null;
      if (mounted) showToast(context, '$_done righe esportate in ${loc.path}');
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Esportazione fallita');
    } finally {
      await sink?.close();
      if (mounted) {
        setState(() {
          _running = false;
          _status = '';
        });
      }
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final readOnly = dc.config.readOnly;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text('Genera dati di test · ${table.name}', overflow: TextOverflow.ellipsis)),
          Segmented<int>(
            value: _page,
            items: const [(0, 'Colonne', null), (1, 'Opzioni', null), (2, 'Anteprima', null)],
            onChanged: (v) => setState(() {
              _page = v;
              if (v == 2) _buildPreview();
            }),
          ),
        ],
      ),
      content: SizedBox(
        width: 940,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: AbsorbPointer(
                absorbing: _running,
                child: switch (_page) {
                  0 => _columnsPage(c),
                  1 => _optionsPage(c),
                  _ => _previewPage(c),
                },
              ),
            ),
            if (_running) ...[
              const SizedBox(height: Gap.md),
              LinearProgressIndicator(value: _total > 0 && _done > 0 ? _done / _total : null),
              const SizedBox(height: Gap.xs),
              Text(
                _status,
                style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary, fontFeatures: kTabular),
              ),
            ] else if (readOnly) ...[
              const SizedBox(height: Gap.sm),
              Text(
                'La connessione è in sola lettura: puoi generare uno script SQL o un file CSV.',
                style: TextStyle(fontSize: TypeSize.small, color: c.warning),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_running)
          OutlinedButton(onPressed: () => setState(() => _cancel = true), child: const Text('Interrompi'))
        else
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Chiudi')),
        OutlinedButton.icon(
          onPressed: _running ? null : _csv,
          icon: const Icon(AppIcons.table, size: 16),
          label: const Text('Esporta CSV…'),
        ),
        OutlinedButton.icon(
          onPressed: _running ? null : _script,
          icon: const Icon(AppIcons.document, size: 16),
          label: const Text('Genera script SQL'),
        ),
        Tooltip(
          message: readOnly ? 'Connessione in sola lettura' : 'Inserisce le righe con una sessione dedicata',
          child: FilledButton.icon(
            onPressed: _running || readOnly ? null : _insert,
            icon: const Icon(AppIcons.addList, size: 16),
            label: Text('Inserisci ${_rowCount > 0 ? _rowCount : ''} righe'),
          ),
        ),
      ],
    );
  }

  Widget _columnsPage(DbColors c) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 360,
          decoration: BoxDecoration(
            color: c.content,
            borderRadius: BorderRadius.circular(Radii.panel),
            border: Border.all(color: c.separator),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListView.builder(itemCount: _configs.length, itemExtent: 44, itemBuilder: (_, i) => _columnTile(c, i)),
        ),
        const SizedBox(width: Gap.lg),
        Expanded(child: SingleChildScrollView(child: _detail(c, _configs[_selected]))),
      ],
    );
  }

  Widget _columnTile(DbColors c, int i) {
    final cfg = _configs[i];
    final sel = i == _selected;
    final k = cfg.effectiveKind;
    final muted = k == MockKind.skip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _selected = i),
      child: Container(
        color: sel ? c.selection : (i.isOdd ? c.zebra : c.content),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: cfg.isPrimaryKey
                  ? Icon(AppIcons.key, size: 13, color: c.warning)
                  : (cfg.fkSample != null ? Icon(AppIcons.link, size: 13, color: c.textTertiary) : null),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          cfg.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: TypeSize.body,
                            fontWeight: FontWeight.w500,
                            color: muted ? c.textTertiary : c.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: Gap.xs),
                      Text(
                        cfg.column.fullType.toLowerCase(),
                        style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
                      ),
                    ],
                  ),
                  Text(
                    [
                      cfg.kind == MockKind.auto ? '${k.label} (auto)' : k.label,
                      if (cfg.summary.isNotEmpty) cfg.summary,
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary),
                  ),
                ],
              ),
            ),
            if (_warning(cfg) != null) Icon(AppIcons.warning, size: 14, color: c.warning),
          ],
        ),
      ),
    );
  }

  String? _warning(MockColumnConfig cfg) {
    final k = cfg.effectiveKind;
    if (!cfg.column.nullable && (k == MockKind.nullValue || (k == MockKind.skip && !cfg.column.autoIncrement))) {
      if (k == MockKind.skip && (cfg.column.defaultValue ?? '').isNotEmpty) return null;
      return 'La colonna è NOT NULL: l\'inserimento fallirà se il database non ha un valore predefinito.';
    }
    if (k == MockKind.foreignKey) {
      final s = cfg.fkSample;
      if (s == null) return 'Nessuna chiave esterna definita su questa colonna.';
      if (s.error != null) return 'Lettura di ${s.refTable} fallita: ${s.error}';
      if (s.loaded && s.tuples.isEmpty) {
        return '${s.refTable} è vuota: ${cfg.column.nullable ? 'verrà inserito NULL' : 'genera prima i dati della tabella referenziata'}.';
      }
    }
    if (cfg.column.autoIncrement && k != MockKind.skip) {
      return 'Colonna a incremento automatico: alcuni database rifiutano valori espliciti.';
    }
    return null;
  }

  Widget _num(String key, String label, num value, ValueChanged<String> onChanged, {String? help}) => FormRow(
    label: label,
    help: help,
    child: TextFormField(
      key: ValueKey('$_selected:$key'),
      initialValue: '$value',
      style: const TextStyle(fontSize: TypeSize.body, fontFeatures: kTabular),
      onChanged: (v) => setState(() => onChanged(v)),
    ),
  );

  Widget _text(String key, String label, String value, ValueChanged<String> onChanged, {String? help, String? hint}) =>
      FormRow(
        label: label,
        help: help,
        child: TextFormField(
          key: ValueKey('$_selected:$key'),
          initialValue: value,
          decoration: InputDecoration(hintText: hint),
          style: monoStyle(context),
          onChanged: (v) => setState(() => onChanged(v)),
        ),
      );

  static String _date(DateTime d) =>
      d.toIso8601String().substring(0, 19).replaceFirst('T', ' ').replaceFirst(' 00:00:00', '');

  Widget _detail(DbColors c, MockColumnConfig cfg) {
    final k = cfg.effectiveKind;
    final kinds = [
      for (final x in MockKind.values)
        if (x != MockKind.foreignKey || cfg.fkSample != null) x,
    ];
    final params = <Widget>[
      if (k == MockKind.sequence) ...[
        _num('seqStart', 'Valore iniziale', cfg.seqStart, (v) => cfg.seqStart = int.tryParse(v) ?? cfg.seqStart),
        _num('seqStep', 'Incremento', cfg.seqStep, (v) => cfg.seqStep = int.tryParse(v) ?? cfg.seqStep),
      ],
      if (k == MockKind.integer) ...[
        _num('intMin', 'Minimo', cfg.intMin, (v) => cfg.intMin = int.tryParse(v) ?? cfg.intMin),
        _num('intMax', 'Massimo', cfg.intMax, (v) => cfg.intMax = int.tryParse(v) ?? cfg.intMax),
      ],
      if (k == MockKind.decimal) ...[
        _num('decMin', 'Minimo', cfg.decMin, (v) => cfg.decMin = double.tryParse(v.replaceAll(',', '.')) ?? cfg.decMin),
        _num(
          'decMax',
          'Massimo',
          cfg.decMax,
          (v) => cfg.decMax = double.tryParse(v.replaceAll(',', '.')) ?? cfg.decMax,
        ),
        _num('scale', 'Decimali', cfg.scale, (v) => cfg.scale = (int.tryParse(v) ?? cfg.scale).clamp(0, 10)),
      ],
      if (k == MockKind.lorem) ...[
        _num('minWords', 'Parole (minimo)', cfg.minWords, (v) => cfg.minWords = max(1, int.tryParse(v) ?? 1)),
        _num('maxWords', 'Parole (massimo)', cfg.maxWords, (v) => cfg.maxWords = max(1, int.tryParse(v) ?? 1)),
      ],
      if (k == MockKind.pattern)
        _text(
          'pattern',
          'Modello',
          cfg.pattern,
          (v) => cfg.pattern = v,
          help: '# cifra · ? lettera · @ minuscola · * alfanumerico · \\ letterale',
        ),
      if (k == MockKind.list)
        _text(
          'list',
          'Valori',
          cfg.listValues,
          (v) {
            cfg.listValues = v;
          },
          help: 'Separati da virgola; peso opzionale con =',
          hint: 'attivo=70, sospeso=20, chiuso=10',
        ),
      if (k == MockKind.dateTime) ...[
        _text(
          'from',
          'Da',
          _date(cfg.dateFrom),
          (v) => cfg.dateFrom = DateTime.tryParse(v.trim()) ?? cfg.dateFrom,
          hint: 'AAAA-MM-GG [hh:mm:ss]',
        ),
        _text(
          'to',
          'A',
          _date(cfg.dateTo),
          (v) => cfg.dateTo = DateTime.tryParse(v.trim()) ?? cfg.dateTo,
          hint: 'AAAA-MM-GG [hh:mm:ss]',
        ),
      ],
      if (k == MockKind.boolean)
        FormRow(
          label: 'Valori veri',
          child: Row(
            children: [
              Expanded(
                child: Slider(
                  value: cfg.truePercent,
                  max: 100,
                  divisions: 20,
                  onChanged: (v) => setState(() => cfg.truePercent = v),
                ),
              ),
              SizedBox(width: 40, child: Text('${cfg.truePercent.round()}%', textAlign: TextAlign.right)),
            ],
          ),
        ),
      if (k == MockKind.constant) _text('const', 'Valore', cfg.constant, (v) => cfg.constant = v),
      if (k == MockKind.foreignKey && cfg.fkSample != null)
        FormRow(
          label: 'Riferimento',
          child: Text(
            '${cfg.fkSample!.refTable} (${cfg.fkSample!.refColumns.join(', ')})\n'
            '${!cfg.fkSample!.loaded ? 'Lettura dei valori…' : '${cfg.fkSample!.tuples.length} valori distinti campionati (max $_fkSampleSize)'}',
            style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
          ),
        ),
    ];
    final canNull = cfg.column.nullable && !cfg.isPrimaryKey && k != MockKind.nullValue && k != MockKind.skip;
    final canUnique = k != MockKind.skip && k != MockKind.nullValue && k != MockKind.sequence && k != MockKind.constant;
    final warn = _warning(cfg);
    List<String> sample = const [];
    if (k != MockKind.skip) {
      try {
        final g = MockDataGenerator([cfg], seed: int.tryParse(_seed.text.trim()) ?? 0, locale: _locale);
        sample = [for (final r in g.take(5)) formatValue(r.first, nullText: 'NULL', maxLen: 60)];
      } catch (e) {
        sample = ['Errore: $e'];
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          title: cfg.name,
          footer:
              '${cfg.column.fullType}${cfg.column.nullable ? '' : ' · NOT NULL'}'
              '${cfg.isPrimaryKey ? ' · chiave primaria' : ''}${cfg.column.autoIncrement ? ' · incremento automatico' : ''}',
          children: [
            FormRow(
              label: 'Generatore',
              child: DropdownButtonHideUnderline(
                child: DropdownButton<MockKind>(
                  value: cfg.kind,
                  isExpanded: true,
                  isDense: true,
                  style: TextStyle(fontSize: TypeSize.body, color: c.text),
                  items: [
                    for (final x in kinds)
                      DropdownMenuItem(
                        value: x,
                        child: Text(x == MockKind.auto ? 'Automatico (${cfg.autoKind.label})' : x.label),
                      ),
                  ],
                  onChanged: (v) => setState(() => cfg.kind = v ?? cfg.kind),
                ),
              ),
            ),
            ...params,
            if (canNull)
              FormRow(
                label: 'Valori NULL',
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: cfg.nullPercent,
                        max: 100,
                        divisions: 20,
                        onChanged: (v) => setState(() => cfg.nullPercent = v),
                      ),
                    ),
                    SizedBox(width: 40, child: Text('${cfg.nullPercent.round()}%', textAlign: TextAlign.right)),
                  ],
                ),
              ),
            if (canUnique)
              FormRow(
                label: 'Univoco',
                help: cfg.isPrimaryKey ? 'Chiave primaria' : 'Scarta i valori già generati',
                child: Align(
                  alignment: Alignment.centerRight,
                  child: DbSwitch(value: cfg.unique, onChanged: (v) => setState(() => cfg.unique = v)),
                ),
              ),
          ],
        ),
        if (warn != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(AppIcons.warning, size: 15, color: c.warning),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    warn,
                    style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        if (sample.isNotEmpty) ...[
          const SectionLabel('Esempi', padding: EdgeInsets.only(left: 2, bottom: Gap.xs)),
          Container(
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
              color: c.codeBackground,
              borderRadius: BorderRadius.circular(Radii.panel),
              border: Border.all(color: c.separator),
            ),
            child: SelectableText(sample.join('\n'), style: monoStyle(context, size: 12)),
          ),
        ],
      ],
    );
  }

  Widget _optionsPage(DbColors c) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            title: 'Generazione',
            children: [
              FormRow(
                label: 'Numero di righe',
                help: 'Massimo $_maxRows',
                child: TextField(
                  controller: _rows,
                  style: const TextStyle(fontFeatures: kTabular),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              FormRow(
                label: 'Seme',
                help: 'Stesso seme, stessi dati',
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _seed,
                        style: const TextStyle(fontFeatures: kTabular),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: Gap.xs),
                    ToolButton(
                      icon: AppIcons.random,
                      tooltip: 'Nuovo seme casuale',
                      onPressed: () => setState(() => _seed.text = '${Random().nextInt(1 << 31)}'),
                    ),
                  ],
                ),
              ),
              FormRow(
                label: 'Lingua dei dati',
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Segmented<MockLocale>(
                    value: _locale,
                    items: [for (final l in MockLocale.values) (l, l.label, null)],
                    onChanged: (v) => setState(() => _locale = v),
                  ),
                ),
              ),
            ],
          ),
          FormGroup(
            title: 'Scrittura',
            footer:
                'Le righe sono inserite con una sessione dedicata e istruzioni INSERT parametriche'
                '${rowsPerInsert(d, _configs.where((e) => e.included).length) > 1 ? ' multiriga' : ''}.',
            children: [
              FormRow(
                label: 'Righe per commit',
                child: TextField(
                  controller: _batch,
                  style: const TextStyle(fontFeatures: kTabular),
                ),
              ),
              FormRow(
                label: 'Transazione',
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Segmented<_TxMode>(
                    value: _txMode,
                    items: const [
                      (_TxMode.perBatch, 'Commit per blocco', null),
                      (_TxMode.single, 'Transazione unica', null),
                      (_TxMode.none, 'Auto-commit', null),
                    ],
                    onChanged: (v) => setState(() => _txMode = v),
                  ),
                ),
              ),
              FormRow(
                label: 'In caso di errore',
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Segmented<_OnError>(
                    value: _onError,
                    items: const [(_OnError.stop, 'Interrompi', null), (_OnError.skip, 'Salta la riga', null)],
                    onChanged: (v) => setState(() => _onError = v),
                  ),
                ),
              ),
              FormRow(
                label: 'Svuota la tabella prima',
                help: widget.details.referencedBy.isNotEmpty
                    ? 'DELETE: la tabella è referenziata da chiavi esterne'
                    : 'TRUNCATE: elimina tutte le righe esistenti',
                labelWidth: 320,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: DbSwitch(value: _truncate, onChanged: (v) => setState(() => _truncate = v)),
                ),
              ),
            ],
          ),
          if (_truncate)
            Row(
              children: [
                Icon(AppIcons.warning, size: 15, color: c.danger),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    'Tutte le righe di ${d.tableName(table)} verranno eliminate prima della generazione.',
                    style: TextStyle(fontSize: TypeSize.small, color: c.danger),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _previewPage(DbColors c) {
    if (_previewError != null) {
      return EmptyState(
        icon: AppIcons.error,
        title: 'Impossibile generare i dati',
        message: _previewError,
      );
    }
    final p = _preview;
    if (p == null) return const Center(child: CircularProgressIndicator());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Prime ${p.length} righe con il seme ${_seed.text}: l\'inserimento produrrà gli stessi valori.',
                style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
              ),
            ),
            ToolButton(
              icon: AppIcons.refresh,
              tooltip: 'Nuovo seme e rigenera',
              onPressed: () => setState(() {
                _seed.text = '${Random().nextInt(1 << 31)}';
                _buildPreview();
              }),
            ),
          ],
        ),
        Expanded(
          child: SimpleGrid(
            headers: _previewHeaders,
            rows: [
              for (final r in p) [for (final v in r) formatValue(v, nullText: 'NULL', maxLen: 60)],
            ],
          ),
        ),
      ],
    );
  }
}
