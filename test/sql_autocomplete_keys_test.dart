import 'package:dbcraft/ui/editors/sql_code_editor.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  // re_editor handles keys through shortcuts only on desktop platforms.
  final desktop = TargetPlatformVariant.only(TargetPlatform.macOS);
  late CodeLineEditingController controller;

  Future<void> pumpEditor(WidgetTester tester) async {
    controller = CodeLineEditingController();
    final holder = CodePromptsBuilderHolder(SqlPromptsBuilder(() => null, () => controller.text, enabled: () => true));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SqlCodeEditor(
            controller: controller,
            findController: CodeFindController(controller),
            promptsBuilder: holder,
            fontSize: 13,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // re_editor uses the delta model: send one insertion delta per character.
  Future<void> type(WidgetTester tester, String text) async {
    final log = tester.testTextInput.log;
    final id = (log.lastWhere((c) => c.method == 'TextInput.setClient').arguments as List)[0] as int;
    final state = log.lastWhere((c) => c.method == 'TextInput.setEditingState').arguments as Map;
    var current = state['text'] as String;
    var at = state['selectionBase'] as int;
    for (final ch in text.split('')) {
      final delta = {
        'oldText': current,
        'deltaText': ch,
        'deltaStart': at,
        'deltaEnd': at,
        'selectionBase': at + 1,
        'selectionExtent': at + 1,
        'selectionAffinity': 'TextAffinity.downstream',
        'selectionIsDirectional': false,
        'composingBase': -1,
        'composingExtent': -1,
      };
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.textInput.name,
        SystemChannels.textInput.codec.encodeMethodCall(
          MethodCall('TextInputClient.updateEditingStateWithDeltas', [
            id,
            {
              'deltas': [delta],
            },
          ]),
        ),
        (_) {},
      );
      current = current.substring(0, at) + ch + current.substring(at);
      at++;
      // Lay out the new text before the editor's 50 ms autocompletion timer.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pumpAndSettle();
  }

  bool popupShown() => find.byType(SqlAutocompleteView).evaluate().isNotEmpty;

  testWidgets('Tab accepts the selected prompt and shows the Tab hint', (tester) async {
    await pumpEditor(tester);
    await type(tester, 'selec');
    expect(popupShown(), isTrue);
    expect(find.text('Tab'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(controller.text, 'SELECT');
    expect(popupShown(), isFalse);
  }, variant: desktop);

  testWidgets('Enter inserts a new line instead of accepting', (tester) async {
    await pumpEditor(tester);
    await type(tester, 'selec');
    expect(popupShown(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, 'selec\n');
    expect(popupShown(), isFalse);
  }, variant: desktop);

  testWidgets('Esc closes the popup, Tab then indents', (tester) async {
    await pumpEditor(tester);
    await type(tester, 'selec');
    expect(popupShown(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(popupShown(), isFalse);
    expect(controller.text, 'selec');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(controller.text, startsWith('selec '));
  }, variant: desktop);
}
