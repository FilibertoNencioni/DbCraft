// UI helpers shared by the matrix suites: navigator, context menus, SQL
// editors and result models.
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/state/result_set_model.dart';
import 'package:dbcraft/ui/editors/sql_editor_view.dart';
import 'package:dbcraft/ui/navigator/navigator_panel.dart';
import 'package:dbcraft/ui/widgets/surfaces.dart' show FormRow;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Finder nav(String text) => find.descendant(of: find.byType(NavigatorPanel), matching: find.text(text));

Future<SqlEditorTab> editor(WidgetTester tester, AppState app, String sql) async {
  final tab = await app.openSqlEditor(app.connections.first, initialSql: sql);
  await settle(tester, 500);
  return tab;
}

/// Runs the editor content with the "Esegui" button and waits for the end.
Future<void> runEditor(WidgetTester tester, SqlEditorTab tab, {int seconds = 60, Future<void> Function()? onDialog}) async {
  await settle(tester, 400);
  final button = find.descendant(of: find.byType(SqlEditorView), matching: find.text('Esegui')).hitTestable();
  await tester.tap(button.first);
  await tester.pump(const Duration(milliseconds: 200));
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (onDialog != null && find.byType(SqlEditorView).evaluate().isNotEmpty) await onDialog();
    if (!tab.running) break;
  }
  await settle(tester, 400);
}

/// Opens the context menu of a navigator node and picks [item] (retrying:
/// a click during an animation can be lost).
Future<void> navMenu(WidgetTester tester, String node, String item) async {
  // D-002: a right click sometimes does not open the menu; retry, then fall
  // back to the "Azioni" button shown on hover, and count the misses.
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.tap(nav(node).first, buttons: kSecondaryButton);
    await settle(tester, 600);
    if (find.text(item).evaluate().isNotEmpty) {
      if (attempt > 0) record('D-002', Outcome.defect, 'menu di $node aperto al clic destro n. ${attempt + 1}');
      await tester.tap(find.text(item).last);
      await settle(tester, 800);
      return;
    }
    await tester.tapAt(const Offset(900, 700));
    await settle(tester, 600);
  }
  final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await hover.addPointer(location: tester.getCenter(nav(node).first));
  await settle(tester, 400);
  final more = find.descendant(of: find.byType(NavigatorPanel), matching: find.byTooltip('Azioni'));
  if (more.evaluate().isNotEmpty) {
    await tester.tap(more.first);
    await settle(tester, 600);
    await hover.removePointer();
    if (find.text(item).evaluate().isNotEmpty) {
      record('D-002', Outcome.defect, 'menu di $node: 3 clic destri a vuoto, aperto dal pulsante Azioni');
      await tester.tap(find.text(item).last);
      await settle(tester, 800);
      return;
    }
  } else {
    await hover.removePointer();
  }
  throw TestFailure('voce "$item" non trovata nel menu di $node');
}

/// Expands a navigator node with its disclosure chevron.
Future<void> navExpand(WidgetTester tester, String node) async {
  final r = tester.getRect(nav(node).first);
  await tester.tapAt(Offset(r.left - 33, r.center.dy));
  await settle(tester, 1200);
}

ResultSetModel lastModel(SqlEditorTab tab) => tab.results.lastWhere((r) => r.model != null).model!;

/// Waits for the model of a table editor's data page.
Future<ResultSetModel> waitModel(WidgetTester tester, TableEditorTab tab) async {
  for (var i = 0; i < 300 && tab.data == null; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (tab.data == null) throw TestFailure('data page not loaded');
  await settle(tester, 500);
  return tab.data!;
}

/// The text fields of the form row labelled [label] (the last sheet on top).
Finder formFields(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(FormRow)).last,
  matching: find.byType(EditableText),
);

Future<void> fill(WidgetTester tester, String label, String value, {int index = 0}) async {
  final f = formFields(label);
  if (f.evaluate().length <= index) throw TestFailure('campo "$label" non trovato');
  await tester.enterText(f.at(index), value);
  await tester.pump(const Duration(milliseconds: 100));
}

/// Connects [connectionName] from the navigator and expands down to the
/// "Tabelle" folder through [path] (catalog, schema).
Future<void> openTablesFolder(WidgetTester tester, String connectionName, List<String> path) async {
  final filter = find.descendant(of: find.byType(NavigatorPanel), matching: find.byType(EditableText));
  if (filter.evaluate().isNotEmpty && (tester.widget<EditableText>(filter.first).controller.text.isNotEmpty)) {
    await tester.enterText(filter.first, '');
    await settle(tester, 800);
  }
  if (nav('Tabelle').evaluate().isEmpty && path.every((p) => nav(p).evaluate().isEmpty)) {
    await doubleTap(tester, nav(connectionName).first);
  }
  for (final p in path) {
    if (nav('Tabelle').evaluate().isNotEmpty) break;
    await waitFor(tester, nav(p), seconds: 40);
    await navExpand(tester, p);
  }
  await waitFor(tester, nav('Tabelle'), seconds: 40);
}
