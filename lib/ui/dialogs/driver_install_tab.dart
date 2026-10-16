// "Installa driver" tab of the Driver Manager: installs ODBC drivers with
// Homebrew and shows its output live.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/connection_config.dart';
import '../../odbc/driver_installer.dart';
import '../../odbc/odbc_types.dart';
import '../../odbc/openssl_check.dart';
import '../widgets/common.dart';

class DriverInstallTab extends StatefulWidget {
  const DriverInstallTab({
    super.key,
    required this.drivers,
    required this.onChanged,
    this.findInstaller = DriverInstaller.find,
  });

  /// Drivers currently registered in odbcinst.ini.
  final List<OdbcDriverInfo> drivers;

  /// Called after an install so the Driver Manager reloads its lists.
  final VoidCallback onChanged;

  /// Locates Homebrew; replaceable in tests.
  final Future<DriverInstaller?> Function() findInstaller;

  @override
  State<DriverInstallTab> createState() => _DriverInstallTabState();
}

class _DriverInstallTabState extends State<DriverInstallTab> {
  static const _maxLogLines = 2000;

  late final Future<DriverInstaller?> _installer = widget.findInstaller();
  late Future<Map<String, DriverStatus>> _statuses = _loadStatuses();
  final _log = <String>[];
  final _logScroll = ScrollController();
  DriverInstaller? _active;
  DriverPackage? _running;
  (bool ok, String message)? _result;

  Future<Map<String, DriverStatus>> _loadStatuses() async {
    final installer = await _installer;
    if (installer == null) return const {};
    return {for (final pkg in driverCatalog) pkg.id: await installer.status(pkg, widget.drivers)};
  }

  @override
  void didUpdateWidget(DriverInstallTab old) {
    super.didUpdateWidget(old);
    if (old.drivers != widget.drivers) _statuses = _loadStatuses();
  }

  @override
  void dispose() {
    // Closing the Driver Manager stops a running install.
    _active?.cancel();
    _logScroll.dispose();
    super.dispose();
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _log.add(line);
      if (_log.length > _maxLogLines) _log.removeRange(0, _log.length - _maxLogLines);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  Future<void> _install(DriverInstaller installer, DriverPackage pkg, DriverStatus status) async {
    if (status == DriverStatus.missing && pkg.eulaUrl != null && !await _confirmEula(pkg)) return;
    setState(() {
      _active = installer;
      _running = pkg;
      _result = null;
      _log.clear();
    });
    try {
      if (status == DriverStatus.missing) {
        await installer.install(pkg, drivers: widget.drivers, onLine: _append, acceptEula: pkg.eulaUrl != null);
      } else {
        await installer.register(pkg, onLine: _append);
      }
      // A SQL Server driver installed while the app runs only gets the
      // openssl@3 redirect at the next launch.
      final sslIssue = pkg.id == 'mssql'
          ? await checkSqlServerOpenSsl([
              OdbcDriverInfo(pkg.driverName, {'Driver': installer.libraryPath(pkg)}),
            ])
          : null;
      _result = (
        true,
        sslIssue == null
            ? '${pkg.label} è pronto: lo trovi tra i driver nella finestra di connessione.'
            : '${pkg.label} è installato. Riavvia DbCraft prima di connetterti: all\'avvio il driver '
                  'viene indirizzato su openssl@3.',
      );
    } catch (e) {
      _result = (false, '$e');
    } finally {
      _active = null;
      if (mounted) {
        setState(() {
          _running = null;
          _statuses = _loadStatuses();
        });
        widget.onChanged();
      }
    }
  }

  Future<bool> _confirmEula(DriverPackage pkg) async {
    var accepted = false;
    final ok = await showSheet<bool>(
      context,
      size: SheetSize.small,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final c = DbColors.of(context);
          void accept() => Navigator.pop(context, true);
          return SheetScaffold(
            title: 'Licenza Microsoft',
            onSubmit: accepted ? accept : null,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${pkg.driverName} è distribuito da Microsoft con una propria licenza: per installarlo '
                  'devi accettarne i termini.',
                  style: uiText(TypeSize.body, color: c.textSecondary, height: 1.4),
                ),
                const SizedBox(height: Gap.md),
                Row(
                  children: [
                    Expanded(
                      child: CheckboxRow(
                        label: 'Ho letto e accetto i termini di licenza',
                        value: accepted,
                        onChanged: (v) => setSheetState(() => accepted = v),
                      ),
                    ),
                    LinkButton(
                      label: 'Leggi la licenza',
                      tooltip: pkg.eulaUrl!,
                      onPressed: () => Process.run('open', [pkg.eulaUrl!]),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context, false)),
              PushButton.primary(label: 'Accetta e installa', onPressed: accepted ? accept : null),
            ],
          );
        },
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _installer,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: Spinner(size: Spinner.large));
        final installer = snap.data;
        if (installer == null) return _noHomebrew();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: FutureBuilder(
                future: _statuses,
                builder: (context, snap) {
                  final statuses = snap.data;
                  if (statuses == null) return const Center(child: Spinner(size: Spinner.large));
                  return ListView(
                    padding: const EdgeInsets.symmetric(vertical: Gap.lg),
                    children: [
                      FormGroup(
                        footer:
                            'Installati con Homebrew in ${installer.prefix} e registrati in odbcinst.ini: '
                            'compaiono subito tra i driver della connessione.',
                        children: [for (final pkg in driverCatalog) _row(installer, pkg, statuses[pkg.id]!)],
                      ),
                    ],
                  );
                },
              ),
            ),
            if (_log.isNotEmpty || _result != null) ...[const SizedBox(height: Gap.sm), _logPanel()],
          ],
        );
      },
    );
  }

  Widget _row(DriverInstaller installer, DriverPackage pkg, DriverStatus status) {
    final c = DbColors.of(context);
    final template = DriverTemplate.forDriver(pkg.driverName);
    final busy = _running != null;
    void run() => _install(installer, pkg, status);
    final Widget trailing;
    if (_running == pkg) {
      trailing = const Spinner(size: Spinner.small);
    } else {
      trailing = switch (status) {
        DriverStatus.ready => const StatusLine('Installato', kind: StatusKind.success),
        DriverStatus.unregistered => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tag('Non registrato', color: c.warning),
            const SizedBox(width: Gap.sm),
            PushButton(
              label: 'Registra',
              size: ControlScale.small,
              tooltip: 'Aggiunge ${pkg.driverName} a odbcinst.ini',
              onPressed: busy ? null : run,
            ),
          ],
        ),
        DriverStatus.missing => PushButton(label: 'Installa', size: ControlScale.small, onPressed: busy ? null : run),
      };
    }
    return ListRow(
      title: pkg.label,
      subtitle: pkg.description,
      icon: template.icon,
      iconColor: template.color,
      tooltip: 'brew install ${pkg.formulae.join(' ')}',
      trailing: trailing,
    );
  }

  Widget _logPanel() {
    final c = DbColors.of(context);
    final result = _result;
    final running = _running != null;
    return Container(
      height: 210,
      decoration: BoxDecoration(
        color: c.codeBackground,
        border: Border.all(color: c.separator, width: 0.5),
        borderRadius: BorderRadius.circular(Radii.menu),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(
            title: 'Output di Homebrew',
            actions: [
              ToolButton(
                icon: AppIcons.copy,
                tooltip: 'Copia log',
                extent: 18,
                onPressed: () => Clipboard.setData(ClipboardData(text: _log.join('\n'))),
              ),
              if (!running)
                ToolButton(
                  icon: AppIcons.close,
                  tooltip: 'Chiudi log',
                  extent: 18,
                  onPressed: () => setState(() {
                    _log.clear();
                    _result = null;
                  }),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.xs),
            child: Row(
              children: [
                Expanded(
                  child: running
                      ? StatusLine.busy('Installazione di ${_running!.label}…')
                      : StatusLine(
                          result?.$2 ?? '',
                          kind: result == null ? StatusKind.info : (result.$1 ? StatusKind.success : StatusKind.danger),
                          selectable: result != null && !result.$1,
                        ),
                ),
                if (running)
                  PushButton(
                    label: 'Interrompi',
                    kind: PushButtonKind.destructive,
                    size: ControlScale.small,
                    tooltip: 'Interrompi l\'installazione',
                    onPressed: () => _active?.cancel(),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                controller: _logScroll,
                padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
                itemCount: _log.length,
                itemBuilder: (context, i) {
                  final command = _log[i].startsWith(r'$ ');
                  return Text(
                    _log[i],
                    style: monoStyle(
                      context,
                      size: TypeSize.monoSmall,
                      color: command ? c.text : c.textSecondary,
                    ).copyWith(fontWeight: command ? FontWeight.w600 : null, height: 1.45),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _noHomebrew() => EmptyState(
    icon: AppIcons.download,
    title: 'Serve Homebrew',
    message: 'I driver si installano con Homebrew. Installalo seguendo le istruzioni su brew.sh, poi riapri questa finestra.',
    action: PushButton.primary(
      label: 'Apri brew.sh',
      icon: AppIcons.openExternal,
      onPressed: () => Process.run('open', ['https://brew.sh']),
    ),
  );
}
