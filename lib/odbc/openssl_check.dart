// Detects a Homebrew setup that breaks Microsoft's SQL Server ODBC drivers.
//
// msodbcsql17/18 are not linked against OpenSSL: they dlopen it at TLS time
// from Homebrew's unversioned `opt/openssl` link, and only support OpenSSL
// 1.0, 1.1 and 3.x. When Homebrew drops that link or moves it to a newer
// major (e.g. openssl@4) the driver fails or crashes as soon as it opens a
// connection. On macOS the app relaunches itself with DYLD_LIBRARY_PATH set to
// openssl@3 in that case (see macos/Runner/AppDelegate.swift), so an issue is
// only reported when that redirect couldn't be applied.
import 'dart:io';

import 'odbc_types.dart';

const _brewPrefixes = ['/opt/homebrew', '/usr/local'];

/// Environment variable set by the macOS runner to the openssl@3 lib directory
/// the SQL Server drivers are redirected to.
const openSslRedirectEnv = 'DBCRAFT_OPENSSL_LIB';

class OpenSslIssue {
  const OpenSslIssue({
    required this.linkPath,
    required this.major,
    required this.drivers,
    required this.fixCommand,
    this.needsRestart = false,
  });

  /// The `opt/openssl` link the driver loads OpenSSL from.
  final String linkPath;

  /// OpenSSL major version the link currently resolves to, or null when the
  /// link is missing and the driver can't find OpenSSL at all.
  final int? major;

  /// Names of the affected SQL Server drivers.
  final List<String> drivers;

  /// Shell command that fixes the setup.
  final String fixCommand;

  /// Whether [fixCommand] installs openssl@3, after which restarting the app
  /// is enough: the launch-time redirect takes over.
  final bool needsRestart;
}

/// Returns an [OpenSslIssue] when a SQL Server ODBC driver is registered and
/// Homebrew's `opt/openssl` is missing or resolves to an OpenSSL major the
/// driver can't load.
Future<OpenSslIssue?> checkSqlServerOpenSsl(
  List<OdbcDriverInfo> drivers, {
  List<String> brewPrefixes = _brewPrefixes,
  bool? isMacOS,
  Map<String, String>? environment,
}) async {
  if (!(isMacOS ?? Platform.isMacOS)) return null;
  final redirect = (environment ?? Platform.environment)[openSslRedirectEnv];
  if (redirect != null && await File('$redirect/libssl.3.dylib').exists()) return null;
  final paths = {
    for (final d in drivers)
      if ((d.attributes['Driver'] ?? '').contains('msodbcsql')) d.name: d.attributes['Driver']!,
  };
  if (paths.isEmpty) return null;

  // Check the Homebrew the driver was installed from; fall back to any
  // Homebrew present when the driver path doesn't tell.
  var prefixes = [
    for (final p in brewPrefixes)
      if (paths.values.any((d) => d.startsWith('$p/'))) p,
  ];
  if (prefixes.isEmpty) {
    prefixes = [
      for (final p in brewPrefixes)
        if (await Directory('$p/opt').exists()) p,
    ];
  }

  for (final prefix in prefixes) {
    final link = '$prefix/opt/openssl';
    final libssl = File('$link/lib/libssl.dylib');
    int? major;
    if (await libssl.exists()) {
      final real = await libssl.resolveSymbolicLinks();
      final m = RegExp(r'libssl\.(\d+)').firstMatch(real.split('/').last);
      if (m == null) continue;
      major = int.parse(m.group(1)!);
      if (major <= 3) continue;
    }

    // With openssl@3 installed the relaunch redirect normally applies; the
    // link is the fallback for when it didn't (e.g. driver outside Homebrew).
    final ssl3 = '$prefix/opt/openssl@3';
    final hasSsl3 = await Directory(ssl3).exists();
    return OpenSslIssue(
      linkPath: link,
      major: major,
      drivers: paths.keys.toList(),
      fixCommand: hasSsl3 ? 'ln -sfn $ssl3 $link' : '$prefix/bin/brew install openssl@3',
      needsRestart: !hasSsl3,
    );
  }
  return null;
}
