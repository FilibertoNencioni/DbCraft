import 'dart:io';

import 'package:dbcraft/state/editor_zoom.dart';
import 'package:dbcraft/ui/editors/sql_code_editor.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  group('EditorZoom', () {
    test('steps through the levels and resets to 100%', () {
      final z = EditorZoom();
      expect(z.isDefault, isTrue);
      z.zoomIn();
      expect(z.value, 1.1);
      z.zoomIn();
      expect(z.label, '125%');
      z.reset();
      z.zoomOut();
      z.zoomOut();
      expect(z.value, 0.8);
      z.reset();
      expect(z.isDefault, isTrue);
    });

    test('clamps at the ends', () {
      final z = EditorZoom();
      for (var i = 0; i < 30; i++) {
        z.zoomIn();
      }
      expect(z.value, EditorZoom.max);
      for (var i = 0; i < 30; i++) {
        z.zoomOut();
      }
      expect(z.value, EditorZoom.min);
      z.set(10);
      expect(z.value, EditorZoom.max);
    });

    test('from an in-between pinch value moves to the next level', () {
      final z = EditorZoom()..set(1.17);
      expect(z.value, 1.15);
      z.zoomIn();
      expect(z.value, 1.25);
      z.set(1.17);
      z.zoomOut();
      expect(z.value, 1.1);
    });

    test('font size follows the zoom', () {
      final z = EditorZoom();
      expect(z.fontSize(14), 14);
      z.zoomIn();
      z.zoomIn();
      expect(z.fontSize(14), 17.5);
    });
  });

  testWidgets('Cmd + wheel zooms the SQL editor', (tester) async {
    final controller = CodeLineEditingController.fromText('select 1');
    final zoom = EditorZoom();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SqlCodeEditor(
            controller: controller,
            findController: CodeFindController(controller),
            promptsBuilder: CodePromptsBuilderHolder(SqlPromptsBuilder(() => null, () => controller.text, enabled: () => true)),
            fontSize: 14,
            zoom: zoom,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double editorFont() => tester.widget<CodeEditor>(find.byType(CodeEditor)).style!.fontSize!;
    expect(editorFont(), 14);

    final center = tester.getCenter(find.byType(CodeEditor));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));

    // Without the modifier the wheel only scrolls.
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -20)));
    await tester.pump();
    expect(zoom.isDefault, isTrue);

    final modifier = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -20)));
    await tester.pump();
    await tester.sendKeyUpEvent(modifier);
    expect(zoom.value, 1.1);
    expect(editorFont(), 15.5);

    zoom.reset();
    await tester.pump();
    expect(editorFont(), 14);
  });
}
