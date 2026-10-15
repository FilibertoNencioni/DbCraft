// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:dbcraft/odbc/odbc_session.dart';
import 'package:flutter_test/flutter_test.dart';

const _sqliteDriver = '/opt/homebrew/lib/libsqlite3odbc.dylib';

void main() {
  final hasDriver = File(_sqliteDriver).existsSync();

  test('drivers & DSN enumeration', () async {
    final drivers = await odbcDrivers();
    expect(drivers, isNotEmpty);
    await odbcDataSources();
  });

  test('sqlite roundtrip', () async {
    final db = '${Directory.systemTemp.path}/dbcraft_test_${DateTime.now().microsecondsSinceEpoch}.db';
    final s = await OdbcSession.open('Driver=$_sqliteDriver;Database=$db');
    try {
      await s.execute('CREATE TABLE dept(id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
      await s.execute(
        'CREATE TABLE emp(id INTEGER PRIMARY KEY, name VARCHAR(50), salary REAL, dept_id INTEGER REFERENCES dept(id), photo BLOB)',
      );
      await s.execute('CREATE INDEX ix_emp_name ON emp(name)');
      await s.execute("INSERT INTO dept VALUES (1,'R&D'),(2,'Sales')");
      for (var i = 0; i < 450; i++) {
        await s.execute(
          'INSERT INTO emp(name, salary, dept_id, photo) VALUES (?,?,?,?)',
          params: [
            'Dipendente è $i ✓',
            1000.5 + i,
            i % 2 + 1,
            Uint8List.fromList([1, 2, i % 256]),
          ],
        );
      }
      final upd = await s.execute('UPDATE emp SET salary = salary + 1 WHERE dept_id = 1');
      expect(upd.rowsAffected, 225);
      final r = await s.execute('SELECT * FROM emp ORDER BY id', fetchSize: 200);
      expect(r.columns.map((c) => c.name), ['id', 'name', 'salary', 'dept_id', 'photo']);
      expect(r.rows.length, 200);
      expect(r.hasMore, true);
      expect(r.rows[0][1], 'Dipendente è 0 ✓');
      expect(r.rows[0][0], 1);
      expect(r.rows[0][4], isA<Uint8List>());
      final r2 = await s.fetchMore(r.cursorId!, 1000);
      expect(r2.rows.length, 250);
      expect(r2.hasMore, false);
      final info = await s.info();
      print(info);
      final tables = await s.catalog('tables', [null, null, '%', null]);
      print(tables.columns.map((c) => c.name).toList());
      print(tables.rows);
      final cols = await s.catalog('columns', [null, null, 'emp', null]);
      print(cols.rows.map((r) => [r[3], r[5], r[6]]).toList());
      final pk = await s.catalog('primaryKeys', [null, null, 'emp']);
      print(pk.rows);
      final fk = await s.catalog('foreignKeys', [null, null, null, null, null, 'emp']);
      print(fk.rows);
      final ix = await s.catalog('statistics', [null, null, 'emp']);
      print(ix.rows);
      await s.setAutoCommit(false);
      await s.execute('DELETE FROM emp');
      await s.rollback();
      final cnt = await s.execute('SELECT COUNT(*) FROM emp');
      expect(cnt.rows[0][0], 450);
      await s.setAutoCommit(true);
      Object? err;
      try {
        await s.execute('SELECT * FROM missing_table');
      } catch (e) {
        err = e;
      }
      print(err);
      expect(err, isNotNull);
    } finally {
      await s.close();
      File(db).deleteSync();
    }
  }, skip: !hasDriver);
}
