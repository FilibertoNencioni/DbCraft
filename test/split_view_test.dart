import 'package:dbcraft/ui/theme/app_theme.dart';
import 'package:dbcraft/ui/widgets/split_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Counter extends StatefulWidget {
  const _Counter(this.label);
  final String label;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => setState(() => taps++),
        child: Text('${widget.label} $taps', textDirection: TextDirection.ltr),
      );
}

Widget _host({required bool collapsedFirst, bool collapsedSecond = false, Duration duration = Duration.zero}) =>
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 1001,
          child: SplitView(
            initialFraction: 0.3,
            collapsedFirst: collapsedFirst,
            collapsedSecond: collapsedSecond,
            collapseDuration: duration,
            first: const _Counter('side'),
            second: const _Counter('main'),
          ),
        ),
      ),
    );

double _firstWidth(WidgetTester t) =>
    t.getSize(find.ancestor(of: find.byType(ClipRect), matching: find.byType(SizedBox)).first).width;

void main() {
  testWidgets('collapsing either pane keeps both panes mounted with their state', (t) async {
    await t.binding.setSurfaceSize(const Size(1001, 600));
    await t.pumpWidget(_host(collapsedFirst: false));
    await t.tap(find.text('side 0'));
    await t.tap(find.text('main 0'));
    await t.pump();

    await t.pumpWidget(_host(collapsedFirst: true));
    expect(find.text('side 1'), findsNothing); // offstage
    expect(find.text('side 1', skipOffstage: false), findsOneWidget);
    await t.pumpWidget(_host(collapsedFirst: false));
    expect(find.text('side 1'), findsOneWidget);
    expect(find.text('main 1'), findsOneWidget);

    await t.pumpWidget(_host(collapsedFirst: false, collapsedSecond: true));
    await t.pumpWidget(_host(collapsedFirst: false));
    expect(find.text('main 1'), findsOneWidget);
  });

  testWidgets('pointer toggles slide, keyboard toggles cut, mid-slide toggles reverse', (t) async {
    await t.binding.setSurfaceSize(const Size(1001, 600));
    const slide = Duration(milliseconds: 200);
    await t.pumpWidget(_host(collapsedFirst: false, duration: slide));
    expect(_firstWidth(t), 300);

    await t.pumpWidget(_host(collapsedFirst: true, duration: slide));
    await t.pump(const Duration(milliseconds: 60));
    final mid = _firstWidth(t);
    expect(mid, inExclusiveRange(0, 300));

    // Reverse before the slide finishes: it heads back without jumping.
    await t.pumpWidget(_host(collapsedFirst: false, duration: slide));
    await t.pump(const Duration(milliseconds: 16));
    expect(_firstWidth(t), greaterThan(mid - 1));
    await t.pumpAndSettle();
    expect(_firstWidth(t), 300);

    await t.pumpWidget(_host(collapsedFirst: true));
    expect(_firstWidth(t), 0);
  });

  testWidgets('a sidebar slide reflows only the visible tab', (t) async {
    await t.binding.setSurfaceSize(const Size(1001, 600));
    final layouts = List.filled(4, 0);
    Widget host(bool collapsed) => MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SplitView(
              collapsedFirst: collapsed,
              collapseDuration: const Duration(milliseconds: 200),
              first: const SizedBox(),
              second: IndexedStack(index: 1, children: [
                for (var i = 0; i < 4; i++) HoldLayout(hold: i != 1, child: _LayoutProbe(() => layouts[i]++)),
              ]),
            ),
          ),
        );
    await t.pumpWidget(host(false));
    layouts.fillRange(0, 4, 0);

    await t.pumpWidget(host(true));
    await t.pumpAndSettle();
    expect(layouts[1], greaterThan(1));
    expect([layouts[0], layouts[2], layouts[3]], [0, 0, 0]);
  });
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe(this.onLayout);
  final VoidCallback onLayout;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLayoutProbe(onLayout);
}

class _RenderLayoutProbe extends RenderProxyBox {
  _RenderLayoutProbe(this.onLayout);
  final VoidCallback onLayout;
  @override
  void performLayout() {
    onLayout();
    size = constraints.biggest;
  }
}
