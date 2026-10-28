import 'dart:convert';
import 'dart:io';

import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/home_page.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Scaffold(body: child),
);

/// An [AppState] on a temporary workspace with two fake connections: a
/// development one and a production one whose password is not saved, so
/// choosing it asks for the password instead of connecting.
Future<AppState> _fakeState(WidgetTester tester) async {
  final ws = Directory.systemTemp.createTempSync('dbcraft-shell-test-');
  addTearDown(() => ws.deleteSync(recursive: true));
  File('${ws.path}/connections.json').writeAsStringSync(
    jsonEncode([
      {'id': 'demo', 'name': 'Demo SQLite', 'mode': 'driver', 'driver': 'SQLite3', 'database': '/tmp/none.db'},
      {
        'id': 'prod',
        'name': 'SQL Server Produzione',
        'mode': 'driver',
        'driver': 'ODBC Driver 17 for SQL Server',
        'host': 'sql.esempio.local',
        'database': 'ERP',
        'user': 'sa',
        'savePassword': false,
        'type': 'production',
      },
    ]),
  );
  final state = (await tester.runAsync(() => AppState.load(workspaceDir: ws)))!;
  state.settings.themeMode = ThemeMode.light;
  return state;
}

Future<void> _pumpShell(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const HomePage()),
    ),
  );
  await tester.pump();
}

/// The shell builds the native menu bar on a macOS host, whose provided items
/// exist only when the target platform is macOS too.
final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

/// Through the 200ms sidebar slide (and the toolbar padding that follows it).
Future<void> _slide(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

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

  group('shell', () {
    final toggle = find.byWidgetPredicate((w) => w is ToolButton && w.icon == AppIcons.sidebar);
    final sidebar = find.ancestor(of: find.byType(SidebarTabs<int>), matching: find.byType(Material)).first;
    final toolbar = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_AppToolbar');
    final newConnection = find.byWidgetPredicate((w) => w is ToolButton && w.icon == AppIcons.addLink);

    testWidgets('sidebar toggle, toolbar inset and status bar follow the sidebar', (tester) async {
      await _pumpShell(tester, await _fakeState(tester));
      final inset = trafficLightInset(false);
      expect(inset, Platform.isMacOS ? 88 : 0);

      // Shown: the toggle sits in the sidebar's title-bar strip, right of the
      // traffic lights; the toolbar starts after the sidebar with a plain margin.
      var side = tester.getRect(sidebar);
      var bar = tester.getRect(toolbar);
      var t = tester.getRect(toggle);
      expect(side.left, 0);
      expect(t.left, inset + Gap.sm);
      expect(t.right, lessThanOrEqualTo(side.right));
      expect(t.top, greaterThanOrEqualTo(0));
      expect(t.bottom, lessThanOrEqualTo(BarHeight.toolbar));
      expect(bar.left, greaterThanOrEqualTo(side.right));
      expect(bar.height, BarHeight.toolbar);
      expect(tester.getRect(newConnection).left - bar.left, Gap.sm);
      // The status bar runs under the content column only.
      var status = tester.getRect(find.byType(StatusBar));
      expect(status.left, bar.left);
      expect(status.right, bar.right);
      expect(status.left, greaterThanOrEqualTo(side.right));
      expect(status.bottom, 900);

      // Hidden with the toolbar button: the toggle stays put, now over the
      // toolbar, which makes room for the traffic lights and the toggle.
      await tester.tap(find.byTooltip('Nascondi barra laterale (${shortcutLabel(_cmd(LogicalKeyboardKey.digit0))})'));
      await _slide(tester);
      expect(find.byType(SidebarTabs<int>), findsNothing, reason: "the collapsed sidebar is offstage");
      bar = tester.getRect(toolbar);
      t = tester.getRect(toggle);
      expect(bar.left, 0);
      expect(t.left, inset + Gap.sm);
      expect(bar.contains(t.center), isTrue);
      expect(t.top, greaterThanOrEqualTo(bar.top));
      expect(t.bottom, lessThanOrEqualTo(bar.bottom));
      final leading = inset + Gap.sm + ControlSize.toolbar + Gap.md;
      expect(tester.getRect(newConnection).left, leading);
      expect(t.right, lessThan(leading), reason: 'the toolbar content clears the toggle');
      status = tester.getRect(find.byType(StatusBar));
      expect(status.left, 0);
      expect(status.right, bar.right);
      expect(
        find.byTooltip('Mostra barra laterale (${shortcutLabel(_cmd(LogicalKeyboardKey.digit0))})'),
        findsOneWidget,
      );

      // Shown again with the keyboard shortcut (no slide).
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await _slide(tester);
      side = tester.getRect(sidebar);
      bar = tester.getRect(toolbar);
      status = tester.getRect(find.byType(StatusBar));
      expect(side.width, greaterThan(0));
      expect(bar.left, greaterThanOrEqualTo(side.right));
      expect(tester.getRect(newConnection).left - bar.left, Gap.sm);
      expect(tester.getRect(toggle).right, lessThanOrEqualTo(side.right));
      expect(status.left, greaterThanOrEqualTo(side.right));
    }, variant: _mac);
  });
}

SingleActivator _cmd(LogicalKeyboardKey k) => SingleActivator(k, meta: Platform.isMacOS, control: !Platform.isMacOS);
