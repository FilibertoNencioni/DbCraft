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
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final c = DbColors.of(context);
          void toggle() => setDialogState(() => accepted = !accepted);
          return AlertDialog(
            title: const Text('Licenza Microsoft'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${pkg.driverName} è distribuito da Microsoft con una propria licenza: per installarlo '
                    'devi accettarne i termini.',
                    style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary, height: 1.4),
                  ),
                  const SizedBox(height: Gap.md),
                  FormGroup(
                    children: [
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: toggle,
                          child: Row(
                            children: [
                              Checkbox(value: accepted, onChanged: (_) => toggle()),
                              const SizedBox(width: Gap.xs),
                              Expanded(
                                child: Text(
                                  'Ho letto e accetto i termini di licenza',
                                  style: TextStyle(fontSize: TypeSize.body, color: c.text),
                                ),
                              ),
                              ToolButton(
                                icon: AppIcons.openExternal,
                                label: 'Leggi',
                                tooltip: pkg.eulaUrl!,
                                size: 14,
                                onPressed: () => Process.run('open', [pkg.eulaUrl!]),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
              FilledButton(
                onPressed: accepted ? () => Navigator.pop(context, true) : null,
                child: const Text('Accetta e installa'),
              ),
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
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
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
                  if (statuses == null) return const Center(child: CircularProgressIndicator());
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.xl),
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
            if (_log.isNotEmpty || _result != null) _logPanel(),
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
      trailing = const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5));
    } else {
      trailing = switch (status) {
        DriverStatus.ready => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.check, size: 15, color: c.success),
            const SizedBox(width: 4),
            Text(
              'Installato',
              style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
            ),
          ],
        ),
        DriverStatus.unregistered => Tooltip(
          message: 'Aggiunge ${pkg.driverName} a odbcinst.ini',
          child: OutlinedButton(onPressed: busy ? null : run, child: const Text('Registra')),
        ),
        DriverStatus.missing => OutlinedButton(onPressed: busy ? null : run, child: const Text('Installa')),
      };
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(template.icon, size: 16, color: template.color),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      pkg.label,
                      style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w500, color: c.text),
                    ),
                    if (status == DriverStatus.unregistered) ...[
                      const SizedBox(width: Gap.sm),
                      Badge2('Non registrato', color: c.warning),
                    ],
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  pkg.description,
                  style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  'brew install ${pkg.formulae.join(' ')}',
                  style: monoStyle(context, size: 11, color: c.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: Gap.md),
          SizedBox(height: 28, child: Center(child: trailing)),
        ],
      ),
    );
  }

  Widget _logPanel() {
    final c = DbColors.of(context);
    final result = _result;
    final running = _running != null;
    return Container(
      height: 210,
      decoration: BoxDecoration(
        color: c.content,
        border: Border(top: BorderSide(color: c.separator)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.only(left: Gap.lg, right: Gap.sm),
            color: c.chrome,
            child: Row(
              children: [
                if (running)
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                else if (result != null)
                  Icon(
                    result.$1 ? AppIcons.checkCircleFill : AppIcons.errorFill,
                    size: 15,
                    color: result.$1 ? c.success : c.danger,
                  ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    running ? 'Installazione di ${_running!.label}…' : result?.$2 ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TypeSize.small,
                      fontWeight: FontWeight.w500,
                      color: result != null && !result.$1 ? c.danger : c.text,
                    ),
                  ),
                ),
                ToolButton(
                  icon: AppIcons.copy,
                  tooltip: 'Copia log',
                  size: 14,
                  onPressed: () => Clipboard.setData(ClipboardData(text: _log.join('\n'))),
                ),
                if (running)
                  ToolButton(
                    icon: AppIcons.stop,
                    label: 'Interrompi',
                    tooltip: 'Interrompi l\'installazione',
                    color: c.danger,
                    onPressed: () => _active?.cancel(),
                  )
                else
                  ToolButton(
                    icon: AppIcons.close,
                    tooltip: 'Chiudi log',
                    size: 14,
                    onPressed: () => setState(() {
                      _log.clear();
                      _result = null;
                    }),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: c.separator),
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                controller: _logScroll,
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
                itemCount: _log.length,
                itemBuilder: (context, i) {
                  final command = _log[i].startsWith(r'$ ');
                  return Text(
                    _log[i],
                    style: monoStyle(
                      context,
                      size: 11.5,
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
    action: PrimaryButton(
      label: 'Apri brew.sh',
      icon: AppIcons.openExternal,
      onPressed: () => Process.run('open', ['https://brew.sh']),
    ),
  );
}
