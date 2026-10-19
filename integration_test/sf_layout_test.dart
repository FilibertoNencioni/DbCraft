// Layout smoke test with the real system fonts (SF on macOS): widget tests
// use a test font at scale 1, so they cannot catch rows that overflow only
// with SF widths. Opens the densest sheets at the default and at the minimum
// window size; any RenderFlex overflow fails the test.
//
//   flutter test integration_test/sf_layout_test.dart -d macos \
//     [--dart-define=SHOT_DIR=/tmp/dbcraft_sf]
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/dialogs/connection_dialog.dart';
import 'package:dbcraft/ui/dialogs/value_dialog.dart';
import 'package:dbcraft/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

/// Default window size and the window's minimum (`MainFlutterWindow.minSize`).
const _sizes = [Size(1440, 900), Size(960, 600)];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  setUpAll(() async {
    final ws = Directory.systemTemp.createTempSync('dbcraft_sf');
    app = await AppState.load(workspaceDir: ws);
  });

  Future<BuildContext> pumpHost(WidgetTester tester, Size size, Brightness b, GlobalKey key) async {
    await tester.binding.setSurfaceSize(size);
    late BuildContext ctx;
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: AppScope(
          state: app,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(b),
            home: Scaffold(body: Builder(builder: (c) => SizedBox.expand(child: Builder(builder: (c2) {
              ctx = c2;
              return const SizedBox();
            })))),
          ),
        ),
      ),
    );
    return ctx;
  }

  Future<void> shot(GlobalKey key, String name) async {
    if (shotDir.isEmpty) return;
    final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await ro.toImage(pixelRatio: 2);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    Directory(shotDir).createSync(recursive: true);
    File('$shotDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  }

  for (final size in _sizes) {
    for (final b in Brightness.values) {
      final tag = '${size.width.toInt()}x${size.height.toInt()}_${b.name}';

      testWidgets('connection sheet fits with SF ($tag)', (tester) async {
        final key = GlobalKey();
        final ctx = await pumpHost(tester, size, b, key);
        showConnectionDialog(ctx, app: app);
        await tester.pumpAndSettle();
        expect(find.text('Tramite'), findsOneWidget);
        await shot(key, 'connection_$tag');
        expect(tester.takeException(), isNull);
      });

      testWidgets('value sheet footer fits with SF ($tag)', (tester) async {
        final key = GlobalKey();
        final ctx = await pumpHost(tester, size, b, key);
        showValueDialog(
          ctx,
          column: const ColumnInfo(index: 0, name: 'descrizione', sqlType: 12, typeName: 'varchar', size: 4000),
          value: List.filled(40, 'Valore lungo con testo di prova').join(' '),
          editable: true,
        );
        await tester.pumpAndSettle();
        await shot(key, 'value_$tag');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
