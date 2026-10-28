// CON-13: Driver Manager lists and the Homebrew installer, driven through the
// UI. Installs psqlODBC and MariaDB Connector/ODBC and registers SQLite3.
//
//   flutter test integration_test/matrix/driver_install_test.dart -d macos --dart-define=TARGET=drivers
import 'package:dbcraft/odbc/odbc_session.dart' show odbcDrivers;
import 'package:dbcraft/ui/widgets/lists.dart' show ListRow;
import 'package:dbcraft/ui/dialogs/app_dialogs.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  matrixTest('driver manager and installer', (tester) async {
    final state = await startApp(tester);
    showDriverManagerDialog(tester.element(find.byType(HomePage)));
    await waitFor(tester, find.text('Driver ODBC'));
    await settle(tester, 1500);
    await shot(tester, 'con13_01_drivers');

    await tester.tap(find.text('Data source'));
    await settle(tester, 800);
    await shot(tester, 'con13_02_dsn');

    await tester.tap(find.text('Installa').first);
    await waitFor(tester, find.text('MariaDB / MySQL'), seconds: 30);
    await settle(tester, 800);
    await shot(tester, 'con13_03_install_before');

    Future<void> installRow(String label, String button) async {
      final row = find.ancestor(of: find.text(label), matching: find.byType(ListRow));
      final btn = find.descendant(of: row, matching: find.text(button));
      if (btn.evaluate().isEmpty) {
        record('CON-13/$label', Outcome.notApplicable, 'nessun pulsante "$button" (già installato?)');
        return;
      }
      await tester.tap(btn);
      await waitFor(tester, find.textContaining('Installazione di'), seconds: 10);
      await shot(tester, 'con13_04_running_${label.replaceAll(RegExp(r'\W'), '_')}');
      await waitFor(tester, find.textContaining('è pronto'), seconds: 900, failShot: 'zz_fail_install_$label');
      await settle(tester, 1000);
      await shot(tester, 'con13_05_done_${label.replaceAll(RegExp(r'\W'), '_')}');
      record('CON-13/$label', Outcome.ok);
    }

    await installRow('SQLite', 'Registra');
    await installRow('PostgreSQL', 'Installa');
    await installRow('MariaDB / MySQL', 'Installa');
    await shot(tester, 'con13_06_install_after');

    final names = (await odbcDrivers(null)).map((d) => d.name).toList();
    record('CON-13/registered', Outcome.ok, names.join(', '));
    expect(names, containsAll(['SQLite3', 'PostgreSQL Unicode', 'MariaDB ODBC Driver']));

    await tester.tap(find.text('Driver').first);
    await settle(tester, 1500);
    await shot(tester, 'con13_07_drivers_after');
    await finish(tester, state);
  });
}
