// Driver Manager: registered ODBC drivers, DSNs and (macOS) driver install.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    showDialog<void>(context: context, builder: (_) => _DriverManagerDialog(page));

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
    return Dialog(
      insetPadding: const EdgeInsets.all(Gap.xl),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 780,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            Divider(height: 1, color: c.separator),
            Expanded(
              child: FutureBuilder(
                future: _data,
                builder: (context, snap) {
                  final data = snap.data ?? _last;
                  if (data == null) return const Center(child: CircularProgressIndicator());
                  _last = data;
                  // The install page stays mounted so a running install survives page switches.
                  return IndexedStack(
                    index: _page.index,
                    sizing: StackFit.expand,
                    children: [
                      _driversPage(data),
                      _dsnPage(data),
                      if (canInstallDrivers)
                        DriverInstallTab(drivers: data.drivers, onChanged: () => setState(() => _data = _load()))
                      else
                        const SizedBox.shrink(),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return SizedBox(
      height: 52,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: Gap.xl,
            child: Text('Driver ODBC', style: Theme.of(context).textTheme.titleLarge),
          ),
          Segmented<DriverManagerPage>(
            value: _page,
            items: [
              (DriverManagerPage.drivers, 'Driver', null),
              (DriverManagerPage.dsn, 'Data source', null),
              if (canInstallDrivers) (DriverManagerPage.install, 'Installa', null),
            ],
            onChanged: (p) => setState(() => _page = p),
          ),
          Positioned(
            right: Gap.md,
            child: ToolButton(icon: AppIcons.close, tooltip: 'Chiudi', onPressed: () => Navigator.pop(context)),
          ),
        ],
      ),
    );
  }

  Widget? _installAction() => canInstallDrivers
      ? PrimaryButton(
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
        TextButton(
          onPressed: () => showErrorDialog(context, error, title: 'Driver Manager ODBC non trovato'),
          child: const Text('Dettagli…'),
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
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.xl),
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
                  child: Text(
                    d.name,
                    style: TextStyle(fontSize: TypeSize.body, color: c.text),
                  ),
                ),
                Flexible(
                  child: Text(
                    d.driver,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
                  ),
                ),
              ],
            ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.xl),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                Icon(t.icon, size: 16, color: generic ? c.textTertiary : t.color),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.name,
                        style: TextStyle(fontSize: TypeSize.body, color: c.text),
                      ),
                      if (library.isNotEmpty)
                        Text(
                          library,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(context, size: 11, color: c.textSecondary),
                        ),
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  child: Icon(AppIcons.chevronRight, size: 16, color: c.textTertiary),
                ),
              ],
            ),
          ),
        ),
        if (_open && attrs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 24, top: Gap.sm),
            child: Column(
              children: [
                for (final e in attrs)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 140,
                          child: Text(
                            e.key,
                            style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            e.value,
                            style: TextStyle(fontSize: TypeSize.small, color: c.text, fontFeatures: kTabular),
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
    final c = DbColors.of(context);
    final where = issue.major == null ? 'non esiste' : 'ora punta a OpenSSL ${issue.major}';
    final fix = issue.needsRestart
        ? 'Installa openssl@3 e riavvia DbCraft: all\'avvio i driver vengono indirizzati su openssl@3, '
              'senza toccare Homebrew.'
        : 'Riporta il link a openssl@3 dal Terminale; gli altri pacchetti Homebrew non ne risentono.';
    return InlineNotice(
      color: c.warning,
      title: issue.major == null
          ? 'I driver SQL Server non trovano OpenSSL'
          : 'OpenSSL ${issue.major} non è supportato dai driver SQL Server',
      message:
          '${issue.drivers.join(', ')} carica OpenSSL da ${issue.linkPath}, che $where. Il driver supporta solo '
          'OpenSSL 1.x e 3.x, quindi le connessioni falliscono. $fix',
      child: Container(
        padding: const EdgeInsets.only(left: Gap.sm),
        decoration: BoxDecoration(
          color: c.content,
          borderRadius: BorderRadius.circular(Radii.control),
          border: Border.all(color: c.separator),
        ),
        child: Row(
          children: [
            Expanded(child: SelectableText(issue.fixCommand, style: monoStyle(context, size: 12))),
            ToolButton(
              icon: AppIcons.copy,
              tooltip: 'Copia comando',
              size: 14,
              onPressed: () => Clipboard.setData(ClipboardData(text: issue.fixCommand)),
            ),
          ],
        ),
      ),
    );
  }
}
