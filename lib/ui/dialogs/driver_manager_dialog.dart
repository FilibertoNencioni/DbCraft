// Driver Manager: registered ODBC drivers, DSNs and (macOS) driver install.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../model/connection_config.dart';
import '../../odbc/odbc_session.dart';
import '../../odbc/odbc_types.dart';
import '../../odbc/openssl_check.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import 'driver_install_tab.dart';

enum DriverManagerPage { drivers, dsn, install }

/// Drivers are installed with Homebrew: macOS only.
final bool canInstallDrivers = Platform.isMacOS;

Future<void> showDriverManagerDialog(BuildContext context, {DriverManagerPage page = DriverManagerPage.drivers}) =>
    showSheet<void>(context, size: SheetSize.large, builder: (_) => _DriverManagerDialog(page));

typedef _DriverData = ({
  List<OdbcDriverInfo> drivers,
  List<OdbcDataSource> dsns,
  OpenSslIssue? sslIssue,
  Object? error,
});

class _DriverManagerDialog extends StatefulWidget {
  const _DriverManagerDialog(this.initialPage);
  final DriverManagerPage initialPage;

  @override
  State<_DriverManagerDialog> createState() => _DriverManagerDialogState();
}

class _DriverManagerDialogState extends State<_DriverManagerDialog> {
  late DriverManagerPage _page = canInstallDrivers || widget.initialPage != DriverManagerPage.install
      ? widget.initialPage
      : DriverManagerPage.drivers;
  late Future<_DriverData> _data = _load();

  /// Last loaded data, kept on screen while a reload runs.
  _DriverData? _last;

  Future<_DriverData> _load() async {
    final lib = AppScope.read(context).settings.libPathOrNull;
    try {
      final drivers = await odbcDrivers(lib);
      return (
        drivers: drivers,
        dsns: await odbcDataSources(lib),
        sslIssue: await checkSqlServerOpenSsl(drivers),
        error: null,
      );
    } catch (e) {
      // The install page still works: installing a driver also installs unixODBC.
      return (drivers: const <OdbcDriverInfo>[], dsns: const <OdbcDataSource>[], sslIssue: null, error: e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return SheetScaffold(
      title: 'Driver ODBC',
      onSubmit: () => Navigator.pop(context),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageSwitcher<DriverManagerPage>(
            value: _page,
            background: c.windowBackground,
            items: [
              (DriverManagerPage.drivers, 'Driver', null),
              (DriverManagerPage.dsn, 'Data source', null),
              if (canInstallDrivers) (DriverManagerPage.install, 'Installa', null),
            ],
            onChanged: (p) => setState(() => _page = p),
          ),
          Expanded(
            child: FutureBuilder(
              future: _data,
              builder: (context, snap) {
                final data = snap.data ?? _last;
                if (data == null) return const Center(child: Spinner(size: Spinner.large));
                _last = data;
                // The install page stays mounted so a running install survives page switches.
                return IndexedStack(
                  index: _page.index,
                  sizing: StackFit.expand,
                  children: [
                    _driversPage(data),
                    _dsnPage(data),
                    if (canInstallDrivers)
                      DriverInstallTab(
                        drivers: data.drivers,
                        onChanged: () => setState(() {
                          _data = _load();
                        }),
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      actions: [PushButton.primary(label: 'Fine', onPressed: () => Navigator.pop(context))],
    );
  }

  Widget? _installAction() => canInstallDrivers
      ? PushButton.primary(
          label: 'Installa un driver',
          icon: AppIcons.download,
          onPressed: () => setState(() => _page = DriverManagerPage.install),
        )
      : null;

  Widget _loadError(Object error) => EmptyState(
    icon: AppIcons.plug,
    title: 'Driver Manager ODBC non trovato',
    message: canInstallDrivers
        ? 'Serve unixODBC: viene installato insieme a qualunque driver.'
        : 'Installa unixODBC o indica la libreria in Preferenze › ODBC.',
    action: Column(
      children: [
        ?_installAction(),
        const SizedBox(height: Gap.sm),
        LinkButton(
          label: 'Dettagli…',
          onPressed: () => showErrorDialog(context, error, title: 'Driver Manager ODBC non trovato'),
        ),
      ],
    ),
  );

  Widget _driversPage(_DriverData data) {
    if (data.error case final Object e) return _loadError(e);
    if (data.drivers.isEmpty) {
      return EmptyState(
        icon: AppIcons.memory,
        title: 'Nessun driver registrato',
        message: canInstallDrivers
            ? 'Installa il driver del tuo database: pochi secondi con Homebrew.'
            : 'Installa il driver ODBC del tuo database: comparirà qui.',
        action: _installAction(),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: Gap.lg),
      children: [
        if (data.sslIssue case final OpenSslIssue issue) _OpenSslNotice(issue),
        FormGroup(
          footer: 'Registrati in odbcinst.ini. Il nome è quello da usare nelle connessioni e nei DSN.',
          children: [for (final d in data.drivers) _DriverRow(d)],
        ),
      ],
    );
  }

  Widget _dsnPage(_DriverData data) {
    if (data.error case final Object e) return _loadError(e);
    if (data.dsns.isEmpty) {
      return const EmptyState(
        icon: AppIcons.server,
        title: 'Nessun DSN configurato',
        message:
            'I DSN si definiscono in odbc.ini. Non sono necessari: una connessione può usare direttamente il driver.',
      );
    }
    final c = DbColors.of(context);
    Widget group(String title, bool system) {
      final items = [
        for (final d in data.dsns)
          if (d.system == system) d,
      ];
      if (items.isEmpty) return const SizedBox.shrink();
      return FormGroup(
        title: title,
        children: [
          for (final d in items)
            Row(
              children: [
                Icon(
                  DriverTemplate.forDriver(d.driver).icon,
                  size: 16,
                  color: DriverTemplate.forDriver(d.driver).color,
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(d.name, style: uiText(TypeSize.body, color: c.text)),
                ),
                Flexible(
                  child: Text(
                    d.driver,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(TypeSize.small, color: c.textSecondary),
                  ),
                ),
              ],
            ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: Gap.lg),
      children: [group('DSN utente', false), group('DSN di sistema', true)],
    );
  }
}

/// A registered driver; the disclosure shows its odbcinst.ini attributes.
class _DriverRow extends StatefulWidget {
  const _DriverRow(this.driver);
  final OdbcDriverInfo driver;

  @override
  State<_DriverRow> createState() => _DriverRowState();
}

class _DriverRowState extends State<_DriverRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final d = widget.driver;
    final t = DriverTemplate.forDriver(d.name);
    final generic = t == DriverTemplate.generic;
    final library = d.attributes['Driver'] ?? '';
    final attrs = [
      for (final e in d.attributes.entries)
        if (e.key != 'Driver') e,
    ];
    final keyWidth = measureLabelWidth(context, [for (final e in attrs) (e.key, TypeSize.small)], max: 200);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: DisclosureButton(
            label: d.name,
            icon: t.icon,
            iconColor: generic ? c.textTertiary : t.color,
            subtitle: library.isEmpty ? null : library,
            monoSubtitle: true,
            expanded: _open,
            onChanged: attrs.isEmpty ? null : (v) => setState(() => _open = v),
          ),
        ),
        if (_open && attrs.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(left: DisclosureButton.contentIndent(icon: true), top: Gap.sm),
            child: Column(
              children: [
                for (final e in attrs)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: keyWidth,
                          child: Text(e.key, style: uiText(TypeSize.small, color: c.textSecondary)),
                        ),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: SelectableText(
                            e.value,
                            style: uiText(TypeSize.small, color: c.text, features: kTabular),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _OpenSslNotice extends StatelessWidget {
  const _OpenSslNotice(this.issue);
  final OpenSslIssue issue;

  @override
  Widget build(BuildContext context) {
    final where = issue.major == null ? 'non esiste' : 'ora punta a OpenSSL ${issue.major}';
    final fix = issue.needsRestart
        ? 'Installa openssl@3 e riavvia DbCraft: all\'avvio i driver vengono indirizzati su openssl@3, '
              'senza toccare Homebrew.'
        : 'Riporta il link a openssl@3 dal Terminale; gli altri pacchetti Homebrew non ne risentono.';
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: Notice(
        title: issue.major == null
            ? 'I driver SQL Server non trovano OpenSSL'
            : 'OpenSSL ${issue.major} non è supportato dai driver SQL Server',
        message:
            '${issue.drivers.join(', ')} carica OpenSSL da ${issue.linkPath}, che $where. Il driver supporta solo '
            'OpenSSL 1.x e 3.x, quindi le connessioni falliscono. $fix',
        child: CodeBox(issue.fixCommand, label: 'Terminale'),
      ),
    );
  }
}
