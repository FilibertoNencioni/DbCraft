import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../drivers/native_driver.dart';
import '../../drivers/native_registry.dart';
import '../../drivers/session_factory.dart';
import '../../model/auth_methods.dart';
import '../../model/connection_config.dart';
import '../../odbc/odbc_session.dart';
import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import 'driver_manager_dialog.dart';

/// Create / edit connection dialog (DBeaver "Connection settings").
Future<ConnectionConfig?> showConnectionDialog(
  BuildContext context, {
  required AppState app,
  ConnectionConfig? existing,
}) {
  return showSheet<ConnectionConfig>(context, builder: (_) => ConnectionDialog(app: app, existing: existing));
}

class ConnectionDialog extends StatefulWidget {
  const ConnectionDialog({super.key, required this.app, this.existing});
  final AppState app;
  final ConnectionConfig? existing;

  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

/// Outcome of "Prova connessione", shown inline in the footer.
class _TestResult {
  const _TestResult.ok(this.summary, this.detail, this.details) : error = null;
  _TestResult.failed(Object this.error)
      : summary = 'Connessione non riuscita',
        detail = _firstLine(error),
        details = null;

  final String summary;

  /// Second line: the DBMS, or what went wrong.
  final String detail;

  /// Full driver/server info, in the tooltip.
  final String? details;
  final Object? error;
  bool get ok => error == null;

  /// First diagnostic without its SQLSTATE and [vendor][driver] prefixes.
  static String _firstLine(Object e) {
    final msg = (e is OdbcException ? e.message : '$e').trim().split('\n').first;
    return msg.replaceFirst(RegExp(r'^(\[\w+\]\s*\(-?\d+\)\s*)?(\[[^\]]*\])*\s*'), '');
  }
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  late final ConnectionConfig cfg =
      widget.existing?.copy() ?? ConnectionConfig(id: DateTime.now().microsecondsSinceEpoch.toString(), name: '');

  late final _name = TextEditingController(text: cfg.name);
  late final _driver = TextEditingController(text: cfg.driver);
  late final _dsn = TextEditingController(text: cfg.dsn);
  late final _host = TextEditingController(text: cfg.host);
  late final _port = TextEditingController(text: cfg.port);
  late final _database = TextEditingController(text: cfg.database);
  late final _user = TextEditingController(text: cfg.user);
  late final _password = TextEditingController(text: cfg.password);
  late final _connStr = TextEditingController(text: cfg.connectionString);
  late final _extra = TextEditingController(text: cfg.extraParams.entries.map((e) => '${e.key}=${odbcEscape(e.value)}').join('\n'));
  late final _folder = TextEditingController(text: cfg.folder);
  late final _defaultCatalog = TextEditingController(text: cfg.defaultCatalog);
  late final _loginTimeout = TextEditingController(text: '${cfg.loginTimeout}');
  late final _queryTimeout = TextEditingController(text: '${cfg.queryTimeout}');
  late final _bootstrap = TextEditingController(text: cfg.bootstrapQueries);
  late final _description = TextEditingController(text: cfg.description);

  /// Auth parameters and native driver options, created on demand.
  final Map<String, TextEditingController> _params = {};

  TextEditingController _param(String key, {String initial = ''}) => _params.putIfAbsent(key, () {
    final v = cfg.secretParams[key] ?? cfg.authParams[key] ?? cfg.extraParams[key] ?? initial;
    return TextEditingController(text: v)..addListener(_changed);
  });

  List<OdbcDriverInfo> _drivers = [];
  List<OdbcDataSource> _dsns = [];
  Object? _loadError;
  bool _testing = false;
  _TestResult? _result;
  late bool _showAdvanced = _hasAdvancedValues();

  /// Any edit makes a previous test result stale.
  void _changed() => setState(() => _result = null);

  bool _hasAdvancedValues() =>
      cfg.description.isNotEmpty ||
      cfg.defaultCatalog.isNotEmpty ||
      cfg.loginTimeout != 15 ||
      cfg.queryTimeout != 0 ||
      cfg.bootstrapQueries.trim().isNotEmpty ||
      (!cfg.isNative && cfg.extraParams.isNotEmpty);

  /// "Integrato" is offered only when this build ships native drivers.
  bool get _offerNative => nativeDrivers.isNotEmpty || cfg.mode == ConnectionMode.native;

  @override
  void initState() {
    super.initState();
    _loadOdbc();
    for (final c in [_driver, _host, _port, _database, _user, _password, _dsn, _connStr, _extra, _defaultCatalog]) {
      c.addListener(_changed);
    }
  }

  Future<void> _loadOdbc() async {
    final lib = widget.app.settings.libPathOrNull;
    try {
      final d = await odbcDrivers(lib);
      final s = await odbcDataSources(lib);
      if (!mounted) return;
      setState(() {
        _loadError = null;
        _drivers = d;
        _dsns = s;
        if (_driver.text.isEmpty && cfg.mode == ConnectionMode.driver && d.isNotEmpty) {
          _driver.text = d.first.name;
          _applyTemplateDefaults();
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _applyTemplateDefaults() {
    final t = DriverTemplate.forDriver(_driver.text);
    if (_port.text.isEmpty && t.defaultPort.isNotEmpty) _port.text = t.defaultPort;
    if (_host.text.isEmpty && t.hostKey != null && !t.fileBased) _host.text = 'localhost';
  }

  ConnectionConfig _collect() {
    cfg
      ..name = _name.text.trim().isEmpty ? _autoName() : _name.text.trim()
      ..driver = _driver.text.trim()
      ..dsn = _dsn.text.trim()
      ..host = _host.text.trim()
      ..port = _port.text.trim()
      ..database = _database.text.trim()
      ..user = _user.text.trim()
      ..password = _password.text
      ..connectionString = _connStr.text.trim()
      ..folder = _folder.text.trim()
      ..defaultCatalog = _defaultCatalog.text.trim()
      ..loginTimeout = int.tryParse(_loginTimeout.text) ?? 15
      ..queryTimeout = int.tryParse(_queryTimeout.text) ?? 0
      ..bootstrapQueries = _bootstrap.text
      ..description = _description.text;
    // Authentication parameters: secrets go to the vault, the rest to JSON.
    final authP = <String, String>{}, secrets = <String, String>{};
    if (!supportedAuthMethods(cfg).contains(cfg.authMethod)) cfg.authMethod = supportedAuthMethods(cfg).first;
    for (final a in authParams(cfg, cfg.authMethod)) {
      final v = _params[a.key]?.text.trim() ?? cfg.authParams[a.key] ?? cfg.secretParams[a.key] ?? '';
      if (v.isEmpty) continue;
      (a.secret ? secrets : authP)[a.key] = v;
    }
    final native = cfg.isNative ? nativeDriverById(cfg.nativeDriver) : null;
    if (native != null) {
      final extra = <String, String>{};
      for (final f in native.fields) {
        final v = _params[f.key]?.text.trim() ?? cfg.extraParams[f.key] ?? cfg.secretParams[f.key] ?? f.defaultValue;
        if (v.isEmpty) continue;
        (f.secret ? secrets : extra)[f.key] = v;
      }
      cfg.extraParams = extra;
    } else {
      cfg.extraParams = parseOdbcParams(_extra.text);
    }
    cfg
      ..authParams = authP
      ..secretParams = secrets;
    return cfg;
  }

  String _autoName() {
    switch (cfg.mode) {
      case ConnectionMode.dsn:
        return _dsn.text.isEmpty ? 'Nuova connessione' : _dsn.text;
      case ConnectionMode.connectionString:
        return 'Nuova connessione';
      case ConnectionMode.native:
        final d = nativeDriverById(cfg.nativeDriver);
        final where = _database.text.isNotEmpty ? _database.text : _host.text;
        return [d?.label ?? 'Nuova connessione', if (where.isNotEmpty) where].join(' - ');
      case ConnectionMode.driver:
        final t = DriverTemplate.forDriver(_driver.text);
        final where = _database.text.isNotEmpty ? _database.text.split(RegExp(r'[\\/]')).last : _host.text;
        return [t == DriverTemplate.generic ? _driver.text : t.label, if (where.isNotEmpty) where].join(' - ');
    }
  }

  Future<void> _test() async {
    final c = _collect();
    setState(() {
      _testing = true;
      _result = null;
    });
    final sw = Stopwatch()..start();
    _TestResult result;
    try {
      final s = await openDbSession(c, libPath: widget.app.settings.libPathOrNull);
      final info = await s.info();
      await s.close();
      String v(String k) => '${info[k] ?? ''}'.trim();
      final dbms = [v('dbmsName'), v('dbmsVersion')].where((x) => x.isNotEmpty).join(' ');
      result = _TestResult.ok(
        'Connesso in ${sw.elapsedMilliseconds} ms',
        dbms.isNotEmpty ? dbms : v('driverName'),
        [
          'Driver: ${v('driverName')} ${v('driverVersion')}'.trim(),
          if (!c.isNative && v('driverOdbcVersion').isNotEmpty) 'ODBC: ${v('driverOdbcVersion')}',
          if (v('serverName').isNotEmpty) 'Server: ${v('serverName')}',
          if (v('databaseName').isNotEmpty) 'Database: ${v('databaseName')}',
          if (v('userName').isNotEmpty) 'Utente: ${v('userName')}',
        ].join('\n'),
      );
    } catch (e) {
      result = _TestResult.failed(e);
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _result = result;
      });
    }
  }

  /// Opens the Driver Manager on the install page, then picks up new drivers.
  Future<void> _openInstaller() async {
    await showDriverManagerDialog(context, page: DriverManagerPage.install);
    if (mounted) await _loadOdbc();
  }

  void _submit() => Navigator.pop(context, _collect());

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) => SheetScaffold(
    title: widget.existing == null ? 'Nuova connessione' : 'Modifica connessione',
    body: _body(),
    onSubmit: _submit,
    leading: [
      PushButton(label: 'Prova connessione', onPressed: _testing ? null : _test),
      ConstrainedBox(constraints: const BoxConstraints(maxWidth: 230), child: _status()),
    ],
    actions: [
      PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
      PushButton.primary(label: widget.existing == null ? 'Crea' : 'Salva', onPressed: _submit),
    ],
  );

  /// Test outcome next to "Prova connessione": summary and DBMS (or error).
  Widget _status() {
    final r = _result;
    if (_testing) return const StatusLine.busy('Connessione in corso…');
    if (r == null) return const SizedBox.shrink();
    final line = StatusLine(
      r.detail.isEmpty ? r.summary : '${r.summary}\n${r.detail}',
      kind: r.ok ? StatusKind.success : StatusKind.danger,
      onDetails: r.ok ? null : () => showErrorDialog(context, r.error!, title: 'Connessione non riuscita'),
    );
    return r.details == null ? line : Tooltip(message: r.details!, child: line);
  }

  Widget _field(TextEditingController ctrl, String hint, {int maxLines = 1, bool mono = false}) => MacTextField(
    controller: ctrl,
    hint: hint,
    maxLines: maxLines,
    minLines: 1,
    mono: mono,
  );

  /// A file path with "Scegli…".
  Widget _pathField(TextEditingController ctrl, String hint, {void Function(String path)? onPicked}) => PathField(
    controller: ctrl,
    hint: hint,
    onChoose: () async {
      final f = await openFile();
      if (f == null) return;
      ctrl.text = f.path;
      onPicked?.call(f.path);
    },
  );

  /// Pickers sit at their natural width on the left of a form row.
  Widget _leading(Widget child) => Align(alignment: Alignment.centerLeft, child: child);

  Widget _hostRow(String defaultPort, {bool withPort = true}) {
    final c = DbColors.of(context);
    return FormRow(
      label: 'Host',
      child: Row(
        children: [
          Expanded(child: _field(_host, 'localhost')),
          if (withPort) ...[
            const SizedBox(width: Gap.md),
            Text('Porta', style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary)),
            const SizedBox(width: Gap.sm),
            NumberField(
              controller: _port,
              hint: defaultPort.isEmpty ? '—' : defaultPort,
              min: 0,
              max: 65535,
              width: 64,
              stepper: false,
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // One page: who it is, where it points, how it signs in, how it behaves.
  // Rarely touched settings wait behind "Avanzate".
  // -------------------------------------------------------------------------

  Widget _body() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _identityGroup(),
        if (_loadError case final Object e when cfg.mode != ConnectionMode.native)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.lg),
            child: Notice(
              kind: NoticeKind.danger,
              title: 'Driver ODBC non disponibili',
              message: canInstallDrivers
                  ? 'Manca il Driver Manager ODBC (unixODBC): si installa insieme a qualunque driver.'
                  : 'Manca il Driver Manager ODBC: installa unixODBC o indica la libreria in Preferenze › ODBC.',
              actions: [
                LinkButton(
                  label: 'Dettagli…',
                  small: true,
                  onPressed: () => showErrorDialog(context, e, title: 'Driver ODBC non disponibili'),
                ),
                if (canInstallDrivers) LinkButton(label: 'Installa…', small: true, onPressed: _openInstaller),
              ],
            ),
          ),
        ..._connectionGroups(),
        _behaviourGroup(),
        _advancedToggle(),
        if (_showAdvanced) ..._advancedGroups(),
      ],
    );
  }

  Widget _identityGroup() => FormGroup(
        footer: cfg.type.confirmExecute
            ? 'Le istruzioni che modificano i dati chiederanno conferma prima di essere eseguite.'
            : null,
        children: [
          FormRow(label: 'Nome', child: _field(_name, _autoName())),
          FormRow(
            label: 'Ambiente',
            child: _leading(
              Segmented<ConnectionType>(
                value: cfg.type,
                items: [for (final t in ConnectionType.values) (t, t.label, null)],
                // Development is the default and stays silent, as everywhere else.
                dot: (t) => t == ConnectionType.development ? null : t.colorOf(DbColors.of(context)),
                onChanged: (t) => setState(() => cfg.type = t),
              ),
            ),
          ),
          FormRow(label: 'Cartella', child: _field(_folder, 'Nessuna (es. Clienti/Produzione)')),
        ],
      );

  Widget _modeRow() => FormRow(
        label: 'Tramite',
        child: _leading(
          Segmented<ConnectionMode>(
            value: cfg.mode,
            items: [
              (ConnectionMode.driver, 'Driver ODBC', null),
              (ConnectionMode.dsn, 'DSN', null),
              (ConnectionMode.connectionString, 'Stringa', null),
              if (_offerNative) (ConnectionMode.native, 'Integrato', null),
            ],
            onChanged: (m) => setState(() {
              cfg.mode = m;
              _result = null;
              if (m == ConnectionMode.native && cfg.nativeDriver.isEmpty && nativeDrivers.isNotEmpty) {
                _selectNative(nativeDrivers.first);
              }
              _fixAuthMethod();
            }),
          ),
        ),
      );

  List<Widget> _connectionGroups() => switch (cfg.mode) {
        ConnectionMode.driver => _driverGroups(),
        ConnectionMode.dsn => _dsnGroups(),
        ConnectionMode.connectionString => _connectionStringGroups(),
        ConnectionMode.native => _nativeGroups(),
      };

  List<Widget> _driverGroups() {
    final c = DbColors.of(context);
    final t = DriverTemplate.forDriver(_driver.text);
    final generic = t == DriverTemplate.generic;
    return [
      FormGroup(
        title: 'Connessione',
        footer: _drivers.isEmpty
            ? (canInstallDrivers
                  ? 'Nessun driver ODBC registrato: installane uno con «Installa driver…» o indica la libreria.'
                  : 'Nessun driver ODBC registrato: indica il percorso della libreria del driver.')
            : null,
        children: [
          _modeRow(),
          FormRow(
            label: 'Driver',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(t.icon, size: 16, color: generic ? c.textTertiary : t.color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ComboField(
                        controller: _driver,
                        hint: 'Nome o percorso del driver',
                        options: () => [for (final d in _drivers) d.name],
                        // Picking (or typing) a registered driver resets the port to its default.
                        onChanged: (v) {
                          if (!_drivers.any((d) => d.name == v)) return;
                          _port.clear();
                          _applyTemplateDefaults();
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    PushButton(
                      label: 'Scegli…',
                      tooltip: 'Scegli la libreria del driver',
                      onPressed: () async {
                        final f = await openFile();
                        if (f != null) {
                          _driver.text = f.path;
                          _applyTemplateDefaults();
                        }
                      },
                    ),
                  ],
                ),
                if (canInstallDrivers)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs, left: 22),
                    child: LinkButton(label: 'Installa driver…', small: true, onPressed: _openInstaller),
                  ),
              ],
            ),
          ),
          if (t.hostKey != null) _hostRow(t.defaultPort, withPort: t.portKey != null || t.portInServer),
          if (t.databaseKey != null)
            FormRow(
              label: t.fileBased ? 'File' : 'Database',
              child: t.fileBased
                  ? _pathField(_database, '/percorso/del/file.db')
                  : _field(_database, 'Nome del database'),
            ),
        ],
      ),
      if (t.userKey != null || supportedAuthMethods(cfg).length > 1) _authFields(),
    ];
  }

  List<Widget> _dsnGroups() => [
        FormGroup(
          title: 'Connessione',
          footer: 'I DSN si configurano in odbc.ini (unixODBC) o nell\'Amministratore ODBC di Windows.',
          children: [
            _modeRow(),
            FormRow(
              label: 'Data Source',
              child: ComboField(
                controller: _dsn,
                hint: _dsns.isEmpty ? 'Nome del DSN (nessuno configurato)' : 'Nome del DSN',
                options: () => [for (final d in _dsns) d.name],
              ),
            ),
          ],
        ),
        _authFields(),
      ];

  List<Widget> _connectionStringGroups() => [
        FormGroup(
          title: 'Connessione',
          children: [
            _modeRow(),
            _field(
              _connStr,
              'DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost;DATABASE=master;UID=sa',
              maxLines: 4,
              mono: true,
            ),
          ],
        ),
        FormGroup(
          title: 'Autenticazione',
          footer: 'Usata solo se la stringa non contiene già PWD.',
          children: [
            FormRow(label: 'Password', child: SecureField(controller: _password, hint: 'Facoltativa')),
            _savePasswordRow(),
          ],
        ),
      ];

  Widget _switchRow(String label, String? help, bool value, ValueChanged<bool> onChanged) => FormRow(
        label: label,
        help: help,
        child: DbSwitch(value: value, onChanged: onChanged),
      );

  Widget _savePasswordRow() => _switchRow(
        'Salva password',
        cfg.savePassword
            ? (widget.app.vault.usesMasterPassword ? 'Cifrata con la master password' : 'Cifrata nel vault del workspace')
            : 'Verrà chiesta a ogni connessione',
        cfg.savePassword,
        (v) => setState(() => cfg.savePassword = v),
      );

  Widget _authFields() {
    final methods = supportedAuthMethods(cfg);
    if (!methods.contains(cfg.authMethod)) cfg.authMethod = methods.first;
    final m = cfg.authMethod;
    final plain = m == AuthMethod.password;
    return FormGroup(
      title: 'Autenticazione',
      footer: plain ? null : m.description,
      children: [
        if (methods.length > 1)
          FormRow(
            label: 'Metodo',
            child: SelectField<AuthMethod>(
              value: m,
              items: [for (final x in methods) (x, x.label, null)],
              onChanged: (v) => setState(() {
                cfg.authMethod = v;
                _result = null;
              }),
            ),
          ),
        if (plain || m.usesUser)
          FormRow(label: 'Utente', child: _field(_user, m.isAzure ? 'utente@dominio.onmicrosoft.com' : 'Nome utente')),
        if (plain || m.usesPassword)
          FormRow(label: 'Password', child: SecureField(controller: _password, hint: 'Password')),
        for (final a in authParams(cfg, m)) _paramRow(a.key, a.label, a.hint, secret: a.secret, file: a.file, help: a.help),
        if (plain || m.usesPassword) _savePasswordRow(),
      ],
    );
  }

  /// A text row bound to an auth parameter / native option.
  Widget _paramRow(
    String key,
    String label,
    String hint, {
    bool secret = false,
    bool file = false,
    String? help,
    String initial = '',
    List<String> options = const [],
    bool multiline = false,
  }) {
    final ctrl = _param(key, initial: initial);
    if (options.isNotEmpty) {
      final value = options.contains(ctrl.text) ? ctrl.text : options.first;
      return FormRow(
        label: label,
        help: help,
        child: SelectField<String>(
          value: value,
          items: [for (final o in options) (o, o, null)],
          onChanged: (v) => ctrl.text = v,
        ),
      );
    }
    final Widget field;
    if (secret) {
      field = SecureField(controller: ctrl, hint: hint);
    } else if (file) {
      field = _pathField(ctrl, hint);
    } else {
      field = _field(ctrl, hint, maxLines: multiline ? 4 : 1);
    }
    return FormRow(label: label, help: help, child: field);
  }

  void _fixAuthMethod() {
    final methods = supportedAuthMethods(cfg);
    if (!methods.contains(cfg.authMethod)) cfg.authMethod = methods.first;
  }

  void _selectNative(NativeDriver d) {
    cfg.nativeDriver = d.id;
    // Replace the port when it is still a default of another driver.
    final defaults = {
      for (final x in nativeDrivers) x.defaultPort,
      for (final t in DriverTemplate.all) t.defaultPort,
    }..remove('');
    if (_port.text.isEmpty || defaults.contains(_port.text)) _port.text = d.defaultPort;
    if (_host.text.isEmpty && d.usesHost) _host.text = 'localhost';
    for (final f in d.fields) {
      if (f.defaultValue.isNotEmpty) _param(f.key, initial: f.defaultValue);
    }
  }

  List<Widget> _nativeGroups() {
    final d = nativeDriverById(cfg.nativeDriver);
    return [
      FormGroup(
        title: 'Connessione',
        footer: nativeDrivers.isEmpty
            ? 'Questa versione non include driver integrati: usa un driver ODBC.'
            : (d != null && d.usesUri ? 'Se indicato, l\'URI sostituisce host, porta, database e utente.' : null),
        children: [
          _modeRow(),
          if (nativeDrivers.isNotEmpty)
            FormRow(
              label: 'Driver',
              child: SelectField<String>(
                value: d?.id ?? nativeDrivers.first.id,
                items: [for (final x in nativeDrivers) (x.id, x.label, (x.icon, x.color))],
                onChanged: (id) => setState(() {
                  _selectNative(nativeDriverById(id)!);
                  _fixAuthMethod();
                  _result = null;
                }),
              ),
            ),
          if (d != null && d.usesUri) FormRow(label: 'URI', child: _field(_connStr, d.uriHint, mono: true)),
          if (d != null && d.usesHost) _hostRow(d.defaultPort),
          if (d != null && d.usesDatabase)
            FormRow(
              label: d.databaseLabel,
              child: _field(_database, d.databaseHint.isEmpty ? 'Facoltativo' : d.databaseHint),
            ),
        ],
      ),
      if (d != null && (d.usesUser || d.usesPassword || supportedAuthMethods(cfg).length > 1)) _authFields(),
      if (d != null && d.fields.isNotEmpty)
        FormGroup(
          title: 'Opzioni del driver',
          children: [
            for (final f in d.fields)
              _paramRow(
                f.key,
                f.label,
                f.hint,
                secret: f.secret,
                file: f.file,
                help: f.help,
                initial: f.defaultValue,
                options: f.options,
                multiline: f.multiline,
              ),
          ],
        ),
    ];
  }

  Widget _behaviourGroup() => FormGroup(
        title: 'Comportamento',
        children: [
          _switchRow(
            'Auto-commit',
            'Se spento, le modifiche restano in sospeso fino a Commit o Rollback',
            cfg.autoCommit,
            (v) => setState(() => cfg.autoCommit = v),
          ),
          _switchRow(
            'Sola lettura',
            'Blocca modifica, importazione ed eliminazione dei dati',
            cfg.readOnly,
            (v) => setState(() => cfg.readOnly = v),
          ),
        ],
      );

  Widget _advancedToggle() => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Align(
          alignment: Alignment.centerLeft,
          child: DisclosureButton(
            label: 'Avanzate',
            expanded: _showAdvanced,
            onChanged: (v) => setState(() => _showAdvanced = v),
          ),
        ),
      );

  List<Widget> _advancedGroups() {
    final c = DbColors.of(context);
    final preview = _collect().maskedConnectionString;
    Widget seconds(TextEditingController ctrl, String hint) =>
        NumberField(controller: ctrl, hint: hint, min: 0, max: 3600, unit: 'secondi');
    return [
      FormGroup(
        children: [
          FormRow(label: 'Descrizione', child: _field(_description, 'Facoltativa', maxLines: 2)),
          FormRow(label: 'Catalogo predefinito', child: _field(_defaultCatalog, 'Quello del login')),
          FormRow(label: 'Timeout di login', child: seconds(_loginTimeout, '15')),
          FormRow(label: 'Timeout query', help: '0 = nessun limite', child: seconds(_queryTimeout, '0')),
        ],
      ),
      if (cfg.mode != ConnectionMode.native)
        FormGroup(
          title: 'Parametri del driver',
          footer: 'Nel formato CHIAVE=valore, uno per riga o separati da punto e virgola, es. Encrypt=yes;TrustServerCertificate=yes',
          children: [_field(_extra, 'ApplicationIntent=ReadOnly', maxLines: 3, mono: true)],
        ),
      FormGroup(
        title: 'Query di inizializzazione',
        footer: 'Eseguite subito dopo ogni connessione, separate da punto e virgola.',
        children: [_field(_bootstrap, 'SET search_path TO public;', maxLines: 5, mono: true)],
      ),
      // A code box, not a form group: the string is read-only output.
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeBox(
            preview.isEmpty ? '—' : preview,
            label: 'Stringa risultante',
            copy: preview.isNotEmpty,
            wrap: true,
            color: c.textSecondary,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 6, bottom: Gap.lg),
            child: Text(
              'La password non viene mai mostrata né copiata.',
              style: uiText(TypeSize.caption, color: c.textSecondary, height: 1.3),
            ),
          ),
        ],
      ),
    ];
  }

  @override
  void dispose() {
    for (final c in [
      _name, _driver, _dsn, _host, _port, _database, _user, _password, _connStr, _extra, //
      _folder, _defaultCatalog, _loginTimeout, _queryTimeout, _bootstrap, _description,
      ..._params.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }
}
