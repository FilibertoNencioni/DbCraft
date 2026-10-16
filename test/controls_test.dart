import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('shortcutLabel', () {
    test('macOS glyph order and Invio', () {
      expect(shortcutLabel(const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true), mac: true), '⇧⌘S');
      expect(shortcutLabel(const SingleActivator(LogicalKeyboardKey.enter, meta: true), mac: true), '⌘Invio');
    });
    test('other platforms spell modifiers', () {
      expect(
        shortcutLabel(const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true), mac: false),
        'Ctrl+Shift+S',
      );
    });
  });

  testWidgets('PushButton fires on click and on Space when focused', (tester) async {
    var n = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_app(PushButton(label: 'Salva', focusNode: focus, onPressed: () => n++)));
    expect(tester.getSize(find.byType(PushButton)).height, ControlSize.regular);
    await tester.tap(find.text('Salva'));
    expect(n, 1);
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(n, 2);
  });

  testWidgets('disabled PushButton ignores taps', (tester) async {
    await tester.pumpWidget(_app(const PushButton(label: 'No', onPressed: null)));
    await tester.tap(find.text('No'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('MacCheckbox toggles and mixed becomes checked', (tester) async {
    bool? value;
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CheckboxRow(label: 'Mostra viste', value: false, onChanged: (v) => set(() => value = v)),
          MacCheckbox(key: const Key('mixed'), value: null, onChanged: (v) => set(() => value = v)),
        ],
      ),
    )));
    await tester.tap(find.text('Mostra viste'));
    expect(value, isTrue);
    await tester.tap(find.byKey(const Key('mixed')));
    expect(value, isTrue);
  });

  testWidgets('Segmented changes with arrows when focused', (tester) async {
    var value = 0;
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => Segmented<int>(
        value: value,
        items: const [(0, 'Griglia', null), (1, 'Record', null), (2, 'JSON', null)],
        onChanged: (v) => set(() => value = v),
      ),
    )));
    await tester.tap(find.text('Record'));
    await tester.pump();
    expect(value, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, 2);
  });

  testWidgets('PopUpButton opens a menu with the current item checked', (tester) async {
    var value = 'mysql';
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => SizedBox(
        width: 200,
        child: SelectField<String>(
          value: value,
          items: const [('pg', 'PostgreSQL', null), ('mysql', 'MySQL', null), ('lite', 'SQLite', null)],
          onChanged: (v) => set(() => value = v),
        ),
      ),
    )));
    await tester.tap(find.text('MySQL'));
    await tester.pumpAndSettle();
    expect(find.text('PostgreSQL'), findsOneWidget);
    expect(find.byIcon(AppIcons.check), findsOneWidget);
    await tester.tap(find.text('SQLite'));
    await tester.pumpAndSettle();
    expect(value, 'lite');
    expect(find.text('PostgreSQL'), findsNothing);
  });

  testWidgets('MacMenu: keyboard, type-to-select, submenu, callbacks', (tester) async {
    String? picked;
    var called = false;
    await tester.pumpWidget(_app(Builder(
      builder: (context) => PushButton(
        label: 'Apri',
        onPressed: () async {
          picked = await showMacMenu<String>(
            context,
            position: const Offset(100, 100),
            entries: [
              const MenuEntry('Copia', value: 'copy', shortcut: SingleActivator(LogicalKeyboardKey.keyC, meta: true)),
              const MenuEntry('Disattivato', value: 'off', enabled: false),
              const MenuEntry.divider(),
              const MenuEntry.submenu('Esporta', children: [MenuEntry('CSV', value: 'csv'), MenuEntry('JSON', value: 'json')]),
              MenuEntry('Elimina', value: 'del', destructive: true, onSelected: () => called = true),
            ],
          );
        },
      ),
    )));

    // ↓ skips disabled items and dividers; Invio chooses.
    await tester.tap(find.text('Apri'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, isNull, reason: 'the submenu row only opens its submenu');
    expect(find.text('CSV'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, 'json');

    // Typing jumps to the matching item; onSelected runs after closing.
    await tester.tap(find.text('Apri'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, 'del');
    expect(called, isTrue);

    // Esc closes without a value.
    await tester.tap(find.text('Apri'));
    await tester.pumpAndSettle();
    expect(find.text('Copia'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Copia'), findsNothing);
    expect(picked, isNull);
  });

  testWidgets('NumberField steps with arrows and the stepper, within bounds', (tester) async {
    final ctrl = TextEditingController(text: '8');
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_app(NumberField(controller: ctrl, min: 0, max: 10, unit: 'secondi')));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(ctrl.text, '9');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(ctrl.text, '10');
    final stepper = tester.getRect(find.byType(MacStepper));
    await tester.tapAt(stepper.bottomCenter - const Offset(0, 3));
    await tester.pump();
    expect(ctrl.text, '9');
  });

  testWidgets('DateField types segments and steps the day', (tester) async {
    DateTime? value;
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => DateField(value: value, onChanged: (v) => set(() => value = v)),
    )));
    await tester.tap(find.text('gg'));
    await tester.pump();
    for (final k in [
      LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit5, // day
      LogicalKeyboardKey.digit3, // month (>1 commits)
      LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit4,
    ]) {
      await tester.sendKeyEvent(k);
      await tester.pump();
    }
    expect(value, DateTime(2024, 3, 5));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(value, DateTime(2024, 3, 6));
  });

  testWidgets('ComboField fills the text from a suggestion', (tester) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_app(SizedBox(
      width: 220,
      child: ComboField(controller: ctrl, options: () => const ['utf8mb4', 'latin1']),
    )));
    await tester.tap(find.bySemanticsLabel('Suggerimenti'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('latin1'));
    await tester.pumpAndSettle();
    expect(ctrl.text, 'latin1');
  });

  testWidgets('PopUpButton type-to-select picks items with the menu closed', (tester) async {
    var value = 'pg';
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => PopUpButton<String>(
        value: value,
        focusNode: focus,
        items: const [('pg', 'PostgreSQL', null), ('my', 'MySQL', null), ('ma', 'MariaDB', null), ('li', 'SQLite', null)],
        onChanged: (v) => set(() => value = v),
      ),
    )));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(value, 'my');
    // The same letter again cycles to the next item starting with it.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(value, 'ma');
    expect(find.text('PostgreSQL'), findsNothing, reason: 'the menu stays closed');
    // After a pause a new prefix starts over.
    await tester.pump(const Duration(seconds: 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(value, 'li');
  });

  testWidgets('ComboField completes inline and narrows the list', (tester) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_app(SizedBox(
      width: 220,
      child: ComboField(controller: ctrl, options: () => const ['utf8mb4', 'utf16', 'latin1']),
    )));
    await tester.enterText(find.byType(TextField), 'utf8');
    await tester.pump();
    expect(ctrl.text, 'utf8mb4');
    expect(ctrl.selection, const TextSelection(baseOffset: 4, extentOffset: 7));
    // Deleting the completion does not bring it back.
    await tester.enterText(find.byType(TextField), 'utf');
    await tester.pump();
    expect(ctrl.text, 'utf');
    await tester.tap(find.bySemanticsLabel('Suggerimenti'));
    await tester.pumpAndSettle();
    expect(find.text('utf16'), findsOneWidget);
    expect(find.text('latin1'), findsNothing);
  });

  testWidgets('NumberField brings a typed value back into range on blur', (tester) async {
    final ctrl = TextEditingController(text: '5');
    final other = FocusNode();
    addTearDown(ctrl.dispose);
    addTearDown(other.dispose);
    await tester.pumpWidget(_app(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        NumberField(controller: ctrl, min: 1, max: 65535),
        Focus(focusNode: other, child: const SizedBox(width: 10, height: 10)),
      ],
    )));
    await tester.enterText(find.byType(TextField), '70000');
    await tester.pump();
    expect(ctrl.text, '70000');
    other.requestFocus();
    await tester.pump();
    expect(ctrl.text, '65535');
  });

  testWidgets('DateField clears with backspace', (tester) async {
    DateTime? value = DateTime(2024, 3, 5);
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => DateField(value: value, onChanged: (v) => set(() => value = v)),
    )));
    await tester.tap(find.text('05'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(value, isNull);
    expect(find.text('gg'), findsOneWidget);
  });

  testWidgets('Popover opens at its anchor and closes with Esc', (tester) async {
    await tester.pumpWidget(_app(Builder(
      builder: (context) => PushButton(
        label: 'Info',
        onPressed: () => showPopover<void>(
          context,
          anchor: anchorRect(context),
          builder: (_) => const Text('Dettagli connessione'),
        ),
      ),
    )));
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    expect(find.text('Dettagli connessione'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Dettagli connessione')).dy,
      greaterThan(tester.getBottomLeft(find.text('Info')).dy),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Dettagli connessione'), findsNothing);
  });

  testWidgets('MacTextField is 22pt and shows its error', (tester) async {
    await tester.pumpWidget(_app(const SizedBox(width: 200, child: MacTextField(hint: 'Host', error: 'Obbligatorio'))));
    expect(tester.getSize(find.byType(TextField)).height, closeTo(ControlSize.regular, 0.6));
    expect(find.text('Obbligatorio'), findsOneWidget);
  });

  testWidgets('ScopeBar toggles items', (tester) async {
    var sel = {'added'};
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => ScopeBar<String>(
        items: const [ScopeItem('added', 'Nuove', count: 3), ScopeItem('removed', 'Eliminate', count: 1)],
        selected: sel,
        onChanged: (v) => set(() => sel = v),
      ),
    )));
    await tester.tap(find.text('Eliminate'));
    await tester.pump();
    expect(sel, {'added', 'removed'});
    await tester.tap(find.text('Nuove'));
    await tester.pump();
    expect(sel, {'removed'});
  });
}
