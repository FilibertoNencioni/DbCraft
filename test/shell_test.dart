import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Scaffold(body: child),
);

void main() {
  group('bars', () {
    testWidgets('PaneBar is 36pt; the loading line runs over it without moving the layout', (tester) async {
      Widget bar(bool loading) => _app(
        Column(
          children: [
            PaneBar(loading: loading, children: const [Text('Esegui')]),
            const Text('sotto'),
          ],
        ),
      );
      await tester.pumpWidget(bar(false));
      expect(tester.getSize(find.byType(PaneBar)).height, BarHeight.bar);
      expect(find.byType(LoadingLine), findsNothing);
      final below = tester.getTopLeft(find.text('sotto'));

      await tester.pumpWidget(bar(true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LoadingLine), findsOneWidget);
      expect(tester.getTopLeft(find.text('sotto')), below);
      expect(tester.getCenter(find.text('Esegui')).dy, closeTo(BarHeight.bar / 2, 1));
    });

    testWidgets('PaneHeader is 28pt, StatusBar 22pt with 11pt text', (tester) async {
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              PaneHeader(
                title: 'Variabili',
                actions: [ToolButton(icon: AppIcons.refresh, tooltip: 'Aggiorna', onPressed: () {})],
              ),
              const Spacer(),
              const StatusBar(children: [Text('demo_pg')]),
            ],
          ),
        ),
      );
      expect(tester.getSize(find.byType(PaneHeader)).height, BarHeight.subbar);
      expect(find.byTooltip('Aggiorna'), findsOneWidget);
      expect(tester.getSize(find.byType(StatusBar)).height, BarHeight.status);
      final style = DefaultTextStyle.of(tester.element(find.text('demo_pg'))).style;
      expect(style.fontSize, TypeSize.caption);
    });
  });

  group('outline row', () {
    testWidgets('busy shows a spinner in place of the chevron and does not toggle', (tester) async {
      final toggles = <bool>[];
      await tester.pumpWidget(
        _app(
          SourceList(
            itemCount: 1,
            itemBuilder: (_, _) =>
                OutlineRow(title: 'demo_pg', expanded: false, busy: true, onExpand: toggles.add, strong: true),
          ),
        ),
      );
      expect(find.byType(Spinner), findsOneWidget);
      expect(find.byType(DisclosureChevron), findsNothing);
      await tester.tap(find.byType(Spinner));
      await tester.tap(find.text('demo_pg'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('demo_pg'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(toggles, isEmpty);
      expect(tester.widget<Text>(find.text('demo_pg')).style?.fontWeight, FontWeight.w600);
    });

    testWidgets('titleColor applies off the accent', (tester) async {
      await tester.pumpWidget(_app(const OutlineRow(title: 'errore', titleColor: Color(0xFFFF0000))));
      expect(tester.widget<Text>(find.text('errore')).style?.color, const Color(0xFFFF0000));
    });
  });

  testWidgets('PopUpButton with custom entries shows them and returns their value', (tester) async {
    var value = 'a';
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => PopUpButton<String>(
            style: PopUpStyle.toolbar,
            value: value,
            items: const [('a', 'demo_pg', null), ('b', 'erp_prod', null)],
            entries: () => [
              MenuEntry.connection(name: 'demo_pg', status: const Color(0xFF00FF00), value: 'a', checked: value == 'a'),
              MenuEntry.connection(
                name: 'erp_prod',
                status: const Color(0xFF888888),
                environment: 'Produzione',
                value: 'b',
              ),
            ],
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );
    await tester.tap(find.text('demo_pg'));
    await tester.pumpAndSettle();
    expect(find.text('Produzione'), findsOneWidget, reason: 'the custom rows carry the environment tag');
    await tester.tap(find.text('erp_prod'));
    await tester.pumpAndSettle();
    expect(value, 'b');
    expect(find.text('erp_prod'), findsOneWidget);
  });
}
