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
    showSheet<void>(
      context,
      size: SheetSize.large,
      builder: (ctx) => SheetScaffold(
        title: 'Script delle modifiche',
        body: SingleChildScrollView(child: CodeBox(sql, label: 'SQL')),
        actions: [PushButton.primary(label: 'Chiudi', onPressed: () => Navigator.pop(ctx))],
        onSubmit: () => Navigator.pop(ctx),
      ),
    );
  }

  void _export() => showResultExportDialog(context, m);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final editable = m.isEditable;
    final save = shortcutLabel(SingleActivator(LogicalKeyboardKey.keyS, meta: Platform.isMacOS, control: !Platform.isMacOS));
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
          PaneBar(
            loading: m.loading,
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
                    tooltip: 'Aggiungi riga (${shortcutLabel(const SingleActivator(LogicalKeyboardKey.insert))})',
                    onPressed: () => _gridKey.currentState?.addRow(),
                  ),
                  ToolButton(
                    icon: AppIcons.duplicate,
                    tooltip: 'Duplica riga',
                    onPressed: () => _gridKey.currentState?.duplicateRow(),
                  ),
                  ToolButton(
                    icon: AppIcons.remove,
                    tooltip: 'Elimina righe selezionate (${shortcutLabel(const SingleActivator(LogicalKeyboardKey.delete))})',
                    onPressed: () => _gridKey.currentState?.deleteSelectedRows(),
                  ),
                ],
                const Spacer(),
                if (m.isDirty) ...[
                  CountBadge('${m.changeCount} ${m.changeCount == 1 ? 'modifica' : 'modifiche'}'),
                  const SizedBox(width: Gap.sm),
                  if (!simple) ...[
                    ToolButton(
                      icon: AppIcons.code,
                      tooltip: 'Mostra l\'SQL che verrà eseguito',
                      onPressed: _showChangesSql,
                    ),
                    const SizedBox(width: Gap.xs),
                  ],
                  PushButton(label: 'Annulla', size: ControlScale.small, onPressed: m.cancelChanges),
                  const SizedBox(width: Gap.xs),
                  PushButton.primary(
                    label: _saving ? 'Salvataggio…' : 'Salva',
                    size: ControlScale.small,
                    tooltip: 'Salva le modifiche ($save)',
                    onPressed: _saving ? null : _save,
                  ),
                  const ToolSeparator(),
                ],
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
    const style = TextStyle(fontFeatures: kTabular);
    return StatusBar(
      children: [
        Text(
          '${count == total ? '$total' : '$count di $total'} ${total == 1 ? 'riga' : 'righe'}'
          '${m.hasMore ? ' · altre disponibili' : ''}  ·  ${m.elapsedMs} ms',
          style: style,
        ),
        if (m.hasNextResultSet) ...[
          const SizedBox(width: Gap.md),
          const Text('Altri result set disponibili'),
        ],
        if (m.error != null) ...[
          const SizedBox(width: Gap.md),
          Flexible(child: Text(m.error!, style: TextStyle(color: c.danger))),
        ],
        const Spacer(),
        Icon(icon, size: 12, color: c.textTertiary),
        const SizedBox(width: 4),
        Flexible(child: Text(editInfo)),
      ],
    );
  }

  Future<void> _openValue(int col) async {
    final row = _record;
    final r = await showValueDialog(
      context,
      column: m.columns[col],
      value: m.rowAt(row).values[col],
      editable: m.isEditable,
    );
    if (r != null && r.changed) m.setValue(row, col, r.value);
  }

  Widget _recordView(AppState app) {
    if (m.view.isEmpty) return const EmptyState(icon: AppIcons.empty, title: 'Nessuna riga');
    _record = _record.clamp(0, m.view.length - 1);
    final row = m.rowAt(_record);
    return Column(
      children: [
        PaneHeader(
          title: 'Riga ${_record + 1} di ${m.view.length}',
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ToolButton(
                icon: AppIcons.firstPage,
                tooltip: 'Prima riga',
                extent: ControlSize.small,
                onPressed: () => setState(() => _record = 0),
              ),
              ToolButton(
                icon: AppIcons.chevronLeft,
                tooltip: 'Riga precedente',
                extent: ControlSize.small,
                onPressed: _record > 0 ? () => setState(() => _record--) : null,
              ),
              ToolButton(
                icon: AppIcons.chevronRight,
                tooltip: 'Riga successiva',
                extent: ControlSize.small,
                onPressed: _record < m.view.length - 1 ? () => setState(() => _record++) : null,
              ),
              ToolButton(
                icon: AppIcons.lastPage,
                tooltip: 'Ultima riga',
                extent: ControlSize.small,
                onPressed: () => setState(() => _record = m.view.length - 1),
              ),
            ],
          ),
          actions: [
            PulldownButton(
              label: m.isEditable ? 'Modifica valore' : 'Apri valore',
              tooltip: 'Apri un campo nell\'editor dei valori',
              entries: () => [
                for (var i = 0; i < m.columns.length; i++) MenuEntry(m.columns[i].name, onSelected: () => _openValue(i)),
              ],
            ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.lg),
            child: RecordView(
              nullText: app.settings.nullText,
              // The pull-down in the header stays as the keyboard path.
              onFieldDoubleTap: _openValue,
              fields: [
                for (var i = 0; i < m.columns.length; i++)
                  RecordField(
                    m.columns[i].name,
                    row.values[i] == null ? null : formatValue(row.values[i], maxLen: 4000),
                    type: m.columns[i].displayType,
                    changed: row.changedCells.contains(i),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
