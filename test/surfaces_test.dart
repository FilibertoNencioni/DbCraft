import 'package:dbcraft/ui/widgets/common.dart';
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
  });
}
