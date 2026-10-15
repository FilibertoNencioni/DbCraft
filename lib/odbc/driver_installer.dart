// Installs ODBC drivers through Homebrew (macOS) and registers them in
// unixODBC's odbcinst.ini so they show up as named drivers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'odbc_types.dart';

const _brewPrefixes = ['/opt/homebrew', '/usr/local'];

/// A driver from the install catalog.
class DriverPackage {
  const DriverPackage({
    required this.id,
    required this.label,
    required this.description,
    required this.formulae,
    required this.driverName,
    required this.library,
    this.eulaUrl,
  });

  final String id;
  final String label;
  final String description;

  /// Homebrew formulae installed together, in order.
  final List<String> formulae;

  /// Name the driver is registered under in odbcinst.ini.
  final String driverName;

  /// Driver library, relative to the Homebrew prefix. Uses the `opt/` link so
  /// the registration survives `brew upgrade`.
  final String library;

  /// License the user must accept before installing (passed to the formula
  /// as HOMEBREW_ACCEPT_EULA).
  final String? eulaUrl;
}

const driverCatalog = [
  DriverPackage(
    id: 'mssql',
    label: 'Microsoft SQL Server',
    description: 'ODBC Driver 18 for SQL Server di Microsoft, con openssl@3 richiesto dal driver.',
    formulae: ['openssl@3', 'microsoft/mssql-release/msodbcsql18'],
    driverName: 'ODBC Driver 18 for SQL Server',
    library: 'opt/msodbcsql18/lib/libmsodbcsql.18.dylib',
    eulaUrl: 'https://aka.ms/odbc18eula',
  ),
  DriverPackage(
    id: 'postgres',
    label: 'PostgreSQL',
    description: 'psqlODBC, il driver ufficiale di PostgreSQL (Unicode).',
    formulae: ['psqlodbc'],
    driverName: 'PostgreSQL Unicode',
    library: 'opt/psqlodbc/lib/psqlodbcw.so',
  ),
  DriverPackage(
    id: 'mariadb',
    label: 'MariaDB / MySQL',
    description: 'MariaDB Connector/ODBC, compatibile anche con MySQL.',
    formulae: ['mariadb-connector-odbc'],
    driverName: 'MariaDB ODBC Driver',
    library: 'opt/mariadb-connector-odbc/lib/mariadb/libmaodbc.dylib',
  ),
  DriverPackage(
    id: 'sqlite',
    label: 'SQLite',
    description: 'SQLite ODBC driver di Christian Werner.',
    formulae: ['sqliteodbc'],
    driverName: 'SQLite3',
    library: 'opt/sqliteodbc/lib/libsqlite3odbc.dylib',
  ),
];

enum DriverStatus {
  /// The driver library isn't installed.
  missing,

  /// Installed but not in odbcinst.ini.
  unregistered,

  ready,
}

class DriverInstallException implements Exception {
  DriverInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Runs Homebrew for one Homebrew installation.
class DriverInstaller {
  DriverInstaller(this.prefix);

  /// The Homebrew installation in use, or null when Homebrew isn't installed.
  static Future<DriverInstaller?> find({List<String> prefixes = _brewPrefixes}) async {
    for (final prefix in prefixes) {
      if (await File('$prefix/bin/brew').exists()) return DriverInstaller(prefix);
    }
    return null;
  }

  final String prefix;
  Process? _process;
  bool _cancelled = false;

  String get brew => '$prefix/bin/brew';

  String libraryPath(DriverPackage pkg) => '$prefix/${pkg.library}';

  /// Whether [pkg] is installed and registered among [drivers].
  Future<DriverStatus> status(DriverPackage pkg, List<OdbcDriverInfo> drivers) async {
    if (!await File(libraryPath(pkg)).exists()) return DriverStatus.missing;
    return isRegistered(pkg, drivers) ? DriverStatus.ready : DriverStatus.unregistered;
  }

  /// Registered under its name, or under any name pointing at the same
  /// library (e.g. `/opt/homebrew/lib/libsqlite3odbc-0.99991.dylib`).
  static bool isRegistered(DriverPackage pkg, List<OdbcDriverInfo> drivers) {
    final stem = p.basenameWithoutExtension(pkg.library);
    return drivers.any((d) => d.name == pkg.driverName || p.basename(d.attributes['Driver'] ?? '').startsWith(stem));
  }

  /// odbcinst.ini section for [pkg].
  String registration(DriverPackage pkg) =>
      '[${pkg.driverName}]\nDescription=${pkg.description}\nDriver=${libraryPath(pkg)}\n';

  /// Installs [pkg] with Homebrew and registers it unless [drivers] already
  /// has it. Output goes to [onLine]; throws [DriverInstallException] when a
  /// step fails or [cancel] is called.
  Future<void> install(
    DriverPackage pkg, {
    required List<OdbcDriverInfo> drivers,
    required void Function(String line) onLine,
    bool acceptEula = false,
  }) async {
    if (pkg.eulaUrl != null && !acceptEula) {
      throw DriverInstallException('Per installare ${pkg.label} devi accettare la licenza (${pkg.eulaUrl}).');
    }
    _cancelled = false;
    await _run(brew, ['install', ...pkg.formulae], onLine, env: {if (pkg.eulaUrl != null) 'HOMEBREW_ACCEPT_EULA': 'Y'});
    if (!await File(libraryPath(pkg)).exists()) {
      throw DriverInstallException('Installazione completata ma ${libraryPath(pkg)} non esiste.');
    }
    // Formulae like msodbcsql18 register themselves.
    if (!isRegistered(pkg, drivers) && !await _registeredInIni(pkg)) await register(pkg, onLine: onLine);
  }

  /// Adds [pkg] to odbcinst.ini with unixODBC's `odbcinst`.
  Future<void> register(DriverPackage pkg, {required void Function(String line) onLine}) async {
    _cancelled = false;
    await _run('$prefix/bin/odbcinst', ['-i', '-d', '-r'], onLine, stdin: registration(pkg));
  }

  /// Stops the running step; [install] then throws.
  void cancel() {
    _cancelled = true;
    _process?.kill();
  }

  Future<bool> _registeredInIni(DriverPackage pkg) async {
    final ini = File('$prefix/etc/odbcinst.ini');
    return await ini.exists() && (await ini.readAsString()).contains('[${pkg.driverName}]');
  }

  Future<void> _run(
    String exe,
    List<String> args,
    void Function(String line) onLine, {
    Map<String, String> env = const {},
    String? stdin,
  }) async {
    if (_cancelled) throw DriverInstallException('Annullato');
    onLine('\$ ${[p.basename(exe), ...args].join(' ')}');
    final Process proc;
    try {
      proc = await Process.start(
        exe,
        args,
        environment: {
          // Apps started from Finder get a minimal PATH.
          'PATH': '$prefix/bin:$prefix/sbin:${Platform.environment['PATH'] ?? '/usr/bin:/bin:/usr/sbin:/sbin'}',
          'NONINTERACTIVE': '1',
          'HOMEBREW_NO_COLOR': '1',
          'HOMEBREW_NO_EMOJI': '1',
          'HOMEBREW_NO_ENV_HINTS': '1',
          ...env,
        },
      );
    } on ProcessException catch (e) {
      throw DriverInstallException('Impossibile avviare $exe: ${e.message}');
    }
    _process = proc;
    if (stdin != null) proc.stdin.write(stdin);
    await proc.stdin.close();
    // Homebrew redraws progress bars with \r: LineSplitter splits on it too.
    final decoder = const Utf8Decoder(allowMalformed: true);
    final output = Future.wait([
      for (final s in [proc.stdout, proc.stderr])
        s.transform(decoder).transform(const LineSplitter()).where((l) => l.trim().isNotEmpty).forEach(onLine),
    ]);
    final code = await proc.exitCode;
    _process = null;
    // Children left behind by a killed brew (curl, …) may keep the pipes open.
    await output.timeout(const Duration(seconds: 2), onTimeout: () => const []);
    if (_cancelled) throw DriverInstallException('Annullato');
    if (code != 0) throw DriverInstallException('${p.basename(exe)} ${args.first} non riuscito (codice $code)');
  }
}
