import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/services/metadata_service.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/editors/sql_code_editor.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

/// Session whose catalog answers columns of `Orders` after a delay.
class _SlowSession implements DbSession {
  @override
  Future<ResultPage> catalog(String function, List<String?> args) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (function != 'columns') return ResultPage(columns: const [], rows: const []);
    return ResultPage(
      columns: const [],
      rows: [
        for (final (i, c) in ['OrderId', 'Total'].indexed)
          ['shop', 'dbo', 'Orders', c, 4, 'int', 10, null, 0, null, 1, null, null, null, null, null, i + 1],
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // re_editor handles keys through shortcuts only on desktop platforms.
  final desktop = TargetPlatformVariant.only(TargetPlatform.macOS);
  late CodeLineEditingController controller;

  Future<void> pumpEditor(WidgetTester tester, {DbConnection? dc, String text = ''}) async {
    controller = CodeLineEditingController.fromText(text);
    final holder = CodePromptsBuilderHolder(SqlPromptsBuilder(() => dc, () => controller.text, enabled: () => true));
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

  testWidgets('the open popup is refreshed when the columns arrive', (tester) async {
    final dc = DbConnection(ConnectionConfig(id: 'c', name: 'c'));
    final md = MetadataService(_SlowSession(), {'dbmsName': 'Microsoft SQL Server'});
    dc.metadata = md;
    await md.cached<List<DbTable>>(
      'tables:shop:dbo',
      () async => [DbTable(catalog: 'shop', schema: 'dbo', name: 'Orders', type: 'TABLE')],
    );
    await pumpEditor(tester, dc: dc, text: '\nFROM Orders x');
    await type(tester, 'T'); // requests the columns of Orders (300 ms)
    expect(popupShown(), isTrue);
    expect(find.text('Caricamento oggetti del database…'), findsOneWidget);
    expect(find.text('Total'), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('Caricamento oggetti del database…'), findsNothing);
  }, variant: desktop);
}
