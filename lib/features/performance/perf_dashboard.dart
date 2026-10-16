// Live performance dashboard: KPI tiles with sparklines and the sessions,
// locks, top queries, biggest tables and index tables of the server.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../drivers/db_session.dart';
import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../ui/actions.dart';
import '../../ui/widgets/common.dart';
import 'lite_table.dart';
import 'perf_metrics.dart';
import 'perf_providers.dart';
import 'sparkline.dart';

/// Editor tab hosting the dashboard of [dc].
class PerformanceDashboardTab extends FeatureTab {
  PerformanceDashboardTab(this.dc);
  final DbConnection dc;

  /// Created on first display: [AppState.openFeatureTab] may dispose a
  /// duplicate tab without ever showing it.
  PerfDashboardController? _controller;

  PerfDashboardController controllerFor(int refreshSec) =>
      _controller ??= PerfDashboardController(dc, refreshSec: refreshSec);

  @override
  String get title => 'Prestazioni · ${dc.config.name}';
  @override
  IconData get icon => AppIcons.performance;
  @override
  DbConnection get connection => dc;

  @override
  Widget buildView(BuildContext context) => PerfDashboardView(tab: this);

  @override
  void dispose() {
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }
}

enum DashboardPhase { idle, notConnected, unsupported, starting, running, failed }

/// Result of a dashboard table.
class TableState {
  List<String> columns = const [];
  List<List<Object?>> rows = const [];
  String? error;
  String? hint;
  bool loading = false;
  DateTime? updated;
}

/// Polls the server on a dedicated read-only session.
class PerfDashboardController extends ChangeNotifier {
  PerfDashboardController(this.dc, {required int refreshSec}) : _refreshSec = refreshSec.clamp(1, 3600);

  final DbConnection dc;
  PerfProvider? provider;
  DbSession? _session;
  Timer? _timer;
  int _refreshSec;
  int _tick = 0;
  bool _busy = false;
  bool _disposed = false;

  DashboardPhase phase = DashboardPhase.idle;
  String? error;
  bool paused = false;
  DateTime? lastUpdate;

  final Map<String, SampleBuffer> buffers = {};
  final Map<String, double?> current = {};
  final Map<int, String> counterErrors = {};
  final Map<String, TableState> tables = {};
  final Map<String, int> _preferred = {};
  final Map<int, Set<String>> _counterKeys = {};
  final Map<String, double> _counters = {};
  CounterSnapshot? _prev;

  int get refreshSec => _refreshSec;

  set refreshSec(int v) {
    _refreshSec = v.clamp(1, 3600);
    if (phase == DashboardPhase.running && !paused) _schedule();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (phase == DashboardPhase.starting || phase == DashboardPhase.running) return;
    error = null;
    if (!dc.isConnected) {
      phase = DashboardPhase.notConnected;
      _notify();
      return;
    }
    provider = PerfProvider.forFamily(dc.dialect.family);
    if (provider == null) {
      phase = DashboardPhase.unsupported;
      _notify();
      return;
    }
    phase = DashboardPhase.starting;
    _notify();
    try {
      final s = await dc.openSession(readOnly: true);
      if (_disposed) {
        await s.close();
        return;
      }
      _session = s;
      phase = DashboardPhase.running;
      _notify();
      await refresh(full: true);
      _schedule();
    } catch (e) {
      phase = DashboardPhase.failed;
      error = _msg(e);
      _notify();
    }
  }

  Future<void> restart() async {
    await _closeSession();
    phase = DashboardPhase.idle;
    _tick = 0;
    _prev = null;
    _counters.clear();
    _preferred.clear();
    for (final b in buffers.values) {
      b.clear();
    }
    await start();
  }

  void _schedule() {
    _timer?.cancel();
    if (paused) return;
    _timer = Timer.periodic(Duration(seconds: _refreshSec), (_) => refresh());
  }

  void togglePause() {
    paused = !paused;
    if (paused) {
      _timer?.cancel();
    } else {
      refresh();
      _schedule();
    }
    _notify();
  }

  static String _msg(Object e) => e is OdbcException ? e.message : e.toString();

  Future<ResultPage> _query(String sql) async {
    final s = _session;
    if (s == null || s.isClosed) throw StateError('Sessione di monitoraggio chiusa');
    final page = await s.execute(sql, fetchSize: 500, queryTimeoutSec: 30);
    if (page.cursorId != null) {
      try {
        await s.closeCursor(page.cursorId!);
      } catch (_) {}
    }
    return page;
  }

  /// Runs the first alternative that works (remembering it for the next
  /// refreshes).
  Future<ResultPage> _queryAlternatives(String key, List<String> sqls) async {
    final first = _preferred[key] ?? 0;
    Object? lastError;
    for (var i = first; i < sqls.length; i++) {
      try {
        final r = await _query(sqls[i]);
        _preferred[key] = i;
        return r;
      } catch (e) {
        lastError = e;
        if (_session?.isClosed ?? true) rethrow;
      }
    }
    throw lastError ?? StateError('Nessuna query');
  }

  /// Reads the counters and the live tables (all tables when [full]).
  Future<void> refresh({bool full = false}) async {
    final p = provider;
    if (p == null || _busy || _disposed || phase != DashboardPhase.running) return;
    _busy = true;
    _tick++;
    try {
      for (var i = 0; i < p.counters.length; i++) {
        final q = p.counters[i];
        if (!full && (_tick - 1) % q.everyTicks != 0 && !counterErrors.containsKey(i)) continue;
        try {
          final page = await _queryAlternatives('c$i', q.sqls);
          final values = q.map(page.columns.map((e) => e.name).toList(), page.rows);
          for (final k in _counterKeys[i] ?? const <String>{}) {
            _counters.remove(k);
          }
          _counterKeys[i] = values.keys.toSet();
          _counters.addAll(values);
          counterErrors.remove(i);
        } catch (e) {
          if (_session?.isClosed ?? true) rethrow;
          counterErrors[i] = _msg(e);
          for (final k in _counterKeys.remove(i) ?? const <String>{}) {
            _counters.remove(k);
          }
        }
        if (_disposed) return;
      }
      final snap = CounterSnapshot(DateTime.now(), Map.of(_counters));
      for (final k in p.kpis) {
        double? v;
        try {
          v = k.compute(snap, _prev);
        } catch (_) {
          v = null;
        }
        current[k.id] = v;
        (buffers[k.id] ??= SampleBuffer()).add(v);
      }
      _prev = snap;
      lastUpdate = snap.time;
      _notify();

      for (final t in p.tables) {
        if (!full && !t.live) continue;
        await refreshTable(t, notify: false);
        if (_disposed) return;
      }
    } catch (e) {
      // Session lost: stop polling, the view offers to restart.
      _timer?.cancel();
      phase = DashboardPhase.failed;
      error = _msg(e);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> refreshTable(TableSpec t, {bool notify = true}) async {
    final st = tables[t.id] ??= TableState();
    st.loading = true;
    if (notify) _notify();
    try {
      if (t.requires != null) {
        final ok = await _query(t.requires!);
        if (ok.rows.isEmpty) {
          st
            ..hint = t.requiresHint
            ..error = null
            ..columns = const []
            ..rows = const [];
          return;
        }
      }
      final page = await _queryAlternatives('t${t.id}', t.sqls);
      st
        ..columns = page.columns.map((e) => e.name.toLowerCase()).toList()
        ..rows = page.rows
        ..error = null
        ..hint = null
        ..updated = DateTime.now();
    } catch (e) {
      if (_session?.isClosed ?? true) rethrow;
      st.error = _msg(e);
    } finally {
      st.loading = false;
      if (notify) _notify();
    }
  }

  /// Runs a kill / cancel statement on a short lived session.
  Future<void> runAction(String sql) async {
    final s = await dc.openSession();
    try {
      final r = await s.execute(sql, queryTimeoutSec: 30);
      if (r.cursorId != null) await s.closeCursor(r.cursorId!);
    } finally {
      await s.close();
    }
    final p = provider;
    if (p != null) {
      for (final t in p.tables.where((t) => t.live)) {
        await refreshTable(t);
      }
    }
  }

  Future<void> _closeSession() async {
    _timer?.cancel();
    _timer = null;
    final s = _session;
    _session = null;
    if (s != null) {
      s.cancel();
      await s.close();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_closeSession());
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

class PerfDashboardView extends StatefulWidget {
  const PerfDashboardView({super.key, required this.tab});
  final PerformanceDashboardTab tab;

  @override
  State<PerfDashboardView> createState() => _PerfDashboardViewState();
}

class _PerfDashboardViewState extends State<PerfDashboardView> {
  late PerfDashboardController ctl;
  String _table = 'sessions';
  int? _selected;
  bool _showIdle = false;

  @override
  void initState() {
    super.initState();
    ctl = widget.tab.controllerFor(AppScope.read(context).settings.perfRefreshSec);
    if (ctl.phase == DashboardPhase.idle) unawaited(ctl.start());
  }

  Future<void> _connect() async {
    if (await ensureConnected(context, widget.tab.dc)) await ctl.restart();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final c = DbColors.of(context);
        return Container(
          color: c.content,
          child: switch (ctl.phase) {
            DashboardPhase.idle || DashboardPhase.starting => const Center(
              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            DashboardPhase.notConnected => EmptyState(
              icon: AppIcons.disconnect,
              title: 'Connessione non attiva',
              message: 'Connetti "${widget.tab.dc.config.name}" per vedere sessioni, lock e metriche del server.',
              action: PrimaryButton(label: 'Connetti', icon: AppIcons.connect, onPressed: _connect),
            ),
            DashboardPhase.unsupported => EmptyState(
              icon: AppIcons.performance,
              title:
                  'Dashboard non supportata per ${widget.tab.dc.serverLabel.isEmpty ? 'questo database' : widget.tab.dc.serverLabel}',
              message:
                  'Le metriche live sono disponibili per PostgreSQL, SQL Server, MySQL/MariaDB e Oracle. '
                  'Per questo database puoi usare il piano visuale dall\'editor SQL (anche per SQLite) '
                  'e interrogare le viste di sistema dall\'editor.',
            ),
            DashboardPhase.failed => EmptyState(
              icon: AppIcons.error,
              title: 'Monitoraggio interrotto',
              message: ctl.error,
              action: PrimaryButton(label: 'Riprova', icon: AppIcons.refresh, onPressed: ctl.restart),
            ),
            DashboardPhase.running => _dashboard(context),
          },
        );
      },
    );
  }

  Widget _dashboard(BuildContext context) {
    final c = DbColors.of(context);
    final p = ctl.provider!;
    if (!p.tables.any((t) => t.id == _table)) _table = p.tables.first.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
          child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [for (final k in p.kpis) _kpi(context, k)]),
        ),
        if (ctl.counterErrors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
            child: Row(
              children: [
                Icon(AppIcons.info, size: 14, color: c.warning),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    'Alcune metriche non sono leggibili: ${ctl.counterErrors.values.first.split('\n').first}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: TypeSize.caption + 0.5, color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.separator)),
          ),
          child: Row(
            children: [
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Segmented<String>(
                    value: _table,
                    items: [for (final t in p.tables) (t.id, t.title, null)],
                    onChanged: (v) => setState(() {
                      _table = v;
                      _selected = null;
                    }),
                  ),
                ),
              ),
              const SizedBox(width: Gap.sm),
              ..._tableActions(context, p.tables.firstWhere((t) => t.id == _table)),
            ],
          ),
        ),
        Expanded(child: _tableBody(context, p.tables.firstWhere((t) => t.id == _table))),
      ],
    );
  }

  Widget _toolbar(BuildContext context) {
    final c = DbColors.of(context);
    final t = ctl.lastUpdate;
    String two(int v) => v.toString().padLeft(2, '0');
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          ToolButton(
            icon: ctl.paused ? AppIcons.run : AppIcons.pause,
            tooltip: ctl.paused ? 'Riprendi l\'aggiornamento automatico' : 'Sospendi l\'aggiornamento automatico',
            label: ctl.paused ? 'Riprendi' : 'Pausa',
            onPressed: ctl.togglePause,
          ),
          ToolButton(
            icon: AppIcons.refresh,
            tooltip: 'Aggiorna ora (tutte le schede)',
            onPressed: () => ctl.refresh(full: true),
          ),
          PopupMenuButton<int>(
            tooltip: 'Intervallo di aggiornamento',
            position: PopupMenuPosition.under,
            onSelected: (v) {
              ctl.refreshSec = v;
              final app = AppScope.read(context);
              app.settings.perfRefreshSec = v;
              unawaited(app.saveSettings());
            },
            itemBuilder: (_) => [
              for (final s in const [1, 2, 5, 10, 30, 60])
                CheckedPopupMenuItem(value: s, checked: s == ctl.refreshSec, child: Text('Ogni $s s')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.timer, size: 15, color: c.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    'Ogni ${ctl.refreshSec} s',
                    style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary, fontFeatures: kTabular),
                  ),
                  Icon(AppIcons.chevronDown, size: 14, color: c.textTertiary),
                ],
              ),
            ),
          ),
          const Spacer(),
          StatusDot(ctl.paused ? c.textTertiary : c.success, size: 7),
          const SizedBox(width: 6),
          Text(
            [
              ctl.provider!.label,
              if (widget.tab.dc.serverLabel.isNotEmpty) widget.tab.dc.serverLabel,
              if (t != null) 'aggiornato alle ${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
            ].join(' · '),
            style: TextStyle(fontSize: TypeSize.caption + 0.5, color: c.textSecondary, fontFeatures: kTabular),
          ),
          const SizedBox(width: Gap.sm),
        ],
      ),
    );
  }

  String _kpiText(KpiSpec k, double? v) {
    if (v == null) return '—';
    return switch (k.unit) {
      KpiUnit.count => formatNumber(v),
      KpiUnit.perSec => formatCompact(v),
      KpiUnit.percent => '${v.toStringAsFixed(v >= 99.95 ? 0 : 1).replaceAll('.', ',')}%',
      KpiUnit.bytes => formatBytes(v),
    };
  }

  Widget _kpi(BuildContext context, KpiSpec k) {
    final c = DbColors.of(context);
    final v = ctl.current[k.id];
    final warn = v != null && ((k.warnAbove != null && v > k.warnAbove!) || (k.warnBelow != null && v < k.warnBelow!));
    final buf = ctl.buffers[k.id];
    final color = warn ? c.warning : c.accent;
    return Tooltip(
      message: [
        k.help ?? k.label,
        if (buf != null && buf.max != null) 'min ${_kpiText(k, buf.min)} · max ${_kpiText(k, buf.max)}',
      ].join('\n'),
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        width: 184,
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
        decoration: BoxDecoration(
          color: c.chrome,
          borderRadius: BorderRadius.circular(Radii.panel),
          border: Border.all(color: c.separator),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              k.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: TypeSize.caption + 0.5, color: c.textSecondary),
            ),
            const SizedBox(height: 2),
            Text(
              _kpiText(k, v),
              style: TextStyle(
                fontSize: TypeSize.title + 2,
                fontWeight: FontWeight.w600,
                color: warn ? c.warning : c.text,
                fontFeatures: kTabular,
              ),
            ),
            const SizedBox(height: Gap.xs),
            Sparkline(values: buf?.values ?? const [], color: color, capacity: buf?.capacity ?? 120, height: 26),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Tables
  // -------------------------------------------------------------------------

  /// Visible rows of [t] (idle sessions filtered, blocking tree order).
  (List<List<Object?>>, List<int> depth, List<int> blocked) _visible(TableSpec t, TableState st) {
    var rows = st.rows;
    if (t.idleColumn != null && !_showIdle) {
      final i = st.columns.indexOf(t.idleColumn!);
      if (i >= 0) rows = rows.where((r) => !t.idleValues.contains((r[i] ?? '').toString().trim())).toList();
    }
    if (t.isBlockingTree) {
      final iId = st.columns.indexOf(t.idColumn!), iBy = st.columns.indexOf(t.blockedByColumn!);
      if (iId >= 0 && iBy >= 0) {
        String id(Object? v) {
          final d = toDouble(v);
          return d != null && d == d.roundToDouble() ? d.round().toString() : (v ?? '').toString();
        }

        final tree = buildBlockingTree([for (final r in rows) BlockingEntry(id(r[iId]), parseBlockers(r[iBy]), r)]);
        return (
          [
            for (final n in tree)
              n.entry.row ?? [for (var j = 0; j < st.columns.length; j++) j == iId ? n.entry.id : null],
          ],
          [for (final n in tree) n.depth],
          [for (final n in tree) n.blockedCount],
        );
      }
    }
    return (rows, const [], const []);
  }

  List<Widget> _tableActions(BuildContext context, TableSpec t) {
    final st = ctl.tables[t.id];
    final out = <Widget>[];
    if (t.help != null) {
      out.add(
        Tooltip(
          message: t.help!,
          child: Icon(AppIcons.help, size: 15, color: DbColors.of(context).textTertiary),
        ),
      );
      out.add(const SizedBox(width: Gap.sm));
    }
    if (t.idleColumn != null) {
      out.addAll([
        Text(
          'Mostra inattive',
          style: TextStyle(fontSize: TypeSize.small, color: DbColors.of(context).textSecondary),
        ),
        const SizedBox(width: 6),
        DbSwitch(value: _showIdle, onChanged: (v) => setState(() => _showIdle = v)),
        const ToolSeparator(),
      ]);
    }
    final a = t.actions;
    final row = _selectedRow(t);
    if (a != null) {
      if (a.cancel != null) {
        out.add(
          ToolButton(
            icon: AppIcons.cancel,
            tooltip: 'Annulla la query in esecuzione nella sessione selezionata',
            label: 'Annulla query',
            onPressed: row == null ? null : () => _action(t, row, cancel: true),
          ),
        );
      }
      out.add(
        ToolButton(
          icon: AppIcons.power,
          tooltip: 'Termina la sessione selezionata',
          label: 'Termina sessione',
          color: DbColors.of(context).danger,
          onPressed: row == null ? null : () => _action(t, row, cancel: false),
        ),
      );
    }
    if (!t.live) {
      out.add(
        ToolButton(
          icon: AppIcons.refresh,
          tooltip: 'Aggiorna questa scheda',
          onPressed: st?.loading ?? false ? null : () => ctl.refreshTable(t),
        ),
      );
    }
    return out;
  }

  Map<String, Object?>? _selectedRow(TableSpec t) {
    final st = ctl.tables[t.id];
    final s = _selected;
    if (st == null || s == null) return null;
    final (rows, _, _) = _visible(t, st);
    if (s >= rows.length) return null;
    return {for (var i = 0; i < st.columns.length; i++) st.columns[i]: rows[s][i]};
  }

  Future<void> _action(TableSpec t, Map<String, Object?> row, {required bool cancel}) async {
    final a = t.actions!;
    final String? sql;
    try {
      sql = cancel ? a.cancel?.call(row) : a.terminate(row);
    } catch (_) {
      showToast(context, 'Identificativo della sessione non disponibile', error: true);
      return;
    }
    if (sql == null) return;
    final dc = widget.tab.dc;
    final what = cancel ? 'Annullare la query in esecuzione' : 'Terminare la sessione';
    final ok = await confirmDialog(
      context,
      cancel ? 'Annulla query' : 'Termina sessione',
      '$what (${a.idLabel(row)}) su "${dc.config.name}"?\n\n$sql',
      ok: cancel ? 'Annulla query' : 'Termina',
      cancel: 'Indietro',
      destructive: true,
    );
    if (!ok || !mounted) return;
    if (dc.config.type.confirmExecute) {
      final ok2 = await confirmDialog(
        context,
        'Connessione di produzione',
        'Stai per intervenire su una sessione di "${dc.config.name}" (${dc.config.type.label}). Continuare?',
        ok: 'Continua',
        destructive: true,
      );
      if (!ok2 || !mounted) return;
    }
    final done = await guarded(context, () => ctl.runAction(sql!), title: 'Operazione non riuscita');
    if (done && mounted) {
      showToast(context, cancel ? 'Richiesta di annullamento inviata' : 'Sessione terminata');
      setState(() => _selected = null);
    }
  }

  Widget _tableBody(BuildContext context, TableSpec t) {
    final c = DbColors.of(context);
    final st = ctl.tables[t.id];
    if (st == null || (st.loading && st.rows.isEmpty && st.error == null && st.hint == null)) {
      if (st == null && !t.live) {
        // Static tables are loaded with the first full refresh.
        return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
      }
      return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (st.hint != null) {
      return EmptyState(icon: AppIcons.extension, title: 'Funzione non disponibile', message: st.hint);
    }
    if (st.error != null) {
      return Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(AppIcons.lock, size: 16, color: c.danger),
                const SizedBox(width: Gap.sm),
                Text(
                  'Impossibile leggere "${t.title}"',
                  style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.text),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              'Spesso dipende dai permessi dell\'utente sulle viste di sistema. Il resto della dashboard continua a funzionare.',
              style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
            ),
            const SizedBox(height: Gap.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: c.chrome,
                borderRadius: BorderRadius.circular(Radii.panel),
                border: Border.all(color: c.separator),
              ),
              child: SelectableText(st.error!, style: monoStyle(context, size: TypeSize.small)),
            ),
          ],
        ),
      );
    }
    final (rows, depth, blocked) = _visible(t, st);
    if (rows.isEmpty) {
      return EmptyState(
        icon: t.isBlockingTree ? AppIcons.lockOpen : AppIcons.empty,
        title: t.emptyTitle,
        message: t.idleColumn != null && !_showIdle && st.rows.isNotEmpty
            ? '${st.rows.length} sessioni inattive nascoste: attiva "Mostra inattive" per vederle.'
            : null,
      );
    }
    final kinds = [for (final col in st.columns) columnKind(col)];
    bool numeric(int i) {
      if (kinds[i] == ColKind.seconds || kinds[i] == ColKind.millis || kinds[i] == ColKind.bytes) return true;
      if (kinds[i] != ColKind.text) return false;
      final sample = rows.take(20).map((r) => r[i]).where((v) => v != null);
      return sample.isNotEmpty && sample.every((v) => v is num);
    }

    final numericCols = [for (var i = 0; i < st.columns.length; i++) numeric(i)];
    return LiteTable(
      headers: [for (final col in st.columns) columnLabel(col)],
      rowCount: rows.length,
      cell: (r, i) => formatCell(rows[r][i], kinds[i] == ColKind.text && numericCols[i] ? ColKind.number : kinds[i]),
      numeric: (i) => numericCols[i],
      mono: (i) => kinds[i] == ColKind.query,
      tooltip: (r, i) => kinds[i] == ColKind.query ? rows[r][i]?.toString() : null,
      selected: _selected,
      onSelect: (r) => setState(() => _selected = r),
      onContextMenu: (r, pos) => _contextMenu(t, st, rows[r], pos),
      leading: depth.isEmpty
          ? null
          : (r) => Padding(
              padding: EdgeInsets.only(left: depth[r] * 14.0, right: 4),
              child: depth[r] == 0
                  ? Tooltip(
                      message: 'Blocca ${blocked[r]} sessioni',
                      child: Icon(AppIcons.lock, size: 13, color: c.danger),
                    )
                  : Icon(AppIcons.subdirectory, size: 13, color: c.textTertiary),
            ),
    );
  }

  Future<void> _contextMenu(TableSpec t, TableState st, List<Object?> row, Offset pos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final qi = st.columns.indexWhere((c) => columnKind(c) == ColKind.query);
    final v = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(pos & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(value: 0, child: Text('Copia riga')),
        if (qi >= 0 && row[qi] != null) const PopupMenuItem(value: 1, child: Text('Copia query')),
        if (qi >= 0 && row[qi] != null) const PopupMenuItem(value: 2, child: Text('Apri query nell\'editor SQL')),
        if (t.actions?.cancel != null) const PopupMenuItem(value: 3, child: Text('Annulla query…')),
        if (t.actions != null) const PopupMenuItem(value: 4, child: Text('Termina sessione…')),
      ],
    );
    if (v == null || !mounted) return;
    final map = {for (var i = 0; i < st.columns.length; i++) st.columns[i]: row[i]};
    switch (v) {
      case 0:
        await Clipboard.setData(ClipboardData(text: row.map((e) => e?.toString() ?? '').join('\t')));
      case 1:
        await Clipboard.setData(ClipboardData(text: row[qi].toString()));
      case 2:
        AppScope.read(context).sqlEditorWith(widget.tab.dc, row[qi].toString());
      case 3:
        await _action(t, map, cancel: true);
      case 4:
        await _action(t, map, cancel: false);
    }
  }
}
