import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {bool reduceMotion = false}) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: child),
  ),
);

/// Fill of the row container that holds [title].
Color? _rowFill(WidgetTester tester, String title) {
  final box = tester.widget<Container>(find.ancestor(of: find.text(title), matching: find.byType(Container)).first);
  return (box.decoration as BoxDecoration?)?.color;
}

void main() {
  group('source list', () {
    testWidgets('arrows move the selection, skipping headers; → / ← expand; Invio activates', (tester) async {
      var selected = 1;
      final expanded = <(int, bool)>[];
      int? activated;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => SourceList(
              itemCount: 4,
              selectedIndex: selected,
              selectable: (i) => i != 2,
              onSelect: (i) => setState(() => selected = i),
              onExpand: (i, e) => expanded.add((i, e)),
              onActivate: (i) => activated = i,
              itemBuilder: (_, i) => i == 2
                  ? const SectionLabel('Gruppo')
                  : OutlineRow(title: 'riga $i', selected: i == selected, onTap: () => setState(() => selected = i)),
            ),
          ),
        ),
      );
      await tester.tap(find.text('riga 1'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(selected, 3, reason: 'the header at 2 is skipped');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(selected, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(expanded, [(1, true), (1, false)]);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(activated, 1);
    });

    testWidgets('the selection is the solid accent only while the list has focus', (tester) async {
      final other = FocusNode();
      addTearDown(other.dispose);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              SizedBox(
                height: 100,
                child: SourceList(
                  itemCount: 1,
                  selectedIndex: 0,
                  itemBuilder: (_, _) => OutlineRow(title: 'dipendenti', selected: true, onTap: () {}),
                ),
              ),
              Focus(focusNode: other, child: const SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      final c = DbColors.light;
      expect(_rowFill(tester, 'dipendenti'), c.selectionMuted);

      await tester.tap(find.text('dipendenti'));
      await tester.pump();
      expect(_rowFill(tester, 'dipendenti'), c.selectionEmphasized);
      final title = tester.widget<Text>(find.text('dipendenti'));
      expect(title.style?.color, c.onSelectionEmphasized);

      other.requestFocus();
      // The focus change lands in a microtask after the first frame.
      await tester.pump();
      await tester.pump();
      expect(other.hasFocus, isTrue);
      expect(_rowFill(tester, 'dipendenti'), c.selectionMuted);
    });
  });

  group('outline row', () {
    testWidgets('a click selects at once; a second click opens', (tester) async {
      var taps = 0;
      var opens = 0;
      await tester.pumpWidget(_app(OutlineRow(title: 'ordini', onTap: () => taps++, onDoubleTap: () => opens++)));
      await tester.tap(find.text('ordini'));
      expect(taps, 1, reason: 'no wait for a possible double click');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('ordini'));
      expect(opens, 1);
      expect(taps, 1);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.tap(find.text('ordini'));
      expect(taps, 2);
    });

    testWidgets('the chevron and a double click toggle a parent row', (tester) async {
      final calls = <bool>[];
      await tester.pumpWidget(
        _app(OutlineRow(title: 'public', expanded: false, onExpand: calls.add, icon: AppIcons.schema)),
      );
      await tester.tap(find.byType(DisclosureChevron));
      expect(calls, [true]);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.tap(find.text('public'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('public'));
      expect(calls, [true, true]);
    });

    testWidgets('"…" replaces the detail on hover when the row has a menu', (tester) async {
      Offset? menuAt;
      await tester.pumpWidget(_app(OutlineRow(title: 'clienti', detail: '200', onMenu: (p) => menuAt = p)));
      expect(find.text('200'), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(find.text('clienti')));
      await tester.pump();
      expect(find.text('200'), findsNothing);
      await tester.tap(find.byIcon(AppIcons.more));
      expect(menuAt, isNotNull);
    });
  });

  testWidgets('a collapsible section label toggles and says Mostra when closed', (tester) async {
    var open = true;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) =>
              SectionLabel('Connessioni', expanded: open, onToggle: (v) => setState(() => open = v)),
        ),
      ),
    );
    expect(find.text('Mostra'), findsNothing);
    await tester.tap(find.text('Connessioni'));
    await tester.pump();
    expect(open, isFalse);
    expect(find.text('Mostra'), findsOneWidget);
  });

  group('table', () {
    Widget table({
      int? selected,
      ValueChanged<int>? onSelect,
      ValueChanged<int>? onSort,
      ValueChanged<int>? onDoubleTap,
      int? sortColumn,
    }) => SizedBox(
      width: 500,
      height: 200,
      child: MacTable(
        headers: const ['id', 'nome'],
        types: (i) => i == 0 ? 'integer' : 'varchar',
        rowCount: 3,
        cell: (r, c) => c == 0 ? '${r + 1}' : 'riga ${r + 1}',
        numeric: (c) => c == 0,
        selected: selected,
        onSelect: onSelect,
        onSort: onSort,
        onDoubleTap: onDoubleTap,
        sortColumn: sortColumn,
        cellBuilder: (_, r, c) => r == 2 && c == 1 ? const Text('controllo') : null,
      ),
    );

    testWidgets('header click sorts, the sorted column shows its chevron', (tester) async {
      int? sorted;
      await tester.pumpWidget(_app(table(onSort: (c) => sorted = c)));
      expect(find.byIcon(AppIcons.chevronUp), findsNothing);
      await tester.tap(find.text('nome'));
      expect(sorted, 1);
      await tester.pumpWidget(_app(table(sortColumn: 1)));
      expect(find.byIcon(AppIcons.chevronUp), findsOneWidget);
      expect(find.text('varchar'), findsOneWidget);
    });

    testWidgets('click, arrows and double click', (tester) async {
      int? selected;
      int? opened;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => table(
              selected: selected,
              onSelect: (r) => setState(() => selected = r),
              onDoubleTap: (r) => opened = r,
            ),
          ),
        ),
      );
      await tester.tap(find.text('riga 1'));
      await tester.pump();
      expect(selected, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(selected, 1);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.tap(find.text('riga 2'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('riga 2'));
      expect(opened, 1);
      expect(find.text('controllo'), findsOneWidget, reason: 'cellBuilder replaces the text');
      expect(find.text('riga 3'), findsNothing);
    });

    testWidgets('dragging the header edge resizes the column', (tester) async {
      await tester.pumpWidget(_app(table()));
      final before = tester.getSize(find.ancestor(of: find.text('id'), matching: find.byType(TableHeaderCell))).width;
      await tester.drag(find.byType(ColumnResizeHandle).first, const Offset(40, 0));
      await tester.pump();
      final after = tester.getSize(find.ancestor(of: find.text('id'), matching: find.byType(TableHeaderCell))).width;
      // The drag recognizer swallows its slop, so only part of the 40pt lands.
      expect(after, greaterThan(before + 10));
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('simple grid copies a row from the context menu', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(
        _app(
          const SimpleGrid(
            headers: ['#', 'Colonna', 'Tipo'],
            rows: [
              ['1', 'id', 'integer'],
            ],
          ),
        ),
      );
      await tester.tap(find.text('id'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copia riga'));
      await tester.pumpAndSettle();
      expect(copied, '1\tid\tinteger');
    });

    testWidgets('property table shows a dash for empty values', (tester) async {
      await tester.pumpWidget(
        _app(const SizedBox(width: 400, child: PropertyTable(entries: [('Motore', 'PostgreSQL'), ('Commento', '')]))),
      );
      expect(find.text('PostgreSQL'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });
  });

  group('tabs', () {
    testWidgets('window tab: ⓧ on hover, dirty dot otherwise, middle click closes', (tester) async {
      var closed = 0;
      var selected = 0;
      await tester.pumpWidget(
        _app(
          WindowTabBar(
            itemCount: 1,
            itemKey: (_) => const ValueKey('t'),
            itemBuilder: (_, _) => WindowTab(
              title: 'query.sql',
              active: true,
              dirty: true,
              onClose: () => closed++,
              onSelect: () => selected++,
            ),
          ),
        ),
      );
      expect(find.byType(DirtyDot), findsOneWidget);
      expect(find.byIcon(AppIcons.close), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(find.text('query.sql')));
      await tester.pump();
      expect(find.byIcon(AppIcons.close), findsOneWidget);
      expect(find.byType(DirtyDot), findsNothing);
      await tester.tap(find.byIcon(AppIcons.close));
      expect(closed, 1);

      await tester.tap(find.text('query.sql'));
      expect(selected, 1);
      await tester.tap(find.text('query.sql'), buttons: kMiddleMouseButton);
      expect(closed, 2);
    });

    testWidgets('window tabs share the width between 110 and 240', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Widget bar(int n) => _app(
        WindowTabBar(
          itemCount: n,
          itemKey: (i) => ValueKey(i),
          itemBuilder: (_, i) => WindowTab(title: 'tab $i', active: i == 0),
        ),
      );
      await tester.pumpWidget(bar(2));
      expect(tester.getSize(find.byType(WindowTab).first).width, 240);
      await tester.pumpWidget(bar(5));
      expect(tester.getSize(find.byType(WindowTab).first).width, 200);
      await tester.pumpWidget(bar(20));
      expect(tester.getSize(find.byType(WindowTab).first).width, 110);
    });

    testWidgets('pane tabs switch and show their counts', (tester) async {
      var value = 0;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => PaneTabs<int>(
              value: value,
              onChanged: (v) => setState(() => value = v),
              tabs: const [PaneTab(0, 'Risultato 1', count: 200), PaneTab(1, 'Output')],
            ),
          ),
        ),
      );
      expect(find.widgetWithText(CountBadge, '200'), findsOneWidget);
      await tester.tap(find.text('Output'));
      await tester.pump();
      expect(value, 1);
    });

    testWidgets('sidebar tabs show the Fill glyph for the selected tab', (tester) async {
      await tester.pumpWidget(
        _app(
          SidebarTabs<int>(
            value: 0,
            onChanged: (_) {},
            items: const [
              SidebarTab(0, 'Database', AppIcons.database, selectedIcon: AppIcons.databaseFill),
              SidebarTab(1, 'Git', AppIcons.git, selectedIcon: AppIcons.gitFill),
            ],
          ),
        ),
      );
      expect(find.byIcon(AppIcons.databaseFill), findsOneWidget);
      expect(find.byIcon(AppIcons.git), findsOneWidget);
      expect(find.byIcon(AppIcons.gitFill), findsNothing);
    });

    testWidgets('path bar: segments click or open a menu', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        _app(
          Center(
            child: PathBar(
              segments: [
                PathSegment('demo_pg', onTap: () => tapped++),
                PathSegment('public', menu: () => const [MenuEntry('hr')]),
                const PathSegment('dipendenti'),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('demo_pg'));
      expect(tapped, 1);
      await tester.tap(find.text('public'));
      await tester.pumpAndSettle();
      expect(find.text('hr'), findsOneWidget);
      final last = tester.widget<Text>(find.text('dipendenti'));
      expect(last.style?.fontWeight, FontWeight.w600);
    });
  });

  group('badges', () {
    test('shortcut labels on and off macOS', () {
      const enter = SingleActivator(LogicalKeyboardKey.enter, meta: true);
      const ins = SingleActivator(LogicalKeyboardKey.insert);
      const del = SingleActivator(LogicalKeyboardKey.delete);
      expect(shortcutLabel(enter, mac: true), '⌘Invio');
      expect(shortcutLabel(enter, mac: false), 'Ctrl+Invio');
      expect(shortcutLabel(ins, mac: true), 'Ins');
      expect(shortcutLabel(del, mac: false), 'Canc');
    });

    testWidgets('accessories turn white on an emphasized row', (tester) async {
      final c = DbColors.light;
      await tester.pumpWidget(
        _app(
          RowTint(
            emphasized: true,
            child: Row(
              children: [
                Tag('Prod', color: c.danger),
                const CountBadge(3),
              ],
            ),
          ),
        ),
      );
      expect(tester.widget<Text>(find.text('Prod')).style?.color, c.onSelectionEmphasized);
      expect(tester.widget<Text>(find.text('3')).style?.color, c.onSelectionEmphasized);
    });

    testWidgets('the connection menu labels the environment with a Tag', (tester) async {
      await tester.pumpWidget(
        _app(
          MacMenuPreview(
            entries: [
              MenuEntry<int>.connection(
                name: 'erp_prod',
                status: DbColors.light.success,
                environment: 'Produzione',
                environmentColor: DbColors.light.danger,
              ),
            ],
          ),
        ),
      );
      expect(find.widgetWithText(Tag, 'Produzione'), findsOneWidget);
    });

    testWidgets('shortcuts sheet lists key caps and closes with Invio', (tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => PushButton(
              label: 'Apri',
              onPressed: () => showShortcutsSheet(context, const [
                (
                  'Griglia dati',
                  [
                    ShortcutHelp('Modifica cella', [
                      SingleActivator(LogicalKeyboardKey.enter),
                      SingleActivator(LogicalKeyboardKey.f2),
                    ]),
                  ],
                ),
              ]),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      expect(find.text('Scorciatoie da tastiera'), findsOneWidget);
      expect(find.byType(KeyCap), findsNWidgets(2));
      expect(find.widgetWithText(KeyCap, 'F2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Scorciatoie da tastiera'), findsNothing);
    });
  });

  group('progress', () {
    testWidgets('indeterminate bars stand still with Reduce Motion', (tester) async {
      await tester.pumpWidget(
        _app(const Column(children: [ProgressBar(width: 100), LoadingLine()]), reduceMotion: true),
      );
      // Would time out if the sweep kept animating.
      await tester.pumpAndSettle();
      expect(find.byType(ProgressBar), findsOneWidget);
    });

    testWidgets('status line: icon by kind and a details link', (tester) async {
      var details = 0;
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              const StatusLine('Connessione riuscita', kind: StatusKind.success),
              StatusLine('Accesso negato', kind: StatusKind.danger, onDetails: () => details++),
            ],
          ),
        ),
      );
      expect(find.byIcon(AppIcons.checkCircleFill), findsOneWidget);
      expect(find.byIcon(AppIcons.clearFill), findsOneWidget);
      await tester.tap(find.text('Dettagli…'));
      expect(details, 1);
    });

    testWidgets('the busy status line shows a spinner', (tester) async {
      await tester.pumpWidget(_app(const StatusLine.busy('Prova in corso…')));
      expect(find.byType(Spinner), findsOneWidget);
    });
  });
}
