import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../odbc/odbc_types.dart';
import '../../services/data_transfer.dart';
import '../../state/result_set_model.dart';
import '../../ui/widgets/common.dart';
import 'chart_data.dart';
import 'chart_painter.dart';
import 'chart_palette.dart';

/// Maximum rows loaded by "Carica tutte le righe".
const kChartRowCap = 100000;

/// Chart settings survive switching between Griglia / Record / Grafico.
final _configs = Expando<ChartConfig>('chartConfig');

/// Analytic chart of a result set (bars, lines, areas, pies, scatter) with
/// a configuration panel, hover tooltips, PNG export and CSV copy.
class ChartView extends StatefulWidget {
  const ChartView({super.key, required ResultSetModel this.model}) : columns = null, rows = null;

  /// Chart of static data (no paging).
  const ChartView.data({super.key, required List<ColumnInfo> this.columns, required List<List<Object?>> this.rows})
    : model = null;

  final ResultSetModel? model;
  final List<ColumnInfo>? columns;
  final List<List<Object?>>? rows;

  @override
  State<ChartView> createState() => _ChartViewState();
}

class _ChartViewState extends State<ChartView> {
  final _boundary = GlobalKey();
  final _hits = ChartHitMap();
  ChartConfig? _ownConfig;
  bool _panel = true;
  ChartHover? _hover;
  Offset _pointer = Offset.zero;
  bool _loadingAll = false;

  // Memoized data
  List<ChartColumn> _cols = const [];
  List<List<Object?>> _rows = const [];
  List<ColumnProfile> _profiles = const [];
  ChartData _data = ChartData.empty;
  bool _stale = true;

  ResultSetModel? get m => widget.model;

  ChartConfig get _config {
    final model = m;
    if (model == null) return _ownConfig ??= ChartConfig.auto(_profiles, _rows.length);
    return _configs[model] ??= ChartConfig.auto(_profiles, _rows.length);
  }

  @override
  void initState() {
    super.initState();
    m?.addListener(_onModel);
  }

  @override
  void didUpdateWidget(ChartView old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model?.removeListener(_onModel);
      widget.model?.addListener(_onModel);
    }
    _stale = true;
  }

  @override
  void dispose() {
    m?.removeListener(_onModel);
    super.dispose();
  }

  void _onModel() {
    if (!mounted) return;
    setState(() => _stale = true);
  }

  void _refresh() {
    if (!_stale) return;
    _stale = false;
    final model = m;
    final cols = model?.columns ?? widget.columns ?? const [];
    _cols = [for (final c in cols) ChartColumn(c.name, sqlType: c.sqlType, typeName: c.typeName)];
    _rows = model == null ? widget.rows ?? const [] : [for (final i in model.view) model.rows[i].values];
    _profiles = profileColumns(_cols, _rows);
    _data = buildChartData(_cols, _profiles, _rows, _config);
  }

  void _update(void Function(ChartConfig c) f) {
    setState(() {
      f(_config);
      _stale = true;
      _hover = null;
    });
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _loadAll() async {
    final model = m;
    if (model == null || !model.hasMore || _loadingAll) return;
    final remaining = kChartRowCap - model.rows.length;
    if (remaining <= 0) return;
    setState(() => _loadingAll = true);
    try {
      await model.fetchNext(count: remaining);
    } finally {
      if (mounted) setState(() => _loadingAll = false);
    }
  }

  Future<void> _exportPng() async {
    final ro = _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (ro == null) return;
    final image = await ro.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final loc = await getSaveLocation(
      suggestedName: 'grafico.png',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG', extensions: ['png']),
      ],
    );
    if (loc == null) return;
    await File(loc.path).writeAsBytes(bytes.buffer.asUint8List());
    if (mounted) showToast(context, 'Grafico salvato in ${loc.path}');
  }

  void _copyCsv() {
    final d = _data;
    if (d.isEmpty) return;
    final csv = DataExporter.exportAll(
      [d.xTitle, for (final s in d.series) s.name],
      [
        for (var i = 0; i < d.labels.length; i++) [d.labels[i], for (final s in d.series) s.values[i]],
      ],
      ExportOptions(),
    );
    Clipboard.setData(ClipboardData(text: csv));
    showToast(context, 'Dati del grafico copiati come CSV (${d.labels.length} righe)');
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _refresh();
    final c = DbColors.of(context);
    return ColoredBox(
      color: c.content,
      child: Column(
        children: [
          _toolbar(c),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _chartArea(c)),
                if (_panel) Inspector(width: 260, children: _configPanel(c)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const _kinds = [
    (ChartKind.bar, AppIcons.barChart),
    (ChartKind.barHorizontal, AppIcons.alignLeft),
    (ChartKind.line, AppIcons.lineChart),
    (ChartKind.area, AppIcons.areaChart),
    (ChartKind.pie, AppIcons.pieChart),
    (ChartKind.donut, AppIcons.donutChart),
    (ChartKind.scatter, AppIcons.scatterChart),
  ];

  Widget _toolbar(DbColors c) {
    final model = m;
    final cfg = _config;
    final capped = model != null && model.hasMore && model.rows.length >= kChartRowCap;
    return PaneBar(
      children: [
        for (final (k, icon) in _kinds)
          ToolButton(icon: icon, tooltip: k.label, active: cfg.kind == k, onPressed: () => _update((x) => x.kind = k)),
        const ToolSeparator(),
        Flexible(
          child: Text(
            '${_rows.length} ${_rows.length == 1 ? 'riga' : 'righe'}'
            '${model != null && model.hasMore ? (capped ? ' · limite di ${formatNumber(kChartRowCap.toDouble())} righe' : ' · altre disponibili') : ''}',
            overflow: TextOverflow.ellipsis,
            style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular),
          ),
        ),
        if (model != null && model.hasMore && !capped) ...[
          const SizedBox(width: Gap.xs),
          ToolButton(
            icon: AppIcons.expandAll,
            tooltip: 'Carica tutte le righe nel grafico (fino a ${formatNumber(kChartRowCap.toDouble())})',
            label: 'Carica tutte le righe',
            onPressed: _loadingAll || model.loading ? null : _loadAll,
          ),
        ],
        if (_loadingAll)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Gap.sm),
            child: Spinner(),
          ),
        const Spacer(),
        ToolButton(
          icon: AppIcons.copy,
          tooltip: 'Copia i dati del grafico (CSV)',
          onPressed: _data.isEmpty ? null : _copyCsv,
        ),
        ToolButton(
          icon: AppIcons.image,
          tooltip: 'Esporta il grafico come PNG…',
          onPressed: _data.isEmpty ? null : _exportPng,
        ),
        ToolButton(
          icon: AppIcons.tune,
          tooltip: _panel ? 'Nascondi impostazioni' : 'Mostra impostazioni',
          active: _panel,
          onPressed: () => setState(() => _panel = !_panel),
        ),
      ],
    );
  }

  Widget _chartArea(DbColors c) {
    final d = _data;
    final cfg = _config;
    if (_cols.isEmpty) {
      return const EmptyState(icon: AppIcons.chart, title: 'Il risultato non ha colonne');
    }
    if (_rows.isEmpty) {
      return const EmptyState(
        icon: AppIcons.chart,
        title: 'Nessuna riga da rappresentare',
        message: 'Il risultato è vuoto o il filtro rapido esclude tutte le righe.',
      );
    }
    if (d.isEmpty) {
      return EmptyState(
        icon: AppIcons.chart,
        title: 'Scegli cosa rappresentare',
        message: _profiles.any((p) => p.numeric)
            ? 'Seleziona almeno una colonna numerica come serie (asse Y) nelle impostazioni.'
            : 'Nessuna colonna numerica: scegli "Conteggio" come aggregazione per contare le righe per categoria.',
        action: _panel ? null : PushButton(label: 'Impostazioni', onPressed: () => setState(() => _panel = true)),
      );
    }
    final palette = ChartPalette.of(context);
    final legend = cfg.legend && !cfg.kind.isPie && d.series.length > 1;
    final chart = LayoutBuilder(
      builder: (context, box) {
        final painter = CustomPaint(
          size: Size(box.maxWidth, box.maxHeight),
          painter: ChartPainter(
            data: d,
            kind: cfg.kind,
            stacked: cfg.stacked,
            colors: c,
            palette: palette,
            hits: _hits,
            hover: _hover,
          ),
        );
        return MouseRegion(
          onHover: (e) {
            final h = _hits.hitTest(e.localPosition, cfg.kind);
            if (h != _hover || h != null) {
              setState(() {
                _hover = h;
                _pointer = e.localPosition;
              });
            }
          },
          onExit: (_) => setState(() => _hover = null),
          child: Stack(
            clipBehavior: Clip.none,
            children: [painter, if (_hover != null) _tooltip(c, palette, box.biggest)],
          ),
        );
      },
    );
    final body = cfg.kind.isPie
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: chart),
              if (cfg.legend) SizedBox(width: 220, child: _pieLegend(c, palette)),
            ],
          )
        : chart;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final n in d.notes)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
            child: Row(
              children: [
                Icon(AppIcons.info, size: 13, color: c.textTertiary),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(n, style: uiText(TypeSize.caption, color: c.textSecondary)),
                ),
              ],
            ),
          ),
        Expanded(
          child: RepaintBoundary(
            key: _boundary,
            child: ColoredBox(
              color: c.content,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (legend) ...[_legend(c, palette), const SizedBox(height: Gap.sm)],
                    Expanded(child: body),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _swatch(Color color, {bool line = false}) => Container(
    width: line ? 14 : 10,
    height: line ? 3 : 10,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(line ? 2 : 3)),
  );

  Widget _legend(DbColors c, ChartPalette palette) {
    final line = _config.kind == ChartKind.line;
    return Wrap(
      spacing: Gap.lg,
      runSpacing: Gap.xs,
      children: [
        for (final s in _data.series)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _swatch(palette[s.slot], line: line),
              const SizedBox(width: 6),
              Text(s.name, style: uiText(TypeSize.small, color: c.textSecondary)),
            ],
          ),
      ],
    );
  }

  Widget _pieLegend(DbColors c, ChartPalette palette) {
    final d = _data;
    final values = d.series.first.values;
    final total = values.fold<double>(0, (t, v) => t + (v ?? 0));
    return ListView(
      padding: const EdgeInsets.only(left: Gap.sm, top: Gap.lg),
      children: [
        for (var i = 0; i < d.labels.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: _hover?.index == i ? c.hover : null,
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Row(
              children: [
                _swatch(i == d.otherIndex ? palette.other : palette[i]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    d.labels[i],
                    overflow: TextOverflow.ellipsis,
                    style: uiText(TypeSize.small, color: c.text),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Text(
                  total > 0 ? '${formatNumber((values[i] ?? 0) / total * 100, maxDecimals: 1)}%' : '',
                  style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _tooltip(DbColors c, ChartPalette palette, Size area) {
    final d = _data;
    final h = _hover!;
    if (h.index >= d.labels.length) return const SizedBox.shrink();
    final cfg = _config;
    final rows = <(Color, String, String)>[];
    String title = d.labels[h.index];
    if (cfg.kind.isPie) {
      final values = d.series.first.values;
      final total = values.fold<double>(0, (t, v) => t + (v ?? 0));
      final v = values[h.index] ?? 0;
      rows.add((
        h.index == d.otherIndex ? palette.other : palette[h.index],
        d.series.first.name,
        '${formatNumber(v, maxDecimals: 6)}  ·  ${formatNumber(total == 0 ? 0 : v / total * 100, maxDecimals: 1)}%',
      ));
    } else if (cfg.kind == ChartKind.scatter && h.series != null) {
      final s = d.series[h.series!];
      title = '${d.xTitle}: ${d.labels[h.index]}';
      rows.add((palette[s.slot], s.name, _fmt(s.values[h.index])));
    } else {
      for (final s in d.series) {
        rows.add((palette[s.slot], s.name, _fmt(s.values[h.index])));
      }
      if (cfg.stacked && cfg.kind.canStack && d.series.length > 1) {
        final tot = d.series.fold<double>(0, (t, s) => t + (s.values[h.index] ?? 0));
        rows.add((Colors.transparent, 'Totale', formatNumber(tot, maxDecimals: 6)));
      }
    }
    const w = 240.0;
    var left = _pointer.dx + 14;
    if (left + w > area.width) left = _pointer.dx - w - 14;
    final est = 26.0 + rows.length * 16;
    var top = _pointer.dy + 14;
    if (top + est > area.height) top = (area.height - est).clamp(0, double.infinity);
    return Positioned(
      left: left.clamp(0, area.width),
      top: top,
      // Follows the pointer, so it is drawn here rather than by a Tooltip,
      // with the look of a RichTooltip (app tooltip style).
      child: IgnorePointer(
        child: Container(
          constraints: const BoxConstraints(maxWidth: w),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: TooltipTheme.of(context).decoration,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: uiText(TypeSize.caption, weight: FontWeight.w600, color: c.text, features: kTabular),
              ),
              const SizedBox(height: 2),
              for (final (color, name, value) in rows)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _swatch(color),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: uiText(TypeSize.caption, color: c.textSecondary),
                        ),
                      ),
                      const SizedBox(width: Gap.md),
                      Text(
                        value,
                        style: uiText(TypeSize.caption, color: c.text, features: kTabular),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(double? v) => v == null ? '—' : formatNumber(v, maxDecimals: 6);

  // -------------------------------------------------------------------------
  // Configuration panel
  // -------------------------------------------------------------------------

  Widget _dropdown<T>(T value, List<(T, String)> items, ValueChanged<T> onChanged) =>
      SelectField<T>(value: value, items: [for (final (v, l) in items) (v, l, null)], onChanged: onChanged);

  List<Widget> _configPanel(DbColors c) {
    final cfg = _config;
    final palette = ChartPalette.of(context);
    final numeric = _profiles.where((p) => p.numeric).toList();
    final xItems = <(int?, String)>[
      (null, 'Numero di riga'),
      for (final p in _profiles)
        if (!p.binary && (cfg.kind != ChartKind.scatter || p.numeric || p.date))
          (
            p.index,
            '${p.name}${p.date
                ? '  · data'
                : p.numeric
                ? '  · numero'
                : ''}',
          ),
    ];
    final maxSeries = cfg.kind == ChartKind.scatter
        ? kMaxScatterSeries
        : cfg.kind.isPie
        ? 1
        : kMaxSeries;
    final label = uiText(TypeSize.caption, weight: FontWeight.w600, color: c.textSecondary);
    Widget field(String text, Widget control) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(text, style: label),
        const SizedBox(height: 4),
        control,
      ],
    );
    return [
      InspectorSection(
        title: 'Dati',
        children: [
          field(
            cfg.kind == ChartKind.barHorizontal ? 'Categorie (asse Y)' : 'Asse X / categorie',
            _dropdown<int?>(
              xItems.any((e) => e.$1 == cfg.x) ? cfg.x : null,
              xItems,
              (v) => _update((x) {
                x.x = v;
                if (v == null) return;
                x.removeY(v);
                if (v < _profiles.length && _profiles[v].date) x.sort = ChartSort.x;
              }),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(cfg.kind.isPie ? 'Valore' : 'Serie (valori numerici)', style: label),
              const SizedBox(height: 2),
              if (numeric.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                  child: Text('Nessuna colonna numerica', style: uiText(TypeSize.small, color: c.textTertiary)),
                ),
              for (final p in numeric)
                if (p.index != cfg.x)
                  SizedBox(
                    height: ListRow.height,
                    child: Row(
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: CheckboxRow(
                              label: p.name,
                              value: cfg.y.contains(p.index),
                              onChanged: (_) => _toggleSeries(p.index),
                            ),
                          ),
                        ),
                        if (cfg.y.contains(p.index) && cfg.y.indexOf(p.index) < maxSeries && !cfg.kind.isPie)
                          _swatch(palette[cfg.slotOf(p.index, 0)]),
                      ],
                    ),
                  ),
            ],
          ),
        ],
      ),
      if (cfg.kind != ChartKind.scatter)
        InspectorSection(
          title: 'Categorie',
          children: [
            field(
              'Aggregazione per categoria',
              _dropdown<ChartAgg>(cfg.agg, [
                for (final a in ChartAgg.values) (a, a.label),
              ], (v) => _update((x) => x.agg = v)),
            ),
            field(
              'Ordinamento',
              _dropdown<ChartSort>(cfg.sort, [
                for (final s in ChartSort.values) (s, s.label),
              ], (v) => _update((x) => x.sort = v)),
            ),
            field(
              'Categorie mostrate',
              _dropdown<int>(const [0, 5, 10, 20, 30, 50, 100].contains(cfg.topN) ? cfg.topN : 0, [
                (0, 'Tutte'),
                for (final n in [5, 10, 20, 30, 50, 100]) (n, 'Prime $n'),
              ], (v) => _update((x) => x.topN = v)),
            ),
          ],
        ),
      InspectorSection(
        title: 'Aspetto',
        spacing: 0,
        children: [
          if (cfg.kind.canStack) _switchRow(c, 'Serie impilate', cfg.stacked, (v) => _update((x) => x.stacked = v)),
          _switchRow(c, 'Legenda', cfg.legend, (v) => _update((x) => x.legend = v)),
        ],
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Text(
          'Il grafico usa le righe caricate e il filtro rapido della griglia.',
          style: uiText(TypeSize.caption, color: c.textTertiary),
        ),
      ),
    ];
  }

  void _toggleSeries(int column) => _update((x) {
    if (x.y.contains(column)) {
      x.removeY(column);
    } else {
      if (x.kind.isPie) x.clearY();
      x.addY(column);
    }
  });

  Widget _switchRow(DbColors c, String text, bool value, ValueChanged<bool> onChanged) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: CheckboxRow(label: text, value: value, onChanged: onChanged),
  );
}
