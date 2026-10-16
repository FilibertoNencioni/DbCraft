import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    ('Menu, popover, tooltip', _menus),
    ('Righe e liste', _rows),
    ('Badge e indicatori', _badges),
    ('Feedback', _feedback),
    ('Sheet e alert', _sheets),
    ('Codice e diff', _code),
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
      PushButton(label: 'Annulla', onPressed: () {}),
      PushButton.primary(label: 'Connetti', onPressed: () {}),
      PushButton(label: 'Elimina', kind: PushButtonKind.destructive, onPressed: () {}),
      PushButton(label: 'Elimina', kind: PushButtonKind.destructive, filled: true, onPressed: () {}),
      const PushButton(label: 'Disabilitato', onPressed: null),
    ]),
    _Row([
      PushButton.primary(label: 'Esegui', icon: AppIcons.run, size: ControlScale.small, onPressed: () {}),
      PushButton(label: 'Commit (2)', size: ControlScale.small, onPressed: () {}),
      PushButton(label: 'Prova connessione', icon: AppIcons.plug, onPressed: () {}),
      PrimaryButton(label: 'Interrompi', icon: AppIcons.stop, color: DbColors.of(context).danger, onPressed: () {}),
    ]),
    _Row([
      ToolButton(icon: AppIcons.sidebar, tooltip: 'Barra laterale', extent: ControlSize.toolbar, onPressed: () {}),
      ToolButton(icon: AppIcons.refresh, tooltip: 'Aggiorna', onPressed: () {}),
      ToolButton(icon: AppIcons.filter, tooltip: 'Filtro attivo', active: true, onPressed: () {}),
      ToolButton(icon: AppIcons.save, tooltip: 'Commit', label: 'Commit (2)', onPressed: () {}),
      ToolButton(icon: AppIcons.more, tooltip: 'Mini', extent: 18, onPressed: () {}),
      const ToolSeparator(),
      const ToolButton(icon: AppIcons.delete, tooltip: 'Disabilitato'),
    ]),
    _Row([
      PulldownButton(icon: AppIcons.more, tooltip: 'Altre azioni', entries: _menuEntries),
      PulldownButton(icon: AppIcons.ai, label: 'AI', entries: _menuEntries),
      PulldownButton(label: 'Esporta', bordered: true, extent: ControlSize.toolbar, entries: _menuEntries),
      LinkButton(label: 'Dettagli…', onPressed: () {}),
      LinkButton(label: 'Carica altri', small: true, onPressed: () {}),
    ]),
    _Row([
      _Demo<bool>(
        false,
        (v, set) => DisclosureButton(label: 'Avanzate', expanded: v, onChanged: set, trailing: Text('3', style: uiText(TypeSize.small, color: DbColors.of(context).textTertiary))),
      ),
    ]),
  ];

  List<MenuEntry<Object?>> _menuEntries() => const [
    MenuEntry('Copia', shortcut: SingleActivator(LogicalKeyboardKey.keyC, meta: true)),
    MenuEntry('Copia come INSERT', shortcut: SingleActivator(LogicalKeyboardKey.keyC, meta: true, shift: true)),
    MenuEntry('Disabilitato', enabled: false),
    MenuEntry.divider(),
    MenuEntry.header('Vista'),
    MenuEntry('Griglia', checked: true),
    MenuEntry('Record'),
    MenuEntry.submenu('Esporta', children: [MenuEntry('CSV'), MenuEntry('JSON'), MenuEntry('Excel')]),
    MenuEntry.divider(),
    MenuEntry('Elimina riga', destructive: true, shortcut: SingleActivator(LogicalKeyboardKey.backspace, meta: true)),
  ];

  List<Widget> _fields(BuildContext context) => [
    _Row([
      const MacTextField(hint: 'Nome del database', width: 200),
      MacTextField(controller: TextEditingController(text: 'localhost'), width: 160),
      const MacTextField(hint: 'Disabilitato', enabled: false, width: 140),
      const MacTextField(hint: 'Piccolo', small: true, width: 120),
    ]),
    _Row([
      const MacTextField(hint: 'id > 10', token: 'WHERE', mono: true, width: 240),
      const MacTextField(hint: '30', unit: 'secondi', width: 140, textAlign: TextAlign.right, tabular: true),
      const MacTextField(hint: 'Porta', error: 'Valore non valido', width: 160),
    ]),
    _Row([
      const SecureField(hint: 'Password', width: 200),
      SearchField(controller: TextEditingController(), hint: 'Filtra tabelle', width: 200),
      SearchField(controller: TextEditingController(text: 'dip'), hint: 'Cerca', width: 200, toolbar: true),
    ]),
    _Row([
      SizedBox(
        width: 200,
        child: ComboField(controller: TextEditingController(text: 'utf8mb4'), options: () => const ['utf8mb4', 'latin1', 'ascii']),
      ),
      NumberField(controller: TextEditingController(text: '5432'), min: 1, max: 65535, width: 80),
      NumberField(controller: TextEditingController(text: '30'), min: 0, unit: 'secondi', width: 110),
      _Demo<DateTime?>(DateTime(2026, 10, 16), (v, set) => DateField(value: v, onChanged: set)),
    ]),
    SizedBox(
      width: 420,
      child: PathField(path: '/Users/demo/Library/Application Support/DbCraft/demo.sqlite', onChoose: () {}),
    ),
    const SizedBox(height: Gap.md),
    _Demo<List<String>>(
      const ['stato = attivo', 'reparto IN (3, 4)'],
      (v, set) => TokenField(
        joiner: 'e',
        tokens: [for (final t in v) FilterToken(label: t, mono: true, onTap: () {}, onRemove: () => set([...v]..remove(t)))],
        trailing: ToolButton(icon: AppIcons.add, tooltip: 'Aggiungi filtro', extent: ControlSize.small, onPressed: () => set([...v, 'nuovo = 1'])),
      ),
    ),
  ];

  List<Widget> _selection(BuildContext context) => [
    _Row([
      _Demo<int>(0, (v, set) => Segmented<int>(value: v, items: const [(0, 'Auto', null), (1, 'Manuale', null)], onChanged: set)),
      _Demo<int>(
        1,
        (v, set) => Segmented<int>(
          value: v,
          items: const [(0, 'Griglia', AppIcons.grid), (1, 'Record', AppIcons.rows), (2, 'JSON', AppIcons.json)],
          onChanged: set,
        ),
      ),
      _Demo<int>(
        0,
        (v, set) => Segmented<int>(
          value: v,
          small: true,
          iconOnly: true,
          items: const [(0, 'Griglia', AppIcons.grid), (1, 'Record', AppIcons.rows)],
          onChanged: set,
        ),
      ),
    ]),
    _Row([
      _Demo<bool?>(true, (v, set) => MacCheckbox(value: v, onChanged: set)),
      _Demo<bool?>(false, (v, set) => MacCheckbox(value: v, onChanged: set)),
      _Demo<bool?>(null, (v, set) => MacCheckbox(value: v, onChanged: set)),
      const MacCheckbox(value: true, onChanged: null),
      _Demo<bool>(true, (v, set) => CheckboxRow(label: 'Mostra viste', value: v, onChanged: set)),
      _Demo<bool>(false, (v, set) => CheckboxRow(label: 'Auto-refresh', small: true, value: v, onChanged: set)),
    ]),
    _Row([
      _Demo<int>(
        0,
        (v, set) => MacRadioGroup<int>(
          value: v,
          onChanged: set,
          items: const [(0, 'CSV', null), (1, 'JSON', 'Un oggetto per riga'), (2, 'SQL INSERT', null)],
        ),
      ),
      _Demo<bool>(true, (v, set) => DbSwitch(value: v, onChanged: set)),
      _Demo<bool>(false, (v, set) => DbSwitch(value: v, onChanged: set)),
      _Demo<bool>(true, (v, set) => DbSwitch(value: v, small: true, onChanged: set)),
      _Demo<double>(0.4, (v, set) => MacSlider(value: v, onChanged: set, valueLabel: '${(v * 100).round()}%')),
    ]),
    _Row([
      _Demo<int>(
        1,
        (v, set) => SizedBox(
          width: 200,
          child: SelectField<int>(
            value: v,
            items: const [(1, 'Utente e password', null), (2, 'Integrata', null), (3, 'Token', null)],
            onChanged: set,
          ),
        ),
      ),
      _Demo<String>(
        'pg',
        (v, set) => PopUpButton<String>(
          value: v,
          items: [
            ('pg', 'demo_pg', (AppIcons.database, DbColors.of(context).accent)),
            ('lite', 'demo.sqlite', (AppIcons.database, DbColors.of(context).success)),
          ],
          onChanged: set,
        ),
      ),
      _Demo<String>(
        'public',
        (v, set) => PopUpButton<String>(
          value: v,
          style: PopUpStyle.inline,
          items: const [('public', 'public', null), ('hr', 'hr', null)],
          onChanged: set,
        ),
      ),
      _Demo<String>(
        'main',
        (v, set) => PopUpButton<String>(
          value: v,
          style: PopUpStyle.toolbar,
          items: const [('main', 'main', null), ('temp', 'temp', null)],
          onChanged: set,
        ),
      ),
      const PopUpButton<int>(value: 0, items: [(0, 'Disabilitato', null)], onChanged: null),
    ]),
    _Demo<Set<String>>(
      const {'added', 'changed'},
      (v, set) => ScopeBar<String>(
        selected: v,
        onChanged: set,
        items: [
          ScopeItem('added', 'Nuove', dot: DbColors.of(context).success, count: 12),
          ScopeItem('changed', 'Modificate', dot: DbColors.of(context).warning, count: 3),
          ScopeItem('removed', 'Eliminate', dot: DbColors.of(context).danger, count: 0),
        ],
      ),
    ),
  ];

  List<Widget> _menus(BuildContext context) {
    final c = DbColors.of(context);
    return [
      _Row([
        Builder(
          builder: (b) => PushButton(
            label: 'Menu contestuale',
            onPressed: () => showMacMenu<Object?>(b, position: anchorRect(b).bottomLeft, entries: _menuEntries()),
          ),
        ),
        Builder(
          builder: (b) => PushButton(
            label: 'Connessioni',
            onPressed: () => showMacMenu<int>(
              b,
              anchor: anchorRect(b),
              entries: [
                MenuEntry.connection(name: 'demo_pg', status: c.success, checked: true, value: 1),
                MenuEntry.connection(name: 'erp_prod', status: c.success, environment: 'Produzione', environmentColor: c.danger, value: 2),
                MenuEntry.connection(name: 'erp_test', status: c.textTertiary, environment: 'Test', environmentColor: c.warning, value: 3),
              ],
            ),
          ),
        ),
        Builder(
          builder: (b) => PushButton(
            label: 'Popover',
            onPressed: () => showPopover<void>(
              b,
              anchor: anchorRect(b),
              builder: (_) => SizedBox(
                width: 220,
                child: Text(
                  'Le modifiche non salvate verranno applicate alla prossima esecuzione.',
                  style: uiText(TypeSize.small, color: c.text),
                ),
              ),
            ),
          ),
        ),
        RichTooltip(
          title: 'stipendio',
          rows: const [('Tipo', 'numeric(10,2)'), ('Null', 'no'), ('Default', '0')],
          child: Text('Tooltip ricco (hover)', style: uiText(TypeSize.body, color: c.accent)),
        ),
      ]),
      _Row([
        MacMenuPreview(entries: _menuEntries(), highlight: 1),
        _Demo<int>(
          1,
          (v, set) => CompletionList(
            width: 300,
            selected: v,
            onSelect: set,
            items: const [
              CompletionItem('SELECT', CompletionKind.keyword),
              CompletionItem('dipendenti', CompletionKind.table, detail: 'public'),
              CompletionItem('v_dipendenti_reparto', CompletionKind.view, detail: 'public'),
              CompletionItem('stipendio', CompletionKind.column, detail: 'numeric'),
              CompletionItem('coalesce', CompletionKind.function),
              CompletionItem('varchar', CompletionKind.type),
            ],
          ),
        ),
      ]),
    ];
  }

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
      Notice(
        title: 'OpenSSL non trovato',
        message: 'Il driver richiede libssl 3. Installalo con Homebrew.',
        actions: [PushButton(label: 'Copia comando', size: ControlScale.small, onPressed: () {})],
        child: const CodeBox('brew install openssl@3'),
      ),
      const SizedBox(height: Gap.md),
      Notice(
        kind: NoticeKind.danger,
        message: 'ORA-00942: tabella o vista inesistente',
        actions: [LinkButton(label: 'Riprova', small: true, onPressed: () {})],
      ),
      const SizedBox(height: Gap.md),
      Notice.card(
        title: 'Scansione completa su ordini',
        message: 'Un indice su (cliente_id, data) eviterebbe di leggere 1,2 milioni di righe.',
        actions: [
          PushButton(label: 'Crea indice', size: ControlScale.small, onPressed: () {}),
          LinkButton(label: 'Dettagli…', small: true, onPressed: () {}),
        ],
      ),
      const SizedBox(height: Gap.md),
      Notice.strip(
        title: 'Conflitti di merge',
        message: '2 file da risolvere prima del commit',
        actions: [LinkButton(label: 'Annulla merge', small: true, onPressed: () {})],
      ),
      const SizedBox(height: Gap.md),
      _Row([
        HudCapsule(message: 'Copiato negli appunti', icon: AppIcons.checkCircle, iconColor: c.success),
        HudCapsule(message: 'Salvataggio non riuscito', icon: AppIcons.error, iconColor: c.danger),
        PushButton(label: 'Mostra HUD', onPressed: () => showToast(context, 'Copiato negli appunti')),
      ]),
      Row(
        children: [
          const Expanded(
            child: SizedBox(
              height: 180,
              child: EmptyState(
                icon: AppIcons.runCircle,
                title: 'Nessun risultato',
                message: 'Premi Esegui o ⌘Invio per eseguire l\'istruzione sotto il cursore.',
              ),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 180,
              child: EmptyState.error(
                'Connessione rifiutata dal server\n[unixODBC][FreeTDS][SQL Server]Unable to connect to data source',
                action: PushButton(label: 'Riprova', onPressed: () {}),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _sheets(BuildContext context) {
    Widget preview(double width, Widget child) => ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: SheetSurface(width: width, child: child),
    );
    final sheetForm = FormGroup(
      children: [
        const FormRow(label: 'Nome', child: MacTextField(hint: 'Produzione')),
        FormRow(label: 'Sola lettura', child: DbSwitch(value: true, onChanged: (_) {})),
      ],
    );
    return [
      _Row([
        PushButton(
          label: 'Sheet M',
          onPressed: () => showSheet<void>(
            context,
            builder: (ctx) => SheetScaffold(
              title: 'Nuova connessione',
              body: sheetForm,
              leading: [PushButton(label: 'Prova connessione', onPressed: () {})],
              onSubmit: () => Navigator.pop(ctx),
              actions: [
                PushButton(label: 'Annulla', onPressed: () => Navigator.pop(ctx)),
                PushButton.primary(label: 'Salva', onPressed: () => Navigator.pop(ctx)),
              ],
            ),
          ),
        ),
        PushButton(
          label: 'Sheet L',
          onPressed: () => showSheet<void>(
            context,
            size: SheetSize.large,
            builder: (ctx) => SheetScaffold(
              title: 'Diff di ordini.sql',
              subtitle: 'main ↔ working copy',
              body: DiffView.unified(_samplePatch),
              actions: [PushButton.primary(label: 'Fine', onPressed: () => Navigator.pop(ctx))],
              onSubmit: () => Navigator.pop(ctx),
            ),
          ),
        ),
        PushButton(
          label: 'Conferma',
          onPressed: () => confirmDialog(context, 'Eseguire lo script?', 'Verranno eseguite 12 istruzioni.'),
        ),
        PushButton(
          label: 'Distruttivo',
          onPressed: () => confirmDialog(
            context,
            'Eliminare la tabella «ordini»?',
            'L\'operazione non si può annullare.',
            ok: 'Elimina',
            destructive: true,
          ),
        ),
        PushButton(
          label: 'Errore',
          onPressed: () => showErrorDialog(
            context,
            'Connessione rifiutata dal server\n[unixODBC][FreeTDS][SQL Server]Unable to connect to data source '
            '(SQLSTATE 08001, codice 20009)',
          ),
        ),
        PushButton(label: 'Prompt', onPressed: () => promptText(context, 'Rinomina script', initial: 'query.sql')),
        PushButton(
          label: '3 bottoni',
          onPressed: () => showAlert<int>(
            context,
            title: 'Transazione aperta',
            message: 'Ci sono 3 modifiche non confermate su Produzione.',
            style: AlertStyle.warning,
            buttons: const [
              AlertButton('Commit e chiudi', 0, role: AlertRole.defaultAction),
              AlertButton('Rollback e chiudi', 1, role: AlertRole.destructive),
              AlertButton('Annulla', 2, role: AlertRole.cancel),
            ],
          ),
        ),
        PushButton(
          label: 'Scegli tabella…',
          onPressed: () => showListPicker<String>(
            context,
            title: 'Scegli una tabella',
            items: const ['clienti', 'dipendenti', 'fatture', 'ordini', 'prodotti', 'reparti'],
            label: (s) => s,
            icon: (_) => AppIcons.table,
            detail: (s) => '${s.length * 37}',
          ),
        ),
        PushButton(
          label: 'Informazioni',
          onPressed: () => showAboutPanel(
            context,
            name: 'DbCraft',
            version: '1.0.0',
            description: 'Client database universale.',
            copyright: '© 2026 DbCraft',
          ),
        ),
      ]),
      Wrap(
        spacing: Gap.xl,
        runSpacing: Gap.xl,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          preview(
            SheetSize.small.width,
            SheetScaffold(
              title: 'Nuova connessione',
              body: sheetForm,
              actions: [
                PushButton(label: 'Annulla', onPressed: () {}),
                PushButton.primary(label: 'Salva', onPressed: () {}),
              ],
            ),
          ),
          preview(
            260,
            AlertPanel<bool>(
              title: 'Eliminare la tabella «ordini»?',
              message: 'L\'operazione non si può annullare.',
              style: AlertStyle.critical,
              onSelected: (_) {},
              buttons: const [
                AlertButton('Elimina', true, role: AlertRole.destructive),
                AlertButton('Annulla', false, role: AlertRole.cancel),
              ],
            ),
          ),
          preview(
            260,
            AlertPanel<int>(
              title: 'Transazione aperta',
              message: 'Ci sono 3 modifiche non confermate.',
              style: AlertStyle.warning,
              onSelected: (_) {},
              buttons: const [
                AlertButton('Commit e chiudi', 0, role: AlertRole.defaultAction),
                AlertButton('Rollback e chiudi', 1),
                AlertButton('Annulla', 2, role: AlertRole.cancel),
              ],
            ),
          ),
          preview(
            280,
            const AboutPanel(
              name: 'DbCraft',
              version: '1.0.0',
              description: 'Client database universale.',
              copyright: '© 2026 DbCraft',
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _code(BuildContext context) => [
    CodeBox(
      'SELECT d.nome, r.nome AS reparto\nFROM dipendenti d\nJOIN reparti r ON r.id = d.reparto_id\nWHERE d.attivo = 1;',
      label: 'sql',
      actions: [ToolButton(icon: AppIcons.run, tooltip: 'Esegui', extent: 18, onPressed: () {})],
    ),
    const SizedBox(height: Gap.md),
    const CodeBox(
      'Driver={ODBC Driver 18 for SQL Server};Server=tcp:db.example.com,1433;Database=vendite;Encrypt=yes;'
      'TrustServerCertificate=no;Connection Timeout=30;',
      maxLines: 2,
    ),
    const SizedBox(height: Gap.md),
    DiffView.unified(_samplePatch, shrinkWrap: true),
  ];

  List<Widget> _forms(BuildContext context) => [
    FormGroup(
      title: 'Connessione',
      footer: 'La porta predefinita di SQL Server è 1433.',
      children: [
        const FormRow(label: 'Host', child: MacTextField(hint: 'localhost')),
        FormRow(
          label: 'Ambiente',
          child: Segmented<int>(
            value: 0,
            items: const [(0, 'Sviluppo', null), (1, 'Test', null), (2, 'Produzione', null)],
            onChanged: (_) {},
          ),
        ),
        FormRow(
          label: 'Salva password',
          help: 'Cifrata nel vault del workspace',
          child: DbSwitch(value: true, onChanged: (_) {}),
        ),
      ],
    ),
  ];
}

const _samplePatch = """diff --git a/ordini.sql b/ordini.sql
index 3f2a1c0..9b8e7d4 100644
--- a/ordini.sql
+++ b/ordini.sql
@@ -1,6 +1,7 @@
 SELECT o.id,
-       o.data,
+       o.data_ordine,
+       c.nome AS cliente,
        o.totale
 FROM ordini o
-WHERE o.totale > 100
+JOIN clienti c ON c.id = o.cliente_id
 ORDER BY o.id;
""";

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

/// Holds one value for an interactive demo.
class _Demo<T> extends StatefulWidget {
  const _Demo(this.initial, this.builder);
  final T initial;
  final Widget Function(T value, ValueChanged<T> set) builder;

  @override
  State<_Demo<T>> createState() => _DemoState<T>();
}

class _DemoState<T> extends State<_Demo<T>> {
  late T _value = widget.initial;

  @override
  Widget build(BuildContext context) => widget.builder(_value, (v) => setState(() => _value = v));
}
