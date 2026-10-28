import 'package:dbcraft/odbc/odbc_ffi.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/ui/dialogs/value_dialog.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // D-004: a 1 MB text used to take ~15 s to open in a text field.
  testWidgets('large values open in the virtualized read-only view', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final big = List.generate(20000, (i) => 'riga $i ${'x' * 40}').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => PushButton(
              label: 'Apri',
              onPressed: () => showValueDialog(
                context,
                column: const ColumnInfo(index: 1, name: 'testo', sqlType: SQL_LONGVARCHAR),
                value: big,
                editable: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Apri'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Valore grande'), findsOneWidget);
    expect(find.byType(EditableText), findsNothing);
    expect(find.text('riga 0 ${'x' * 40}'), findsOneWidget);
    await tester.tap(find.text('Modifica comunque'));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsOneWidget);
  });
}
