// Security manager: users, roles and logins of a connection on the left,
// the editor of the selected one on the right (Generale, Ruoli, Permessi,
// Privilegi di sistema, DDL). Edits stay pending until Salva, which runs
// the script through the script sheet; passwords travel as secrets.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/sql_dialect.dart';
import '../../../state/app_state.dart';
import '../../../state/db_connection.dart';
import '../../../state/editor_tabs.dart';
import '../../../ui/editors/sql_code_editor.dart';
import '../../../ui/navigator/nav_nodes.dart' show principalIcon, principalKindPlural;
import '../../../ui/widgets/common.dart';
import '../../../ui/widgets/split_view.dart';
import '../../schema/ddl_builder.dart';
import '../../schema/ddl_execution.dart';
import '../catalog/design_catalog.dart';
import '../catalog/security.dart';
import '../ddl/security/security_ddl.dart';
import '../ddl_script.dart';
import '../model/security_defs.dart';
import '../security_design.dart';
import 'grants_grid.dart';
import 'object_dialogs.dart';

/// Opens the security manager of [dc] (SQL Server: of [catalog]), selecting
/// [select] or starting a new principal of kind [create].
Future<void> openSecurity(
  BuildContext context,
  DbConnection dc, {
  String? catalog,
  PrincipalDef? select,
  PrincipalKind? create,
}) async {
  final app = AppScope.read(context);
  final tab = app.openFeatureTab(
    SecurityTab(dc, catalog: catalog),
    match: (t) => t.dc == dc && (catalog == null || t.catalog == catalog),
  );
  if (select != null) await tab.select(context, select);
  if (create != null && context.mounted) await tab.create(context, create);
}

class SecurityTab extends FeatureTab {
  SecurityTab(this.dc, {String? catalog})
    : catalog = dc.dialect.family == DbFamily.sqlServer
          ? (catalog ?? dc.defaultCatalog ?? dc.metadata?.currentCatalog)
          : null {
    load();
  }

  final DbConnection dc;

  /// SQL Server database whose users and roles are listed.
  String? catalog;

  SecurityDdl get ddl => SecurityDdl.forFamily(dc.dialect);

  List<PrincipalDef> principals = const [];

  /// MongoDB databases (where users authenticate and roles live).
  List<String> databases = const [];

  /// Redis keeps the users in an ACL file: scripts end with ACL SAVE.
  bool aclFile = false;
  Object? loadError;
  bool loading = false;

  PrincipalDesign? design;
  bool accessLoading = false;
  Object? accessError;
  int page = 0;

  /// Selection waiting for the list (opened from the navigator).
  String? _pending;

  @override
  DbConnection get connection => dc;
  @override
  String get title => 'Utenti e ruoli';
  @override
  String get tooltip => '${dc.config.name}: utenti e ruoli${catalog == null ? '' : ' di $catalog'}';
  @override
  IconData get icon => AppIcons.security;
  @override
  bool get isDirty => design?.isDirty ?? false;

  DesignCatalog? get _cat => DesignCatalog.of(dc);

  Future<void> load() async {
    final cat = _cat;
    if (cat == null) return;
    loading = true;
    notifyListeners();
    try {
      principals = await cat.principals(catalog: catalog);
      loadError = null;
      if (dc.dialect.family == DbFamily.mongodb) databases = await dc.metadata!.catalogs();
      if (dc.dialect.family == DbFamily.redis) aclFile = await _aclFile(cat);
    } catch (e) {
      principals = const [];
      loadError = e;
    }
    loading = false;
    notifyListeners();
  }

  Future<bool> _aclFile(DesignCatalog cat) async {
    try {
      final rows = await cat.queries.rows('CONFIG GET aclfile');
      return rows.any((r) => r.values.any((v) => v != null && '$v'.trim().isNotEmpty && '$v' != 'aclfile'));
    } catch (_) {
      return false;
    }
  }

  /// The listed principal with [key].
  PrincipalDef? byKey(String key) => principals.where((p) => p.key == key).firstOrNull;

  Future<bool> _leave(BuildContext context) async {
    final d = design;
    if (d == null || !d.isDirty) return true;
    return confirmDialog(
      context,
      'Scartare le modifiche?',
      d.isNew
          ? '${d.working.kind.label} ${d.working.display} non è ancora stato creato.'
          : 'Le modifiche a ${d.working.display} non ancora salvate andranno perse.',
      ok: 'Scarta',
      destructive: true,
    );
  }

  void _setDesign(PrincipalDesign? d) {
    design?.removeListener(notifyListeners);
    design?.dispose();
    if (d != null && aclFile) d.trailing = const ['ACL SAVE'];
    design = d;
    d?.addListener(notifyListeners);
    notifyListeners();
  }

  Future<void> select(BuildContext context, PrincipalDef p) async {
    if (design != null && !design!.isNew && design!.original!.key == p.key) return;
    if (!await _leave(context)) return;
    if (loading) {
      _pending = p.key;
      while (loading) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      p = byKey(_pending ?? p.key) ?? p;
      _pending = null;
    }
    _setDesign(null);
    accessLoading = true;
    accessError = null;
    notifyListeners();
    try {
      final access = await _cat!.access(p, catalog: catalog);
      _setDesign(PrincipalDesign.existing(dc.dialect, p, access, catalog: catalog));
    } catch (e) {
      accessError = e;
      // Without the privileges the principal can still be edited.
      _setDesign(PrincipalDesign.existing(dc.dialect, p, PrincipalAccess.none, catalog: catalog));
    }
    accessLoading = false;
    notifyListeners();
  }

  Future<void> create(BuildContext context, PrincipalKind kind) async {
    if (!await _leave(context)) return;
    accessError = null;
    page = 0;
    _setDesign(PrincipalDesign.create(dc.dialect, kind, catalog: catalog));
  }

  void discard() {
    final d = design;
    if (d == null) return;
    if (d.isNew) {
      _setDesign(null);
    } else {
      _setDesign(
        PrincipalDesign.existing(
          dc.dialect,
          d.original!,
          PrincipalAccess(grants: d.originalGrants, memberOf: d.originalRoles),
          catalog: catalog,
        ),
      );
    }
  }

  Future<void> setCatalog(BuildContext context, String? c) async {
    if (c == catalog || !await _leave(context)) return;
    catalog = c;
    _setDesign(null);
    await load();
  }

  @override
  String? get saveLabel {
    final d = design;
    if (d == null || !d.isDirty || d.errors.isNotEmpty || dc.config.readOnly || d.readOnly) return null;
    return d.isNew ? 'Crea ${d.working.display}' : 'Salva ${d.working.display}';
  }

  @override
  Future<void> save(BuildContext context) async {
    final d = design;
    if (d == null || d.errors.isNotEmpty) return;
    final ok = await showDdlScriptDialog(
      context,
      dc: dc,
      title: d.isNew ? 'Crea ${d.working.display}' : 'Salva ${d.working.display}',
      script: d.script(),
    );
    if (!ok) return;
    final key = d.working.copyWith(originalName: null).key;
    await load();
    _setDesign(null);
    final now = byKey(key);
    if (now != null && context.mounted) await select(context, now);
  }

  Future<void> drop(BuildContext context, PrincipalDef p) async {
    final options = [
      if (ddl.canDropCascade(p))
        DropOption(
          'cascade',
          dc.dialect.family == DbFamily.oracle
              ? 'Elimina anche gli oggetti del suo schema (CASCADE)'
              : 'Riassegna ed elimina gli oggetti che possiede (DROP OWNED)',
        ),
    ];
    final chosen = await showDropDialog(
      context,
      title: 'Elimina ${p.kind.label.toLowerCase()}',
      objectLabel: '${p.kind.label.toLowerCase()} ${p.display}',
      confirmName: p.display,
      options: options,
    );
    if (chosen == null || !context.mounted) return;
    final ok = await showDdlScriptDialog(
      context,
      dc: dc,
      title: 'Elimina ${p.display}',
      script: DdlScript(
        [...ddl.dropPrincipal(p, cascade: chosen.contains('cascade')), if (aclFile) 'ACL SAVE'],
        scope: SchemaScope.security(catalog),
        catalog: p.kind == PrincipalKind.login ? null : catalog,
      ),
    );
    if (!ok) return;
    if (design?.original?.key == p.key) _setDesign(null);
    await load();
  }

  @override
  Future<bool> canClose(BuildContext context) => _leave(context);

  @override
  void dispose() {
    design?.removeListener(notifyListeners);
    design?.dispose();
    super.dispose();
  }

  @override
  Widget buildView(BuildContext context) => _SecurityView(tab: this);
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

class _SecurityView extends StatefulWidget {
  const _SecurityView({required this.tab});
  final SecurityTab tab;

  @override
  State<_SecurityView> createState() => _SecurityViewState();
}

class _SecurityViewState extends State<_SecurityView> {
  final _filter = TextEditingController();
  List<String> _catalogs = const [];

  SecurityTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    tab.addListener(_changed);
    if (tab.catalog != null) {
      tab.dc.metadata?.catalogs().then((c) {
        if (mounted) setState(() => _catalogs = c);
      }, onError: (_) {});
    }
  }

  @override
  void dispose() {
    tab.removeListener(_changed);
    _filter.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: SplitView(
        initialFraction: 0.26,
        minFirst: 220,
        minSecond: 420,
        first: _list(context),
        second: _editor(context),
      ),
    );
  }

  // -- List ------------------------------------------------------------------

  List<MenuEntry<Object?>> _newEntries(BuildContext context) => [
    for (final k in tab.ddl.kinds)
      MenuEntry<Object?>(
        'Nuovo ${k.label.toLowerCase()}…',
        enabled: tab.ddl.canCreate(k) && !tab.dc.config.readOnly,
        onSelected: () => tab.create(context, k),
      ),
  ];

  Widget _list(BuildContext context) {
    final c = DbColors.of(context);
    final f = _filter.text.trim().toLowerCase();
    final rows = <Object>[];
    for (final k in tab.ddl.kinds) {
      final ps = [
        for (final p in tab.principals)
          if (p.kind == k && (f.isEmpty || p.display.toLowerCase().contains(f))) p,
      ];
      if (ps.isEmpty) continue;
      rows
        ..add(k)
        ..addAll(ps);
    }
    final selectedKey = tab.design?.original?.key;
    final selected = rows.indexWhere((r) => r is PrincipalDef && r.key == selectedKey);
    return ColoredBox(
      color: c.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(
            'Utenti e ruoli',
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.xs),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PulldownButton(icon: AppIcons.add, tooltip: 'Nuovo', entries: () => _newEntries(context)),
                ToolButton(icon: AppIcons.refresh, tooltip: 'Ricarica', onPressed: tab.loading ? null : tab.load),
              ],
            ),
          ),
          if (_catalogs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, Gap.sm),
              child: PopUpButton<String?>(
                value: tab.catalog,
                expand: true,
                tooltip: 'Database degli utenti e dei ruoli (i login sono del server)',
                items: [for (final x in _catalogs) (x, x, (AppIcons.database, c.textSecondary))],
                onChanged: (x) => tab.setCatalog(context, x),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, Gap.sm),
            child: SearchField(controller: _filter, hint: 'Filtra', onChanged: (_) => setState(() {})),
          ),
          if (tab.loading) const LoadingLine(),
          Expanded(
            child: tab.loadError != null
                ? EmptyState.error(tab.loadError!, title: 'Impossibile leggere utenti e ruoli')
                : rows.isEmpty && !tab.loading
                ? EmptyState(
                    icon: AppIcons.security,
                    title: f.isEmpty ? 'Nessun utente' : 'Nessun risultato',
                    message: f.isEmpty ? 'Crea un utente o un ruolo con +.' : 'Cambia il filtro.',
                  )
                : SourceList(
                    itemCount: rows.length,
                    selectedIndex: selected < 0 ? null : selected,
                    selectable: (i) => rows[i] is PrincipalDef,
                    onSelect: (i) {
                      final r = rows[i];
                      if (r is PrincipalDef) tab.select(context, r);
                    },
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      if (r is PrincipalKind) {
                        return SectionLabel(
                          principalKindPlural(r),
                          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.md, 0, 2),
                        );
                      }
                      final p = r as PrincipalDef;
                      return OutlineRow(
                        title: p.display,
                        icon: principalIcon(p.kind),
                        muted: p.builtIn,
                        detail: p.locked ? 'disabilitato' : (p.builtIn ? 'di sistema' : null),
                        selected: i == selected,
                        onTap: () => tab.select(context, p),
                        onMenu: (pos) => _menu(context, p, pos),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _menu(BuildContext context, PrincipalDef p, Offset pos) {
    final ro = tab.dc.config.readOnly;
    showMacMenu<void>(
      context,
      position: pos,
      entries: [
        MenuEntry('Apri', onSelected: () => tab.select(context, p)),
        MenuEntry(
          'Elimina…',
          destructive: true,
          enabled: !ro && !p.builtIn && tab.ddl.canCreate(p.kind),
          onSelected: () => tab.drop(context, p),
        ),
        const MenuEntry.divider(),
        MenuEntry('Copia nome', onSelected: () => Clipboard.setData(ClipboardData(text: p.display))),
      ],
    );
  }

  // -- Editor ----------------------------------------------------------------

  Widget _editor(BuildContext context) {
    final d = tab.design;
    if (tab.accessLoading) return const Center(child: Spinner());
    if (d == null) {
      return const EmptyState(
        icon: AppIcons.security,
        title: 'Nessun utente selezionato',
        message: 'Scegli un utente o un ruolo nell\'elenco, o creane uno nuovo.',
      );
    }
    return _PrincipalEditor(key: ObjectKey(d), tab: tab, design: d);
  }
}

class _PrincipalEditor extends StatefulWidget {
  const _PrincipalEditor({super.key, required this.tab, required this.design});
  final SecurityTab tab;
  final PrincipalDesign design;

  @override
  State<_PrincipalEditor> createState() => _PrincipalEditorState();
}

class _PrincipalEditorState extends State<_PrincipalEditor> {
  SecurityTab get tab => widget.tab;
  PrincipalDesign get d => widget.design;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final c = DbColors.of(context);
        final ddl = tab.ddl;
        final kind = d.working.kind;
        final ro = tab.dc.config.readOnly;
        final enabled = !ro && !d.readOnly;
        final pages = <(int, String, IconData?)>[
          (0, 'Generale', null),
          if (ddl.hasRoles(kind) || (kind == PrincipalKind.login && ddl.serverRoles.isNotEmpty)) (1, 'Ruoli', null),
          if (ddl.objectTargets(kind).isNotEmpty) (2, 'Permessi', null),
          if (ddl.systemPrivileges(kind).isNotEmpty) (3, 'Privilegi di sistema', null),
          (4, 'DDL', null),
        ];
        final page = pages.any((p) => p.$1 == tab.page) ? tab.page : 0;
        final errors = d.errors;
        final mac = Theme.of(context).platform == TargetPlatform.macOS;
        final save = SingleActivator(LogicalKeyboardKey.keyS, meta: mac, control: !mac);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: c.content,
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.md),
              child: Row(
                children: [
                  Icon(principalIcon(kind), size: 18, color: c.accent),
                  const SizedBox(width: Gap.sm),
                  Flexible(
                    child: Text(
                      d.working.name.isEmpty ? 'Nuovo ${kind.label.toLowerCase()}' : d.working.display,
                      overflow: TextOverflow.ellipsis,
                      style: uiText(TypeSize.title, weight: FontWeight.w600, color: c.text),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Tag(kind.label.toLowerCase()),
                  if (d.isNew) ...[const SizedBox(width: Gap.xs), Tag('nuovo', color: c.diffAdded)],
                  if (d.readOnly) ...[const SizedBox(width: Gap.xs), const Tag('di sistema')],
                  if (d.isDirty) ...[const SizedBox(width: Gap.xs), const DirtyDot()],
                  const Spacer(),
                  if (!d.isNew)
                    ToolButton(
                      icon: AppIcons.delete,
                      tooltip: 'Elimina ${kind.label.toLowerCase()}…',
                      onPressed: enabled && ddl.canCreate(kind) ? () => tab.drop(context, d.original!) : null,
                    ),
                  ToolButton(
                    icon: AppIcons.replay,
                    tooltip: d.isNew ? 'Annulla la creazione' : 'Scarta le modifiche',
                    onPressed: d.isDirty || d.isNew ? tab.discard : null,
                  ),
                  const SizedBox(width: Gap.xs),
                  PushButton.primary(
                    label: d.isNew ? 'Crea' : 'Salva',
                    icon: AppIcons.save,
                    size: ControlScale.small,
                    tooltip: ro
                        ? 'Connessione in sola lettura'
                        : errors.isNotEmpty
                        ? errors.first
                        : 'Mostra lo script ed esegue le modifiche (${shortcutLabel(save)})',
                    onPressed: enabled && d.isDirty && errors.isEmpty ? () => tab.save(context) : null,
                  ),
                ],
              ),
            ),
            if (tab.accessError != null)
              Notice.strip(
                kind: NoticeKind.warning,
                message: 'Ruoli e permessi non leggibili: ${describeError(tab.accessError!).split('\n').first}',
              ),
            PageSwitcher<int>(value: page, items: pages, onChanged: (p) => setState(() => tab.page = p)),
            Expanded(
              child: switch (page) {
                1 => _RolesPage(tab: tab, design: d, enabled: enabled),
                2 => GrantsPage(dc: tab.dc, design: d, catalog: tab.catalog, enabled: enabled),
                3 => SystemPrivilegesPage(dialect: tab.dc.dialect, design: d, enabled: enabled),
                4 => _DdlPage(dialect: tab.dc.dialect, design: d),
                _ => _GeneralPage(tab: tab, design: d, enabled: enabled),
              },
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Generale
// ---------------------------------------------------------------------------

class _GeneralPage extends StatefulWidget {
  const _GeneralPage({required this.tab, required this.design, required this.enabled});
  final SecurityTab tab;
  final PrincipalDesign design;
  final bool enabled;

  @override
  State<_GeneralPage> createState() => _GeneralPageState();
}

class _GeneralPageState extends State<_GeneralPage> {
  final Map<String, TextEditingController> _text = {};
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  PrincipalDesign get d => widget.design;

  TextEditingController _field(String key, String? value) =>
      _text.putIfAbsent(key, () => TextEditingController(text: value ?? ''));

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? _opt(String v) => v.trim().isEmpty ? null : v.trim();

  void _syncPassword() {
    d.setPassword(_password.text.isNotEmpty && _password.text == _confirm.text ? _password.text : null);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ddl = widget.tab.ddl;
    final p = d.working;
    final attrs = ddl.attributes(p.kind);
    final on = widget.enabled;
    bool has(PrincipalAttr a) => attrs.contains(a);
    final family = widget.tab.dc.dialect.family;
    Widget text(
      String label,
      String key,
      String? value,
      PrincipalDef Function(String? v) apply, {
      String? hint,
      String? help,
    }) => FormRow(
      label: label,
      help: help,
      child: MacTextField(
        controller: _field(key, value),
        enabled: on,
        hint: hint,
        onChanged: (v) => d.update(apply(_opt(v))),
      ),
    );
    Widget flag(String label, bool value, PrincipalDef Function(bool v) apply, {String? help}) =>
        CheckboxRow(value: value, label: label, help: help, onChanged: on ? (v) => d.update(apply(v)) : null);
    final mismatch = _confirm.text.isNotEmpty && _password.text != _confirm.text;
    final logins = [
      for (final x in widget.tab.principals)
        if (x.kind == PrincipalKind.login) x.name,
    ];
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: FormScope(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (d.readOnly) ...[
                    const Notice(
                      kind: NoticeKind.info,
                      message: 'Principal predefinito del DBMS: le proprietà sono in sola lettura.',
                    ),
                    const SizedBox(height: Gap.md),
                  ],
                  FormGroup(
                    children: [
                      FormRow(
                        label: 'Nome',
                        child: MacTextField(
                          controller: _field('name', p.name),
                          autofocus: d.isNew,
                          enabled: on && (d.isNew || has(PrincipalAttr.rename)),
                          hint: family == DbFamily.sqlServer && p.auth == PrincipalAuth.windows
                              ? r'DOMINIO\utente'
                              : null,
                          onChanged: (v) =>
                              d.update(p.copyWith(name: v.trim(), originalName: d.isNew ? null : d.original!.dbName)),
                        ),
                      ),
                      if (has(PrincipalAttr.host) && family == DbFamily.mongodb)
                        FormRow(
                          label: 'Database',
                          help: p.kind == PrincipalKind.user
                              ? 'Database in cui l\'utente si autentica'
                              : 'Database in cui è definito il ruolo',
                          child: ComboField(
                            controller: _field('host', p.host),
                            enabled: on && d.isNew,
                            options: () => widget.tab.databases,
                            onChanged: (v) => d.update(p.copyWith(host: _opt(v) ?? 'admin')),
                            onSelected: (v) => d.update(p.copyWith(host: _opt(v) ?? 'admin')),
                          ),
                        )
                      else if (has(PrincipalAttr.host))
                        text(
                          'Host',
                          'host',
                          p.host,
                          (v) => p.copyWith(host: v ?? '%', originalName: d.original?.dbName),
                          hint: '%',
                          help: 'Da dove può connettersi: % per qualunque host',
                        ),
                      if (has(PrincipalAttr.auth) && ddl.authOptions(p.kind).isNotEmpty)
                        FormRow(
                          label: 'Autenticazione',
                          child: PopUpButton<PrincipalAuth>(
                            value: p.auth,
                            expand: true,
                            items: [for (final a in ddl.authOptions(p.kind)) (a, a.label, null)],
                            onChanged: on && d.isNew ? (a) => d.update(p.copyWith(auth: a)) : null,
                          ),
                        ),
                      if (has(PrincipalAttr.login) && p.auth == PrincipalAuth.login)
                        FormRow(
                          label: 'Login',
                          help: 'Login del server associato all\'utente (vuoto: stesso nome)',
                          child: ComboField(
                            controller: _field('login', p.login),
                            options: () => logins,
                            enabled: on,
                            onChanged: (v) => d.update(p.copyWith(login: _opt(v))),
                          ),
                        ),
                    ],
                  ),
                  if (has(PrincipalAttr.password) &&
                      !(family == DbFamily.sqlServer && p.auth != PrincipalAuth.password)) ...[
                    const SizedBox(height: Gap.lg),
                    FormGroup(
                      title: 'Password',
                      footer: 'La password non viene salvata né registrata nella cronologia: nello script compare come ••••••.',
                      children: [
                        FormRow(
                          label: d.isNew
                              ? 'Password'
                              : (family == DbFamily.redis ? 'Aggiungi password' : 'Nuova password'),
                          help: family == DbFamily.redis && !d.isNew
                              ? 'Redis aggiunge la password a quelle già valide per l\'utente'
                              : null,
                          child: SecureField(
                            controller: _password,
                            enabled: on,
                            hint: d.isNew
                                ? null
                                : (family == DbFamily.redis ? 'Vuoto: nessuna' : 'Lascia vuoto per non cambiarla'),
                            onChanged: (_) => _syncPassword(),
                          ),
                        ),
                        FormRow(
                          label: 'Conferma',
                          child: SecureField(
                            controller: _confirm,
                            enabled: on,
                            revealable: false,
                            error: mismatch ? 'Le password non coincidono' : null,
                            onChanged: (_) => _syncPassword(),
                          ),
                        ),
                        if (has(PrincipalAttr.passwordExpired))
                          flag(
                            'Password scaduta',
                            p.passwordExpired,
                            (v) => p.copyWith(passwordExpired: v),
                            help: 'Va cambiata al prossimo accesso',
                          ),
                        if (has(PrincipalAttr.mustChangePassword))
                          flag(
                            'Cambio password al primo accesso',
                            p.mustChangePassword,
                            (v) => p.copyWith(mustChangePassword: v),
                          ),
                        if (has(PrincipalAttr.validUntil))
                          text(
                            'Valida fino al',
                            'until',
                            p.validUntil,
                            (v) => p.copyWith(validUntil: v),
                            hint: 'AAAA-MM-GG',
                          ),
                      ],
                    ),
                  ],
                  if (has(PrincipalAttr.aclRules)) ...[
                    const SizedBox(height: Gap.lg),
                    FormGroup(
                      title: 'Regole ACL',
                      footer:
                          'Chiavi ~schema, canali &schema, comandi e categorie +@read -flushall. '
                          'Salvando, chiavi, canali e comandi vengono sostituiti; le password restano.',
                      children: [
                        FormRow(
                          label: 'Regole',
                          child: MacTextField(
                            controller: _field('acl', p.aclRules),
                            enabled: on,
                            mono: true,
                            maxLines: 4,
                            hint: '~app:* &* +@read +@write',
                            onChanged: (v) => d.update(p.copyWith(aclRules: _opt(v))),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_hasOptions(attrs)) ...[
                    const SizedBox(height: Gap.lg),
                    FormGroup(
                      title: 'Opzioni',
                      children: [
                        if (has(PrincipalAttr.locked))
                          flag(
                            family == DbFamily.sqlServer || family == DbFamily.snowflake || family == DbFamily.firebird
                                ? 'Disabilitato'
                                : 'Account bloccato',
                            p.locked,
                            (v) => p.copyWith(locked: v),
                          ),
                        if (has(PrincipalAttr.superuser))
                          flag('Superutente', p.superuser, (v) => p.copyWith(superuser: v)),
                        if (has(PrincipalAttr.createDb))
                          flag('Può creare database', p.createDb, (v) => p.copyWith(createDb: v)),
                        if (has(PrincipalAttr.createRole))
                          flag('Può creare ruoli', p.createRole, (v) => p.copyWith(createRole: v)),
                        if (has(PrincipalAttr.inherit))
                          flag('Eredita i privilegi dei ruoli', p.inherit, (v) => p.copyWith(inherit: v)),
                        if (has(PrincipalAttr.replication))
                          flag('Replica', p.replication, (v) => p.copyWith(replication: v)),
                        if (has(PrincipalAttr.connectionLimit))
                          FormRow(
                            label: 'Limite connessioni',
                            help: 'Vuoto: nessun limite',
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: NumberField(
                                controller: _field('limit', p.connectionLimit?.toString()),
                                min: 0,
                                enabled: on,
                                onChanged: (v) => d.update(p.copyWith(connectionLimit: int.tryParse(v.trim()))),
                              ),
                            ),
                          ),
                        if (has(PrincipalAttr.defaultDatabase))
                          text('Database predefinito', 'db', p.defaultDatabase, (v) => p.copyWith(defaultDatabase: v)),
                        if (has(PrincipalAttr.defaultSchema))
                          text(
                            'Schema predefinito',
                            'schema',
                            p.defaultSchema,
                            (v) => p.copyWith(defaultSchema: v),
                            hint: 'dbo',
                          ),
                        if (has(PrincipalAttr.defaultTablespace))
                          text(
                            'Tablespace',
                            'ts',
                            p.defaultTablespace,
                            (v) => p.copyWith(defaultTablespace: v),
                            hint: 'USERS',
                          ),
                        if (has(PrincipalAttr.temporaryTablespace))
                          text(
                            'Tablespace temporaneo',
                            'tmp',
                            p.temporaryTablespace,
                            (v) => p.copyWith(temporaryTablespace: v),
                            hint: 'TEMP',
                          ),
                        if (has(PrincipalAttr.profile))
                          text('Profilo', 'profile', p.profile, (v) => p.copyWith(profile: v), hint: 'DEFAULT'),
                        if (has(PrincipalAttr.defaultRole))
                          text('Ruolo predefinito', 'role', p.defaultRole, (v) => p.copyWith(defaultRole: v)),
                        if (has(PrincipalAttr.defaultWarehouse))
                          text(
                            'Warehouse predefinito',
                            'wh',
                            p.defaultWarehouse,
                            (v) => p.copyWith(defaultWarehouse: v),
                          ),
                        if (has(PrincipalAttr.comment))
                          text('Commento', 'comment', p.comment, (v) => p.copyWith(comment: v)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static bool _hasOptions(Set<PrincipalAttr> a) => a.any(
    (x) => !const {
      PrincipalAttr.password,
      PrincipalAttr.host,
      PrincipalAttr.auth,
      PrincipalAttr.login,
      PrincipalAttr.rename,
      PrincipalAttr.passwordExpired,
      PrincipalAttr.mustChangePassword,
      PrincipalAttr.validUntil,
      PrincipalAttr.aclRules,
    }.contains(x),
  );
}

// ---------------------------------------------------------------------------
// Ruoli
// ---------------------------------------------------------------------------

class _RolesPage extends StatelessWidget {
  const _RolesPage({required this.tab, required this.design, required this.enabled});
  final SecurityTab tab;
  final PrincipalDesign design;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ddl = tab.ddl;
    final p = design.working;
    final login = p.kind == PrincipalKind.login;
    // (name, host, server role)
    final roles = <(String, String?, bool)>[
      if (login)
        for (final r in ddl.serverRoles) (r, null, true)
      else
        for (final r in tab.principals)
          if (r.kind == PrincipalKind.role && r.key != (design.original?.key ?? '')) (r.name, r.host, false),
    ];
    if (tab.dc.dialect.family == DbFamily.mongodb && !login) {
      for (final (r, db) in mongoBuiltinRoles(tab.databases)) {
        if (!roles.any((x) => x.$1 == r && x.$2 == db)) roles.add((r, db, false));
      }
    }
    // Memberships of roles not listed (not readable) stay visible.
    for (final m in design.roles) {
      if (!roles.any((r) => r.$1.toLowerCase() == m.role.toLowerCase() && r.$3 == m.serverRole)) {
        roles.add((m.role, m.roleHost, m.serverRole));
      }
    }
    if (roles.isEmpty) {
      return const EmptyState(
        icon: AppIcons.role,
        title: 'Nessun ruolo',
        message: 'Crea un ruolo per raggruppare i privilegi.',
      );
    }
    final admin = ddl.adminOption && !login;
    return MacTable(
      headers: ['Ruolo', 'Membro', if (admin) 'Con ADMIN OPTION'],
      rowCount: roles.length,
      emphasis: 0,
      flex: (col) => col == 0 ? 1 : null,
      cell: (row, col) {
        final (name, host, server) = roles[row];
        final m = design.roleOf(name, roleHost: host, serverRole: server);
        return switch (col) {
          0 => host == null || host == '%' ? name : '$name@$host',
          1 => m == null ? '' : '✓',
          _ => m?.withAdmin == true ? '✓' : '',
        };
      },
      cellBuilder: (context, row, col) {
        if (col == 0) return null;
        final (name, host, server) = roles[row];
        final m = design.roleOf(name, roleHost: host, serverRole: server);
        if (col == 1) {
          return Center(
            child: MacCheckbox(
              value: m != null,
              semanticLabel: 'Membro di $name',
              onChanged: enabled ? (v) => design.setRole(name, v, roleHost: host, serverRole: server) : null,
            ),
          );
        }
        return Center(
          child: MacCheckbox(
            value: m?.withAdmin ?? false,
            onChanged: enabled && m != null ? (v) => design.setAdmin(name, v, roleHost: host) : null,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// DDL
// ---------------------------------------------------------------------------

class _DdlPage extends StatelessWidget {
  const _DdlPage({required this.dialect, required this.design});
  final SqlDialect dialect;
  final PrincipalDesign design;

  @override
  Widget build(BuildContext context) {
    final b = DdlBuilder(dialect);
    final changes = design.isNew ? const <String>[] : design.statements;
    final text = [
      if (changes.isNotEmpty) ...['-- Modifiche da salvare', DdlScript.masked(b.render(changes)), ''],
      '-- ${design.working.kind.label} ${design.working.display}',
      DdlScript.masked(b.render(design.ddlScript)),
    ].join('\n');
    return SqlCodeView(key: ValueKey(text), text: text);
  }
}
