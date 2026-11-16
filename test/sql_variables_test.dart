import 'package:dbcraft/odbc/odbc_ffi.dart' show SQL_TYPE_DATE;
import 'package:dbcraft/odbc/odbc_types.dart' show SqlParam;
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/services/sql_splitter.dart';
import 'package:dbcraft/services/sql_variables.dart';
import 'package:flutter_test/flutter_test.dart';

SqlDialect dialect(String name) => SqlDialect(dbmsName: name);

List<String> refs(String sql, DbFamily f) => scanVariables(sql, f).refs.map((r) => r.display).toList();

VariablePlan plan(String script, String dbms, List<ScriptVariable> vars, {bool odbc = true, List<SqlUnit>? units}) {
  final d = dialect(dbms);
  final sp = SqlSplitter(family: d.family, blankLineDelimiter: true);
  final all = sp.units(script);
  return prepareVariables(
    script: script,
    units: units ?? all,
    textOf: (u) => u.text,
    dialect: d,
    variables: vars,
    odbc: odbc,
    scriptUnits: all,
  );
}

void main() {
  group('references', () {
    test('SQL Server: @x, not @@system, emails, user@host or EXEC parameter names', () {
      expect(
        refs("SELECT @@ROWCOUNT, @da, 'a@b.it', x@y FROM t WHERE c = @Cli -- @no\n/* @no */", DbFamily.sqlServer),
        ['@da', '@Cli'],
      );
      expect(refs('EXEC dbo.p @id = @x, @flag = 1; EXEC @ret = dbo.q @a = @y', DbFamily.sqlServer), ['@x', '@ret', '@y']);
      expect(refs('SELECT :id FROM [a:b]', DbFamily.sqlServer), [':id']);
    });

    test('routine bodies are not the script\'s', () {
      expect(refs('CREATE PROCEDURE p @a INT AS SELECT @a', DbFamily.sqlServer), isEmpty);
      expect(refs('CREATE OR REPLACE TRIGGER t BEFORE INSERT ON x FOR EACH ROW BEGIN :new.a := :b; END', DbFamily.oracle),
          isEmpty);
    });

    test(':name skips casts, assignments, :new / :old and identifiers', () {
      expect(refs("SELECT a::int, :id, b:=1, x:y, ':s', :new FROM t WHERE c=:c", DbFamily.postgres), [':id', ':c']);
    });

    test('Snowflake: \$x but not \$1 or \$\$ bodies', () {
      expect(refs(r'SELECT $da, $1, t$x FROM t', DbFamily.snowflake), [r'$da']);
      expect(refs(r'EXECUTE IMMEDIATE $$ SELECT $x $$', DbFamily.snowflake), isEmpty);
    });

    test('MongoDB and Redis have no variables', () {
      expect(refs('db.c.find({a: @x})', DbFamily.mongodb), isEmpty);
    });
  });

  group('declarations', () {
    test('SQL Server DECLARE lists, with and without semicolons', () {
      const sql = "DECLARE @a INT = 5, @b AS NVARCHAR(20) = N'x', @c DATE\nDECLARE @d INT = (SELECT MAX(id) FROM t)\n"
          'DECLARE @t TABLE (id INT, n VARCHAR(10))\nSELECT @a, @b, @c, @d FROM @t';
      final s = scanVariables(sql, DbFamily.sqlServer);
      expect(s.decls.map((d) => d.display), ['@a', '@b', '@c', '@d', '@t']);
      expect(s.decls.map((d) => d.sqlType), ['INT', 'NVARCHAR(20)', 'DATE', 'INT', 'TABLE (id INT, n VARCHAR(10))']);
      expect(s.decls.map((d) => d.init), ['5', "N'x'", null, '(SELECT MAX(id) FROM t)', null]);
      expect(s.decls.map((d) => d.editable), [true, true, true, false, false]);
      expect(s.refs.map((r) => r.display), ['@a', '@b', '@c', '@d', '@t']);
      // Where the literal of @c would go.
      final c = s.decls[2];
      expect(sql.substring(0, c.initStart!), endsWith('@c DATE'));
    });

    test('MySQL SET, := and INTO', () {
      final s = scanVariables("SET @a = 1, @b := 'x', @@sql_mode = ''; SELECT @c := 2, @a INTO @d FROM t", DbFamily.mysql);
      expect(s.decls.map((d) => d.display), ['@a', '@b', '@c', '@d']);
      expect(s.decls.map((d) => d.editable), [true, true, false, false]);
      expect(s.refs.map((r) => r.display), ['@c', '@a']);
    });

    test('Snowflake SET', () {
      final s = scanVariables("SET x = 'a'; SET (y, z) = (1, 2); UPDATE t SET c = \$x", DbFamily.snowflake);
      expect(s.decls.map((d) => d.display), [r'$x', r'$y', r'$z']);
      expect(s.decls.first.editable, isTrue);
    });
  });

  group('values', () {
    test('types, validation and SQL Server types', () {
      expect(ScriptVariable('a', value: '42').typed, 42);
      expect(ScriptVariable('a', value: '').hasValue, isFalse);
      expect(ScriptVariable('a', type: VarType.text, value: '').hasValue, isTrue);
      expect(ScriptVariable('a', type: VarType.number, value: 'x').error, isNotNull);
      expect(ScriptVariable('a', type: VarType.date, value: '2026-1-1').error, isNotNull);
      expect(ScriptVariable('a', type: VarType.boolean, value: 'vero').typed, isTrue);
      expect(tsqlTypeOf(ScriptVariable('a', value: '42')), 'INT');
      expect(tsqlTypeOf(ScriptVariable('a', value: '9999999999')), 'BIGINT');
      expect(tsqlTypeOf(ScriptVariable('a', type: VarType.number, value: '1,25')), 'DECIMAL(38, 2)');
      expect(tsqlTypeOf(ScriptVariable('a', value: 'abc')), 'VARCHAR(8000)');
      expect(tsqlTypeOf(ScriptVariable('a', value: 'città')), 'NVARCHAR(4000)');
      expect(tsqlTypeOf(ScriptVariable('a', type: VarType.date, value: '2026-01-01')), 'DATE');
      expect(tsqlTypeOf(ScriptVariable('a', value: '1', sqlType: 'TINYINT')), 'TINYINT');
      final d = ScriptVariable('d', type: VarType.date, value: '2026-01-31').bindValue(odbc: true);
      expect(d, isA<SqlParam>().having((p) => p.sqlType, 'type', SQL_TYPE_DATE));
    });

    test('json round trip', () {
      final v = ScriptVariable('da', type: VarType.date, value: '2026-01-01', sqlType: 'DATE');
      final back = ScriptVariable.fromJson(v.toJson())!;
      expect([back.name, back.type, back.value, back.isNull, back.sqlType], ['da', VarType.date, '2026-01-01', false, 'DATE']);
      expect(ScriptVariable.fromJson(ScriptVariable('n', isNull: true).toJson())!.isNull, isTrue);
    });
  });

  group('prepare', () {
    test('SQL Server: panel variables are declared in front of the batch', () {
      final p = plan('SELECT * FROM o WHERE d >= @da AND c = @cli AND x = :k', 'Microsoft SQL Server', [
        ScriptVariable('da', type: VarType.date, value: '2026-01-01'),
        ScriptVariable('cli', value: '42'),
        ScriptVariable('k', value: "o'k"),
      ]);
      expect(p.ready, isTrue);
      expect(p.units.single.sql,
          "DECLARE @da DATE = '2026-01-01', @cli INT = 42; SELECT * FROM o WHERE d >= @da AND c = @cli AND x = 'o''k'");
      expect(p.units.single.params, isEmpty);
    });

    test('SQL Server: the script wins over the panel', () {
      final p = plan('DECLARE @x INT = 5;\nSELECT @x, @y', 'Microsoft SQL Server', [
        ScriptVariable('x', value: '1'),
        ScriptVariable('y', value: '2'),
      ]);
      expect(p.units.single.sql, 'DECLARE @y INT = 2; DECLARE @x INT = 5;\nSELECT @x, @y');
    });

    test('SQL Server: a statement run alone carries the declarations of its batch', () {
      const script = 'DECLARE @a INT = 1;\nDECLARE @b INT = @a + 1;\nSELECT @b;\nGO\nSELECT 2';
      final sp = SqlSplitter(family: DbFamily.sqlServer);
      final st = sp.split(script).firstWhere((s) => s.text == 'SELECT @b');
      final p = plan(script, 'Microsoft SQL Server', [], units: [SqlUnit(st.text, st.start, st.end, [st])]);
      expect(p.units.single.sql, 'DECLARE @a INT = 1; DECLARE @b INT = @a + 1; SELECT @b');
      expect(p.carried, ['@b', '@a']);
    });

    test('missing and invalid values stop the run', () {
      final p = plan('SELECT @a, @b, @c', 'Microsoft SQL Server', [
        ScriptVariable('b', type: VarType.number, value: 'x'),
        ScriptVariable('c'),
      ]);
      expect(p.ready, isFalse);
      expect(p.missing, ['a', 'c']);
      expect(p.invalid, ['b']);
    });

    test('MySQL: a SET before the run, the script\'s own SET untouched', () {
      final p = plan("SET @own = 1;\nSELECT @own, @da, :k", 'MySQL', [
        ScriptVariable('da', value: '2026-01-01'),
        ScriptVariable('k', value: '7'),
      ]);
      expect(p.setup, ["SET @da = '2026-01-01'"]);
      expect(p.units.map((u) => u.sql), ['SET @own = 1', 'SELECT @own, @da, ?']);
      expect(p.units.last.params, [7]);
    });

    test('Snowflake: SET name = literal', () {
      final p = plan(r'SELECT $da', 'Snowflake', [ScriptVariable('da', type: VarType.date, value: '2026-01-01')]);
      expect(p.setup, ["SET da = '2026-01-01'::DATE"]);
    });

    test('PostgreSQL: :name bound once for the whole script, ? asked', () {
      final p = plan('SELECT :id;\nSELECT * FROM t WHERE a = :id AND b = ?', 'PostgreSQL', [ScriptVariable('id', value: '3')]);
      expect(p.units.map((u) => u.sql), ['SELECT ?', 'SELECT * FROM t WHERE a = ? AND b = ?']);
      expect(p.units.last.params, [3, null]);
      expect(p.units.last.positional, [1]);
    });

    test('BigQuery: @x bound', () {
      final p = plan('SELECT @x', 'Google BigQuery', [ScriptVariable('x', value: 'a')], odbc: false);
      expect(p.units.single.sql, 'SELECT ?');
      expect(p.units.single.params, ['a']);
    });
  });

  test('panel rows: script variables, panel ones and unused', () {
    final scan = scanVariables('DECLARE @x INT = 1; SELECT @x, @da', DbFamily.sqlServer);
    final rows = buildVariableRows(scan, [ScriptVariable('old', value: '1'), ScriptVariable('x', value: '9')], const VarSyntax(at: true));
    expect(rows.map((r) => r.display), ['@x', '@da', '@old']);
    expect(rows.map((r) => r.inScript), [true, false, false]);
    expect(rows.map((r) => r.needsValue), [false, true, false]);
    expect(rows.map((r) => r.used), [true, true, false]);
  });
}
