import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/odbc/odbc_core.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/state/result_set_model.dart';
import 'package:dbcraft/services/data_transfer.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/services/sql_formatter.dart';
import 'package:dbcraft/services/sql_splitter.dart';
import 'package:dbcraft/services/storage.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:re_editor/re_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SqlSplitter', () {
    test('splits on ; ignoring strings and comments', () {
      final s = SqlSplitter().split("select 'a;b' from t; -- x;y\nselect \"c;d\" /* ; */ from u;");
      expect(s.map((e) => e.text), ["select 'a;b' from t", "-- x;y\nselect \"c;d\" /* ; */ from u"]);
    });
    test('MySQL DELIMITER directive (D-009)', () {
      final s = SqlSplitter().split(
        'DELIMITER \$\$\n'
        'CREATE PROCEDURE p_dlm(IN a INT)\nBEGIN\n  SELECT a; SELECT \'\$\$\';\nEND \$\$\n'
        'CREATE FUNCTION f() RETURNS INT RETURN 1\$\$\n'
        'DELIMITER ;\n'
        'SELECT 1; SELECT 2;',
      );
      expect(s.map((e) => e.text), [
        "CREATE PROCEDURE p_dlm(IN a INT)\nBEGIN\n  SELECT a; SELECT '\$\$';\nEND",
        'CREATE FUNCTION f() RETURNS INT RETURN 1',
        'SELECT 1',
        'SELECT 2',
      ]);
      expect(SqlSplitter().split('delimiter //\nselect 1//\ndelimiter ;').map((e) => e.text), ['select 1']);
    });
    test('GO and / delimiters', () {
      final s = SqlSplitter().split('select 1\nGO\nselect 2\n/\nselect 3');
      expect(s.map((e) => e.text), ['select 1', 'select 2', 'select 3']);
    });
    test('procedure bodies with BEGIN/END', () {
      const sql = 'CREATE PROCEDURE p AS BEGIN\n  SELECT 1;\n  IF x THEN SELECT 2; END IF;\nEND;\nSELECT 3;';
      final s = SqlSplitter().split(sql);
      expect(s.length, 2);
      expect(s.last.text, 'SELECT 3');
    });
    test('BEGIN TRANSACTION is not a block', () {
      final s = SqlSplitter().split('BEGIN TRANSACTION; UPDATE t SET a=1; COMMIT;');
      expect(s.length, 3);
    });
    test('dollar quoting', () {
      final s = SqlSplitter().split(
        r"CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END $$ LANGUAGE plpgsql; SELECT f();",
      );
      expect(s.length, 2);
    });
    test('statement at caret with blank lines', () {
      const sql = 'select 1\nfrom a\n\nselect 2\nfrom b';
      final sp = SqlSplitter(blankLineDelimiter: true);
      expect(sp.statementAt(sql, 2)!.text, 'select 1\nfrom a');
      expect(sp.statementAt(sql, sql.length)!.text, 'select 2\nfrom b');
    });
    test('parameters', () {
      final p = findParameters("select * from t where a = :id and b = ? and c = '::x' and d::int = :id");
      expect(p.map((e) => e.name), ['id', '?1', 'id']);
      final (sql, order) = toPositional('select :a, :b', findParameters('select :a, :b'));
      expect(sql, 'select ?, ?');
      expect(order, ['a', 'b']);
    });
    test('strip leading comments', () {
      expect(stripLeadingComments('-- a\n/* b */ select 1'), 'select 1');
    });
  });

  test('formatter', () {
    final f = SqlFormatter().format("select a, b from t join u on t.id = u.id where x = 'y' order by a");
    expect(f, 'SELECT\n    a,\n    b\nFROM t\nJOIN u ON t.id = u.id\nWHERE x = \'y\'\nORDER BY a');
  });

  group('SQL editor statements to run', () {
    SqlEditorTab editor(String text) => SqlEditorTab(settings: AppSettings(), initialText: text);

    test('without a selection the whole script runs, not the line at the caret', () {
      final t = editor('SELECT 1;\nSELECT 2;\nSELECT 3;');
      t.controller.selection = const CodeLineSelection.collapsed(index: 2, offset: 9);
      expect(t.statementsToRun(), ['SELECT 1', 'SELECT 2', 'SELECT 3']);
      expect(t.currentStatement()!.text, 'SELECT 3');
    });

    test('a selection runs only the selected statements', () {
      final t = editor('SELECT 1;\nSELECT 2;\nSELECT 3;');
      t.controller.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 1, extentOffset: 9);
      expect(t.statementsToRun(), ['SELECT 1', 'SELECT 2']);
    });

    test('the editor database defaults to the connection and resets with it', () {
      final t = editor('')..catalog = 'sales';
      expect(t.catalog, 'sales');
      t.catalog = null;
      expect(t.catalog, isNull);
    });
  });

  group('dialect', () {
    test('quoting', () {
      final d = SqlDialect(dbmsName: 'PostgreSQL');
      expect(d.quoteIdent('users'), 'users');
      expect(d.quoteIdent('Users'), '"Users"');
      expect(d.quoteIdent('order'), '"order"');
      expect(d.qualified(null, 'public', 'my table'), 'public."my table"');
      final ms = SqlDialect(dbmsName: 'Microsoft SQL Server', quote: '"');
      expect(ms.qualified('db', null, 't'), 'db..t');
      expect(ms.literal('città'), "N'città'");
    });
  });

  test('single table SELECT without base table metadata (D-011)', () {
    expect(singleTableSelect('SELECT * FROM tipi ORDER BY id'), (catalog: null, schema: null, name: 'tipi'));
    expect(singleTableSelect('select id, [nome] from dbo.[Tabella Strana] t where id > 1;'), (
      catalog: null,
      schema: 'dbo',
      name: 'Tabella Strana',
    ));
    expect(singleTableSelect('SELECT TOP 10 * FROM d.dbo.t'), (catalog: 'd', schema: 'dbo', name: 't'));
    expect(singleTableSelect('SELECT a + 1 FROM t'), isNull);
    expect(singleTableSelect('SELECT a AS b FROM t'), isNull);
    expect(singleTableSelect('SELECT * FROM a JOIN b ON a.id = b.id'), isNull);
    expect(singleTableSelect('SELECT * FROM a, b'), isNull);
    expect(singleTableSelect('SELECT DISTINCT a FROM t'), isNull);
    expect(singleTableSelect('SELECT * FROM (SELECT 1 x) s'), isNull);
  });

  test('error lines, decimals, versions, modifying statements', () {
    expect(
      mainErrorLine(
        '[08001] (101) could not initiate GSSAPI security context: Cannot find KDC\n'
        '[08001] (101) FATAL:  password authentication failed for user "dbcraft"',
      ),
      contains('FATAL:  password authentication failed'),
    );
    expect(mainErrorLine('only line\nsecond'), 'only line');
    expect(normalizeDecimalText('.0000000001'), '0.0000000001');
    expect(normalizeDecimalText('-.5'), '-0.5');
    expect(normalizeDecimalText('12.5'), '12.5');
    expect(normalizeServerInfo({'dbmsName': 'MySQL', 'dbmsVersion': '08.04.000003'})['dbmsVersion'], '8.4.3');
    expect(
      normalizeServerInfo({'dbmsName': 'Microsoft SQL Server', 'dbmsVersion': '16.00.4135'})['dbmsVersion'],
      '16.00.4135',
    );
    expect(isModifyingSql("UPDATE progetti SET budget = budget + 1 WHERE codice = 'ERP-07'"), isTrue);
    expect(isModifyingSql('-- c\nCOPY t FROM stdin'), isTrue);
    expect(isModifyingSql('SELECT * FROM t'), isFalse);
  });

  test('connection strings', () {
    final c = ConnectionConfig(
      id: '1',
      name: 'x',
      driver: 'ODBC Driver 18 for SQL Server',
      host: 'h',
      port: '1433',
      database: 'd',
      user: 'u',
      password: 'p;w',
    );
    expect(
      c.buildConnectionString(),
      'DRIVER={ODBC Driver 18 for SQL Server};SERVER=h,1433;DATABASE=d;UID=u;PWD={p;w};TrustServerCertificate=yes;MARS_Connection=yes',
    );
    expect(c.maskedConnectionString.contains('p;w'), false);
    final pg = ConnectionConfig(
      id: '2',
      name: 'p',
      driver: 'PostgreSQL Unicode',
      host: 'h',
      port: '5432',
      database: 'd',
    );
    expect(pg.buildConnectionString(), 'DRIVER={PostgreSQL Unicode};SERVER=h;PORT=5432;DATABASE=d');
  });

  test('Oracle ODBC: host, port and service name go in DBQ (EZConnect)', () {
    ConnectionConfig ora(String host, String port, String db) =>
        ConnectionConfig(id: 'o', name: 'o', driver: 'Oracle 23 ODBC driver', host: host, port: port, database: db);
    expect(ora('h', '1521', 'ORCLPDB1').buildConnectionString(), 'DRIVER={Oracle 23 ODBC driver};DBQ=h:1521/ORCLPDB1');
    expect(ora('h', '', 'XE').buildConnectionString(), 'DRIVER={Oracle 23 ODBC driver};DBQ=h/XE');
    // Connections saved before: everything typed in the host field.
    expect(ora('h:1521/XE', '', '').buildConnectionString(), 'DRIVER={Oracle 23 ODBC driver};DBQ=h:1521/XE');
  });

  test('password in a connection string moves to the vault (D-007)', () {
    final c = ConnectionConfig(
      id: '1',
      name: 'x',
      mode: ConnectionMode.connectionString,
      connectionString: 'Driver={PostgreSQL Unicode};Server=h;Uid=u;Pwd={p;w};Port=5432',
    );
    expect(c.movePasswordToVault(), isTrue);
    expect(c.password, 'p;w');
    expect(c.savePassword, isTrue);
    expect(c.connectionString, 'Driver={PostgreSQL Unicode};Server=h;Uid=u;Pwd=;Port=5432');
    expect(c.toJson().toString().contains('p;w'), isFalse);
    expect(c.buildConnectionString(), 'Driver={PostgreSQL Unicode};Server=h;Uid=u;Pwd={p;w};Port=5432');
    expect(c.movePasswordToVault(), isFalse);
    final other = ConnectionConfig(
      id: '2',
      name: 'y',
      mode: ConnectionMode.connectionString,
      connectionString: 'DSN=x;PASSWORD=s3cr',
    );
    expect(other.movePasswordToVault(), isTrue);
    expect(other.buildConnectionString(), 'DSN=x;PASSWORD=s3cr');
    final none = ConnectionConfig(id: '3', name: 'z', mode: ConnectionMode.connectionString, connectionString: 'DSN=x', password: 'q');
    expect(none.movePasswordToVault(), isFalse);
    expect(none.buildConnectionString(), 'DSN=x;PWD=q');
  });

  test('driver parameters', () {
    expect(parseOdbcParams('a=1;b=2'), {'a': '1', 'b': '2'});
    expect(parseOdbcParams('a=1\n b = 2 ;\n\nc=3;'), {'a': '1', 'b': '2', 'c': '3'});
    expect(parseOdbcParams('x={p;q}}r};y=z'), {'x': 'p;q}r', 'y': 'z'});
    expect(parseOdbcParams('noequals;=v'), isEmpty);
    final c = ConnectionConfig(id: '1', name: 'x', driver: 'PostgreSQL Unicode', host: 'h', extraParams: parseOdbcParams('a=1;b=2;c={x;y}'));
    expect(c.buildConnectionString(), 'DRIVER={PostgreSQL Unicode};SERVER=h;a=1;b=2;c={x;y}');
    // Round trip through the dialog text representation.
    final text = c.extraParams.entries.map((e) => '${e.key}=${odbcEscape(e.value)}').join('\n');
    expect(parseOdbcParams(text), c.extraParams);
  });

  test('export formats', () {
    final o = ExportOptions(format: ExportFormat.csv);
    expect(
      DataExporter.exportAll(
        ['a', 'b'],
        [
          [1, 'x,y'],
          [null, 'q"'],
        ],
        o,
      ),
      'a,b\n1,"x,y"\n,"q"""\n',
    );
    o.format = ExportFormat.json;
    expect(
      DataExporter.exportAll(
        ['a'],
        [
          [1],
          [null],
        ],
        o,
      ),
      '[\n  {"a":1},\n  {"a":null}\n]\n',
    );
    o
      ..format = ExportFormat.sql
      ..tableName = 't';
    expect(
      DataExporter.exportAll(
        ['a', 'b'],
        [
          [1, "it's"],
        ],
        o,
      ),
      "INSERT INTO t (a, b) VALUES\n\t(1, 'it''s');\n",
    );
    expect(parseCsv('a,b\n"1,2",3\n'), [
      ['a', 'b'],
      ['1,2', '3'],
    ]);
  });
}
