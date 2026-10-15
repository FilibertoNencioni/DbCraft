import 'dart:io';

import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/odbc/openssl_check.dart';
import 'package:flutter_test/flutter_test.dart';

const _mssql = OdbcDriverInfo('ODBC Driver 18 for SQL Server', {'Driver': '/x/lib/libmsodbcsql.18.dylib'});
const _sqlite = OdbcDriverInfo('SQLite3', {'Driver': '/x/lib/libsqlite3odbc.dylib'});

/// Fake Homebrew prefix with openssl@3 / openssl@4 kegs and `opt/openssl`
/// pointing at [current].
Future<String> _brew(String? current, {bool withSsl3 = true}) async {
  final root = (await Directory.systemTemp.createTemp('dbcraft_brew')).path;
  for (final (keg, major) in [if (withSsl3) ('openssl@3', 3), ('openssl@4', 4)]) {
    final lib = await Directory('$root/Cellar/$keg/x/lib').create(recursive: true);
    await File('${lib.path}/libssl.$major.dylib').create();
    await Link('${lib.path}/libssl.dylib').create('libssl.$major.dylib');
    await Directory('$root/opt').create(recursive: true);
    await Link('$root/opt/$keg').create('$root/Cellar/$keg/x');
  }
  if (current != null) await Link('$root/opt/openssl').create('$root/opt/$current');
  return root;
}

void main() {
  test('flags openssl@4 when a SQL Server driver is registered', () async {
    final root = await _brew('openssl@4');
    final issue = await checkSqlServerOpenSsl(
      [_sqlite, _mssql],
      brewPrefixes: [root],
      isMacOS: true,
      environment: const {},
    );
    expect(issue, isNotNull);
    expect(issue!.major, 4);
    expect(issue.drivers, [_mssql.name]);
    expect(issue.fixCommand, 'ln -sfn $root/opt/openssl@3 $root/opt/openssl');
    expect(issue.needsRestart, isFalse);

    // Applying the suggested fix clears the warning.
    await Process.run('sh', ['-c', issue.fixCommand]);
    expect(await checkSqlServerOpenSsl([_mssql], brewPrefixes: [root], isMacOS: true, environment: const {}), isNull);
  });

  test('flags a missing opt/openssl link', () async {
    final root = await _brew(null);
    final issue = await checkSqlServerOpenSsl([_mssql], brewPrefixes: [root], isMacOS: true, environment: const {});
    expect(issue, isNotNull);
    expect(issue!.major, isNull);
    await Process.run('sh', ['-c', issue.fixCommand]);
    expect(await checkSqlServerOpenSsl([_mssql], brewPrefixes: [root], isMacOS: true, environment: const {}), isNull);
  });

  test('suggests installing openssl@3 when missing', () async {
    final root = await _brew('openssl@4', withSsl3: false);
    final issue = await checkSqlServerOpenSsl([_mssql], brewPrefixes: [root], isMacOS: true, environment: const {});
    expect(issue!.fixCommand, '$root/bin/brew install openssl@3');
    expect(issue.needsRestart, isTrue);
  });

  test('no warning when the launch-time redirect to openssl@3 is active', () async {
    final root = await _brew(null);
    final ssl3Lib = '$root/opt/openssl@3/lib';
    expect(
      await checkSqlServerOpenSsl(
        [_mssql],
        brewPrefixes: [root],
        isMacOS: true,
        environment: {openSslRedirectEnv: ssl3Lib},
      ),
      isNull,
    );
    // A stale marker pointing nowhere doesn't hide the issue.
    expect(
      await checkSqlServerOpenSsl(
        [_mssql],
        brewPrefixes: [root],
        isMacOS: true,
        environment: {openSslRedirectEnv: '$root/nope'},
      ),
      isNotNull,
    );
  });

  test('no warning without SQL Server drivers or off macOS', () async {
    final root = await _brew('openssl@4');
    expect(await checkSqlServerOpenSsl([_sqlite], brewPrefixes: [root], isMacOS: true, environment: const {}), isNull);
    expect(await checkSqlServerOpenSsl([_mssql], brewPrefixes: [root], isMacOS: false, environment: const {}), isNull);
  });
}
