import 'dart:ui' show PointerDeviceKind;

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

  testWidgets('menu rows keep the check and the leading icon in separate columns', (tester) async {
    await tester.pumpWidget(_app(MacMenuPreview(entries: [
      MenuEntry<Object?>('SQL Server', checked: true, leading: Icon(AppIcons.server, size: 14)),
      MenuEntry<Object?>('PostgreSQL', leading: Icon(AppIcons.database, size: 14)),
      const MenuEntry<Object?>('Senza icona'),
    ])));
    // The current item shows both marks: ✓ first, then its icon.
    final check = tester.getCenter(find.byIcon(AppIcons.check));
    final server = tester.getCenter(find.byIcon(AppIcons.server));
    expect(check.dx, lessThan(server.dx));
    expect(check.dy, server.dy);
    // Icons and labels line up across rows, with or without a check or icon.
    expect(tester.getTopLeft(find.byIcon(AppIcons.database)).dx, tester.getTopLeft(find.byIcon(AppIcons.server)).dx);
    final labels = ['SQL Server', 'PostgreSQL', 'Senza icona'].map((t) => tester.getTopLeft(find.text(t)).dx).toSet();
    expect(labels, hasLength(1));
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

  testWidgets('DbSwitch toggles on click and on Space, ignores taps when disabled', (tester) async {
    var value = false;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => DbSwitch(value: value, focusNode: focus, onChanged: (v) => set(() => value = v)),
    )));
    expect(tester.getSize(find.byType(DbSwitch)), const Size(38, 22));
    await tester.tap(find.byType(DbSwitch));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(value, isFalse);

    await tester.pumpWidget(_app(const DbSwitch(value: true, onChanged: null)));
    await tester.tap(find.byType(DbSwitch));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<Opacity>(find.descendant(of: find.byType(DbSwitch), matching: find.byType(Opacity))).opacity, 0.5);
  });

  testWidgets('MacRadioGroup selects by click, is one Tab stop and moves with the arrows', (tester) async {
    var value = 'b';
    final after = FocusNode();
    addTearDown(after.dispose);
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MacRadioGroup<String>(
            value: value,
            items: const [('a', 'TCP/IP', null), ('b', 'Socket', 'Solo locale'), ('c', 'SSH', null)],
            onChanged: (v) => set(() => value = v),
          ),
          PushButton(label: 'Dopo', focusNode: after, onPressed: () {}),
        ],
      ),
    )));
    expect(find.text('Solo locale'), findsOneWidget);
    MacRadio<String> radio(int i) => tester.widget<MacRadio<String>>(find.byType(MacRadio<String>).at(i));
    List<bool> rings() => [
      for (var i = 0; i < 3; i++)
        tester.widget<FocusRing>(find.ancestor(of: find.byType(MacRadio<String>).at(i), matching: find.byType(FocusRing)).first).visible,
    ];
    expect(radio(1).groupValue, 'b');
    await tester.tap(find.text('SSH'));
    await tester.pump();
    expect(value, 'c');
    expect(radio(2).value == radio(2).groupValue, isTrue);
    expect(rings(), [false, false, false]);

    // Tab focuses the group: the ring sits on the selected radio; Space changes nothing.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(rings(), [false, false, true]);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(value, 'c');

    // The arrows move the selection and the ring, without wrapping.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(value, 'b');
    expect(rings(), [false, true, false]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(value, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(value, 'b');

    // One Tab leaves the whole group.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(after.hasFocus, isTrue);
    expect(rings(), [false, false, false]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('horizontal MacRadioGroup moves with ←/→', (tester) async {
    var value = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => MacRadioGroup<int>(
        value: value,
        axis: Axis.horizontal,
        focusNode: focus,
        items: const [(0, 'Uno', null), (1, 'Due', null), (2, 'Tre', null)],
        onChanged: (v) => set(() => value = v),
      ),
    )));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(value, 1, reason: '↑/↓ belong to vertical groups');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(value, 0);
  });

  testWidgets('disabled MacRadioGroup ignores taps', (tester) async {
    await tester.pumpWidget(_app(const MacRadioGroup<int>(value: 0, items: [(0, 'Uno', null), (1, 'Due', null)], onChanged: null)));
    await tester.tap(find.text('Due'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.widget<MacRadio<int>>(find.byType(MacRadio<int>).at(1)).onChanged, isNull);
  });

  testWidgets('PulldownButton opens its menu and runs the chosen command', (tester) async {
    String? ran;
    await tester.pumpWidget(_app(PulldownButton(
      label: 'Azioni',
      entries: () => [
        MenuEntry<Object?>('Duplica', onSelected: () => ran = 'dup'),
        MenuEntry<Object?>('Rinomina', onSelected: () => ran = 'ren'),
      ],
    )));
    await tester.tap(find.text('Azioni'));
    await tester.pumpAndSettle();
    expect(find.text('Duplica'), findsOneWidget);
    await tester.tap(find.text('Rinomina'));
    await tester.pumpAndSettle();
    expect(ran, 'ren');
    expect(find.text('Duplica'), findsNothing);
    expect(find.text('Azioni'), findsOneWidget, reason: 'the title does not follow the choice');
  });

  testWidgets('disabled PulldownButton does not open', (tester) async {
    await tester.pumpWidget(_app(PulldownButton(
      label: 'Azioni',
      enabled: false,
      entries: () => const [MenuEntry<Object?>('Duplica')],
    )));
    await tester.tap(find.text('Azioni'));
    await tester.pumpAndSettle();
    expect(find.text('Duplica'), findsNothing);
  });

  testWidgets('LinkButton fires on tap and is inert when disabled', (tester) async {
    var n = 0;
    await tester.pumpWidget(_app(LinkButton(label: 'Dettagli…', onPressed: () => n++)));
    await tester.tap(find.text('Dettagli…'));
    expect(n, 1);
    final c = DbColors.of(tester.element(find.byType(LinkButton)));
    expect(tester.widget<Text>(find.text('Dettagli…')).style?.color, c.accent);

    await tester.pumpWidget(_app(const LinkButton(label: 'Dettagli…', onPressed: null)));
    await tester.tap(find.text('Dettagli…'));
    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(find.text('Dettagli…')).style?.color, c.textTertiary);
  });

  testWidgets('DisclosureButton toggles its expanded state', (tester) async {
    var expanded = false;
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DisclosureButton(label: 'Avanzate', expanded: expanded, onChanged: (v) => set(() => expanded = v)),
          if (expanded) const Text('Timeout'),
        ],
      ),
    )));
    expect(find.text('Timeout'), findsNothing);
    await tester.tap(find.text('Avanzate'));
    await tester.pumpAndSettle();
    expect(expanded, isTrue);
    expect(find.text('Timeout'), findsOneWidget);
    expect(tester.widget<DisclosureChevron>(find.byType(DisclosureChevron)).expanded, isTrue);
    expect(tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns, 0.25);
    await tester.tap(find.text('Avanzate'));
    await tester.pumpAndSettle();
    expect(expanded, isFalse);
    expect(find.text('Timeout'), findsNothing);
  });

  testWidgets('SecureField eye button reveals and hides the text', (tester) async {
    await tester.pumpWidget(_app(const SizedBox(width: 220, child: SecureField(hint: 'Password'))));
    bool obscured() => tester.widget<TextField>(find.byType(TextField)).obscureText;
    expect(obscured(), isTrue);
    await tester.tap(find.byTooltip('Mostra password'));
    await tester.pump();
    expect(obscured(), isFalse);
    expect(find.byIcon(AppIcons.eyeOff), findsOneWidget);
    await tester.tap(find.byTooltip('Nascondi password'));
    await tester.pump();
    expect(obscured(), isTrue);

    await tester.pumpWidget(_app(const SizedBox(width: 220, child: SecureField(revealable: false))));
    expect(find.byIcon(AppIcons.eye), findsNothing);
  });

  testWidgets('PathField shows the path and Scegli… calls the picker', (tester) async {
    var n = 0;
    await tester.pumpWidget(_app(SizedBox(width: 320, child: PathField(path: '/tmp/chinook.db', onChoose: () => n++))));
    expect(find.text('/tmp/chinook.db'), findsOneWidget);
    await tester.tap(find.text('Scegli…'));
    expect(n, 1);

    await tester.pumpWidget(_app(SizedBox(width: 320, child: PathField(onChoose: () => n++))));
    expect(find.text('Nessun file'), findsOneWidget);

    await tester.pumpWidget(_app(SizedBox(width: 320, child: PathField(enabled: false, onChoose: () => n++))));
    await tester.tap(find.text('Scegli…'));
    expect(n, 1);
  });

  testWidgets('TokenField joins FilterTokens and ⓧ removes one', (tester) async {
    final removed = <String>[];
    var tapped = 0;
    await tester.pumpWidget(_app(TokenField(
      joiner: 'e',
      tokens: [
        FilterToken(label: 'id > 3', onRemove: () => removed.add('id'), onTap: () => tapped++),
        FilterToken(label: 'nome = x', onRemove: () => removed.add('nome')),
        const FilterToken(label: 'fisso'),
      ],
    )));
    expect(find.text('e'), findsNWidgets(2));
    expect(find.byIcon(AppIcons.clearFill), findsNWidgets(2), reason: 'no ⓧ without onRemove');
    await tester.tap(find.byIcon(AppIcons.clearFill).at(1));
    expect(removed, ['nome']);
    await tester.tap(find.byIcon(AppIcons.clearFill).first);
    expect(removed, ['nome', 'id']);
    expect(tapped, 0, reason: 'ⓧ does not also tap the token');
    await tester.tap(find.text('id > 3'));
    expect(tapped, 1);
  });

  testWidgets('CompletionList renders kinds, highlights the selection and picks on tap', (tester) async {
    var selected = 0;
    int? chosen;
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => CompletionList(
        items: const [
          CompletionItem('SELECT', CompletionKind.keyword),
          CompletionItem('customers', CompletionKind.table),
          CompletionItem('email', CompletionKind.column, detail: 'varchar(255)'),
        ],
        selected: selected,
        onSelect: (i) => set(() {
          chosen = i;
          selected = i;
        }),
      ),
    )));
    final c = DbColors.of(tester.element(find.byType(CompletionList)));
    for (final letter in ['K', 'T', 'C']) {
      expect(find.text(letter), findsOneWidget);
    }
    expect(find.text('varchar(255)'), findsOneWidget);
    expect(tester.getSize(find.byType(CompletionList)).height, CompletionList.heightFor(3));
    Color? rowFill(String label) => (tester
            .widget<Container>(find.ancestor(of: find.text(label), matching: find.byType(Container)).first)
            .decoration as BoxDecoration?)
        ?.color;
    List<bool> onAccent() => tester.widgetList<CompletionBadge>(find.byType(CompletionBadge)).map((b) => b.onAccent).toList();
    expect(rowFill('SELECT'), c.accent);
    expect(rowFill('email'), isNull);
    expect(onAccent(), [true, false, false]);
    expect(tester.widget<Text>(find.text('SELECT')).style?.color, c.onAccent);

    await tester.tap(find.text('email'));
    await tester.pump();
    expect(chosen, 2);
    expect(rowFill('email'), c.accent);
    expect(rowFill('SELECT'), isNull);
    expect(onAccent(), [false, false, true]);
  });

  // On macOS the highlight mode starts traditional (keyboard). Elsewhere the
  // test binding starts in touch mode and a mouse connected later flips the
  // default silently, so FocusableActionDetector never hears about it.
  testWidgets('FocusRing shows for keyboard focus only, not after a click', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_app(PushButton(label: 'Salva', focusNode: focus, onPressed: () {})));
    bool ring() =>
        tester.widget<FocusRing>(find.descendant(of: find.byType(PushButton), matching: find.byType(FocusRing))).visible;

    // A mouse click activates the button without taking focus.
    await tester.tap(find.text('Salva'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isFalse);
    expect(ring(), isFalse);

    // Tab moves focus with the keyboard: traditional highlight, ring on.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional);
    expect(ring(), isTrue);

    // A touch switches to touch highlight: the ring goes away, focus stays.
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
    expect(focus.hasFocus, isTrue);
    expect(ring(), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('default PushButton is accent in the key window, gray in the background', (tester) async {
    for (final active in [true, false]) {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light, active: active),
        home: Scaffold(body: Center(child: PushButton.primary(label: 'Connetti', onPressed: () {}))),
      ));
      await tester.pumpAndSettle();
      final c = DbColors.of(tester.element(find.byType(PushButton)));
      final box = tester
          .widgetList<Container>(find.descendant(of: find.byType(PushButton), matching: find.byType(Container)))
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .first;
      expect(c.windowActive, active);
      expect(box.color, c.defaultButton);
      expect(c.defaultButton, active ? c.accent : c.controlBackground);
      expect(box.gradient != null, active, reason: 'the accent gradient only in the key window');
      expect(tester.widget<Text>(find.text('Connetti')).style?.color, active ? c.onAccent : c.text);
    }
  });

  testWidgets('ComboField menu shows details, icons and actions', (tester) async {
    final ctrl = TextEditingController(text: 'opus');
    addTearDown(ctrl.dispose);
    var installs = 0;
    await tester.pumpWidget(_app(SizedBox(
      width: 260,
      child: ComboField(
        controller: ctrl,
        options: () => const ['opus', 'sonnet', 'haiku'],
        optionDetail: (o) => o == 'sonnet' ? 'Più veloce' : null,
        optionIcon: (o) => o == 'haiku' ? (AppIcons.database, null) : null,
        actions: [MenuEntry<String>('Installa driver…', onSelected: () => installs++)],
      ),
    )));
    await tester.tap(find.bySemanticsLabel('Suggerimenti'));
    await tester.pumpAndSettle();
    expect(find.text('Più veloce'), findsOneWidget);
    expect(find.byIcon(AppIcons.database), findsOneWidget);
    expect(find.byIcon(AppIcons.check), findsOneWidget, reason: 'the current suggestion is checked');
    // Actions sit below the suggestions and leave the text alone.
    expect(tester.getTopLeft(find.text('Installa driver…')).dy, greaterThan(tester.getTopLeft(find.text('haiku')).dy));
    await tester.tap(find.text('Installa driver…'));
    await tester.pumpAndSettle();
    expect(installs, 1);
    expect(ctrl.text, 'opus');

    // With no suggestions the menu still offers the actions.
    await tester.pumpWidget(_app(SizedBox(
      width: 260,
      child: ComboField(
        controller: ctrl,
        options: () => const [],
        actions: [MenuEntry<String>('Installa driver…', onSelected: () => installs++)],
      ),
    )));
    await tester.tap(find.bySemanticsLabel('Suggerimenti'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Installa driver…'));
    await tester.pumpAndSettle();
    expect(installs, 2);
  });

  testWidgets('ComboField leading sits inside the field, before the text', (tester) async {
    final ctrl = TextEditingController(text: 'PostgreSQL');
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_app(SizedBox(
      width: 260,
      child: ComboField(controller: ctrl, options: () => const [], leading: const Icon(AppIcons.database, size: 16)),
    )));
    final icon = find.descendant(of: find.byType(TextField), matching: find.byIcon(AppIcons.database));
    expect(icon, findsOneWidget);
    final field = tester.getRect(find.byType(TextField));
    final iconRect = tester.getRect(icon);
    expect(iconRect.left, greaterThan(field.left));
    expect(tester.getRect(find.byType(EditableText)).left, greaterThanOrEqualTo(iconRect.right));
  });

  testWidgets('ComboField onSelected runs for menu picks only', (tester) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    final changed = <String>[];
    final selected = <String>[];
    await tester.pumpWidget(_app(SizedBox(
      width: 220,
      child: ComboField(
        controller: ctrl,
        options: () => const ['integer', 'varchar'],
        onChanged: changed.add,
        onSelected: selected.add,
      ),
    )));
    await tester.enterText(find.byType(TextField), 'int');
    await tester.pump();
    expect(changed, ['integer'], reason: 'typing completes inline');
    expect(selected, isEmpty);
    await tester.tap(find.bySemanticsLabel('Suggerimenti'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('varchar'));
    await tester.pumpAndSettle();
    expect(changed, ['integer', 'varchar']);
    expect(selected, ['varchar']);
  });

  testWidgets('multi-line SecureField grows when revealed and offers Scegli…', (tester) async {
    final ctrl = TextEditingController(text: '{"type": "service_account"}');
    addTearDown(ctrl.dispose);
    var chosen = 0;
    await tester.pumpWidget(_app(SizedBox(
      width: 320,
      child: SecureField(controller: ctrl, maxLines: 4, onChoose: () => chosen++),
    )));
    TextField field() => tester.widget<TextField>(find.byType(TextField));
    expect(field().obscureText, isTrue);
    expect(field().maxLines, 1);
    expect(tester.getSize(find.byType(TextField)).height, closeTo(ControlSize.regular, 0.6));
    expect(field().style?.fontFamily, kMonoFamily);
    await tester.tap(find.byTooltip('Mostra password'));
    await tester.pump();
    expect(field().obscureText, isFalse);
    expect(field().maxLines, 4);
    expect(field().minLines, 1);
    await tester.tap(find.text('Scegli…'));
    expect(chosen, 1);

    await tester.pumpWidget(_app(const SizedBox(width: 320, child: SecureField())));
    expect(find.text('Scegli…'), findsNothing);
  });

  testWidgets('MacTextField expands to its parent and takes a text color', (tester) async {
    await tester.pumpWidget(_app(const SizedBox(width: 300, height: 200, child: MacTextField(expands: true, mono: true))));
    expect(tester.getSize(find.byType(TextField)).height, 200);
    expect(tester.widget<TextField>(find.byType(TextField)).expands, isTrue);

    await tester.pumpWidget(_app(Builder(
      builder: (context) => SizedBox(
        width: 200,
        child: MacTextField(controller: TextEditingController(text: 'nuova'), color: DbColors.of(context).success),
      ),
    )));
    final c = DbColors.of(tester.element(find.byType(MacTextField)));
    expect(tester.widget<TextField>(find.byType(TextField)).style?.color, c.success);
  });

  testWidgets('DateField with time types and steps hours and minutes', (tester) async {
    DateTime? value;
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => DateField(value: value, time: true, onChanged: (v) => set(() => value = v)),
    )));
    expect(find.text('hh'), findsOneWidget);
    await tester.tap(find.text('gg'));
    await tester.pump();
    for (final k in [
      LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit5, // day
      LogicalKeyboardKey.digit3, // month
      LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit4, // year
      LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit9, // hour
      LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit7, // minute
    ]) {
      await tester.sendKeyEvent(k);
      await tester.pump();
    }
    expect(value, DateTime(2024, 3, 5, 9, 7));
    // ↑ on the minutes, then ← to the hours and ↓ (wrapping).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(value, DateTime(2024, 3, 5, 9, 8));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(value, DateTime(2024, 3, 5, 23, 8));
    // The calendar replaces the day and keeps the time.
    await tester.tap(find.byTooltip('Calendario'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('12'));
    await tester.pumpAndSettle();
    expect(value, DateTime(2024, 3, 12, 23, 8));
  });

  testWidgets('PopUpButton can select a null value', (tester) async {
    int? value = 0;
    final picks = <int?>[];
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, set) => SizedBox(
        width: 220,
        child: SelectField<int?>(
          value: value,
          items: const [(null, 'Numero di riga', null), (0, 'id', null), (1, 'nome', null)],
          onChanged: (v) => set(() {
            picks.add(v);
            value = v;
          }),
        ),
      ),
    )));
    await tester.tap(find.text('id'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Numero di riga'));
    await tester.pumpAndSettle();
    expect(picks, [null]);
    expect(value, isNull);
    expect(find.text('Numero di riga'), findsOneWidget, reason: 'the button shows the null choice');
    // Reopening checks the null item; Esc changes nothing.
    await tester.tap(find.text('Numero di riga'));
    await tester.pumpAndSettle();
    expect(find.byIcon(AppIcons.check), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(picks, [null]);
    await tester.tap(find.text('Numero di riga'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('nome'));
    await tester.pumpAndSettle();
    expect(picks, [null, 1]);
  });

  testWidgets('CheckboxRow shows its tooltip and label color', (tester) async {
    await tester.pumpWidget(_app(Builder(
      builder: (context) => CheckboxRow(
        label: 'Elimina oggetti in più',
        value: true,
        onChanged: (_) {},
        tooltip: 'Pericoloso',
        labelColor: DbColors.of(context).danger,
      ),
    )));
    final c = DbColors.of(tester.element(find.byType(CheckboxRow)));
    expect(find.byTooltip('Pericoloso'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Elimina oggetti in più')).style?.color, c.danger);

    await tester.pumpWidget(_app(Builder(
      builder: (context) => CheckboxRow(
        label: 'Elimina oggetti in più',
        value: true,
        onChanged: null,
        labelColor: DbColors.of(context).danger,
      ),
    )));
    expect(tester.widget<Text>(find.text('Elimina oggetti in più')).style?.color, c.textTertiary);
  });

  testWidgets('ScopeItem shows its tooltip and groups thousands in the count', (tester) async {
    await tester.pumpWidget(_app(ScopeBar<String>(
      items: const [
        ScopeItem('added', 'Nuove', count: 1234567, tooltip: 'Nascondi: nuove'),
        ScopeItem('removed', 'Eliminate', count: 999),
      ],
      selected: const {'added'},
      onChanged: (_) {},
    )));
    expect(find.text('1.234.567'), findsOneWidget);
    expect(find.text('999'), findsOneWidget);
    expect(find.byTooltip('Nascondi: nuove'), findsOneWidget);
  });
}
