import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
  theme: buildTheme(brightness),
  home: Scaffold(body: child),
);

BoxDecoration _decoration(WidgetTester tester, Finder of) =>
    tester.widget<Container>(find.descendant(of: of, matching: find.byType(Container)).first).decoration!
        as BoxDecoration;

void main() {
  group('Inspector', () {
    testWidgets('sits on windowBackground with the hairline towards the content, width clamped', (tester) async {
      await tester.pumpWidget(
        _app(
          const Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Inspector(width: 500, children: [Text('a')]),
              Spacer(),
              Inspector(width: 100, side: InspectorSide.start, children: [Text('b')]),
            ],
          ),
        ),
      );
      final c = DbColors.light;
      final inspectors = find.byType(Inspector);
      expect(tester.getSize(inspectors.first).width, Inspector.maxWidth);
      expect(tester.getSize(inspectors.last).width, Inspector.minWidth);

      final end = _decoration(tester, inspectors.first);
      expect(end.color, c.windowBackground);
      final endBorder = end.border! as Border;
      expect(endBorder.left.width, 0.5);
      expect(endBorder.right, BorderSide.none);

      final startBorder = _decoration(tester, inspectors.last).border! as Border;
      expect(startBorder.right.width, 0.5);
      expect(startBorder.left, BorderSide.none);
    });

    testWidgets('splits consecutive sections with a hairline', (tester) async {
      await tester.pumpWidget(
        _app(
          const Inspector(
            children: [
              Text('Intestazione'),
              InspectorSection(title: 'Dati', children: [Text('x')]),
              InspectorSection(title: 'Aspetto', children: [Text('y')]),
              InspectorSection(title: 'Avanzate', children: [Text('z')]),
            ],
          ),
        ),
      );
      expect(find.descendant(of: find.byType(Inspector), matching: find.byType(Divider)), findsNWidgets(2));
    });
  });

  group('InspectorSection', () {
    testWidgets('the header toggles the content, from the label and from the chevron', (tester) async {
      final changes = <bool>[];
      await tester.pumpWidget(
        _app(
          Inspector(
            children: [
              InspectorSection(title: 'Dati', onExpandedChanged: changes.add, children: const [Text('Asse X')]),
            ],
          ),
        ),
      );
      final title = tester.widget<Text>(find.text('Dati'));
      expect(title.style!.fontSize, TypeSize.caption);
      expect(title.style!.fontWeight, FontWeight.w600);
      expect(find.byType(DisclosureChevron), findsOneWidget);
      expect(find.text('Asse X'), findsOneWidget);

      await tester.tap(find.text('Dati'));
      await tester.pumpAndSettle();
      expect(find.text('Asse X'), findsNothing);

      await tester.tap(find.byType(DisclosureChevron));
      await tester.pumpAndSettle();
      expect(find.text('Asse X'), findsOneWidget);
      expect(changes, [false, true]);
    });

    testWidgets('starts collapsed with initiallyExpanded: false', (tester) async {
      await tester.pumpWidget(
        _app(
          const Inspector(
            children: [
              InspectorSection(title: 'Avanzate', initiallyExpanded: false, children: [Text('Serie impilate')]),
            ],
          ),
        ),
      );
      expect(find.text('Serie impilate'), findsNothing);
      await tester.tap(find.text('Avanzate'));
      await tester.pumpAndSettle();
      expect(find.text('Serie impilate'), findsOneWidget);
    });

    testWidgets('a controlled section follows expanded and reports taps', (tester) async {
      var expanded = true;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, set) => Inspector(
              children: [
                InspectorSection(
                  title: 'Opzioni',
                  expanded: expanded,
                  onExpandedChanged: (v) => set(() => expanded = v),
                  children: const [Text('Ignora maiuscole')],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Opzioni'));
      await tester.pumpAndSettle();
      expect(expanded, isFalse);
      expect(find.text('Ignora maiuscole'), findsNothing);
    });

    testWidgets('collapsible: false has no chevron and always shows its rows', (tester) async {
      await tester.pumpWidget(
        _app(
          const Inspector(
            children: [
              InspectorSection(title: 'Piano', collapsible: false, children: [Text('Costo')]),
            ],
          ),
        ),
      );
      expect(find.byType(DisclosureChevron), findsNothing);
      await tester.tap(find.text('Piano'));
      await tester.pumpAndSettle();
      expect(find.text('Costo'), findsOneWidget);
    });
  });

  group('StatTile', () {
    testWidgets('label 11 secondary, value 17 semibold tabular, child below', (tester) async {
      await tester.pumpWidget(
        _app(
          const Center(
            child: StatTile(
              label: 'Connessioni',
              value: '42',
              child: SizedBox(key: Key('spark'), height: 26),
            ),
          ),
        ),
      );
      final c = DbColors.light;
      final label = tester.widget<Text>(find.text('Connessioni'));
      expect(label.style!.fontSize, TypeSize.caption);
      expect(label.style!.color, c.textSecondary);
      final value = tester.widget<Text>(find.text('42'));
      expect(value.style!.fontSize, TypeSize.sheetTitle);
      expect(value.style!.fontWeight, FontWeight.w600);
      expect(value.style!.fontFeatures, kTabular);
      expect(value.style!.color, c.text);
      expect(
        tester.getTopLeft(find.byKey(const Key('spark'))).dy,
        greaterThan(tester.getBottomLeft(find.text('42')).dy),
      );

      final box = _decoration(tester, find.byType(StatTile));
      expect(box.color, c.content);
      expect(box.borderRadius, BorderRadius.circular(Radii.panel));
      expect((box.border! as Border).top.width, 0.5);
      expect(tester.getSize(find.byType(StatTile)).width, StatTile.defaultWidth);
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('warning turns the value amber and tooltip adds a Tooltip', (tester) async {
      await tester.pumpWidget(
        _app(
          const Center(
            child: StatTile(label: 'Cache hit', value: '80%', warning: true, tooltip: 'Sotto soglia'),
          ),
        ),
      );
      expect(tester.widget<Text>(find.text('80%')).style!.color, DbColors.light.warning);
      expect(find.byTooltip('Sotto soglia'), findsOneWidget);
    });
  });

  testWidgets('InsetBox: content, radius 8, 0.5 hairline, clipped', (tester) async {
    await tester.pumpWidget(
      _app(
        Center(
          child: InsetBox(width: 200, height: 100, child: Container(color: DbColors.light.accent)),
        ),
        brightness: Brightness.dark,
      ),
    );
    final box = tester.widget<Container>(
      find.descendant(of: find.byType(InsetBox), matching: find.byType(Container)).first,
    );
    final d = box.decoration! as BoxDecoration;
    expect(d.color, DbColors.dark.content);
    expect(d.borderRadius, BorderRadius.circular(Radii.panel));
    expect((d.border! as Border).top.width, 0.5);
    expect((d.border! as Border).top.color, DbColors.dark.separator);
    expect(box.clipBehavior, Clip.antiAlias);
    expect(tester.getSize(find.byType(InsetBox)), const Size(200, 100));
  });

  group('DragChip', () {
    testWidgets('a raised capsule with the menu shadow, icon and 12pt label', (tester) async {
      await tester.pumpWidget(
        _app(
          const Center(
            child: DragChip(label: 'dipendenti', icon: AppIcons.table),
          ),
        ),
      );
      final c = DbColors.light;
      final shadow = tester.widget<DecoratedBox>(
        find.descendant(of: find.byType(DragChip), matching: find.byType(DecoratedBox)).first,
      );
      expect((shadow.decoration as BoxDecoration).boxShadow, Elevation.menu(Brightness.light));
      expect(find.descendant(of: find.byType(DragChip), matching: find.byType(Capsule)), findsOneWidget);
      expect(tester.getSize(find.byType(Capsule)).height, ControlSize.regular);
      final icon = tester.widget<Icon>(find.byIcon(AppIcons.table));
      expect(icon.color, c.accent);
      final label = tester.widget<Text>(find.text('dipendenti'));
      expect(label.style!.fontSize, TypeSize.small);
      expect(label.style!.color, c.text);
    });

    testWidgets('renders as drag feedback outside any Material', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Center(
            child: Draggable<int>(
              data: 1,
              feedback: DragChip(label: 'd.reparto_id'),
              child: SizedBox(width: 80, height: 30, child: Text('trascina')),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(find.text('trascina')));
      await gesture.moveBy(const Offset(40, 40));
      await tester.pump();
      expect(find.text('d.reparto_id'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
      expect(tester.takeException(), isNull);
      await gesture.up();
      await tester.pump();
    });
  });
}
