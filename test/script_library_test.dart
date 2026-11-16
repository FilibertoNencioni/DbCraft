import 'dart:io';

import 'package:dbcraft/services/script_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory ws;
  late ScriptLibrary lib;

  setUp(() {
    ws = Directory.systemTemp.createTempSync('scriptlib');
    lib = ScriptLibrary(root: Directory(p.join(ws.path, 'scripts')), stateDir: Directory(p.join(ws.path, '.dbcraft')));
  });
  tearDown(() => ws.deleteSync(recursive: true));

  test('tree lists folders and .sql files, skipping hidden and other files', () async {
    await lib.createFolder('', 'Report');
    await lib.createScript('Report', 'vendite', 'SELECT 1');
    await lib.createScript('', 'a', 'SELECT 2');
    File(lib.abs('note.txt')).writeAsStringSync('x');
    Directory(lib.abs('.nascosta')).createSync();
    final t = await lib.tree();
    expect(t.children.map((c) => c.path).toSet(), {'Report', 'a.sql'});
    expect(t.scripts.map((s) => s.path).toSet(), {'Report/vendite.sql', 'a.sql'});
    expect(await lib.folderPaths(), ['Report']);
    expect(lib.relOf(lib.abs('Report/vendite.sql')), 'Report/vendite.sql');
    expect(lib.relOf(p.join(ws.path, 'altro.sql')), isNull);
  });

  test('rename, move and collisions', () async {
    await lib.createFolder('', 'A');
    await lib.createFolder('', 'B');
    await lib.createScript('A', 'x', '1');
    await lib.createScript('B', 'x', '2');
    expect(await lib.rename('A/x.sql', 'y'), 'A/y.sql');
    expect(lib.fileOf('A/y.sql').existsSync(), isTrue);
    await expectLater(lib.move('B/x.sql', 'A'), completes);
    await expectLater(lib.createScript('A', 'x', '3'), throwsA(isA<ScriptLibraryException>()));
    await expectLater(lib.rename('A/x.sql', 'y'), throwsA(isA<ScriptLibraryException>()));
    // Case-only rename.
    expect(await lib.rename('A/x.sql', 'X'), 'A/X.sql');
    // Folders: into itself is refused, elsewhere moves the content.
    await expectLater(lib.move('A', 'A'), throwsA(isA<ScriptLibraryException>()));
    expect(await lib.move('A', 'B'), 'B/A');
    expect(lib.fileOf('B/A/y.sql').existsSync(), isTrue);
    await expectLater(lib.rename('B/A', 'bad/name'), throwsA(isA<ScriptLibraryException>()));
    expect(await lib.duplicate('B/A/y.sql'), 'B/A/y copia.sql');
    expect(await lib.duplicate('B/A/y.sql'), 'B/A/y copia 2.sql');
  });

  test('trash: delete, restore (also when the name is taken), purge', () async {
    await lib.createFolder('', 'F');
    await lib.createScript('F', 's', 'SELECT 1');
    final item = await lib.trash('F/s.sql');
    expect(lib.fileOf('F/s.sql').existsSync(), isFalse);
    expect((await lib.listTrash()).single.path, 'F/s.sql');
    await lib.createScript('F', 's', 'nuovo');
    expect(await lib.restore(item), 'F/s 2.sql');
    expect(lib.fileOf('F/s 2.sql').readAsStringSync(), 'SELECT 1');
    expect(await lib.listTrash(), isEmpty);

    final folder = await lib.trash('F');
    expect(Directory(lib.abs('F')).existsSync(), isFalse);
    expect(await lib.restore(folder), 'F');
    expect(lib.fileOf('F/s.sql').existsSync(), isTrue);

    await lib.trash('F/s.sql');
    await lib.purgeTrash(maxAge: Duration.zero);
    expect(await lib.listTrash(), isEmpty);
  });

  test('search by name, then by content with the matching line', () async {
    await lib.createScript('', 'clienti', 'SELECT 1');
    await lib.createScript('', 'ordini', 'SELECT *\nFROM clienti c\nWHERE 1=1');
    await lib.createScript('', 'altro', 'SELECT 2');
    final r = await lib.search('CLIENTI');
    expect(r.map((m) => m.path), ['clienti.sql', 'ordini.sql']);
    expect(r[0].line, isNull);
    expect(r[1].line, 'FROM clienti c');
    expect(r[1].lineNumber, 2);
  });
}
