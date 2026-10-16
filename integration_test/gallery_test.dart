// Renders the control gallery with the real macOS fonts and saves it as a
// PNG, to compare the components against native screenshots.
//
//   flutter test integration_test/gallery_test.dart -d macos \
//     --dart-define=SHOT_DIR=/tmp/dbcraft_gallery
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dbcraft/ui/dev/control_gallery.dart';
import 'package:dbcraft/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('control gallery', (tester) async {
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(1400, 3800));
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          home: const ControlGallery(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Galleria controlli'), findsOneWidget);
    if (shotDir.isEmpty) return;
    final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await ro.toImage(pixelRatio: 2);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    Directory(shotDir).createSync(recursive: true);
    File('$shotDir/gallery.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}
