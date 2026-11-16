import 'package:dbcraft/ui/editors/drag_autoscroll.dart';
import 'package:dbcraft/ui/editors/sql_code_editor.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  test('speed grows with the distance past the edge', () {
    expect(DragSelectAutoScroll.speed(0), lessThan(200));
    expect(DragSelectAutoScroll.speed(100), greaterThan(DragSelectAutoScroll.speed(20) * 3));
    expect(DragSelectAutoScroll.speed(1e6), 60000);
  });

  testWidgets('dragging a selection above the editor reaches the top of a long script quickly', (tester) async {
    final controller = CodeLineEditingController.fromText([for (var i = 0; i < 400; i++) 'select $i from t;'].join('\n'));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Column(children: [
            const SizedBox(height: 200),
            SizedBox(
              height: 300,
              child: SqlCodeEditor(
                controller: controller,
                findController: CodeFindController(controller),
                promptsBuilder: CodePromptsBuilderHolder(
                  SqlPromptsBuilder(() => null, () => controller.text, enabled: () => false),
                ),
                fontSize: 14,
              ),
            ),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = find.byType(CodeEditor);
    ScrollPosition vertical() => tester
        .stateList<ScrollableState>(find.descendant(of: editor, matching: find.byType(Scrollable)))
        .firstWhere((s) => s.position.axis == Axis.vertical)
        .position;

    // Scroll to the end.
    final center = tester.getCenter(editor);
    final wheel = TestPointer(9, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(wheel.hover(center));
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 100000)));
    await tester.pump();
    expect(vertical().pixels, greaterThan(5000));

    // Press on a line, drag a little to start the selection, then far above
    // the editor and keep the mouse still.
    final top = tester.getTopLeft(editor).dy;
    final g = await tester.startGesture(center, kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await g.moveTo(center - const Offset(0, 40));
    await tester.pump();
    await g.moveTo(Offset(center.dx, top - 150));
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(vertical().pixels, 0, reason: 're_editor alone scrolls ~10 lines/s: only ~24 lines in 2.4 s');
    expect(controller.selection.isCollapsed, isFalse);
    expect(controller.selection.startIndex, 0);
    expect(controller.selection.endIndex, greaterThan(350));

    await g.up();
    await tester.pumpAndSettle();
    // Released: no more scrolling.
    final after = vertical().pixels;
    await tester.pump(const Duration(milliseconds: 500));
    expect(vertical().pixels, after);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS)); // re_editor's desktop gestures
}
