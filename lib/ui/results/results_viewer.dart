import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/charts/chart_view.dart';
import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../../state/result_set_model.dart';
import '../dialogs/export_dialog.dart';
import '../dialogs/value_dialog.dart';
import '../widgets/common.dart';
import 'result_grid.dart';

/// Presentation of a result set.
enum ResultsViewMode { grid, record, chart }

/// Grid + toolbar + status line for a result set.
class ResultsViewer extends StatefulWidget {
  const ResultsViewer({super.key, required this.model, this.onRefresh, this.filterBar, this.onFilterByValue});

  final ResultSetModel model;
  final VoidCallback? onRefresh;

  /// Optional server-side filter bar (table data editor).
  final Widget? filterBar;
  final CellFilterCallback? onFilterByValue;

  @override
  State<ResultsViewer> createState() => _ResultsViewerState();
}

class _ResultsViewerState extends State<ResultsViewer> {
  final _gridKey = GlobalKey<ResultGridState>();
  ResultsViewMode _mode = ResultsViewMode.grid;
  int _record = 0;
  final _quick = TextEditingController();
  bool _saving = false;

  ResultSetModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    m.addListener(_changed);
  }

  @override
  void didUpdateWidget(ResultsViewer old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_changed);
      widget.model.addListener(_changed);
      _record = 0;
      _quick.text = widget.model.quickFilter;
    }
  }

  @override
  void dispose() {
    m.removeListener(_changed);
    _quick.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    if (!m.isDirty || _saving) return;
    setState(() => _saving = true);
    try {
      final changes = m.buildChanges();
      final n = await m.saveChanges();
      if (mounted) {
        showToast(context, 'Salvate ${changes.length} modifiche ($n righe)');
      }
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Salvataggio non riuscito');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showChangesSql() {
    final sql = m
        .buildChanges()
        .map((e) {
          var s = e.$1;
          for (final p in e.$2) {
            s = s.replaceFirst('?', m.connection.dialect.literal(p));
          }
          return '$s;';
        })
        .join('\n');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Script delle modifiche'),
        content: SizedBox(
          width: 700,
          child: SingleChildScrollView(child: SelectableText(sql, style: monoStyle(ctx))),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: sql)),
            child: const Text('Copia'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Chiudi')),
        ],
      ),
    );
  }

  void _export() => showResultExportDialog(context, m);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = DbColors.of(context);
    final editable = m.isEditable;
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl+';
    // Simplified analyst view: filter, chart and export first; SQL-centric
    // actions are hidden.
    final simple = app.settings.simpleMode;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
      },
      child: Column(
        children: [
          ?widget.filterBar,
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            decoration: BoxDecoration(
              color: c.content,
              border: Border(bottom: BorderSide(color: c.separator)),
            ),
            child: Row(
              children: [
                Segmented<ResultsViewMode>(
                  value: _mode,
                  items: const [
                    (ResultsViewMode.grid, 'Griglia', AppIcons.grid),
                    (ResultsViewMode.record, 'Record', AppIcons.palettePanel),
                    (ResultsViewMode.chart, 'Grafico', AppIcons.chart),
                  ],
                  onChanged: (v) => setState(() {
                    final sel = _mode == ResultsViewMode.grid ? _gridKey.currentState?.selectedRows : null;
                    _mode = v;
                    if (v == ResultsViewMode.record && sel != null && sel.isNotEmpty) _record = sel.first;
                  }),
                ),
                const SizedBox(width: Gap.sm),
                SearchField(
                  controller: _quick,
                  hint: simple ? 'Filtra le righe' : 'Cerca nei risultati',
                  width: 200,
                  onChanged: m.setQuickFilter,
                ),
                const SizedBox(width: Gap.xs),
                if (editable && _mode != ResultsViewMode.chart) ...[
                  const ToolSeparator(),
                  ToolButton(
                    icon: AppIcons.add,
                    tooltip: 'Aggiungi riga (Ins)',
                    onPressed: () => _gridKey.currentState?.addRow(),
                  ),
                  ToolButton(
                    icon: AppIcons.duplicate,
                    tooltip: 'Duplica riga',
                    onPressed: () => _gridKey.currentState?.duplicateRow(),
                  ),
                  ToolButton(
                    icon: AppIcons.remove,
                    tooltip: 'Elimina righe selezionate (Canc)',
                    onPressed: () => _gridKey.currentState?.deleteSelectedRows(),
                  ),
                ],
                const Spacer(),
                if (m.isDirty) ...[
                  Badge2('${m.changeCount} ${m.changeCount == 1 ? 'modifica' : 'modifiche'}', color: c.warning),
                  const SizedBox(width: Gap.sm),
                  if (!simple) ...[
                    ToolButton(
                      icon: AppIcons.code,
                      tooltip: 'Mostra l\'SQL che verrà eseguito',
                      onPressed: _showChangesSql,
                    ),
                    const SizedBox(width: Gap.xs),
                  ],
                  OutlinedButton(onPressed: m.cancelChanges, child: const Text('Annulla')),
                  const SizedBox(width: Gap.sm),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Salvataggio…' : 'Salva (${mod}S)'),
                  ),
                  const ToolSeparator(),
                ],
                if (m.loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: Gap.sm),
                    child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  ),
                if (m.hasMore) ...[
                  ToolButton(
                    icon: AppIcons.chevronDown,
                    tooltip: 'Leggi altre ${app.settings.fetchSize} righe',
                    onPressed: m.loading ? null : () => m.fetchNext(),
                  ),
                  ToolButton(
                    icon: AppIcons.expandAll,
                    tooltip: 'Leggi tutte le righe',
                    onPressed: m.loading ? null : m.fetchAll,
                  ),
                ],
                if (widget.onRefresh != null)
                  ToolButton(icon: AppIcons.refresh, tooltip: 'Aggiorna', onPressed: widget.onRefresh),
                ToolButton(
                  icon: AppIcons.share,
                  tooltip: 'Esporta…',
                  label: simple ? 'Esporta' : null,
                  onPressed: _export,
                ),
              ],
            ),
          ),
          Expanded(
            child: m.columns.isEmpty
                ? const EmptyState(icon: AppIcons.rows, title: 'Il risultato non ha colonne')
                : switch (_mode) {
                    ResultsViewMode.record => _recordView(app),
                    ResultsViewMode.chart => ChartView(key: ObjectKey(m), model: m),
                    ResultsViewMode.grid => ResultGrid(
                      key: _gridKey,
                      model: m,
                      nullText: app.settings.nullText,
                      fontSize: app.settings.gridFontSize,
                      onFilterByValue: widget.onFilterByValue,
                      onExport: _export,
                      simpleMode: simple,
                    ),
                  },
          ),
          _statusBar(),
        ],
      ),
    );
  }

  Widget _statusBar() {
    final c = DbColors.of(context);
    final count = m.view.length;
    final total = m.rows.length;
    final (IconData icon, String editInfo) = m.connection.config.readOnly
        ? (AppIcons.lock, 'Sola lettura')
        : m.table == null
        ? (AppIcons.lock, 'Non modificabile')
        : m.keyIsVirtual
        ? (AppIcons.edit, 'Modificabile · nessuna chiave primaria')
        : (AppIcons.edit, 'Modificabile · chiave ${m.keyColumns.join(', ')}');
    final style = TextStyle(fontSize: TypeSize.caption + 0.5, color: c.textSecondary, fontFeatures: kTabular);
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      decoration: BoxDecoration(
        color: c.chrome,
        border: Border(top: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          Text(
            '${count == total ? '$total' : '$count di $total'} ${total == 1 ? 'riga' : 'righe'}'
            '${m.hasMore ? ' · altre disponibili' : ''}  ·  ${m.elapsedMs} ms',
            style: style,
          ),
          if (m.hasNextResultSet) ...[
            const SizedBox(width: Gap.md),
            Text('Altri result set disponibili', style: style),
          ],
          if (m.error != null) ...[
            const SizedBox(width: Gap.md),
            Flexible(
              child: Text(
                m.error!,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(color: c.danger),
              ),
            ),
          ],
          const Spacer(),
          Icon(icon, size: 12, color: c.textTertiary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(editInfo, overflow: TextOverflow.ellipsis, style: style),
          ),
        ],
      ),
    );
  }

  Widget _recordView(AppState app) {
    final c = DbColors.of(context);
    if (m.view.isEmpty) return const EmptyState(icon: AppIcons.empty, title: 'Nessuna riga');
    _record = _record.clamp(0, m.view.length - 1);
    final row = m.rowAt(_record);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
          child: Row(
            children: [
              ToolButton(
                icon: AppIcons.firstPage,
                tooltip: 'Prima riga',
                onPressed: () => setState(() => _record = 0),
              ),
              ToolButton(
                icon: AppIcons.chevronLeft,
                tooltip: 'Riga precedente',
                onPressed: _record > 0 ? () => setState(() => _record--) : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                child: Text(
                  'Riga ${_record + 1} di ${m.view.length}',
                  style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary, fontFeatures: kTabular),
                ),
              ),
              ToolButton(
                icon: AppIcons.chevronRight,
                tooltip: 'Riga successiva',
                onPressed: _record < m.view.length - 1 ? () => setState(() => _record++) : null,
              ),
              ToolButton(
                icon: AppIcons.lastPage,
                tooltip: 'Ultima riga',
                onPressed: () => setState(() => _record = m.view.length - 1),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
            itemCount: m.columns.length,
            itemBuilder: (context, i) {
              final col = m.columns[i];
              final v = row.values[i];
              return GestureDetector(
                onDoubleTap: () async {
                  final r = await showValueDialog(context, column: col, value: v, editable: m.isEditable);
                  if (r != null && r.changed) m.setValue(_record, i, r.value);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 7),
                  decoration: BoxDecoration(
                    color: row.changedCells.contains(i)
                        ? c.warning.withValues(alpha: 0.15)
                        : (i.isOdd ? c.zebra : Colors.transparent),
                    borderRadius: BorderRadius.circular(Radii.control),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 220,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: col.name,
                                style: TextStyle(fontWeight: FontWeight.w500, color: c.textSecondary),
                              ),
                              TextSpan(
                                text: '  ${col.displayType.toLowerCase()}',
                                style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          v == null ? app.settings.nullText : formatValue(v, maxLen: 4000),
                          style: TextStyle(
                            fontStyle: v == null ? FontStyle.italic : null,
                            color: v == null ? c.textTertiary : c.text,
                            fontFeatures: kTabular,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
