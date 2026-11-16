import 'dart:io';

import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Drafts, explicit saving and session restore (no UI).
void main() {
  late Directory ws;

  setUp(() => ws = Directory.systemTemp.createTempSync('scriptsession'));
  tearDown(() => ws.deleteSync(recursive: true));

  Directory scripts() => Directory(p.join(ws.path, 'scripts'));
  List<String> scriptFiles() =>
      scripts().listSync(recursive: true).whereType<File>().map((f) => p.relative(f.path, from: scripts().path)).toList();

  test('a new editor is a draft: nothing is written in the library', () async {
    final app = await AppState.load(workspaceDir: ws);
    final t = await app.openSqlEditor(null, initialSql: 'SELECT 1');
    expect(t.isDraft, isTrue);
    expect(t.name, 'Bozza 1');
    expect((await app.openSqlEditor(null)).name, 'Bozza 2');
    expect(scriptFiles(), isEmpty);
    // The text is in the buffer.
    expect(await app.scriptSession.readBuffer(t.bufferId), 'SELECT 1');
  });

  test('saving a draft writes the script and drops the buffer', () async {
    final app = await AppState.load(workspaceDir: ws);
    final t = await app.openSqlEditor(null, initialSql: 'SELECT 1');
    await t.saveAs(app.library.fileOf('Report/vendite.sql'));
    expect(t.isDraft, isFalse);
    expect(t.isDirty, isFalse);
    expect(scriptFiles(), [p.join('Report', 'vendite.sql')]);
    expect(await app.scriptSession.readBuffer(t.bufferId), isNull);
    expect(app.scriptSession.recent.first, 'Report/vendite.sql');
  });

  test('a saved script changes only on save; the changes live in the buffer', () async {
    final app = await AppState.load(workspaceDir: ws);
    final f = app.library.fileOf('a.sql')..createSync(recursive: true);
    f.writeAsStringSync('SELECT 1');
    final t = await app.openScript(f);
    t.controller.text = 'SELECT 2';
    expect(t.isDirty, isTrue);
    await app.shutdown();
    expect(f.readAsStringSync(), 'SELECT 1');
    expect(await app.scriptSession.readBuffer(t.bufferId), 'SELECT 2');

    // Restart: the editor comes back with the unsaved text.
    final again = await AppState.load(workspaceDir: ws);
    final r = again.tabs.single as dynamic;
    expect(r.file.path, f.path);
    expect(r.controller.text, 'SELECT 2');
    expect(r.isDirty, isTrue);
    await r.save();
    expect(f.readAsStringSync(), 'SELECT 2');
  });

  test('session restore: drafts, order, active tab and connection', () async {
    final app = await AppState.load(workspaceDir: ws);
    final dc = await app.addConnection(ConnectionConfig(id: 'c1', name: 'Locale'));
    final a = await app.openSqlEditor(dc, initialSql: 'SELECT a');
    await app.openSqlEditor(null, initialSql: 'SELECT b');
    app.activate(a);
    await app.shutdown();

    final again = await AppState.load(workspaceDir: ws);
    expect(again.tabs.map((t) => t.title), ['Bozza 1 <Locale>', 'Bozza 2']);
    expect(again.activeTab, 0);
    expect(again.tabs.first.connection?.config.id, 'c1');
  });

  test('rememberTabs off: the drafts go to "Chiuse di recente"', () async {
    final app = await AppState.load(workspaceDir: ws);
    app.settings.rememberTabs = false;
    await app.saveSettings();
    await app.openSqlEditor(null, initialSql: 'SELECT a');
    await app.openSqlEditor(null);
    await app.shutdown();

    final again = await AppState.load(workspaceDir: ws);
    expect(again.tabs, isEmpty);
    expect(again.closedDrafts.map((b) => b.label), ['Bozza 1']);
  });

  test('closing keeps the text in "Chiuse di recente"; empty drafts vanish', () async {
    final app = await AppState.load(workspaceDir: ws);
    final a = await app.openSqlEditor(null, initialSql: 'SELECT a');
    final empty = await app.openSqlEditor(null);
    app.closeTab(empty);
    app.closeTab(a);
    expect(app.closedDrafts.map((b) => b.label), ['Bozza 1']);
    final back = (await app.reopenLastClosed())!;
    expect(back.controller.text, 'SELECT a');
    expect(back.name, 'Bozza 1');
    expect(app.closedDrafts, isEmpty);
    app.closeTab(back, keepText: false);
    expect(app.closedDrafts, isEmpty);
    expect(await app.scriptSession.readBuffer(back.bufferId), isNull);
  });

  test('old closed drafts are purged at startup', () async {
    final app = await AppState.load(workspaceDir: ws);
    app.closeTab(await app.openSqlEditor(null, initialSql: 'SELECT a'));
    app.closedDrafts.single.closedAt = DateTime.now().subtract(const Duration(days: 31));
    await app.shutdown();
    final again = await AppState.load(workspaceDir: ws);
    expect(again.closedDrafts, isEmpty);
  });

  test('moving a folder updates open editors and remembered bindings', () async {
    final app = await AppState.load(workspaceDir: ws);
    final dc = await app.addConnection(ConnectionConfig(id: 'c1', name: 'Locale'));
    await app.library.createScript('A', 'x', 'SELECT 1');
    final t = await app.openScript(app.library.fileOf('A/x.sql'), connection: dc);
    t.connection = dc;
    app.toggleFavorite('A/x.sql');
    final to = await app.library.move('A', 'B');
    app.scriptsMoved('A', to);
    expect(app.library.relOf(t.file!.path), 'B/A/x.sql');
    expect(app.scriptSession.bindings['B/A/x.sql']?.connection, 'c1');
    expect(app.scriptSession.favorites, ['B/A/x.sql']);

    // Reopened later, the script uses its connection again.
    app.closeTab(t);
    app.selectedConnection = null;
    final again = await app.openScript(app.library.fileOf('B/A/x.sql'));
    expect(again.connection, dc);
  });

  test('deleting a connection keeps its SQL editors, without connection', () async {
    final app = await AppState.load(workspaceDir: ws);
    final dc = await app.addConnection(ConnectionConfig(id: 'c1', name: 'Locale'));
    final t = await app.openSqlEditor(dc, initialSql: 'SELECT 1');
    await app.deleteConnection(dc);
    expect(app.tabs, [t]);
    expect(t.connection, isNull);
  });
}
