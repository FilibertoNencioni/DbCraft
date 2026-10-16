
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/ai/ai.dart';
import '../../services/storage.dart';
import '../../state/app_state.dart';
import '../security/security_settings.dart';
import '../widgets/common.dart';

export 'driver_manager_dialog.dart' show DriverManagerPage, canInstallDrivers, showDriverManagerDialog;

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

/// Preferences window (System Settings layout): a source list of pages on
/// the left, the page title over the content, grouped forms on
/// `windowBackground`. Settings apply at once; "Fine" (or Esc) closes.
Future<void> showSettingsDialog(BuildContext context) =>
    showSheet<void>(context, size: SheetSize.large, builder: (_) => const SettingsWindow());

class SettingsWindow extends StatefulWidget {
  const SettingsWindow({super.key});
  @override
  State<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<SettingsWindow> {
  late final AppState app = AppScope.read(context);
  late final AppSettings s = app.settings;
  late final _lib = TextEditingController(text: s.odbcLibPath);
  late final _fetch = TextEditingController(text: '${s.fetchSize}');
  late final _null = TextEditingController(text: s.nullText);
  late final _history = TextEditingController(text: '${s.maxHistory}');
  int _page = 0;

  static const _pages = [
    (AppIcons.palette, 'Aspetto'),
    (AppIcons.script, 'Editor SQL'),
    (AppIcons.rows, 'Risultati'),
    (AppIcons.insights, 'Analisi'),
    (AppIcons.lock, 'Sicurezza'),
    (AppIcons.ai, 'Assistente AI'),
    (AppIcons.plug, 'ODBC'),
  ];

  @override
  void dispose() {
    for (final c in [_lib, _fetch, _null, _history]) {
      c.dispose();
    }
    super.dispose();
  }

  /// macOS settings apply immediately.
  void _apply(VoidCallback change) {
    setState(change);
    app.saveSettings();
  }

  void _applyTexts() {
    s
      ..odbcLibPath = _lib.text.trim()
      ..fetchSize = (int.tryParse(_fetch.text) ?? s.fetchSize).clamp(10, 100000)
      ..nullText = _null.text
      ..maxHistory = (int.tryParse(_history.text) ?? s.maxHistory).clamp(10, 100000);
    app.saveSettings();
  }

  Widget _switch(String label, String? help, bool value, ValueChanged<bool> onChanged) => FormRow(
    label: label,
    help: help,
    child: DbSwitch(value: value, onChanged: (v) => _apply(() => onChanged(v))),
  );

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged) => FormRow(
    label: label,
    child: MacSlider(
      value: value,
      min: min,
      max: max,
      divisions: (max - min).round(),
      valueLabel: '${value.round()}',
      onChanged: (v) => _apply(() => onChanged(v)),
    ),
  );

  Widget _number(TextEditingController c, String hint) =>
      NumberField(controller: c, hint: hint, min: 10, max: 100000, step: 10, onChanged: (_) => _applyTexts());

  List<Widget> _content() {
    switch (_page) {
      case 0:
        return [
          FormGroup(
            title: 'Tema',
            children: [
              FormRow(
                label: 'Aspetto',
                child: Segmented<ThemeMode>(
                  value: s.themeMode,
                  items: const [
                    (ThemeMode.system, 'Automatico', null),
                    (ThemeMode.light, 'Chiaro', null),
                    (ThemeMode.dark, 'Scuro', null),
                  ],
                  onChanged: (v) => _apply(() => s.themeMode = v),
                ),
              ),
            ],
          ),
          FormGroup(
            title: 'Testo',
            children: [
              _slider('Editor SQL', s.editorFontSize, 10, 24, (v) => s.editorFontSize = v),
              _slider('Griglia risultati', s.gridFontSize, 10, 20, (v) => s.gridFontSize = v),
            ],
          ),
        ];
      case 1:
        return [
          FormGroup(
            children: [
              _switch(
                'Autocompletamento',
                'Parole chiave, tabelle e colonne mentre scrivi',
                s.autoComplete,
                (v) => s.autoComplete = v,
              ),
              _switch(
                'Riga vuota come separatore',
                'Esegui istruzione considera il blocco sotto il cursore',
                s.blankLineDelimiter,
                (v) => s.blankLineDelimiter = v,
              ),
              _switch(
                'Parole chiave in maiuscolo',
                'Usato da Formatta SQL',
                s.upperCaseKeywords,
                (v) => s.upperCaseKeywords = v,
              ),
            ],
          ),
          FormGroup(
            title: 'Sicurezza',
            children: [
              _switch(
                'Conferma istruzioni pericolose',
                'DROP, TRUNCATE, DELETE e UPDATE senza WHERE',
                s.confirmDangerous,
                (v) => s.confirmDangerous = v,
              ),
            ],
          ),
        ];
      case 2:
        return [
          FormGroup(
            children: [
              FormRow(label: 'Righe per pagina', help: 'Fetch size', child: _number(_fetch, '200')),
              FormRow(
                label: 'Testo per NULL',
                child: MacTextField(controller: _null, hint: '[NULL]', width: 160, onChanged: (_) => _applyTexts()),
              ),
              FormRow(label: 'Voci di cronologia', help: 'Massimo conservato', child: _number(_history, '1000')),
            ],
          ),
        ];
      case 3:
        return [
          FormGroup(
            title: 'Vista semplificata',
            footer:
                'Per chi consulta e analizza i dati: tabelle e viste in primo piano, filtri visuali, grafici ed '
                'esportazione; strumenti per sviluppatori nascosti.',
            children: [_switch('Vista semplificata per analisti', null, s.simpleMode, (v) => s.simpleMode = v)],
          ),
          FormGroup(
            title: 'Prestazioni',
            children: [
              FormRow(
                label: 'Aggiornamento dashboard',
                child: PopUpButton<int>(
                  value: const [2, 5, 10, 30, 60].contains(s.perfRefreshSec) ? s.perfRefreshSec : 5,
                  items: [for (final v in const [2, 5, 10, 30, 60]) (v, '$v secondi', null)],
                  onChanged: (v) => _apply(() => s.perfRefreshSec = v),
                ),
              ),
            ],
          ),
        ];
      case 4:
        return const [SecuritySettings()];
      case 5:
        return [aiSettingsSection(context)];
      default:
        return [
          FormGroup(
            title: 'Driver Manager',
            footer: 'Lascia vuoto per cercarlo automaticamente (unixODBC, iODBC o odbc32.dll).',
            children: [
              FormRow(
                label: 'Libreria',
                child: PathField(
                  controller: _lib,
                  hint: '/opt/homebrew/lib/libodbc.2.dylib',
                  onChanged: (_) => _applyTexts(),
                  onChoose: () async {
                    final f = await openFile();
                    if (f != null) {
                      _lib.text = f.path;
                      _applyTexts();
                    }
                  },
                ),
              ),
            ],
          ),
          FormGroup(
            title: 'Workspace',
            children: [SelectableText(app.workspace.root.path, style: monoStyle(context, size: TypeSize.mono))],
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 200,
          child: SourceList(
            autofocus: true,
            padding: const EdgeInsets.fromLTRB(10, Gap.lg, 10, Gap.sm),
            itemCount: _pages.length,
            selectedIndex: _page,
            onSelect: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => OutlineRow(
              icon: _pages[i].$1,
              title: _pages[i].$2,
              selected: _page == i,
              onTap: () => setState(() => _page = i),
            ),
          ),
        ),
        Container(width: 0.5, color: c.separator),
        Expanded(
          child: ColoredBox(
            color: c.windowBackground,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: BarHeight.bar,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                  alignment: Alignment.bottomLeft,
                  child: Text(_pages[_page].$2, style: uiText(TypeSize.title, weight: FontWeight.w700, color: c.text)),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.md, Gap.xl, Gap.sm),
                    children: _content(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.sm, Gap.xl, Gap.lg),
                  child: Row(
                    children: [
                      const Spacer(),
                      PushButton.primary(label: 'Fine', onPressed: () => Navigator.pop(context)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Query manager (history)
// ---------------------------------------------------------------------------

Future<void> showHistoryDialog(BuildContext context) =>
    showSheet<void>(context, size: SheetSize.xlarge, builder: (_) => const _HistoryDialog());

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog();
  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  final _search = TextEditingController();
  String _filter = '';
  bool _errorsOnly = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = DbColors.of(context);
    final matching = app.history
        .where(
          (h) =>
              _filter.isEmpty ||
              h.sql.toLowerCase().contains(_filter) ||
              h.connectionName.toLowerCase().contains(_filter),
        )
        .toList();
    final items = _errorsOnly ? matching.where((h) => !h.success).toList() : matching;
    return SheetScaffold(
      title: 'Query Manager',
      leading: [
        PushButton(
          label: 'Svuota cronologia…',
          onPressed: app.history.isEmpty
              ? null
              : () async {
                  if (await confirmDialog(
                    context,
                    'Svuota cronologia',
                    'Eliminare tutta la cronologia?',
                    ok: 'Svuota',
                    destructive: true,
                  )) {
                    await app.clearHistory();
                  }
                },
        ),
      ],
      actions: [PushButton.primary(label: 'Fine', onPressed: () => Navigator.pop(context))],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ScopeBar<bool>(
                multi: false,
                items: [
                  ScopeItem(false, 'Tutte', count: matching.length),
                  ScopeItem(true, 'Solo errori', count: matching.where((h) => !h.success).length),
                ],
                selected: {_errorsOnly},
                onChanged: (v) => setState(() => _errorsOnly = v.first),
              ),
              const Spacer(),
              SearchField(
                controller: _search,
                hint: 'Cerca nelle query…',
                width: 280,
                autofocus: true,
                onChanged: (v) => setState(() => _filter = v.toLowerCase()),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: c.content,
                borderRadius: BorderRadius.circular(Radii.panel),
                border: Border.all(color: c.separator, width: 0.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: items.isEmpty
                  ? EmptyState(
                      icon: AppIcons.history,
                      title: _filter.isEmpty && !_errorsOnly ? 'Nessuna query' : 'Nessuna query corrispondente',
                    )
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final h = items[i];
                        void open() {
                          final conn = app.byId(h.connectionId);
                          Navigator.pop(context);
                          if (conn != null) {
                            app.sqlEditorWith(conn, h.sql, reuse: true);
                          } else {
                            app.openSqlEditor(null, initialSql: h.sql);
                          }
                        }

                        return ListRow(
                          zebra: true,
                          index: i,
                          mono: true,
                          leading: Icon(
                            h.success ? AppIcons.checkCircle : AppIcons.error,
                            color: h.success ? c.success : c.danger,
                            size: 16,
                          ),
                          title: h.sql.replaceAll(RegExp(r'\s+'), ' '),
                          subtitle:
                              '${h.connectionName} · ${h.time.toString().substring(0, 19)} · ${h.durationMs} ms'
                              '${h.rows >= 0 ? ' · ${h.rows} righe' : ''}${h.error != null ? ' · ${h.error!.split('\n').first}' : ''}',
                          tooltip: h.sql,
                          onDoubleTap: open,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ToolButton(
                                icon: AppIcons.copy,
                                tooltip: 'Copia',
                                onPressed: () => Clipboard.setData(ClipboardData(text: h.sql)),
                              ),
                              ToolButton(icon: AppIcons.openExternal, tooltip: 'Apri in editor SQL', onPressed: open),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
