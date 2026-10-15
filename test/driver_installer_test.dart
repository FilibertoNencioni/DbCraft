import 'dart:io';

import 'package:dbcraft/odbc/driver_installer.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:flutter_test/flutter_test.dart';

final _mssql = driverCatalog.firstWhere((p) => p.id == 'mssql');
final _sqlite = driverCatalog.firstWhere((p) => p.id == 'sqlite');

/// Fake Homebrew prefix whose `brew install` logs its arguments and creates
/// the formula's library, and whose `odbcinst` appends stdin to odbcinst.ini.
Future<String> _fakeBrew({int brewExit = 0}) async {
  final root = (await Directory.systemTemp.createTemp('dbcraft_brew')).path;
  await Directory('$root/bin').create();
  await Directory('$root/etc').create();
  Future<void> script(String name, String body) async {
    await File('$root/bin/$name').writeAsString('#!/bin/sh\n$body\n');
    await Process.run('chmod', ['+x', '$root/bin/$name']);
  }

  await script('brew', '''
echo "brew \$* eula=\$HOMEBREW_ACCEPT_EULA"
echo "warning" >&2
for f in ${[for (final p in driverCatalog) p.library].map((l) => '"$root/$l"').join(' ')}; do
  mkdir -p "\$(dirname "\$f")" && touch "\$f"
done
exit $brewExit''');
  await script('odbcinst', 'cat >> "$root/etc/odbcinst.ini"; echo "odbcinst \$*"');
  return root;
}

void main() {
  test('isRegistered matches by name or by library file', () {
    expect(DriverInstaller.isRegistered(_sqlite, []), isFalse);
    expect(DriverInstaller.isRegistered(_sqlite, [const OdbcDriverInfo('SQLite3', {})]), isTrue);
    expect(
      DriverInstaller.isRegistered(_sqlite, [
        const OdbcDriverInfo('SQLite', {'Driver': '/opt/homebrew/lib/libsqlite3odbc-0.99991.dylib'}),
      ]),
      isTrue,
    );
    // Driver 17 is not Driver 18.
    expect(
      DriverInstaller.isRegistered(_mssql, [
        const OdbcDriverInfo('ODBC Driver 17 for SQL Server', {'Driver': '/opt/homebrew/lib/libmsodbcsql.17.dylib'}),
      ]),
      isFalse,
    );
  });

  test('finds Homebrew and reports driver status', () async {
    final root = await _fakeBrew();
    expect(await DriverInstaller.find(prefixes: ['$root/none']), isNull);
    final installer = (await DriverInstaller.find(prefixes: ['$root/none', root]))!;
    expect(installer.prefix, root);
    expect(await installer.status(_sqlite, []), DriverStatus.missing);

    await File(installer.libraryPath(_sqlite)).create(recursive: true);
    expect(await installer.status(_sqlite, []), DriverStatus.unregistered);
    expect(await installer.status(_sqlite, [const OdbcDriverInfo('SQLite3', {})]), DriverStatus.ready);
  });

  test('installs, streams output and registers the driver', () async {
    final root = await _fakeBrew();
    final installer = DriverInstaller(root);
    final log = <String>[];
    await installer.install(_sqlite, drivers: [], onLine: log.add);

    expect(log.first, r'$ brew install sqliteodbc');
    expect(log, containsAll(['brew install sqliteodbc eula=', 'warning', 'odbcinst -i -d -r']));
    final ini = await File('$root/etc/odbcinst.ini').readAsString();
    expect(ini, contains('[SQLite3]\n'));
    expect(ini, contains('Driver=$root/opt/sqliteodbc/lib/libsqlite3odbc.dylib\n'));
  });

  test('Microsoft driver needs the license accepted', () async {
    final root = await _fakeBrew();
    final installer = DriverInstaller(root);
    final log = <String>[];
    await expectLater(installer.install(_mssql, drivers: [], onLine: log.add), throwsA(isA<DriverInstallException>()));
    expect(log, isEmpty);

    await installer.install(_mssql, drivers: [], onLine: log.add, acceptEula: true);
    expect(log, contains('brew install openssl@3 microsoft/mssql-release/msodbcsql18 eula=Y'));
  });

  test('a failing brew stops before registering', () async {
    final root = await _fakeBrew(brewExit: 1);
    final installer = DriverInstaller(root);
    await expectLater(
      installer.install(_sqlite, drivers: [], onLine: (_) {}),
      throwsA(isA<DriverInstallException>().having((e) => e.message, 'message', contains('codice 1'))),
    );
    expect(await File('$root/etc/odbcinst.ini').exists(), isFalse);
  });

  test('cancel stops the running install', () async {
    final root = await _fakeBrew();
    await File('$root/bin/brew').writeAsString('#!/bin/sh\necho started\nexec sleep 30\n');
    final installer = DriverInstaller(root);
    final run = installer.install(
      _sqlite,
      drivers: [],
      onLine: (l) {
        if (l == 'started') installer.cancel();
      },
    );
    await expectLater(run, throwsA(isA<DriverInstallException>().having((e) => e.message, 'message', 'Annullato')));
  });
}
