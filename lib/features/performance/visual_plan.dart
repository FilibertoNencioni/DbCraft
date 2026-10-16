// Visual execution plan: graphical tree (pan / zoom), table, text and
// source views with a detail panel for the selected operator.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../ui/actions.dart';
import '../../ui/widgets/common.dart';
import 'lite_table.dart';
import 'plan_model.dart';
import 'plan_runner.dart';

/// Opens the visual plan of [sql] in a new editor tab.
Future<void> showVisualPlan(BuildContext context, DbConnection dc, String sql) async {
  if (sql.trim().isEmpty) {
    showToast(context, 'Seleziona o posiziona il cursore su un\'istruzione', error: true);
    return;
  }
  if (!await ensureConnected(context, dc)) return;
  if (!context.mounted) return;
  if (!visualPlanSupported(dc.dialect.family)) {
    showToast(context, 'Piano visuale non disponibile per ${dc.serverLabel}: usa "Piano" nell\'editor', error: true);
    return;
  }
  AppScope.read(context).openFeatureTab(VisualPlanTab(dc, sql));
}

enum PlanViewMode { graph, table, text, source }

class VisualPlanTab extends FeatureTab {
  VisualPlanTab(this.dc, this.sql);
  final DbConnection dc;
  final String sql;

  PlanTree? plan;
  Object? error;
  bool loading = false;
  bool analyze = false;
  PlanNode? selected;
  PlanViewMode mode = PlanViewMode.graph;
  bool _started = false;
  bool _disposed = false;

  @override
  String get title {
    final s = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
    return 'Piano · ${s.length > 24 ? '${s.substring(0, 24)}…' : s}';
  }

  @override
  String get tooltip => '${dc.config.name}: $sql';
  @override
  IconData get icon => AppIcons.tree;
  @override
  DbConnection get connection => dc;

  @override
  Widget buildView(BuildContext context) => VisualPlanView(tab: this);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> run() async {
    if (loading) return;
    _started = true;
    loading = true;
    error = null;
    _notify();
    try {
      final p = await runVisualPlan(dc, sql, analyze: analyze);
      plan = p;
      selected = null;
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      _notify();
    }
  }

  void select(PlanNode? n) {
    selected = n;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class VisualPlanView extends StatefulWidget {
  const VisualPlanView({super.key, required this.tab});
  final VisualPlanTab tab;

  @override
  State<VisualPlanView> createState() => _VisualPlanViewState();
}

class _VisualPlanViewState extends State<VisualPlanView> {
  final _transform = TransformationController();
  Size _viewport = Size.zero;
  PlanTree? _laidOut;
  PlanLayout? _layout;
  bool _needsFit = true;

  VisualPlanTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    // Started after the first frame: run() notifies the app state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !tab._started) unawaited(tab.run());
    });
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _toggleAnalyze(bool v) async {
    if (v) {
      final modifying = isModifyingSql(tab.sql);
      final ok = await confirmDialog(
        context,
        'Eseguire l\'istruzione?',
        'Con ANALYZE l\'istruzione viene eseguita per misurare tempi e righe effettive. '
            'Viene eseguita in una transazione che poi viene annullata (rollback)'
            '${modifying ? ', ma l\'istruzione modifica i dati: lock, trigger e sequenze hanno comunque effetto.' : '.'}',
        ok: 'Abilita ANALYZE',
        destructive: modifying,
      );
      if (!ok || !mounted) return;
      if (modifying && tab.dc.config.type.confirmExecute) {
        final ok2 = await confirmDialog(
          context,
          'Connessione di produzione',
          'L\'istruzione verrà eseguita su "${tab.dc.config.name}" (${tab.dc.config.type.label}). Continuare?',
          ok: 'Continua',
          destructive: true,
        );
        if (!ok2 || !mounted) return;
      }
    }
    tab.analyze = v;
    _needsFit = true;
    await tab.run();
  }

  double _nodeWidth(PlanNode n) => 196 + 72 * n.share;

  void _fit() {
    final l = _layout;
    if (l == null || _viewport.isEmpty) return;
    final s = math.min(1.0, math.min(_viewport.width / l.size.width, _viewport.height / l.size.height));
    final scale = s.clamp(0.2, 1.0);
    final dx = math.max(0.0, (_viewport.width - l.size.width * scale) / 2);
    _transform.value = Matrix4.identity()
      ..translateByDouble(dx, 0, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _zoom(double f) {
    final m = _transform.value.clone();
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    _transform.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(m);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) {
        final c = DbColors.of(context);
        final p = tab.plan;
        if (p != null && !identical(p, _laidOut)) {
          _laidOut = p;
          _layout = layoutPlan(p.root, width: _nodeWidth);
          _needsFit = true;
        }
        Widget body;
        if (tab.loading && p == null) {
          body = const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
        } else if (tab.error != null) {
          final e = tab.error!;
          body = EmptyState(
            icon: AppIcons.error,
            title: 'Piano non disponibile',
            message: e is OdbcException ? e.message : e.toString().replaceFirst(RegExp(r'^\w+Error: '), ''),
            action: PrimaryButton(label: 'Riprova', icon: AppIcons.refresh, onPressed: tab.run),
          );
        } else if (p == null) {
          body = const SizedBox();
        } else {
          body = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: switch (tab.mode) {
                  PlanViewMode.graph => _graph(context, p),
                  PlanViewMode.table => _table(context, p),
                  PlanViewMode.text => _textView(context, p.text ?? planToText(p)),
                  PlanViewMode.source => _textView(context, _prettySource(p)),
                },
              ),
              Container(width: 1, color: c.separator),
              SizedBox(width: 320, child: _details(context, p)),
            ],
          );
        }
        return Container(
          color: c.content,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(context),
              if (tab.loading && p != null) const LinearProgressIndicator(minHeight: 2),
              Expanded(child: body),
              if (p != null) _statusBar(context, p),
            ],
          ),
        );
      },
    );
  }

  Widget _toolbar(BuildContext context) {
    final c = DbColors.of(context);
    final analyzable = planAnalyzeSupported(tab.dc.dialect.family);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          PrimaryButton(
            label: 'Aggiorna',
            icon: AppIcons.refresh,
            tooltip: 'Ricalcola il piano',
            onPressed: tab.loading ? null : tab.run,
          ),
          if (analyzable) ...[
            const SizedBox(width: Gap.md),
            DbSwitch(value: tab.analyze, onChanged: tab.loading ? null : _toggleAnalyze),
            const SizedBox(width: 6),
            Tooltip(
              message: 'Esegue l\'istruzione (in una transazione annullata) per misurare tempi e righe effettive',
              child: Text(
                'Analyze',
                style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary),
              ),
            ),
          ],
          const ToolSeparator(),
          Segmented<PlanViewMode>(
            value: tab.mode,
            items: const [
              (PlanViewMode.graph, 'Grafico', AppIcons.tree),
              (PlanViewMode.table, 'Tabella', AppIcons.rows),
              (PlanViewMode.text, 'Testo', AppIcons.notes),
              (PlanViewMode.source, 'Sorgente', AppIcons.code),
            ],
            onChanged: (m) {
              tab.mode = m;
              if (m == PlanViewMode.graph) _needsFit = true;
              tab.refresh();
            },
          ),
          if (tab.mode == PlanViewMode.graph) ...[
            const ToolSeparator(),
            ToolButton(icon: AppIcons.zoomOut, tooltip: 'Riduci', onPressed: () => _zoom(1 / 1.25)),
            ToolButton(icon: AppIcons.zoomIn, tooltip: 'Ingrandisci', onPressed: () => _zoom(1.25)),
            ToolButton(icon: AppIcons.fitScreen, tooltip: 'Adatta alla finestra', onPressed: _fit),
          ],
          const Spacer(),
          ToolButton(
            icon: AppIcons.copy,
            tooltip: 'Copia il piano come testo',
            onPressed: tab.plan == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: planToText(tab.plan!)));
                    showToast(context, 'Piano copiato');
                  },
          ),
          ToolButton(
            icon: AppIcons.script,
            tooltip: 'Apri l\'istruzione nell\'editor SQL',
            onPressed: () => AppScope.read(context).sqlEditorWith(tab.dc, tab.sql),
          ),
        ],
      ),
    );
  }

  Widget _statusBar(BuildContext context, PlanTree p) {
    final c = DbColors.of(context);
    final warnings = p.allWarnings.length;
    final parts = <String>[
      if (p.root.cost != null) 'Costo totale ${p.root.cost!.toStringAsFixed(2)}',
      '${p.nodes.length} operatori',
      for (final k in const ['Planning Time', 'Execution Time'])
        if (p.summary[k] != null) '${k == 'Planning Time' ? 'Pianificazione' : 'Esecuzione'} ${p.summary[k]} ms',
      if (p.analyzed) 'valori effettivi' else 'stime',
    ];
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(top: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join(' · '),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: TypeSize.caption + 0.5, color: c.textSecondary, fontFeatures: kTabular),
            ),
          ),
          if (warnings > 0) ...[
            Icon(AppIcons.warning, size: 13, color: c.warning),
            const SizedBox(width: 4),
            Text(
              '$warnings avvisi',
              style: TextStyle(fontSize: TypeSize.caption + 0.5, color: c.warning),
            ),
          ],
        ],
      ),
    );
  }

  Color? _heat(BuildContext context, PlanNode n) {
    final c = DbColors.of(context);
    if (n.share >= 0.5) return c.danger;
    if (n.share >= 0.2) return c.warning;
    return null;
  }

  Widget _graph(BuildContext context, PlanTree p) {
    final c = DbColors.of(context);
    final l = _layout!;
    return LayoutBuilder(
      builder: (context, box) {
        _viewport = box.biggest;
        if (_needsFit) {
          _needsFit = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fit();
          });
        }
        return GestureDetector(
          onTap: () => tab.select(null),
          child: InteractiveViewer(
            transformationController: _transform,
            constrained: false,
            minScale: 0.15,
            maxScale: 3,
            boundaryMargin: const EdgeInsets.all(600),
            child: SizedBox(
              width: l.size.width,
              height: l.size.height,
              child: Stack(
                children: [
                  Positioned.fill(child: CustomPaint(painter: _EdgesPainter(l, c.textTertiary.withValues(alpha: 0.6)))),
                  for (final e in l.rects.entries) Positioned.fromRect(rect: e.value, child: _nodeCard(context, e.key)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _nodeCard(BuildContext context, PlanNode n) {
    final c = DbColors.of(context);
    final heat = _heat(context, n);
    final selected = tab.selected == n;
    final pct = (n.share * 100);
    final metrics = <String>[
      if (n.cost != null) 'costo ${n.cost!.toStringAsFixed(n.cost! < 10 ? 2 : 0)}',
      if (n.rowsActual != null)
        'righe ${formatCount(n.rowsActual!)}${n.rowsEstimated != null ? '/${formatCount(n.rowsEstimated!)}' : ''}'
      else if (n.rowsEstimated != null)
        'righe ${formatCount(n.rowsEstimated!)}',
      if (n.timeMs != null) '${n.timeMs!.toStringAsFixed(n.timeMs! < 10 ? 2 : 0)} ms',
    ];
    final worst = n.warnings.fold<PlanWarningLevel?>(
      null,
      (a, w) => a == null || w.level.index > a.index ? w.level : a,
    );
    return GestureDetector(
      onTap: () => tab.select(n),
      child: Tooltip(
        message: [n.title, if (n.detail != null) n.detail!, for (final w in n.warnings) '⚠ ${w.message}'].join('\n'),
        waitDuration: const Duration(milliseconds: 700),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              (heat ?? c.accent).withValues(alpha: heat == null ? 0.03 : 0.06 + 0.16 * n.share),
              c.content,
            ),
            borderRadius: BorderRadius.circular(Radii.panel),
            border: Border.all(
              color: selected ? c.accent : (heat ?? c.separator),
              width: selected ? 2 : (heat == null ? 1 : 1.5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      n.operation,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: TypeSize.small + 0.5, fontWeight: FontWeight.w600, color: c.text),
                    ),
                  ),
                  if (worst != null)
                    Icon(
                      AppIcons.warning,
                      size: 14,
                      color: worst == PlanWarningLevel.danger
                          ? c.danger
                          : (worst == PlanWarningLevel.warning ? c.warning : c.textTertiary),
                    ),
                ],
              ),
              Text(
                n.object ?? n.detail ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      metrics.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary, fontFeatures: kTabular),
                    ),
                  ),
                  Text(
                    '${pct.toStringAsFixed(pct < 10 ? 1 : 0)}%',
                    style: TextStyle(
                      fontSize: TypeSize.caption,
                      fontWeight: FontWeight.w600,
                      color: heat ?? c.textSecondary,
                      fontFeatures: kTabular,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: n.share.clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: c.pressed,
                  color: heat ?? c.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _table(BuildContext context, PlanTree p) {
    final c = DbColors.of(context);
    final nodes = p.nodes;
    String n2(double? v, [int d = 2]) => v == null ? '' : v.toStringAsFixed(d);
    const headers = [
      'Operazione',
      'Oggetto',
      '%',
      'Costo',
      'Righe stimate',
      'Righe effettive',
      'Tempo ms',
      'Loop',
      'Avvisi',
    ];
    return LiteTable(
      headers: headers,
      rowCount: nodes.length,
      cell: (r, i) {
        final n = nodes[r];
        return switch (i) {
          0 => n.operation,
          1 => n.object ?? '',
          2 => (n.share * 100).toStringAsFixed(1),
          3 => n2(n.cost),
          4 => n.rowsEstimated == null ? '' : formatCount(n.rowsEstimated!),
          5 => n.rowsActual == null ? '' : formatCount(n.rowsActual!),
          6 => n2(n.timeMs, 3),
          7 => n.loops?.toString() ?? '',
          _ => n.warnings.map((w) => w.message).join(' · '),
        };
      },
      numeric: (i) => i >= 2 && i <= 7,
      width: (i) => i == 0 ? 280 : null,
      leading: (r) => SizedBox(width: nodes[r].depth * 14.0),
      selected: tab.selected == null ? null : nodes.indexOf(tab.selected!),
      onSelect: (r) => tab.select(nodes[r]),
      rowTint: (r) {
        final h = _heat(context, nodes[r]);
        return h == null ? null : Color.alphaBlend(h.withValues(alpha: 0.08), c.content);
      },
      tooltip: (r, i) => i == 8 || i == 0 ? (i == 0 ? nodes[r].detail : nodes[r].warnings.join('\n')) : null,
    );
  }

  String _prettySource(PlanTree p) {
    final s = p.source.trim();
    if (s.startsWith('{') || s.startsWith('[')) {
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
      } catch (_) {}
    }
    if (s.startsWith('<')) return s.replaceAll('><', '>\n<');
    return s;
  }

  Widget _textView(BuildContext context, String text) => SingleChildScrollView(
    padding: const EdgeInsets.all(Gap.lg),
    child: SizedBox(
      width: double.infinity,
      child: SelectableText(text, style: monoStyle(context, size: TypeSize.small)),
    ),
  );

  Widget _details(BuildContext context, PlanTree p) {
    final c = DbColors.of(context);
    final n = tab.selected;
    final children = <Widget>[];
    if (n == null) {
      children.addAll([
        Text(
          'Piano',
          style: TextStyle(fontSize: TypeSize.title, fontWeight: FontWeight.w600, color: c.text),
        ),
        const SizedBox(height: Gap.xs),
        Text(
          'Seleziona un operatore per vederne le proprietà.',
          style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
        ),
        const SizedBox(height: Gap.md),
        if (p.summary.isNotEmpty)
          PropertyTable(labelWidth: 120, entries: [for (final e in p.summary.entries) (e.key, e.value)]),
        const SizedBox(height: Gap.md),
        ..._warningList(
          context,
          p.allWarnings.map((e) => e.$2).toList(),
          nodes: p.allWarnings.map((e) => e.$1).toList(),
        ),
        if (p.allWarnings.isEmpty)
          Row(
            children: [
              Icon(AppIcons.checkCircle, size: 15, color: c.success),
              const SizedBox(width: Gap.xs),
              Text(
                'Nessun avviso',
                style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
              ),
            ],
          ),
      ]);
    } else {
      final pct = n.share * 100;
      children.addAll([
        Text(
          n.operation,
          style: TextStyle(fontSize: TypeSize.title, fontWeight: FontWeight.w600, color: c.text),
        ),
        if (n.object != null)
          Text(
            n.object!,
            style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
          ),
        const SizedBox(height: Gap.sm),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            Badge2(
              '${pct.toStringAsFixed(1)}% del ${p.analyzed && n.selfTimeMs != null ? 'tempo' : 'costo'}',
              color: _heat(context, n) ?? c.accent,
            ),
            if (n.loops != null) Badge2('${n.loops} loop'),
          ],
        ),
        const SizedBox(height: Gap.md),
        ..._warningList(context, n.warnings),
        if (n.detail != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
              color: c.chrome,
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(color: c.separator),
            ),
            child: SelectableText(n.detail!, style: monoStyle(context, size: TypeSize.caption + 0.5)),
          ),
          const SizedBox(height: Gap.md),
        ],
        PropertyTable(
          labelWidth: 120,
          entries: [
            if (n.cost != null) ('Costo totale', n.cost!.toStringAsFixed(2)),
            ('Costo proprio', n.selfCost.toStringAsFixed(2)),
            if (n.startupCost != null) ('Costo iniziale', n.startupCost!.toStringAsFixed(2)),
            if (n.rowsEstimated != null) ('Righe stimate', formatCount(n.rowsEstimated!)),
            if (n.rowsActual != null) ('Righe effettive', formatCount(n.rowsActual!)),
            if (n.timeMs != null) ('Tempo totale', '${n.timeMs!.toStringAsFixed(3)} ms'),
            if (n.selfTimeMs != null) ('Tempo proprio', '${n.selfTimeMs!.toStringAsFixed(3)} ms'),
            if (n.buffers != null) ('Buffer / letture', formatCount(n.buffers!)),
          ],
        ),
        const SizedBox(height: Gap.md),
        Text(
          'Tutte le proprietà',
          style: TextStyle(fontSize: TypeSize.caption, fontWeight: FontWeight.w600, color: c.textTertiary),
        ),
        const SizedBox(height: Gap.xs),
        PropertyTable(labelWidth: 120, entries: [for (final e in n.props.entries) (e.key, e.value)]),
      ]);
    }
    return Container(
      color: c.content,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: children),
    );
  }

  List<Widget> _warningList(BuildContext context, List<PlanWarning> warnings, {List<PlanNode?>? nodes}) {
    final c = DbColors.of(context);
    return [
      for (var i = 0; i < warnings.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Container(
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
              color: (switch (warnings[i].level) {
                PlanWarningLevel.danger => c.danger,
                PlanWarningLevel.warning => c.warning,
                PlanWarningLevel.info => c.textTertiary,
              }).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      warnings[i].level == PlanWarningLevel.info
                          ? AppIcons.info
                          : AppIcons.warning,
                      size: 14,
                      color: switch (warnings[i].level) {
                        PlanWarningLevel.danger => c.danger,
                        PlanWarningLevel.warning => c.warning,
                        PlanWarningLevel.info => c.textSecondary,
                      },
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        warnings[i].message,
                        style: TextStyle(fontSize: TypeSize.small, color: c.text),
                      ),
                    ),
                  ],
                ),
                if (nodes != null && nodes[i] != null)
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 24)),
                    onPressed: () => tab.select(nodes[i]),
                    child: Text('Vai a ${nodes[i]!.operation}', style: const TextStyle(fontSize: TypeSize.small)),
                  ),
                if (warnings[i].suggestion != null) ...[
                  const SizedBox(height: Gap.xs),
                  SelectableText(warnings[i].suggestion!, style: monoStyle(context, size: TypeSize.caption + 0.5)),
                  Row(
                    children: [
                      ToolButton(
                        icon: AppIcons.copy,
                        tooltip: 'Copia',
                        onPressed: () => Clipboard.setData(ClipboardData(text: warnings[i].suggestion!)),
                      ),
                      ToolButton(
                        icon: AppIcons.script,
                        tooltip: 'Apri nell\'editor SQL',
                        onPressed: () => AppScope.read(context).sqlEditorWith(tab.dc, warnings[i].suggestion!),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
    ];
  }
}

/// Elbow connectors between parents and children; the stroke grows with the
/// number of rows flowing through the edge.
class _EdgesPainter extends CustomPainter {
  _EdgesPainter(this.layout, this.color);
  final PlanLayout layout;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final e in layout.rects.entries) {
      final parent = e.value;
      for (final child in e.key.children) {
        final r = layout.rects[child];
        if (r == null) continue;
        final rows = child.rowsActual ?? child.rowsEstimated ?? 1;
        paint.strokeWidth = (1 + math.log(rows + 1) / math.ln10 * 0.7).clamp(1.0, 6.0);
        final a = Offset(parent.center.dx, parent.bottom);
        final b = Offset(r.center.dx, r.top);
        final midY = (a.dy + b.dy) / 2;
        final path = Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(a.dx, midY)
          ..lineTo(b.dx, midY)
          ..lineTo(b.dx, b.dy);
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_EdgesPainter old) => old.layout != layout || old.color != color;
}
