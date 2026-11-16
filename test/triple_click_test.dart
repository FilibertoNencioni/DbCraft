import 'package:dbcraft/ui/editors/sql_code_editor.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

// re_editor recognizes double clicks with DateTime.now() (real time, always
// "fast" in tests) and a 10 px slop; TripleClickLineSelect uses the event
// time stamps, driven here by [clock].
void main() {
  late CodeLineEditingController controller;
  var clock = Duration.zero;
  final mouse = TestPointer(1, PointerDeviceKind.mouse);
  const slow = Duration(seconds: 1);

  Future<void> click(WidgetTester tester, Offset p, {Duration gap = const Duration(milliseconds: 120)}) async {
    clock += gap;
    await tester.sendEventToBinding(mouse.down(p, timeStamp: clock));
    clock += const Duration(milliseconds: 30);
    await tester.sendEventToBinding(mouse.up(timeStamp: clock));
    await tester.pump();
  }

  Future<void> pumpEditor(WidgetTester tester) async {
    clock = Duration.zero;
    addTearDown(() async {
      // Lets the editor's pending timers (cursor blink, focus) run out.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
    controller = CodeLineEditingController.fromText('select 1;\nselect a, b from t;\nselect 3;');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
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
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A point on a word of [line], found by clicking; then a click far away
  /// resets re_editor's double click state.
  Future<Offset> pointOnLine(WidgetTester tester, int line) async {
    final topLeft = tester.getTopLeft(find.byType(CodeEditor));
    // Alternate x by more than the slop so re_editor never sees a double click.
    for (var i = 0; i < 60; i++) {
      final p = topLeft + Offset(i.isEven ? 90 : 120, i * 2.0);
      await click(tester, p, gap: slow);
      if (controller.selection.extentIndex == line) {
        await click(tester, topLeft + const Offset(400, 250), gap: slow);
        return p;
      }
    }
    fail('line $line not found');
  }

  testWidgets('triple click selects the whole line with its line break', (tester) async {
    await pumpEditor(tester);
    final p = await pointOnLine(tester, 1);
    await click(tester, p, gap: slow);
    await click(tester, p);
    expect(controller.selection.isCollapsed, isFalse, reason: 'double click selects a word');
    expect(controller.selection.baseIndex, 1);
    await click(tester, p);
    expect(controller.selection, const CodeLineSelection(baseIndex: 1, baseOffset: 0, extentIndex: 2, extentOffset: 0));
    expect(controller.selectedText, 'select a, b from t;\n');
    // A fourth quick click keeps the line.
    await click(tester, p);
    expect(controller.selectedText, 'select a, b from t;\n');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS)); // re_editor's desktop gestures

  testWidgets('triple click on the last line selects up to the end of the text', (tester) async {
    await pumpEditor(tester);
    final p = await pointOnLine(tester, 2);
    await click(tester, p, gap: slow);
    await click(tester, p);
    await click(tester, p);
    expect(controller.selectedText, 'select 3;');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('three slow clicks do not select the line', (tester) async {
    await pumpEditor(tester);
    final p = await pointOnLine(tester, 1);
    for (var i = 0; i < 3; i++) {
      await click(tester, p, gap: slow);
    }
    // re_editor still sees double clicks (real time): at most a word.
    expect(controller.selectedText, isNot(contains('\n')));
    expect(controller.selectedText.length, lessThan('select a, b from t;'.length));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
