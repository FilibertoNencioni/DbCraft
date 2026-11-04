// Connection folders of the navigator: nested paths, manual order, moves
// from the menus and by drag and drop.

import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/model/connection_folders.dart';
import 'package:dbcraft/services/storage.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/navigator/nav_nodes.dart';
import 'package:dbcraft/ui/navigator/navigator_panel.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design/helpers.dart';

DbConnection conn(String name, [String folder = '']) =>
    DbConnection(ConnectionConfig(id: name, name: name, folder: folder));

List<String> names(AppState app) => [for (final c in app.connections) c.config.name];

Map<String, String> foldersOf(AppState app) => {for (final c in app.connections) c.config.name: c.config.folder};

void main() {
  group('paths', () {
    test('normalized, with their ancestors', () {
      expect(normalizeFolder(' Clienti / /Prod '), 'Clienti/Prod');
      expect(normalizeFolder('  '), '');
      expect(allFolders(['Clienti/Prod/EU', 'Interni', '']), {'Clienti', 'Clienti/Prod', 'Clienti/Prod/EU', 'Interni'});
      expect(folderName('Clienti/Prod'), 'Prod');
      expect(folderParent('Clienti/Prod'), 'Clienti');
      expect(folderParent('Clienti'), '');
      expect(isInFolder('Clienti/Prod', 'Clienti'), isTrue);
      expect(isInFolder('Clienti2', 'Clienti'), isFalse);
    });

    test('manual order first, then alphabetical, depth first', () {
      final all = allFolders(['b', 'a/z', 'a/y', 'c']);
      expect(orderedFolders(all, const []), ['a', 'a/y', 'a/z', 'b', 'c']);
      expect(orderedFolders(all, const ['c', 'a/z', 'gone']), ['c', 'a', 'a/z', 'a/y', 'b']);
    });

    test('moving a folder carries its subfolders and places it', () {
      final all = allFolders(['A/A1', 'B', 'C']);
      final m = moveFolder(all, const [], 'A', parent: 'B')!;
      expect(m.renames, {'A': 'B/A', 'A/A1': 'B/A/A1'});
      expect(m.order, ['B', 'B/A', 'B/A/A1', 'C']);

      final before = moveFolder(all, const [], 'C', parent: '', before: 'A')!;
      expect(before.renames, {'C': 'C'});
      expect(before.order, ['C', 'A', 'A/A1', 'B']);
    });

    test('a folder cannot go into itself; a same-named sibling merges', () {
      final all = allFolders(['A/A1', 'B/A1']);
      expect(moveFolder(all, const [], 'A', parent: 'A/A1'), isNull);
      expect(moveFolder(all, const [], 'A', parent: 'A'), isNull);
      final m = moveFolder(all, const [], 'B/A1', parent: 'A')!;
      expect(m.renames, {'B/A1': 'A/A1'});
      // B stays: only the connections tell whether it is left empty.
      expect(m.order, ['A', 'A/A1', 'B']);
    });

    test('renaming keeps the place, shifting swaps siblings', () {
      final all = allFolders(['A', 'B', 'C']);
      final r = moveFolder(all, const [], 'B', parent: '', name: 'Z', before: 'C')!;
      expect(r.order, ['A', 'Z', 'C']);
      expect(shiftFolder(all, const [], 'B', -1), ['B', 'A', 'C']);
      expect(shiftFolder(all, const [], 'A', -1), isNull);
    });

    test('the order is a setting that round-trips', () {
      expect(AppSettings().folderOrder, isEmpty);
      expect(AppSettings.fromJson(const {}).folderOrder, isEmpty);
      expect(AppSettings.fromJson(AppSettings(folderOrder: ['B', 'A']).toJson()).folderOrder, ['B', 'A']);
    });
  });

  group('app state', () {
    testWidgets('connections move into folders and around each other', (tester) async {
      final app = await testApp(tester);
      app.connections.addAll([conn('a', 'X'), conn('b'), conn('c', 'X'), conn('d')]);

      await tester.runAsync(() => app.moveConnectionTo(app.byId('d')!, 'X', before: app.byId('c')));
      expect(names(app), ['a', 'b', 'd', 'c']);
      expect(app.byId('d')!.config.folder, 'X');

      await tester.runAsync(() => app.moveConnectionTo(app.byId('b')!, ' X / Y '));
      expect(app.byId('b')!.config.folder, 'X/Y');
      expect(app.folders, ['X', 'X/Y']);

      await tester.runAsync(() => app.moveConnectionTo(app.byId('a')!, ''));
      expect(names(app).last, 'a');
      expect(app.byId('a')!.config.folder, '');

      // "Sposta giù" swaps with the next connection of the same folder.
      await tester.runAsync(() => app.moveConnection(app.byId('d')!, 1));
      expect(names(app), ['c', 'd', 'b', 'a']);
    });

    testWidgets('folders move and rename with their connections', (tester) async {
      final app = await testApp(tester);
      app.connections.addAll([conn('a', 'A/A1'), conn('b', 'B'), conn('c', 'C')]);

      final renames = await tester.runAsync(() => app.moveFolderTo('A', 'B'));
      expect(renames, {'A': 'B/A', 'A/A1': 'B/A/A1'});
      expect(foldersOf(app), {'a': 'B/A/A1', 'b': 'B', 'c': 'C'});
      expect(app.settings.folderOrder, ['B', 'B/A', 'B/A/A1', 'C']);

      await tester.runAsync(() => app.moveFolderTo('C', '', before: 'B'));
      expect(app.folders, ['C', 'B', 'B/A', 'B/A/A1']);

      await tester.runAsync(() => app.renameFolder('B', 'Clienti'));
      expect(app.folders, ['C', 'Clienti', 'Clienti/A', 'Clienti/A/A1']);
      expect(foldersOf(app), {'a': 'Clienti/A/A1', 'b': 'Clienti', 'c': 'C'});

      expect(await tester.runAsync(() => app.moveFolderTo('Clienti', 'Clienti/A')), isNull);

      await tester.runAsync(() => app.shiftFolderBy('Clienti', -1));
      expect(app.folders.first, 'Clienti');
    });
  });

  group('navigator', () {
    test('folders nest and their nodes survive rebuilds', () {
      final conns = [conn('a', 'X/Y'), conn('b', 'X'), conn('c')];
      final cache = <String, NavNode>{};
      final folders = orderedFolders(allFolders(conns.map((c) => c.config.folder)), const []);
      final roots = buildRoots(conns, folders, cache);
      expect(roots.map((n) => n.label), ['X', 'c']);
      final x = roots.first as ConnectionFolderNode;
      expect(x.items.map((n) => n.label), ['Y', 'b']);
      expect((x.items.first as ConnectionFolderNode).items.map((n) => n.label), ['a']);
      expect(x.expanded, isFalse, reason: 'folders start closed');
      x.expanded = true;
      final again = buildRoots(conns, folders, cache);
      expect(again.first, same(x));
      expect(x.expanded, isTrue);
    });

    Future<AppState> pumpNavigator(WidgetTester tester, List<DbConnection> conns) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = await testApp(tester);
      app.connections.addAll(conns);
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: NavigatorPanel()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return app;
    }

    Future<void> dragTo(WidgetTester tester, Finder from, Offset to) async {
      final g = await tester.startGesture(tester.getCenter(from));
      await g.moveBy(const Offset(0, 12));
      await tester.pump();
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      // Saving the workspace is real I/O.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }

    testWidgets('a connection dragged onto a folder goes into it', (tester) async {
      final app = await pumpNavigator(tester, [conn('a', 'X'), conn('b')]);
      expect(find.text('a'), findsNothing, reason: 'folders start closed');
      await tester.tap(find.descendant(
        of: find.ancestor(of: find.text('X'), matching: find.byType(OutlineRow)),
        matching: find.byType(DisclosureChevron),
      ));
      await tester.pumpAndSettle();
      await dragTo(tester, find.text('b'), tester.getCenter(find.text('X')));
      expect(app.byId('b')!.config.folder, 'X');
    });

    testWidgets('a connection dragged below the rows goes to the top level', (tester) async {
      final app = await pumpNavigator(tester, [conn('a', 'X'), conn('b')]);
      expect(find.text('a'), findsNothing, reason: 'folders start closed');
      await tester.tap(find.descendant(
        of: find.ancestor(of: find.text('X'), matching: find.byType(OutlineRow)),
        matching: find.byType(DisclosureChevron),
      ));
      await tester.pumpAndSettle();
      await dragTo(tester, find.text('a'), tester.getCenter(find.text('b')) + const Offset(0, 40));
      expect(app.byId('a')!.config.folder, '');
      expect(names(app), ['b', 'a']);
    });

    testWidgets('a connection dropped on the upper half of another goes before it', (tester) async {
      final app = await pumpNavigator(tester, [conn('a'), conn('b'), conn('c')]);
      await dragTo(tester, find.text('c'), tester.getTopLeft(find.text('a')) + const Offset(4, 0));
      expect(names(app), ['c', 'a', 'b']);
    });

    testWidgets('a folder dragged onto another folder nests in it', (tester) async {
      final app = await pumpNavigator(tester, [conn('a', 'A'), conn('b', 'B')]);
      await dragTo(tester, find.text('B'), tester.getCenter(find.text('A')));
      expect(app.byId('b')!.config.folder, 'A/B');
      expect(find.text('B'), findsOneWidget, reason: 'the target folder opens');
    });
  });
}
