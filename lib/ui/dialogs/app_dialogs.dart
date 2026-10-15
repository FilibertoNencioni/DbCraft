
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

Future<void> showSettingsDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _SettingsDialog());

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();
  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final AppState app = AppScope.read(context);
  late final AppSettings s = app.settings;
  late final _lib = TextEditingController(text: s.odbcLibPath);
  late final _fetch = TextEditingController(text: '${s.fetchSize}');
  late final _null = TextEditingController(text: s.nullText);
  late final _history = TextEditingController(text: '${s.maxHistory}');
  int _page = 0;

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
    labelWidth: 320,
    child: Align(
      alignment: Alignment.centerRight,
      child: DbSwitch(value: value, onChanged: (v) => _apply(() => onChanged(v))),
    ),
  );

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged) => FormRow(
    label: label,
    child: Row(
      children: [
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: (max - min).round(),
            onChanged: (v) => _apply(() => onChanged(v)),
          ),
        ),
        SizedBox(
          width: 28,
          child: Text(
            '${value.round()}',
            textAlign: TextAlign.right,
            style: const TextStyle(fontFeatures: kTabular),
          ),
        ),
      ],
    ),
  );

  Widget _text(TextEditingController c, String hint, {double? width}) => SizedBox(
    width: width,
    child: TextField(
      controller: c,
      decoration: InputDecoration(hintText: hint),
      onChanged: (_) => _applyTexts(),
    ),
  );

  List<Widget> _content() {
    switch (_page) {
      case 0:
        return [
          FormGroup(
            title: 'Tema',
            children: [
              FormRow(
                label: 'Aspetto',
                child: Align(
                  alignment: Alignment.centerRight,
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
              FormRow(label: 'Righe per pagina', help: 'Fetch size', child: _text(_fetch, '200')),
              FormRow(label: 'Testo per NULL', child: _text(_null, '[NULL]')),
              FormRow(label: 'Voci di cronologia', help: 'Massimo conservato', child: _text(_history, '1000')),
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
                help: 'secondi',
                child: Align(
                  alignment: Alignment.centerRight,
                  child: DropdownButton<int>(
                    value: const [2, 5, 10, 30, 60].contains(s.perfRefreshSec) ? s.perfRefreshSec : 5,
                    isDense: true,
                    underline: const SizedBox(),
                    items: [
                      for (final v in const [2, 5, 10, 30, 60]) DropdownMenuItem(value: v, child: Text('$v s')),
                    ],
                    onChanged: (v) => _apply(() => s.perfRefreshSec = v ?? 5),
                  ),
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
                child: Row(
                  children: [
                    Expanded(child: _text(_lib, '/opt/homebrew/lib/libodbc.2.dylib')),
                    ToolButton(
                      icon: Icons.folder_open_outlined,
                      tooltip: 'Scegli la libreria',
                      onPressed: () async {
                        final f = await openFile();
                        if (f != null) {
                          _lib.text = f.path;
                          _applyTexts();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          FormGroup(
            title: 'Workspace',
            children: [SelectableText(app.workspace.root.path, style: monoStyle(context, size: 12))],
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    const pages = [
      (Icons.palette_outlined, 'Aspetto'),
      (Icons.edit_note_rounded, 'Editor SQL'),
      (Icons.table_rows_outlined, 'Risultati'),
      (Icons.insights_outlined, 'Analisi'),
      (Icons.lock_outline_rounded, 'Sicurezza'),
      (Icons.auto_awesome_outlined, 'Assistente AI'),
      (Icons.cable_rounded, 'ODBC'),
    ];
    return Dialog(
      insetPadding: const EdgeInsets.all(Gap.xl),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 780,
        height: 560,
        child: Row(
          children: [
            Container(
              width: 190,
              color: c.sidebar,
              padding: const EdgeInsets.all(Gap.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: Gap.sm),
                  for (final (i, (icon, label)) in pages.indexed)
                    GestureDetector(
                      onTap: () => setState(() => _page = i),
                      child: Container(
                        height: 30,
                        margin: const EdgeInsets.only(bottom: 2),
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                        decoration: BoxDecoration(
                          color: _page == i ? c.accent : Colors.transparent,
                          borderRadius: BorderRadius.circular(Radii.control),
                        ),
                        child: Row(
                          children: [
                            Icon(icon, size: 16, color: _page == i ? Colors.white : c.textSecondary),
                            const SizedBox(width: Gap.sm),
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: TypeSize.body,
                                color: _page == i ? Colors.white : c.text,
                                fontWeight: _page == i ? FontWeight.w500 : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            VerticalDivider(width: 1, color: c.separator),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.md, Gap.sm),
                    child: Row(
                      children: [
                        Expanded(child: Text(pages[_page].$2, style: Theme.of(context).textTheme.titleLarge)),
                        ToolButton(
                          icon: Icons.close_rounded,
                          tooltip: 'Chiudi',
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.sm, Gap.xl, Gap.xl),
                      children: _content(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Query manager (history)
// ---------------------------------------------------------------------------

Future<void> showHistoryDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _HistoryDialog());

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog();
  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  String _filter = '';
  bool _errorsOnly = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final items = app.history
        .where(
          (h) =>
              (!_errorsOnly || !h.success) &&
              (_filter.isEmpty ||
                  h.sql.toLowerCase().contains(_filter) ||
                  h.connectionName.toLowerCase().contains(_filter)),
        )
        .toList();
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 700),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Text('Query Manager', style: theme.textTheme.titleLarge),
                  const SizedBox(width: 24),
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Cerca nelle query…',
                      ),
                      onChanged: (v) => setState(() => _filter = v.toLowerCase()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilterChip(
                    label: const Text('Solo errori'),
                    selected: _errorsOnly,
                    onSelected: (v) => setState(() => _errorsOnly = v),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () async {
                      if (await confirmDialog(context, 'Svuota cronologia', 'Eliminare tutta la cronologia?')) {
                        await app.clearHistory();
                      }
                    },
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('Svuota'),
                  ),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('Nessuna query'))
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final h = items[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            h.success ? Icons.check_circle_outline : Icons.error_outline,
                            color: h.success ? Colors.green : theme.colorScheme.error,
                            size: 18,
                          ),
                          title: Text(
                            h.sql.replaceAll(RegExp(r'\s+'), ' '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(context, size: 12.5),
                          ),
                          subtitle: Text(
                            '${h.connectionName} · ${h.time.toString().substring(0, 19)} · ${h.durationMs} ms'
                            '${h.rows >= 0 ? ' · ${h.rows} righe' : ''}${h.error != null ? ' · ${h.error!.split('\n').first}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Copia',
                                icon: const Icon(Icons.copy, size: 16),
                                onPressed: () => Clipboard.setData(ClipboardData(text: h.sql)),
                              ),
                              IconButton(
                                tooltip: 'Apri in editor SQL',
                                icon: const Icon(Icons.open_in_new, size: 16),
                                onPressed: () {
                                  final c = app.byId(h.connectionId);
                                  Navigator.pop(context);
                                  if (c != null) {
                                    app.sqlEditorWith(c, h.sql, reuse: true);
                                  } else {
                                    app.openSqlEditor(null, initialSql: h.sql);
                                  }
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
