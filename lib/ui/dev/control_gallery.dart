import 'package:flutter/material.dart';

import '../widgets/common.dart';

/// Debug-only page that shows every design-system component in all its
/// states, light and dark side by side, to compare against native macOS
/// screenshots (Xcode, System Settings, Finder). Opened from Aiuto ▸ Galleria
/// controlli in debug builds.
Future<void> showControlGallery(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ControlGallery()));

class ControlGallery extends StatefulWidget {
  const ControlGallery({super.key});

  @override
  State<ControlGallery> createState() => _ControlGalleryState();
}

class _ControlGalleryState extends State<ControlGallery> {
  bool _inactive = false;
  bool _tracking = true;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    Widget column(Brightness b) => Expanded(
      child: Theme(
        data: buildTheme(b, accent: c.accent, active: !_inactive),
        child: Builder(
          builder: (context) => ColoredBox(
            color: DbColors.of(context).windowBackground,
            child: ListView(
              padding: const EdgeInsets.all(Gap.xl),
              children: [for (final s in _sections) _Section(s.$1, s.$2(context))],
            ),
          ),
        ),
      ),
    );
    return Scaffold(
      body: Column(
        children: [
          Container(
            height: BarHeight.toolbar,
            padding: EdgeInsets.only(left: trafficLightInset(false) + Gap.sm, right: Gap.md),
            decoration: BoxDecoration(
              color: c.chrome,
              border: Border(bottom: BorderSide(color: c.separator)),
            ),
            child: Row(
              children: [
                ToolButton(
                  icon: AppIcons.chevronLeft,
                  tooltip: 'Indietro',
                  extent: ControlSize.toolbar,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: Gap.sm),
                Text('Galleria controlli', style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text)),
                const Spacer(),
                Text('Finestra inattiva', style: uiText(TypeSize.body, color: c.text)),
                const SizedBox(width: Gap.sm),
                DbSwitch(value: _inactive, onChanged: (v) => setState(() => _inactive = v)),
                const SizedBox(width: Gap.lg),
                Text('Tracking SF', style: uiText(TypeSize.body, color: c.text)),
                const SizedBox(width: Gap.sm),
                DbSwitch(value: _tracking, onChanged: (v) => setState(() => _tracking = v)),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                column(Brightness.light),
                VerticalDivider(width: 1, color: c.separator),
                column(Brightness.dark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<(String, List<Widget> Function(BuildContext))> get _sections => [
    ('Colori', _colors),
    ('Tipografia', _type),
    ('Icone', _icons),
    ('Bottoni', _buttons),
    ('Campi', _fields),
    ('Selezione', _selection),
    ('Righe e liste', _rows),
    ('Badge e indicatori', _badges),
    ('Feedback', _feedback),
    ('Form', _forms),
  ];

  List<Widget> _colors(BuildContext context) {
    final c = DbColors.of(context);
    final swatches = <(String, Color)>[
      ('content', c.content),
      ('chrome', c.chrome),
      ('sidebar', c.sidebar),
      ('raised', c.raised),
      ('windowBackground', c.windowBackground),
      ('separator', c.separator),
      ('text', c.text),
      ('textSecondary', c.textSecondary),
      ('textTertiary', c.textTertiary),
      ('accent', c.accent),
      ('selection', c.selection),
      ('selectionMuted', c.selectionMuted),
      ('selectionEmphasized', c.selectionEmphasized),
      ('focusRing', c.focusRing),
      ('controlBackground', c.controlBackground),
      ('controlBorder', c.controlBorder),
      ('defaultButton', c.defaultButton),
      ('segmentSelected', c.segmentSelected),
      ('menuBackground', c.menuBackground),
      ('tooltipBackground', c.tooltipBackground),
      ('zebra', c.zebra),
      ('success', c.success),
      ('warning', c.warning),
      ('danger', c.danger),
      ('keyIcon', c.keyIcon),
      ('foreignKeyIcon', c.foreignKeyIcon),
      ('codeKeyword', c.codeKeyword),
      ('codeFunction', c.codeFunction),
      ('codeColumn', c.codeColumn),
      ('codeType', c.codeType),
    ];
    return [
      Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        children: [
          for (final (name, color) in swatches)
            SizedBox(
              width: 120,
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(Radii.small),
                      border: Border.all(color: c.separator, width: 0.5),
                    ),
                  ),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: uiText(TypeSize.mini, color: c.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ];
  }

  List<Widget> _type(BuildContext context) {
    final c = DbColors.of(context);
    TextStyle s(double size, [FontWeight? w]) {
      final st = uiText(size, weight: w, color: c.text);
      return _tracking ? st : st.copyWith(letterSpacing: 0);
    }

    return [
      for (final (label, size, weight) in const [
        ('Display 26 bold', TypeSize.display, FontWeight.w700),
        ('Sheet title 17 semibold', TypeSize.sheetTitle, FontWeight.w600),
        ('Title 15 semibold', TypeSize.title, FontWeight.w600),
        ('Body 13 — Filtra tabelle e procedure', TypeSize.body, FontWeight.w400),
        ('Body 13 semibold — Demo SQLite', TypeSize.body, FontWeight.w600),
        ('Small 12 — 200 righe · altre disponibili', TypeSize.small, FontWeight.w400),
        ('Caption 11 — Connessioni', TypeSize.caption, FontWeight.w600),
        ('Mini 10 — varchar(10)', TypeSize.mini, FontWeight.w400),
      ])
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(label, style: s(size, weight))),
      const SizedBox(height: Gap.sm),
      Text('SELECT * FROM dipendenti WHERE id = 42;', style: monoStyle(context, size: TypeSize.mono)),
      Text('1837.5   2015-01-12   [NULL]', style: monoStyle(context, size: TypeSize.monoSmall)),
    ];
  }

  List<Widget> _icons(BuildContext context) {
    final c = DbColors.of(context);
    return [
      Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final e in AppIcons.all.entries)
            Tooltip(
              message: e.key,
              waitDuration: const Duration(milliseconds: 300),
              child: SizedBox(width: 26, height: 26, child: Icon(e.value, size: 16, color: c.textSecondary)),
            ),
        ],
      ),
    ];
  }

  List<Widget> _buttons(BuildContext context) => [
    _Row([
      PrimaryButton(label: 'Esegui', icon: AppIcons.run, onPressed: () {}),
      FilledButton(onPressed: () {}, child: const Text('Crea')),
      OutlinedButton(onPressed: () {}, child: const Text('Annulla')),
      TextButton(onPressed: () {}, child: const Text('Dettagli…')),
      const FilledButton(onPressed: null, child: Text('Disabilitato')),
    ]),
    _Row([
      ToolButton(icon: AppIcons.sidebar, tooltip: 'Barra laterale', extent: ControlSize.toolbar, onPressed: () {}),
      ToolButton(icon: AppIcons.refresh, tooltip: 'Aggiorna', onPressed: () {}),
      ToolButton(icon: AppIcons.filter, tooltip: 'Filtro attivo', active: true, onPressed: () {}),
      ToolButton(icon: AppIcons.save, tooltip: 'Commit', label: 'Commit (2)', onPressed: () {}),
      const ToolSeparator(),
      const ToolButton(icon: AppIcons.delete, tooltip: 'Disabilitato'),
    ]),
  ];

  List<Widget> _fields(BuildContext context) => [
    _Row([
      const SizedBox(width: 200, child: TextField(decoration: InputDecoration(hintText: 'Nome del database'))),
      SizedBox(width: 160, child: TextField(controller: TextEditingController(text: 'localhost'))),
    ]),
    _Row([
      SearchField(controller: TextEditingController(), hint: 'Filtra tabelle', width: 200),
      SizedBox(
        width: 200,
        child: SelectField<int>(
          value: 1,
          items: const [(1, 'Utente e password', null), (2, 'Integrata', null)],
          onChanged: (_) {},
        ),
      ),
    ]),
  ];

  List<Widget> _selection(BuildContext context) => [
    _Row([
      Segmented<int>(value: 0, items: const [(0, 'Auto', null), (1, 'Manuale', null)], onChanged: (_) {}),
      Segmented<int>(
        value: 1,
        items: const [(0, 'Griglia', AppIcons.grid), (1, 'Record', AppIcons.rows)],
        onChanged: (_) {},
      ),
    ]),
    _Row([
      Checkbox(value: true, onChanged: (_) {}),
      Checkbox(value: false, onChanged: (_) {}),
      Checkbox(value: null, tristate: true, onChanged: (_) {}),
      DbSwitch(value: true, onChanged: (_) {}),
      DbSwitch(value: false, onChanged: (_) {}),
      SizedBox(width: 160, child: Slider(value: 0.4, onChanged: (_) {})),
    ]),
  ];

  List<Widget> _rows(BuildContext context) => [
    SizedBox(
      width: 280,
      child: Column(
        children: [
          SidebarRow(icon: AppIcons.table, title: 'dipendenti', detail: '200', onTap: () {}),
          SidebarRow(icon: AppIcons.table, title: 'reparti (selezionata)', selected: true, onTap: () {}),
          SidebarRow(icon: AppIcons.view, title: 'v_dipendenti_reparto', onTap: () {}, onMenu: (_) {}),
        ],
      ),
    ),
  ];

  List<Widget> _badges(BuildContext context) {
    final c = DbColors.of(context);
    return [
      _Row([
        const Badge2('12'),
        Badge2('Produzione', color: c.danger),
        Badge2('3 modifiche', color: c.warning),
        Badge2('nuova', color: c.success, filled: true),
        StatusDot(c.success),
        StatusDot(c.textTertiary, ring: true),
        EnvDot(c.warning, show: true),
      ]),
      _Row(const [
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 160, child: LinearProgressIndicator(value: 0.6)),
        SizedBox(width: 160, child: LinearProgressIndicator()),
      ]),
    ];
  }

  List<Widget> _feedback(BuildContext context) {
    final c = DbColors.of(context);
    return [
      InlineNotice(
        color: c.warning,
        title: 'OpenSSL non trovato',
        message: 'Il driver richiede libssl 3. Installalo con Homebrew.',
        action: OutlinedButton(onPressed: () {}, child: const Text('Copia comando')),
      ),
      const SizedBox(
        height: 160,
        child: EmptyState(
          icon: AppIcons.runCircle,
          title: 'Nessun risultato',
          message: 'Premi Esegui o ⌘Invio per eseguire l\'istruzione sotto il cursore.',
        ),
      ),
    ];
  }

  List<Widget> _forms(BuildContext context) => [
    FormGroup(
      title: 'Connessione',
      footer: 'La porta predefinita di SQL Server è 1433.',
      children: [
        const FormRow(label: 'Host', child: TextField(decoration: InputDecoration(hintText: 'localhost'))),
        FormRow(
          label: 'Ambiente',
          child: Align(
            alignment: Alignment.centerLeft,
            child: Segmented<int>(
              value: 0,
              items: const [(0, 'Sviluppo', null), (1, 'Test', null), (2, 'Produzione', null)],
              onChanged: (_) {},
            ),
          ),
        ),
        FormRow(
          label: 'Salva password',
          help: 'Cifrata nel vault del workspace',
          child: Align(alignment: Alignment.centerRight, child: DbSwitch(value: true, onChanged: (_) {})),
        ),
      ],
    ),
  ];
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(title, padding: const EdgeInsets.only(bottom: Gap.sm)),
        ...children,
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.children);
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.md),
    child: Wrap(spacing: Gap.md, runSpacing: Gap.sm, crossAxisAlignment: WrapCrossAlignment.center, children: children),
  );
}
