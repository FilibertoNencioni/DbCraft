import 'dart:async';

import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An app with one button that runs [onPressed] with a context under the
/// navigator.
Widget _launcher(void Function(BuildContext context) onPressed) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(child: PushButton(label: 'Apri', onPressed: () => onPressed(context))),
    ),
  ),
);

Widget _app(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Scaffold(body: child),
);

void main() {
  group('sheets', () {
    testWidgets('Esc closes a sheet, Invio runs the default action', (tester) async {
      var submitted = 0;
      Object? result = 'pending';
      await tester.pumpWidget(_launcher((context) async {
        result = await showSheet<String>(
          context,
          builder: (ctx) => SheetScaffold(
            title: 'Nuova connessione',
            body: const Text('corpo'),
            onSubmit: () => submitted++,
            actions: [PushButton(label: 'Annulla', onPressed: () => Navigator.pop(ctx))],
          ),
        );
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      expect(find.text('Nuova connessione'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(submitted, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Nuova connessione'), findsNothing);
      expect(result, isNull);
    });

    testWidgets('Invio in a multi-line field inserts text, ⌘Invio submits', (tester) async {
      var submitted = 0;
      await tester.pumpWidget(_launcher((context) {
        showSheet<void>(
          context,
          builder: (ctx) => SheetScaffold(
            title: 'Commit',
            body: const MacTextField(maxLines: 4, autofocus: true),
            onSubmit: () => submitted++,
          ),
        );
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(submitted, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(submitted, 1);
    });

    testWidgets('large sheets have a fixed height and a large title', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_launcher((context) {
        showSheet<void>(
          context,
          size: SheetSize.large,
          builder: (_) => const SheetScaffold(title: 'Grande', body: SizedBox.expand()),
        );
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SheetSurface)), const Size(780, 560));
      expect(tester.getCenter(find.byType(SheetSurface)), const Offset(600, 450));
      expect(tester.widget<Text>(find.text('Grande')).style!.fontSize, TypeSize.sheetTitle);
    });
  });

  group('alerts', () {
    testWidgets('confirmDialog: button, Invio and Esc', (tester) async {
      bool? result;
      await tester.pumpWidget(_launcher((context) async {
        result = await confirmDialog(context, 'Eliminare?', 'Non si può annullare.', ok: 'Elimina', destructive: true);
      }));

      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SheetSurface)).width, 260);
      await tester.tap(find.text('Elimina'));
      await tester.pumpAndSettle();
      expect(result, isTrue);

      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(result, isFalse);

      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('promptText returns the typed text on Invio', (tester) async {
      String? result;
      await tester.pumpWidget(_launcher((context) async {
        result = await promptText(context, 'Rinomina', initial: 'a.sql');
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'b.sql');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, 'b.sql');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('three buttons stack, the first on top', (tester) async {
      await tester.pumpWidget(_launcher((context) {
        showAlert<int>(
          context,
          title: 'Transazione aperta',
          buttons: const [
            AlertButton('Commit', 0, role: AlertRole.defaultAction),
            AlertButton('Rollback', 1),
            AlertButton('Annulla', 2, role: AlertRole.cancel),
          ],
        );
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      final commit = tester.getCenter(find.text('Commit'));
      final cancel = tester.getCenter(find.text('Annulla'));
      expect(commit.dx, cancel.dx);
      expect(commit.dy, lessThan(cancel.dy));
    });

    testWidgets('error alert shows the first line, details on demand', (tester) async {
      await tester.pumpWidget(_launcher((context) {
        showErrorDialog(context, Exception('Connessione rifiutata\nSQLSTATE 08001'));
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      expect(find.text('Connessione rifiutata'), findsOneWidget);
      expect(find.textContaining('SQLSTATE'), findsNothing);
      await tester.tap(find.text('Mostra dettagli'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SQLSTATE 08001'), findsOneWidget);
    });

    testWidgets('list picker filters, moves with arrows, chooses with Invio', (tester) async {
      String? result;
      await tester.pumpWidget(_launcher((context) async {
        result = await showListPicker<String>(
          context,
          title: 'Scegli',
          items: const ['clienti', 'ordini', 'ordini_righe', 'prodotti'],
          label: (s) => s,
        );
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'ord');
      await tester.pump();
      expect(find.text('clienti'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, 'ordini_righe');
    });

    testWidgets('list picker loads its items behind a spinner, with tinted icons', (tester) async {
      final c = DbColors.light;
      final items = Completer<List<String>>();
      await tester.pumpWidget(_launcher((context) {
        showListPicker<String>(
          context,
          title: 'Tabelle',
          load: () => items.future,
          label: (s) => s,
          icon: (_) => AppIcons.table,
          iconColor: (_) => c.accent,
        );
      }));
      await tester.tap(find.text('Apri'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(Spinner), findsOneWidget);
      expect(tester.widget<PushButton>(find.widgetWithText(PushButton, 'Scegli')).onPressed, isNull);

      items.complete(['clienti', 'ordini']);
      await tester.pump();
      expect(find.byType(Spinner), findsNothing);
      expect(find.text('ordini'), findsOneWidget);
      final icons = tester.widgetList<Icon>(find.byIcon(AppIcons.table)).toList();
      expect(icons.first.color, c.onSelectionEmphasized, reason: 'the selected row stays white');
      expect(icons.last.color, c.accent);
    });

    testWidgets('list picker shows load errors and empty lists in the list', (tester) async {
      await tester.pumpWidget(_launcher((context) {
        showListPicker<String>(
          context,
          title: 'Tabelle',
          load: () => Future.error(Exception('permesso negato')),
          label: (s) => s,
          loadError: 'Tabelle non disponibili',
        );
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      expect(find.text('Tabelle non disponibili'), findsOneWidget);
      expect(find.textContaining('permesso negato'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.pumpWidget(_launcher((context) {
        showListPicker<String>(context, title: 'Tabelle', items: const [], label: (s) => s, empty: 'Nessuna tabella');
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      expect(find.text('Nessuna tabella'), findsOneWidget);
    });

    testWidgets('list picker chooses on a double click only', (tester) async {
      String? result;
      await tester.pumpWidget(_launcher((context) async {
        result = await showListPicker<String>(
          context,
          title: 'Scegli',
          items: const ['clienti', 'ordini'],
          label: (s) => s,
        );
      }));
      await tester.tap(find.text('Apri'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ordini'));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.tap(find.text('ordini'));
      await tester.pump();
      expect(find.text('ordini'), findsOneWidget, reason: 'two slow clicks only select');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('ordini'));
      await tester.pumpAndSettle();
      expect(result, 'ordini');
    });
  });

  group('feedback', () {
    testWidgets('showToast shows a HUD that fades away', (tester) async {
      await tester.pumpWidget(_launcher((context) => showToast(context, 'Copiato')));
      await tester.tap(find.text('Apri'));
      await tester.pump();
      expect(find.text('Copiato'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Copiato'), findsNothing);
    });

    testWidgets('a new HUD replaces the current one', (tester) async {
      var n = 0;
      await tester.pumpWidget(_launcher((context) => showToast(context, 'Messaggio ${++n}')));
      await tester.tap(find.text('Apri'));
      await tester.pump();
      await tester.tap(find.text('Apri'));
      await tester.pump();
      expect(find.text('Messaggio 1'), findsNothing);
      expect(find.text('Messaggio 2'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('EmptyState.error keeps the first line visible', (tester) async {
      await tester.pumpWidget(_app(const EmptyState.error('Timeout\nstack trace')));
      expect(find.text('Impossibile caricare i dati'), findsOneWidget);
      expect(find.text('Timeout'), findsOneWidget);
      expect(find.text('Mostra dettagli'), findsOneWidget);
    });

    testWidgets('Notice styles render title, message and actions', (tester) async {
      await tester.pumpWidget(_app(Column(
        children: [
          Notice(title: 'Titolo', message: 'Testo', actions: [LinkButton(label: 'Azione', onPressed: () {})]),
          const Notice.strip(kind: NoticeKind.danger, message: 'Striscia'),
          const Notice.card(message: 'Scheda'),
        ],
      )));
      expect(find.text('Titolo'), findsOneWidget);
      expect(find.text('Azione'), findsOneWidget);
      expect(find.textContaining('Striscia', findRichText: true), findsOneWidget);
      expect(tester.getSize(find.byType(Notice).at(1)).height, BarHeight.subbar);
    });
  });

  group('surfaces', () {
    test('parseUnifiedDiff numbers old and new lines', () {
      final lines = parseUnifiedDiff(
        'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -3,3 +3,3 @@\n a\n-b\n+c\n d\n',
      );
      expect(lines.map((l) => l.kind).toList(), [
        DiffLineKind.meta,
        DiffLineKind.meta,
        DiffLineKind.meta,
        DiffLineKind.hunk,
        DiffLineKind.context,
        DiffLineKind.removed,
        DiffLineKind.added,
        DiffLineKind.context,
      ]);
      expect(lines[5].text, 'b');
      expect(lines[5].oldLine, 4);
      expect(lines[6].newLine, 4);
      expect((lines[7].oldLine, lines[7].newLine), (5, 5));
    });

    testWidgets('DiffView lays out lazily and shrink-wrapped', (tester) async {
      const patch = '@@ -1,2 +1,2 @@\n-vecchia\n+nuova\n uguale\n';
      await tester.pumpWidget(_app(Column(
        children: [
          SizedBox(height: 120, child: DiffView.unified(patch)),
          DiffView.unified(patch, shrinkWrap: true),
        ],
      )));
      expect(find.text('nuova'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('FormGroup sizes the label column to the widest label', (tester) async {
      await tester.pumpWidget(_app(const SizedBox(
        width: 600,
        child: FormGroup(
          children: [
            FormRow(label: 'Host', child: MacTextField()),
            FormRow(label: 'Nome del database', child: MacTextField()),
          ],
        ),
      )));
      final short = tester.getTopLeft(find.byType(MacTextField).first).dx;
      final long = tester.getTopLeft(find.byType(MacTextField).last).dx;
      expect(short, long);
      expect(short, greaterThan(tester.getTopRight(find.text('Nome del database')).dx));
    });

    testWidgets('CodeBox header copies the code', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(_app(const CodeBox('SELECT 1;\n', label: 'sql')));
      expect(find.text('sql'), findsOneWidget);
      await tester.tap(find.byTooltip('Copia'));
      expect(copied, 'SELECT 1;');
    });

    testWidgets('FormGroups in a sheet share the label column', (tester) async {
      Widget groups(String other) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FormGroup(children: [FormRow(label: 'Host', child: MacTextField())]),
          FormGroup(title: 'Autenticazione', children: [FormRow(label: other, child: const MacTextField())]),
        ],
      );
      double field(int i) => tester.getTopLeft(find.byType(MacTextField).at(i)).dx;

      await tester.pumpWidget(_app(SizedBox(width: 600, child: groups('Nome utente'))));
      expect(field(0), lessThan(field(1)), reason: 'outside a scope each group fits its own labels');

      await tester.pumpWidget(_app(SizedBox(
        width: 600,
        height: 500,
        child: SheetScaffold(title: 'Connessione', body: groups('Nome utente')),
      )));
      expect(field(0), field(1));
      expect(field(0), greaterThan(tester.getTopRight(find.text('Nome utente')).dx));
    });

    testWidgets('a long label elsewhere in the scope does not squeeze a group', (tester) async {
      var long = false;
      await tester.pumpWidget(_app(SizedBox(
        width: 600,
        height: 500,
        child: StatefulBuilder(
          builder: (context, set) => SheetScaffold(
            title: 'Account',
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormGroup(
                  children: [
                    FormRow(label: 'Host', child: PushButton(label: 'Altro', onPressed: () => set(() => long = true))),
                  ],
                ),
                FormGroup(
                  children: [
                    const FormRow(label: 'Utente', child: MacTextField()),
                    if (long) const FormRow(label: 'Chiave di accesso segreta del servizio', child: MacTextField()),
                  ],
                ),
              ],
            ),
          ),
        ),
      )));
      final inner = tester.getSize(find.byType(FormGroup).first).width - Gap.md * 2;
      double hostColumn() => tester.getTopLeft(find.byType(MacTextField).first).dx;
      final before = hostColumn();
      await tester.tap(find.text('Altro'));
      await tester.pump();
      expect(hostColumn(), greaterThan(before), reason: 'the groups realign on the wider label');
      final groupLeft = tester.getTopLeft(find.byType(FormGroup).first).dx + Gap.md;
      final sharedColumn = tester.getTopLeft(find.byType(PushButton)).dx;
      expect(tester.getTopLeft(find.text('Host')).dx - groupLeft, lessThan(1));
      expect(sharedColumn, greaterThan(groupLeft));
      // The group with the long label takes up to 40%, the other stops at 30%.
      final hostLabel = tester
          .getSize(find.ancestor(of: find.text('Host'), matching: find.byType(SizedBox)).first)
          .width;
      expect(hostLabel, lessThanOrEqualTo(inner * 0.3 + 0.5));
      expect(hostColumn(), greaterThan(groupLeft + hostLabel));
      expect(tester.takeException(), isNull);
    });

    testWidgets('CodeBox.lines builds lazily and stays on the last line', (tester) async {
      final lines = [for (var i = 0; i < 500; i++) 'riga $i'];
      late StateSetter update;
      await tester.pumpWidget(_app(StatefulBuilder(
        builder: (context, set) {
          update = set;
          return SizedBox(
            height: 200,
            child: CodeBox.lines(lines, label: 'Output', emphasize: (l) => l.startsWith(r'$ ')),
          );
        },
      )));
      await tester.pump();
      expect(find.text('riga 0'), findsNothing);
      expect(find.text('riga 499'), findsOneWidget);

      update(() => lines.add(r'$ brew install'));
      await tester.pump();
      await tester.pump();
      expect(find.text(r'$ brew install'), findsOneWidget);
      expect(tester.widget<Text>(find.text(r'$ brew install')).style!.fontWeight, FontWeight.w600);
      expect(tester.widget<Text>(find.text('riga 499')).style!.color, DbColors.light.textSecondary);

      // Scrolled up, new lines do not move the view.
      await tester.drag(find.text('riga 499'), const Offset(0, 150));
      await tester.pump();
      update(() => lines.add('fine'));
      await tester.pump();
      await tester.pump();
      expect(find.text('fine'), findsNothing);
    });

    testWidgets('CodeBox.lines copies all the lines and shows a status row', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(_app(const CodeBox.lines(
        ['uno', 'due'],
        label: 'Log',
        maxLines: 4,
        status: Text('In corso'),
      )));
      expect(find.text('In corso'), findsOneWidget);
      await tester.tap(find.byTooltip('Copia'));
      expect(copied, 'uno\ndue');
    });
  });

  group('bars and navigation', () {
    BoxDecoration barDecoration(WidgetTester tester) {
      final bar = find.descendant(of: find.byType(PaneBar), matching: find.byType(Container)).first;
      return tester.widget<Container>(bar).decoration! as BoxDecoration;
    }

    testWidgets('PaneBar puts the hairline below, above or on both edges', (tester) async {
      await tester.pumpWidget(_app(const PaneBar(children: [Text('Barra')])));
      var border = barDecoration(tester).border! as Border;
      expect((border.top.style, border.bottom.style), (BorderStyle.none, BorderStyle.solid));

      await tester.pumpWidget(_app(const PaneBar.footer(loading: true, children: [Text('Barra')])));
      border = barDecoration(tester).border! as Border;
      expect((border.top.style, border.bottom.style), (BorderStyle.solid, BorderStyle.none));
      expect(tester.getTopLeft(find.byType(LoadingLine)).dy, closeTo(tester.getTopLeft(find.byType(PaneBar)).dy, 0.5));
      expect(tester.getSize(find.byType(PaneBar)).height, BarHeight.bar);

      await tester.pumpWidget(_app(const PaneBar(hairline: BarHairline.both, children: [Text('Barra')])));
      border = barDecoration(tester).border! as Border;
      expect((border.top.style, border.bottom.style), (BorderStyle.solid, BorderStyle.solid));
    });

    testWidgets('PaneTab tints its icon and closes on a middle click', (tester) async {
      final c = DbColors.light;
      var closed = 0;
      await tester.pumpWidget(_app(PaneTabs<int>(
        value: 0,
        onChanged: (_) {},
        tabs: [
          PaneTab(0, 'Risultato 1', icon: AppIcons.error, iconColor: c.danger, onClose: () => closed++),
          const PaneTab(1, 'Log', icon: AppIcons.history),
        ],
      )));
      expect(tester.widget<Icon>(find.byIcon(AppIcons.error)).color, c.danger);
      expect(tester.widget<Icon>(find.byIcon(AppIcons.history)).color, c.textSecondary);
      await tester.tap(find.text('Risultato 1'), buttons: kTertiaryButton);
      expect(closed, 1);
      await tester.tap(find.text('Log'), buttons: kTertiaryButton);
      expect(closed, 1, reason: 'tabs without onClose stay');
    });

    testWidgets('PageSwitcher places its accessory after the Segmented', (tester) async {
      await tester.pumpWidget(_app(PageSwitcher<int>(
        value: 0,
        items: const [(0, 'Dati', null), (1, 'Colonne', null)],
        onChanged: (_) {},
        trailing: const Text('Dettagli'),
      )));
      final segmented = tester.getRect(find.byType(Segmented<int>));
      final accessory = tester.getRect(find.text('Dettagli'));
      expect(accessory.left, greaterThan(segmented.right));
      expect(accessory.center.dy, closeTo(segmented.center.dy, 1));
    });

    testWidgets('DisclosureButton with icon and subtitle; disabled without chevron', (tester) async {
      var expanded = false;
      await tester.pumpWidget(_app(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 300,
            child: StatefulBuilder(
              builder: (context, set) => DisclosureButton(
                label: 'ODBC Driver 18',
                icon: AppIcons.database,
                subtitle: '/opt/homebrew/lib/libmsodbcsql.18.dylib',
                monoSubtitle: true,
                expanded: expanded,
                onChanged: (v) => set(() => expanded = v),
              ),
            ),
          ),
          const DisclosureButton(label: 'FreeTDS', icon: AppIcons.database, expanded: false, onChanged: null),
        ],
      )));
      expect(find.byIcon(AppIcons.database), findsNWidgets(2));
      expect(find.text('/opt/homebrew/lib/libmsodbcsql.18.dylib'), findsOneWidget);
      expect(find.byType(DisclosureChevron), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('FreeTDS')).dx,
        tester.getTopLeft(find.text('ODBC Driver 18')).dx,
        reason: 'the empty chevron slot keeps rows aligned',
      );
      expect(
        tester.getTopLeft(find.text('FreeTDS')).dx - tester.getTopLeft(find.byType(DisclosureButton).last).dx,
        DisclosureButton.contentIndent(icon: true),
      );
      await tester.tap(find.text('ODBC Driver 18'));
      expect(expanded, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('progress and badges', () {
    testWidgets('LevelIndicator without a value sweeps', (tester) async {
      final c = DbColors.light;
      await tester.pumpWidget(_app(const Center(child: LevelIndicator(value: 0.4, width: 100))));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(_app(const Center(
        child: LevelIndicator(value: null, width: 100, semanticLabel: 'dump.csv'),
      )));
      expect(tester.hasRunningAnimations, isTrue);
      expect(find.byType(LevelIndicator), paints..rrect(color: c.accent));
      expect(tester.getSize(find.byType(LevelIndicator)), const Size(100, 4));
    });

    testWidgets('StatusLine with a dot: neutral text, colored dot', (tester) async {
      final c = DbColors.light;
      await tester.pumpWidget(_app(Center(child: StatusLine('In pausa alla riga 12', dot: c.warning))));
      expect(tester.widget<StatusDot>(find.byType(StatusDot)).color, c.warning);
      expect(find.byType(Icon), findsNothing);
      expect(tester.widget<Text>(find.text('In pausa alla riga 12')).style!.color, c.textSecondary);
    });

    testWidgets('TypeLabel takes a state color', (tester) async {
      final c = DbColors.light;
      await tester.pumpWidget(_app(Column(
        children: [
          const TypeLabel('integer', mono: true),
          TypeLabel('bigint', mono: true, color: c.warning),
        ],
      )));
      expect(tester.widget<Text>(find.text('integer')).style!.color, c.textTertiary);
      expect(tester.widget<Text>(find.text('bigint')).style!.color, c.warning);
    });
  });
}
