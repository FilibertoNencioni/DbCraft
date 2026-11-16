// Script variables and batches on the test servers (tool/design_db/compose.yml:
// pg, mssql, mysql). Not part of `flutter test`:
//
//   docker compose -f tool/design_db/compose.yml up -d pg mssql mysql
//   flutter test tool/test_matrix/script_variables_test.dart [--dart-define=ONLY=mssql]
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/services/sql_variables.dart';
import 'package:dbcraft/services/storage.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

const _pwd = 'DbCraft_Test1';
const pgCs = 'Driver={PostgreSQL Unicode};Server=127.0.0.1;Port=55432;Database=dbcraft;Uid=dbcraft;Pwd=$_pwd';
const msCs =
    'Driver={ODBC Driver 18 for SQL Server};Server=127.0.0.1,51433;Database=master;Uid=sa;Pwd=$_pwd;TrustServerCertificate=yes';
const myCs = 'Driver={MariaDB ODBC Driver};Server=127.0.0.1;Port=53306;Database=dbcraft;Uid=root;Pwd=$_pwd';
const only = String.fromEnvironment('ONLY');

bool wanted(String key) => only.isEmpty || only.split(',').contains(key);

class _Ui implements ExecutionUi {
  final confirms = <String>[];
  @override
  Future<Map<String, Object?>?> askParameters(List<String> names, Map<String, Object?> previous) async => {};
  @override
  Future<bool> confirm(String title, String message) async {
    confirms.add('$title: $message');
    return true;
  }

  @override
  Future<bool> ensureConnected(DbConnection c) async => true;
}

Future<DbConnection> open(String cs) async {
  final dc = DbConnection(ConnectionConfig(id: cs, name: 'x', mode: ConnectionMode.connectionString, connectionString: cs));
  await dc.connect();
  return dc;
}

SqlEditorTab editor(DbConnection dc, String sql, [List<ScriptVariable> vars = const []]) =>
    SqlEditorTab(settings: AppSettings(), connection: dc, initialText: sql, variables: [...vars]);

/// Title → first column of every row, for each result; errors as "!message".
List<Object?> outcome(SqlEditorTab t) => [
  for (final r in t.results)
    if (r.error != null)
      '!${r.error!.split('\n').first}'
    else if (r.model != null)
      [for (final row in r.model!.rows) row.values.first]
    else if (r.title != 'Statistiche')
      r.title,
];

void placeCaret(SqlEditorTab t, String marker) {
  final text = t.controller.text;
  final at = text.indexOf(marker);
  final before = text.substring(0, at);
  final line = '\n'.allMatches(before).length;
  final col = at - (before.lastIndexOf('\n') + 1);
  t.controller.selection = CodeLineSelection.collapsed(index: line, offset: col);
}

void main() {
  group('SQL Server', skip: !wanted('mssql'), () {
    late DbConnection dc;
    setUpAll(() async => dc = await open(msCs));
    tearDownAll(() async => dc.disconnect());

    test('DECLARE and the statements after it run in one batch', () async {
      final t = editor(dc, 'DECLARE @x INT = 1;\nSELECT @x AS a;\n\nSELECT @x + 1 AS b');
      await t.execute(_Ui());
      expect(outcome(t), [
        [1],
        [2],
      ]);
    });

    test('the statement under the caret carries the declarations of its batch', () async {
      final t = editor(dc, 'DECLARE @x INT = 1;\nDECLARE @y INT = @x * 10;\nSELECT @y + 1 AS b;\nGO\nSELECT 9 AS z');
      placeCaret(t, '@y + 1');
      await t.executeCurrent(_Ui());
      expect(outcome(t), [
        [11],
      ]);
      expect(t.log.map((e) => e.message), contains('Dichiarazioni riportate dal batch: @y, @x'));
    });

    test('panel variables: typed DECLARE in front of the batch; the script wins', () async {
      final t = editor(dc, "DECLARE @own INT = 5;\nSELECT @own AS own, @da AS d, @cli + 1 AS c, @t AS t", [
        ScriptVariable('own', value: '1'),
        ScriptVariable('da', type: VarType.date, value: '2026-01-31'),
        ScriptVariable('cli', value: '41'),
        ScriptVariable('t', value: 'città'),
      ]);
      await t.execute(_Ui());
      expect(t.results.single.model!.rows.single.values.map((v) => '$v'), ['5', '2026-01-31', '42', 'città']);
      expect(t.log.map((e) => e.sql).whereType<String>().first, startsWith("DECLARE @da DATE = '2026-01-31', @cli INT = 41, @t NVARCHAR(4000) = N'città'; "));
    });

    test('a missing value stops everything', () async {
      final t = editor(dc, 'SELECT @nope AS x');
      await t.execute(_Ui());
      expect(t.results, isEmpty);
      expect(t.blockedVariables, {'nope'});
    });

    test('temporary tables live across batches, GO n repeats', () async {
      final t = editor(dc, 'CREATE TABLE #r (a INT);\nGO\nINSERT INTO #r VALUES (1)\nGO 3\nSELECT COUNT(*) AS n FROM #r;\nDROP TABLE #r');
      await t.execute(_Ui());
      expect(outcome(t).whereType<List>().single, [3]);
    });

    test('an error in the middle of a batch is shown, the batch goes on', () async {
      final t = editor(dc, 'SELECT 1 AS a;\nSELECT 1/0 AS b;\nSELECT 3 AS c;\nPRINT \'fine\'');
      await t.execute(_Ui());
      final o = outcome(t);
      // ignore: avoid_print
      print('mid-batch error: $o / output ${t.serverOutput}');
      expect(o.whereType<String>().where((s) => s.startsWith('!')).single, contains('Divide by zero'));
      expect(o.whereType<List>().map((l) => l.first), containsAll([1, 3]));
      expect(t.serverOutput.any((m) => m.contains('fine')), isTrue);
    });

    test('an error before the first result ends the run (ODBC limit)', () async {
      // The Driver Manager refuses SQLMoreResults after a failed execution:
      // what follows in the batch cannot be read.
      final t = editor(dc, "DECLARE @z INT = 0;\nSELECT 1 / @z AS b;\nSELECT 3 AS c");
      await t.execute(_Ui());
      expect(outcome(t).single, contains('Divide by zero'));
    });

    test('an error while sending rows: the rows, the error, then the rest', () async {
      final t = editor(dc, 'SELECT * FROM (VALUES (1), (0)) v(a) WHERE 1 / a > 0;\nSELECT 3 AS c');
      await t.execute(_Ui());
      final o = outcome(t);
      expect(o.whereType<List>().toList(), [
        [1],
        [3],
      ]);
      expect(o.whereType<String>().single, contains('Divide by zero'));
    });

    test('a compile error aborts the batch and is reported', () async {
      final t = editor(dc, 'SELECT 1 AS a;\nSELECT * FROM dbo.no_such_table;');
      await t.execute(_Ui());
      // ignore: avoid_print
      print('compile error: ${outcome(t)}');
      expect(outcome(t).whereType<String>().single, contains('no_such_table'));
    });

    test('a big result does not hold back the rest of the batch', () async {
      final t = editor(
        dc,
        'DECLARE @n INT = 0;\nSELECT value FROM GENERATE_SERIES(1, 500);\nSET @n = 7;\nSELECT @n AS n',
      );
      await t.execute(_Ui());
      final sets = t.results.where((r) => r.model != null).map((r) => r.model!).toList();
      expect(sets.first.rows.length, 500);
      expect(sets.last.rows.single.values.first, 7);
    });

    test('statements that must be alone keep working without GO', () async {
      final t = editor(
        dc,
        'CREATE OR ALTER VIEW dbo.v_vars AS SELECT 1 AS a;\nSELECT a FROM dbo.v_vars;\nDROP VIEW dbo.v_vars;',
      );
      await t.execute(_Ui());
      expect(outcome(t).whereType<List>().single, [1]);
      expect(t.results.where((r) => r.error != null), isEmpty);
    });

    test('read-only connections see the statements inside a batch', () async {
      final ro = DbConnection(
        ConnectionConfig(id: 'ro', name: 'ro', mode: ConnectionMode.connectionString, connectionString: msCs, readOnly: true),
      );
      await ro.connect();
      final t = editor(ro, 'DECLARE @x INT = 1;\nDELETE FROM dbo.nothing WHERE 1 = @x');
      await t.execute(_Ui());
      expect(t.results.single.title, 'Sola lettura');
      await ro.disconnect();
    });
  });

  group('MySQL', skip: !wanted('mysql'), () {
    late DbConnection dc;
    setUpAll(() async => dc = await open(myCs));
    tearDownAll(() async => dc.disconnect());

    test('panel variables become session variables; the script\'s SET wins', () async {
      final t = editor(dc, "SET @own = 5;\nSELECT @own AS own, @da AS d, @n + 1 AS n", [
        ScriptVariable('own', value: '1'),
        ScriptVariable('da', type: VarType.date, value: '2026-01-31'),
        ScriptVariable('n', value: '41'),
      ]);
      await t.execute(_Ui());
      final row = t.results.firstWhere((r) => r.model != null).model!.rows.single.values;
      expect(row.map((v) => '$v'), ['5', '2026-01-31', '42']);
      expect(t.log.map((e) => e.sql), contains("SET @da = '2026-01-31', @n = 41"));
    });
  });

  group('PostgreSQL', skip: !wanted('pg'), () {
    late DbConnection dc;
    setUpAll(() async => dc = await open(pgCs));
    tearDownAll(() async => dc.disconnect());

    test(':name bound once for the whole script, dates typed', () async {
      final t = editor(dc, 'SELECT :id::int + 1 AS a;\nSELECT CASE WHEN current_date >= :da THEN 1 ELSE 0 END AS b', [
        ScriptVariable('id', value: '41'),
        ScriptVariable('da', type: VarType.date, value: '2020-01-01'),
      ]);
      await t.execute(_Ui());
      expect(outcome(t).whereType<List>().toList(), [
        [42],
        [1],
      ]);
    });

    test('DO blocks run whole, notices in the output', () async {
      final t = editor(dc, "DO \$\$ DECLARE x int := 1; BEGIN RAISE NOTICE 'x=%', x; END \$\$;\nSELECT 1 AS a");
      await t.execute(_Ui());
      expect(t.results.where((r) => r.error != null), isEmpty);
      expect(t.serverOutput.any((m) => m.contains('x=1')), isTrue);
    });
  });
}
