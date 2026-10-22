import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/state/result_set_model.dart';
import 'package:dbcraft/ui/results/result_grid.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// Three rows of `dipendenti`, no database behind them. With [editable] the
/// model has a source table and a key, as the table data editor sets.
ResultSetModel _model({bool editable = false}) {
  final m = ResultSetModel(
    connection: DbConnection(ConnectionConfig(id: 'demo', name: 'demo')),
    first: ResultPage(
      columns: const [
        ColumnInfo(index: 1, name: 'id', sqlType: 4, typeName: 'INTEGER'),
        ColumnInfo(index: 2, name: 'nome', sqlType: 12, typeName: 'VARCHAR'),
      ],
      rows: [
        [10, 'Carla'],
        [20, 'Anna'],
        [30, 'Bruno'],
      ],
    ),
    sql: 'select * from dipendenti',
  );
  if (editable) {
    m.table = DbTable(catalog: null, schema: 'public', name: 'dipendenti', type: 'TABLE');
    m.keyColumns = ['id'];
  }
  return m;
}

Widget _grid(ResultSetModel m) => SizedBox(width: 600, height: 200, child: ResultGrid(model: m));

/// Color of the 3pt edit-state stripe in the row header labelled [label].
Color? _marker(WidgetTester tester, String label) {
  final header = find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
  final stripe = find.descendant(
    of: header,
    matching: find.byWidgetPredicate((w) => w is Container && w.constraints?.maxWidth == GridMetrics.marker),
  );
  return tester.widget<Container>(stripe).color;
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

    testWidgets('the detail sits on the right edge and only the title it crowds out truncates', (tester) async {
      bool clipped(String text) {
        final p = tester.renderObject<RenderParagraph>(find.text(text));
        return p.didExceedMaxLines;
      }

      Future<void> row(String title, String detail) => tester.pumpWidget(
        _app(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 260,
              child: OutlineRow(title: title, detail: detail),
            ),
          ),
        ),
      );

      // Short title: a detail wider than 40% takes the free space instead of
      // half the row (the test font is square: 12px per character).
      await row('main', 'acme/reports');
      expect(clipped('main'), isFalse);
      expect(clipped('acme/reports'), isFalse);
      expect(tester.getTopRight(find.text('acme/reports')).dx, closeTo(260 - 4 - 2 - 2, 1));

      // Long title: the title keeps priority; the detail stays whole.
      await row('fix_indirizzi_fatturazione_duplicati_clienti', '1 h fa');
      expect(clipped('1 h fa'), isFalse);
      expect(clipped('fix_indirizzi_fatturazione_duplicati_clienti'), isTrue);

      // Both long: the detail gives up to 40% of the row.
      await row('fix_indirizzi_fatturazione_duplicati_clienti', 'eu-south-1 · profilo produzione-lettura');
      expect(tester.getSize(find.text('eu-south-1 · profilo produzione-lettura')).width, lessThan(260 * 0.4));
      expect(tester.getSize(find.text('fix_indirizzi_fatturazione_duplicati_clienti')).width, greaterThan(260 * 0.5));
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

  group('result grid', () {
    testWidgets('rows carry a 3pt stripe for inserted, deleted and changed', (tester) async {
      final m = _model(editable: true)
        ..setValue(0, 1, 'Carlo')
        ..toggleDelete([1])
        ..addRow();
      await tester.pumpWidget(_app(_grid(m)));
      final c = DbColors.light;
      expect(_marker(tester, '1'), c.diffChanged);
      expect(_marker(tester, '2'), c.diffRemoved);
      expect(_marker(tester, '3'), Colors.transparent);
      expect(_marker(tester, 'nuova'), c.diffAdded);
      expect(tester.widget<Text>(find.text('Anna')).style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('the cursor cell has a focus ring only while the grid has focus', (tester) async {
      final other = FocusNode();
      addTearDown(other.dispose);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              _grid(_model()),
              Focus(focusNode: other, child: const SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      Finder ringOn(String text) =>
          find.ancestor(of: find.text(text), matching: find.byWidgetPredicate((w) => w is FocusRing && w.visible));
      Iterable<FocusRing> visible() => tester.widgetList<FocusRing>(find.byType(FocusRing)).where((r) => r.visible);
      expect(visible(), isEmpty);

      await tester.tap(find.text('Anna'));
      await tester.pump();
      expect(visible(), hasLength(1));
      expect(ringOn('Anna'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(ringOn('Bruno'), findsOneWidget);
      expect(ringOn('Anna'), findsNothing);

      other.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(visible(), isEmpty, reason: 'the cursor stays but the ring goes with the focus');
    });

    testWidgets('a double click edits the cell with the cell editor decoration', (tester) async {
      final m = _model(editable: true);
      await tester.pumpWidget(_app(_grid(m)));
      await tester.tap(find.text('Anna'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Anna'));
      await tester.pump();
      await tester.pump();

      final c = DbColors.of(tester.element(find.byType(TextField)));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, 'Anna');
      final d = field.decoration!;
      expect(d.filled, isTrue);
      expect(d.fillColor, c.content);
      expect(d.border, const CellFieldBorder());
      expect(d.focusedBorder, CellFieldBorder(ring: c.focusRing));

      await tester.enterText(find.byType(TextField), 'Annalisa');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(m.rowAt(1).values[1], 'Annalisa');
      expect(_marker(tester, '2'), c.diffChanged);
    });

    testWidgets('dragging the header handle resizes, a header click sorts', (tester) async {
      final m = _model();
      await tester.pumpWidget(_app(_grid(m)));
      Finder header(String name) => find.ancestor(of: find.text(name), matching: find.byType(TableHeaderCell));
      final before = tester.getSize(header('id')).width;
      await tester.drag(
        find.descendant(of: header('id'), matching: find.byType(ColumnResizeHandle)),
        const Offset(40, 0),
      );
      await tester.pump();
      expect(tester.getSize(header('id')).width, greaterThan(before + 10));
      await tester.pump(kDoubleTapTimeout);

      expect(find.byIcon(AppIcons.chevronUp), findsNothing);
      await tester.tap(find.text('nome'));
      await tester.pump();
      expect(m.sortColumn, 1);
      expect(m.view, [1, 2, 0]);
      expect(find.byIcon(AppIcons.chevronUp), findsOneWidget);
      expect(tester.getTopLeft(find.text('Anna')).dy, lessThan(tester.getTopLeft(find.text('Carla')).dy));

      await tester.tap(find.text('nome'));
      await tester.pump();
      expect(m.view, [0, 2, 1]);
      expect(find.byIcon(AppIcons.chevronDown), findsOneWidget);
    });
  });

  testWidgets('record view: name and type, NULL in italics, changed values tinted', (tester) async {
    await tester.pumpWidget(
      _app(
        const SingleChildScrollView(
          child: RecordView(
            title: 'Riga 2',
            fields: [
              RecordField('id', '20', type: 'INTEGER'),
              RecordField('nome', 'Annalisa', type: 'VARCHAR', changed: true),
              RecordField('note', null),
            ],
          ),
        ),
      ),
    );
    final c = DbColors.of(tester.element(find.byType(RecordView)));
    expect(find.text('Riga 2'), findsOneWidget);
    expect(find.widgetWithText(TypeLabel, 'integer'), findsOneWidget);
    Finder value(String text) => find.byWidgetPredicate((w) => w is SelectableText && w.data == text);
    expect(tester.widget<SelectableText>(value('NULL')).style?.fontStyle, FontStyle.italic);
    Decoration? box(String text) =>
        tester.widget<Container>(find.ancestor(of: value(text), matching: find.byType(Container)).first).decoration;
    expect((box('Annalisa') as BoxDecoration?)?.color, c.diffChanged.withValues(alpha: Tint.regular));
    expect(box('20'), isNull);
  });

  testWidgets('level indicator turns warning and danger at its thresholds', (tester) async {
    final c = DbColors.light;
    Future<void> level(double v, {Color? color}) => tester.pumpWidget(
      _app(
        Center(
          child: LevelIndicator(value: v, warningAt: 0.8, dangerAt: 0.95, width: 100, color: color),
        ),
      ),
    );
    final bar = find.byType(LevelIndicator);
    await level(0.5);
    expect(bar, paints..rrect(color: c.accent));
    await level(0.8);
    expect(bar, paints..rrect(color: c.warning));
    await level(0.94);
    expect(bar, paints..rrect(color: c.warning));
    await level(0.95);
    expect(bar, paints..rrect(color: c.danger));
    const series = Color(0xFFAF52DE);
    await level(0.99, color: series);
    expect(bar, paints..rrect(color: series), reason: 'a fixed color ignores the thresholds');
  });

  testWidgets('activity view: name, environment, spinner while busy, opens the menu', (tester) async {
    final c = DbColors.light;
    var opened = 0;
    Widget view({required bool busy}) => _app(
      Center(
        child: ActivityView(
          title: 'erp_prod',
          status: busy ? 'Connessione…' : 'Errore',
          statusColor: busy ? null : c.danger,
          busy: busy,
          dot: c.success,
          environment: 'Produzione',
          environmentColor: c.danger,
          onPressed: () => opened++,
        ),
      ),
    );
    await tester.pumpWidget(view(busy: true));
    expect(tester.getSize(find.byType(ActivityView)).height, ControlSize.toolbar);
    expect(tester.widget<Text>(find.text('erp_prod')).style?.fontWeight, FontWeight.w600);
    expect(find.widgetWithText(Tag, 'Produzione'), findsOneWidget);
    expect(find.byType(StatusDot), findsOneWidget);
    expect(find.byType(Spinner), findsOneWidget);
    expect(find.byIcon(AppIcons.upDown), findsOneWidget);
    await tester.tap(find.text('erp_prod'));
    await tester.pump();
    expect(opened, 1);

    await tester.pumpWidget(view(busy: false));
    expect(find.byType(Spinner), findsNothing);
    expect(tester.widget<Text>(find.text('Errore')).style?.color, c.danger);
  });

  testWidgets('window tabs reorder by dragging', (tester) async {
    final order = ['a.sql', 'b.sql', 'c.sql'];
    final moves = <(int, int)>[];
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => WindowTabBar(
            itemCount: order.length,
            itemKey: (i) => ValueKey(order[i]),
            onReorder: (from, to) {
              moves.add((from, to));
              setState(() => order.insert(to, order.removeAt(from)));
            },
            itemBuilder: (_, i) => WindowTab(title: order[i], active: i == 0),
          ),
        ),
      ),
    );
    final drag = await tester.startGesture(tester.getCenter(find.text('a.sql')));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await drag.moveBy(const Offset(100, 0));
      await tester.pump();
    }
    await drag.up();
    await tester.pumpAndSettle();
    expect(moves, [(0, 2)]);
    expect(order, ['b.sql', 'c.sql', 'a.sql']);
    expect(tester.getCenter(find.text('a.sql')).dx, greaterThan(tester.getCenter(find.text('c.sql')).dx));
  });

  group('table refinements', () {
    /// First filled Container above [text]: the cell when it is tinted,
    /// the row otherwise.
    Color? fill(WidgetTester tester, String text) => tester
        .widgetList<Container>(find.ancestor(of: find.text(text), matching: find.byType(Container)))
        .map((w) => w.color)
        .firstWhere((c) => c != null, orElse: () => null);

    double width(WidgetTester tester, String header) =>
        tester.getSize(find.ancestor(of: find.text(header), matching: find.byType(TableHeaderCell))).width;

    testWidgets('multiple selection: click, ⇧-click, ⌘-click, ⇧↑, ⌘A and ⌘C', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      var sel = <int>{};
      int? opened;
      int? menuRow;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 500,
              height: 300,
              child: MacTable(
                headers: const ['id', 'nome'],
                rowCount: 5,
                cell: (r, c) => c == 0 ? '${r + 1}' : 'riga ${r + 1}',
                selection: sel,
                onSelectionChanged: (s) => setState(() => sel = s),
                onDoubleTap: (r) => opened = r,
                onContextMenu: (r, _, _) => menuRow = r,
              ),
            ),
          ),
        ),
      );
      Future<void> click(String text, [LogicalKeyboardKey? modifier]) async {
        if (modifier != null) await tester.sendKeyDownEvent(modifier);
        await tester.tap(find.text(text));
        if (modifier != null) await tester.sendKeyUpEvent(modifier);
        // Past the double click timeout, so the next click is a new one.
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      }

      await click('riga 2');
      expect(sel, {1});
      await click('riga 4', LogicalKeyboardKey.shiftLeft);
      expect(sel, {1, 2, 3}, reason: '⇧-click selects the range from the anchor');
      await click('riga 1', LogicalKeyboardKey.metaLeft);
      expect(sel, {0, 1, 2, 3}, reason: '⌘-click adds a row');
      await click('riga 3', LogicalKeyboardKey.metaLeft);
      expect(sel, {0, 1, 3}, reason: '⌘-click removes a selected row');
      expect(opened, isNull, reason: 'clicks apart are not a double click');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(copied, '1\triga 1\n2\triga 2\n4\triga 4', reason: '⌘C copies the rows in order, tab-separated');

      await click('riga 5');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(sel, {2, 3, 4}, reason: '⇧↑ extends from the anchor');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(sel, {3}, reason: 'an arrow alone moves a single selection');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(sel, {0, 1, 2, 3, 4});

      await tester.tap(find.text('riga 3'), buttons: kSecondaryButton);
      await tester.pump();
      expect(sel, {0, 1, 2, 3, 4}, reason: 'right click on a selected row keeps the selection');
      expect(menuRow, 2);
      await click('riga 1');
      await tester.tap(find.text('riga 3'), buttons: kSecondaryButton);
      await tester.pump();
      expect(sel, {2}, reason: 'right click elsewhere selects that row');

      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.tap(find.text('riga 2'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('riga 2'));
      expect(opened, 1);
      expect(sel, {1});
      opened = null;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened, 1, reason: 'Invio opens the current row');
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('emphasized selection: solid accent with focus, muted without', (tester) async {
      final other = FocusNode();
      addTearDown(other.dispose);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              Focus(focusNode: other, child: const SizedBox(height: 10)),
              Expanded(
                child: MacTable(
                  headers: const ['nome'],
                  rowCount: 2,
                  cell: (r, _) => 'riga ${r + 1}',
                  selection: const {0},
                  onSelectionChanged: (_) {},
                  emphasizeSelection: true,
                ),
              ),
            ],
          ),
        ),
      );
      final c = DbColors.of(tester.element(find.byType(MacTable)));
      expect(fill(tester, 'riga 1'), Color.alphaBlend(c.selectionMuted, c.content));
      // The selection is fixed here: the click only focuses the table.
      await tester.tap(find.text('riga 2'));
      await tester.pump();
      expect(fill(tester, 'riga 1'), Color.alphaBlend(c.selectionEmphasized, c.content));
      expect(tester.widget<Text>(find.text('riga 1')).style?.color, c.onSelectionEmphasized);
      other.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(fill(tester, 'riga 1'), Color.alphaBlend(c.selectionMuted, c.content));
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('cell tint, header icon and footer', (tester) async {
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 400,
            height: 200,
            child: MacTable(
              headers: const ['id', 'nome'],
              rowCount: 2,
              cell: (r, c) => c == 0 ? '${r + 1}' : 'riga ${r + 1}',
              cellTint: (r, c) => r == 1 && c == 1 ? const Color(0x38FF9500) : null,
              headerLeading: (c) => c == 0 ? const Icon(AppIcons.key, size: 11) : null,
              footer: const Text('Carica altri'),
            ),
          ),
        ),
      );
      expect(fill(tester, 'riga 2'), const Color(0x38FF9500));
      expect(fill(tester, '2'), isNot(const Color(0x38FF9500)));
      expect(find.descendant(of: find.byType(TableHeaderCell), matching: find.byIcon(AppIcons.key)), findsOneWidget);
      expect(find.text('Carica altri'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Carica altri')).dy,
        greaterThan(tester.getBottomLeft(find.text('riga 2')).dy),
      );
    });

    testWidgets('flex columns share the width left by the fixed ones', (tester) async {
      Widget table(double w) => _app(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: w,
            child: MacTable(
              headers: const ['nome', 'a', 'b'],
              rowCount: 1,
              cell: (_, c) => 'x',
              shrinkWrap: true,
              resizable: false,
              width: (c) => c == 0 ? 100 : 60,
              flex: (c) => c == 0 ? null : c.toDouble(),
            ),
          ),
        ),
      );
      await tester.pumpWidget(table(400));
      expect(width(tester, 'nome'), 100);
      expect(width(tester, 'a'), closeTo(100, 0.01));
      expect(width(tester, 'b'), closeTo(200, 0.01));
      await tester.pumpWidget(table(200));
      expect(width(tester, 'a'), 60, reason: 'width is the minimum of a flex column');
      expect(width(tester, 'b'), closeTo(66.67, 0.01));
    });

    testWidgets('wrap: long cells wrap and the row grows', (tester) async {
      const long = 'una descrizione molto lunga che non entra in una sola riga della colonna';
      Widget table({required bool wrap}) => _app(
        Align(
          alignment: Alignment.topLeft,
          child: MacTable(
            headers: const ['nome', 'nota'],
            rowCount: 2,
            cell: (r, c) => c == 0 ? 'riga ${r + 1}' : (r == 0 ? long : 'breve'),
            width: (c) => c == 0 ? 120 : 160,
            shrinkWrap: true,
            wrap: wrap,
          ),
        ),
      );
      double rowHeight(String text) =>
          tester.getSize(find.ancestor(of: find.text(text), matching: find.byType(RowTint)).first).height;
      await tester.pumpWidget(table(wrap: false));
      expect(rowHeight('riga 1'), GridMetrics.row);
      await tester.pumpWidget(table(wrap: true));
      expect(rowHeight('riga 1'), greaterThan(GridMetrics.row * 2));
      // 24 with SF; the test font's line is 1pt taller.
      expect(rowHeight('riga 2'), closeTo(GridMetrics.row, 1), reason: 'a one-line row keeps its height');
      expect(tester.getTopLeft(find.text('riga 1')).dy, tester.getTopLeft(find.text(long)).dy, reason: 'top aligned');
    });
  });

  testWidgets('record view: a double click on a field opens it', (tester) async {
    final opened = <int>[];
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: RecordView(
            fields: const [RecordField('id', '20'), RecordField('nome', 'Annalisa')],
            onFieldDoubleTap: opened.add,
          ),
        ),
      ),
    );
    Finder value(String text) => find.byWidgetPredicate((w) => w is SelectableText && w.data == text);
    await tester.tap(value('Annalisa'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.tap(value('Annalisa'));
    expect(opened, isEmpty, reason: 'two clicks apart');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(value('Annalisa'));
    expect(opened, [1]);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.tap(find.text('id'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('id'));
    expect(opened, [1, 0], reason: 'the name opens the field too');
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets('list row: the hover accessory shows only under the pointer', (tester) async {
    await tester.pumpWidget(
      _app(
        ListRow(
          title: 'demo_pg',
          trailing: const Text('dot'),
          trailingOnHover: LinkButton(label: 'Apri', small: true, onPressed: () {}),
          onTap: () {},
        ),
      ),
    );
    bool shown() =>
        tester.widget<Visibility>(find.ancestor(of: find.text('Apri'), matching: find.byType(Visibility))).visible;
    final before = tester.getTopLeft(find.text('dot'));
    expect(shown(), isFalse);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.text('demo_pg')));
    await tester.pump();
    expect(shown(), isTrue);
    expect(tester.getTopLeft(find.text('dot')), before, reason: 'the space is kept');
    await mouse.moveTo(const Offset(1000, 1000));
    await tester.pump();
    expect(shown(), isFalse);
  });

  testWidgets('outline row: leading sits before the icon, or replaces a missing one', (tester) async {
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            OutlineRow(
              title: 'clienti',
              icon: AppIcons.table,
              leading: MacCheckbox(value: true, onChanged: (_) {}),
            ),
            const OutlineRow(title: 'ordini.sql', leading: Text('M')),
          ],
        ),
      ),
    );
    final box = tester.getRect(find.byType(MacCheckbox));
    final icon = tester.getRect(find.byIcon(AppIcons.table));
    expect(box.right, lessThanOrEqualTo(icon.left), reason: 'checkbox, then the icon');
    expect(icon.right, lessThan(tester.getTopLeft(find.text('clienti')).dx));
    expect(tester.getTopLeft(find.text('M')).dx, lessThan(tester.getTopLeft(find.text('ordini.sql')).dx));
  });
}
