import 'dart:math';
import 'dart:typed_data';

import 'package:dbcraft/features/mock_data/generators.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/odbc/odbc_ffi.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:flutter_test/flutter_test.dart';

DbColumn _col(
  String name,
  int type, {
  String typeName = '',
  int? size,
  int? decimals,
  bool nullable = true,
  bool autoIncrement = false,
}) => DbColumn(
  name: name,
  dataType: type,
  typeName: typeName.isEmpty ? 'T$type' : typeName,
  size: size,
  decimals: decimals,
  nullable: nullable,
  position: 1,
  autoIncrement: autoIncrement,
);

MockColumnConfig _cfg(DbColumn c, {bool pk = false}) => MockColumnConfig(c, isPrimaryKey: pk);

void main() {
  group('Italian identifiers', () {
    test('fiscal code check character', () {
      expect(italianCheckChar('RSSMRA85T10A562'), 'S');
      expect(isValidFiscalCode('RSSMRA85T10A562S'), isTrue);
      expect(isValidFiscalCode('RSSMRA85T10A562A'), isFalse);
    });

    test('fiscal code construction', () {
      final cf = italianFiscalCode(
        lastName: 'Rossi',
        firstName: 'Mario',
        birth: DateTime(1985, 12, 10),
        female: false,
        placeCode: 'A562',
      );
      expect(cf, 'RSSMRA85T10A562S');
      final f = italianFiscalCode(
        lastName: "D'Angelo",
        firstName: 'Gianfranco',
        birth: DateTime(2001, 1, 5),
        female: true,
        placeCode: 'H501',
      );
      expect(f.substring(0, 6), 'DNGGFR');
      expect(f.substring(9, 11), '45');
      expect(isValidFiscalCode(f), isTrue);
    });

    test('VAT number check digit', () {
      expect(vatCheckDigit('0123456789'), 7);
      expect(isValidVatNumber('01234567897'), isTrue);
      expect(isValidVatNumber('01234567890'), isFalse);
    });

    test('IBAN checksum and CIN', () {
      expect(isValidIban('IT60X0542811101000000123456'), isTrue);
      expect(isValidIban('IT61X0542811101000000123456'), isFalse);
      expect(italianIban('05428', '11101', '000000123456'), 'IT60X0542811101000000123456');
    });

    test('generated identifiers are valid', () {
      final g = MockDataGenerator([
        _cfg(_col('codice_fiscale', SQL_VARCHAR, size: 16)),
        _cfg(_col('partita_iva', SQL_VARCHAR, size: 11)),
        _cfg(_col('iban', SQL_VARCHAR, size: 34)),
      ], seed: 7);
      expect(g.columns.map((c) => c.effectiveKind), [MockKind.fiscalCode, MockKind.vatNumber, MockKind.iban]);
      for (final r in g.take(200)) {
        expect(isValidFiscalCode(r[0] as String), isTrue, reason: r[0] as String);
        expect(isValidVatNumber(r[1] as String), isTrue, reason: r[1] as String);
        expect(isValidIban(r[2] as String), isTrue, reason: r[2] as String);
        expect((r[2] as String).length, 27);
      }
    });
  });

  group('heuristics', () {
    test('kinds from names and types', () {
      MockKind k(String n, int t, {int? size, bool pk = false, bool auto = false, String typeName = ''}) => _cfg(
        _col(n, t, size: size, autoIncrement: auto, typeName: typeName),
        pk: pk,
      ).effectiveKind;
      expect(k('id', SQL_INTEGER, pk: true), MockKind.sequence);
      expect(k('id', SQL_INTEGER, auto: true), MockKind.skip);
      expect(k('nome', SQL_VARCHAR, size: 50), MockKind.firstName);
      expect(k('FirstName', SQL_WVARCHAR, size: 50), MockKind.firstName);
      expect(k('cognome', SQL_VARCHAR, size: 50), MockKind.lastName);
      expect(k('email', SQL_VARCHAR, size: 100), MockKind.email);
      expect(k('telefono', SQL_VARCHAR, size: 20), MockKind.phone);
      expect(k('indirizzo', SQL_VARCHAR, size: 100), MockKind.address);
      expect(k('città', SQL_VARCHAR, size: 50), MockKind.city);
      expect(k('cap', SQL_CHAR, size: 5), MockKind.zip);
      expect(k('provincia', SQL_CHAR, size: 2), MockKind.province);
      expect(k('country', SQL_VARCHAR, size: 40), MockKind.country);
      expect(k('ragione_sociale', SQL_VARCHAR, size: 100), MockKind.company);
      expect(k('website_url', SQL_VARCHAR, size: 200), MockKind.url);
      expect(k('username', SQL_VARCHAR, size: 30), MockKind.username);
      expect(k('password_hash', SQL_VARCHAR, size: 100), MockKind.passwordHash);
      expect(k('guid', SQL_CHAR, size: 36), MockKind.uuid);
      expect(k('rowguid', SQL_GUID), MockKind.uuid);
      expect(k('ip_address', SQL_VARCHAR, size: 45), MockKind.ip);
      expect(k('colore', SQL_VARCHAR, size: 20), MockKind.color);
      expect(k('descrizione', SQL_VARCHAR, size: 500), MockKind.lorem);
      expect(k('nome_prodotto', SQL_VARCHAR, size: 80), MockKind.lorem);
      expect(k('prezzo', SQL_DECIMAL), MockKind.decimal);
      expect(k('quantita', SQL_INTEGER), MockKind.integer);
      expect(k('data_nascita', SQL_TYPE_DATE), MockKind.dateTime);
      expect(k('attivo', SQL_BIT), MockKind.boolean);
      expect(k('is_deleted', SQL_TINYINT), MockKind.boolean);
      expect(k('enabled', SQL_VARCHAR, typeName: 'bool'), MockKind.boolean);
      expect(k('stato', SQL_VARCHAR, size: 20), MockKind.list);
      expect(k('codice_ordine', SQL_VARCHAR, size: 20), MockKind.pattern);
      expect(k('foto', SQL_VARBINARY, size: 100), MockKind.bytes);
    });

    test('foreign keys default to sampled values', () {
      final s = MockFkSample(
        name: 'fk',
        refTable: 'clienti',
        refColumns: const ['id'],
        tuples: const [
          [1],
          [2],
          [3],
        ],
      );
      final c = MockColumnConfig(_col('cliente_id', SQL_INTEGER, nullable: false), fkSample: s);
      expect(c.effectiveKind, MockKind.foreignKey);
      final g = MockDataGenerator([c], seed: 1);
      final values = g.take(100).map((r) => r.single).toSet();
      expect(values.difference({1, 2, 3}), isEmpty);
    });

    test('composite foreign keys use coherent tuples', () {
      final s = MockFkSample(
        name: 'fk',
        refTable: 'righe',
        refColumns: const ['a', 'b'],
        tuples: const [
          [1, 'x'],
          [2, 'y'],
        ],
      );
      final g = MockDataGenerator([
        MockColumnConfig(_col('a', SQL_INTEGER), fkSample: s),
        MockColumnConfig(_col('b', SQL_VARCHAR, size: 5), fkSample: s, fkPosition: 1),
      ], seed: 3);
      for (final r in g.take(50)) {
        expect(r[0] == 1 ? r[1] == 'x' : r[1] == 'y', isTrue);
      }
    });

    test('empty non-nullable foreign key fails clearly', () {
      final s = MockFkSample(name: 'fk', refTable: 'clienti', refColumns: const ['id']);
      final g = MockDataGenerator([MockColumnConfig(_col('cliente_id', SQL_INTEGER, nullable: false), fkSample: s)]);
      expect(g.next, throwsA(isA<MockGenerationException>()));
    });
  });

  group('generation', () {
    test('integer and decimal ranges', () {
      final i = _cfg(_col('n', SQL_INTEGER))
        ..kind = MockKind.integer
        ..intMin = 5
        ..intMax = 9;
      final d = _cfg(_col('p', SQL_DECIMAL, size: 8, decimals: 2))
        ..kind = MockKind.decimal
        ..decMin = 10
        ..decMax = 20;
      final g = MockDataGenerator([i, d], seed: 42);
      for (final r in g.take(500)) {
        expect(r[0] as int, inInclusiveRange(5, 9));
        final p = double.parse(r[1] as String);
        expect(p, inInclusiveRange(10, 20));
        expect((r[1] as String).split('.').last.length, 2);
      }
    });

    test('date range and formats', () {
      final d = _cfg(_col('d', SQL_TYPE_DATE))
        ..kind = MockKind.dateTime
        ..dateFrom = DateTime(2020, 1, 1)
        ..dateTo = DateTime(2020, 12, 31);
      final ts = _cfg(_col('ts', SQL_TYPE_TIMESTAMP))
        ..dateFrom = DateTime(2021, 1, 1)
        ..dateTo = DateTime(2021, 1, 2);
      final g = MockDataGenerator([d, ts], seed: 1);
      for (final r in g.take(100)) {
        expect(r[0] as String, matches(RegExp(r'^2020-\d{2}-\d{2}$')));
        expect(r[1] as String, matches(RegExp(r'^2021-01-0[12] \d{2}:\d{2}:\d{2}$')));
      }
    });

    test('null percentage only on nullable columns', () {
      final a = _cfg(_col('a', SQL_VARCHAR, size: 20))..nullPercent = 30;
      final b = _cfg(_col('b', SQL_VARCHAR, size: 20, nullable: false))..nullPercent = 100;
      final g = MockDataGenerator([a, b], seed: 9);
      final rows = g.take(2000).toList();
      final nulls = rows.where((r) => r[0] == null).length;
      expect(nulls, inInclusiveRange(450, 750));
      expect(rows.every((r) => r[1] != null), isTrue);
    });

    test('unique values and exhaustion', () {
      final u = _cfg(_col('n', SQL_INTEGER))
        ..kind = MockKind.integer
        ..intMin = 1
        ..intMax = 50
        ..unique = true;
      final g = MockDataGenerator([u], seed: 5, maxAttempts: 1000);
      final values = g.take(50).map((r) => r.single).toSet();
      expect(values.length, 50);
      expect(g.next, throwsA(isA<MockGenerationException>()));
    });

    test('unique text falls back to suffixes within the size', () {
      final u = _cfg(_col('c', SQL_VARCHAR, size: 8))
        ..kind = MockKind.pattern
        ..pattern = 'AB#'
        ..unique = true;
      final g = MockDataGenerator([u], seed: 5);
      final values = g.take(40).map((r) => r.single as String).toList();
      expect(values.toSet().length, 40);
      expect(values.every((v) => v.length <= 8), isTrue);
    });

    test('primary key sequences and composite keys', () {
      final g = MockDataGenerator([_cfg(_col('id', SQL_INTEGER, nullable: false), pk: true)..seqStart = 10], seed: 1);
      expect(g.take(3).map((r) => r.single).toList(), [10, 11, 12]);
      final a = MockColumnConfig(_col('a', SQL_INTEGER), isPrimaryKey: true, compositeKey: true)
        ..kind = MockKind.integer
        ..intMin = 1
        ..intMax = 3;
      final b = MockColumnConfig(_col('b', SQL_INTEGER), isPrimaryKey: true, compositeKey: true)
        ..kind = MockKind.integer
        ..intMin = 1
        ..intMax = 3;
      final g2 = MockDataGenerator([a, b], seed: 2, maxAttempts: 500);
      final tuples = g2.take(9).map((r) => '${r[0]}-${r[1]}').toSet();
      expect(tuples.length, 9);
    });

    test('size truncation', () {
      final c = _cfg(_col('descrizione', SQL_VARCHAR, size: 12))
        ..minWords = 20
        ..maxWords = 30;
      final g = MockDataGenerator([c], seed: 3);
      for (final r in g.take(50)) {
        expect((r.single as String).length, lessThanOrEqualTo(12));
      }
    });

    test('seed determinism and column independence', () {
      List<MockColumnConfig> cols() => [
        _cfg(_col('nome', SQL_VARCHAR, size: 30)),
        _cfg(_col('email', SQL_VARCHAR, size: 100)),
        _cfg(_col('importo', SQL_DECIMAL, size: 10, decimals: 2)),
      ];
      final a = MockDataGenerator(cols(), seed: 1234).take(20).toList();
      final b = MockDataGenerator(cols(), seed: 1234).take(20).toList();
      final c = MockDataGenerator(cols(), seed: 4321).take(20).toList();
      expect(a, b);
      expect(a, isNot(c));
      // Changing one column does not change the values of the others.
      final changed = cols()..[0].kind = MockKind.constant;
      final d = MockDataGenerator(changed, seed: 1234).take(20).toList();
      expect(d.map((r) => r[1]).toList(), a.map((r) => r[1]).toList());
    });

    test('skip columns are excluded', () {
      final g = MockDataGenerator([
        _cfg(_col('id', SQL_INTEGER, autoIncrement: true)),
        _cfg(_col('nome', SQL_VARCHAR, size: 30)),
      ]);
      expect(g.columns.map((c) => c.name), ['nome']);
      expect(g.next().length, 1);
    });

    test('lists, weights, patterns, booleans, uuid', () {
      expect(parseWeightedList('a=3, b, c=0.5'), [('a', 3.0), ('b', 1.0), ('c', 0.5)]);
      final l = _cfg(_col('s', SQL_VARCHAR, size: 10))
        ..kind = MockKind.list
        ..listValues = 'x=9, y=1';
      final p = _cfg(_col('o', SQL_VARCHAR, size: 20))
        ..kind = MockKind.pattern
        ..pattern = r'ORD-#####-??\#';
      final b = _cfg(_col('f', SQL_BIT))..truePercent = 100;
      final u = _cfg(_col('u', SQL_CHAR, size: 36))..kind = MockKind.uuid;
      final rows = MockDataGenerator([l, p, b, u], seed: 11).take(500).toList();
      final xs = rows.where((r) => r[0] == 'x').length;
      expect(xs, greaterThan(400));
      expect(rows.every((r) => RegExp(r'^ORD-\d{5}-[A-Z]{2}#$').hasMatch(r[1] as String)), isTrue);
      expect(rows.every((r) => r[2] == true), isTrue);
      expect(
        rows.every(
          (r) =>
              RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(r[3] as String),
        ),
        isTrue,
      );
      expect(expandPattern('##', Random(1)).length, 2);
    });

    test('binary and type coercion', () {
      final bin = _cfg(_col('foto', SQL_VARBINARY, size: 8));
      final txt = _cfg(_col('codice', SQL_VARCHAR, size: 10))
        ..kind = MockKind.sequence
        ..seqStart = 100;
      final r = MockDataGenerator([bin, txt], seed: 1).next();
      expect(r[0], isA<Uint8List>());
      expect((r[0] as Uint8List).length, 8);
      expect(r[1], '100');
    });
  });

  group('SQL', () {
    test('multi-row parameterized insert sizing', () {
      final ms = SqlDialect(dbmsName: 'Microsoft SQL Server', quote: '[');
      expect(rowsPerInsert(ms, 10), 200);
      expect(rowsPerInsert(SqlDialect(dbmsName: 'Oracle'), 10), 1);
      expect(rowsPerInsert(SqlDialect(dbmsName: 'SQLite'), 3), 333);
      expect(
        parameterizedInsert(ms, '[dbo].[t]', const ['a', 'b'], 2),
        'INSERT INTO [dbo].[t] (a, b) VALUES (?, ?), (?, ?)',
      );
    });

    test('insert script with typed literals', () {
      final pg = SqlDialect(dbmsName: 'PostgreSQL');
      final cols = [
        _cfg(_col('id', SQL_INTEGER)),
        _cfg(_col('nome', SQL_VARCHAR, size: 20)),
        _cfg(_col('attivo', SQL_BIT)),
        _cfg(_col('creato', SQL_TYPE_TIMESTAMP)),
      ];
      final s = mockInsertScript(pg, 'public.t', cols, [
        [1, "D'Amico", true, '2024-01-01 10:00:00'],
        [2, null, false, null],
      ]);
      expect(
        s,
        "INSERT INTO public.t (id, nome, attivo, creato) VALUES (1, 'D''Amico', TRUE, '2024-01-01 10:00:00');\n"
        'INSERT INTO public.t (id, nome, attivo, creato) VALUES (2, NULL, FALSE, NULL);\n',
      );
    });
  });

  test('declared types reported as text (SQLite ODBC) still get numeric and date generators', () {
    DbColumn col(String name, String type, {int? size}) => DbColumn(
      name: name,
      dataType: SQL_VARCHAR,
      typeName: type,
      size: size ?? 255,
      decimals: null,
      nullable: true,
      position: 1,
    );
    final salary = MockColumnConfig(col('stipendio', 'decimal(10,2)', size: 10));
    expect(salary.effectiveKind, MockKind.decimal);
    expect(salary.scale, 2);
    expect(MockColumnConfig(col('assunto_il', 'date')).effectiveKind, MockKind.dateTime);
    expect(MockColumnConfig(col('ore', 'integer')).effectiveKind, MockKind.integer);
    expect(MockColumnConfig(col('codice', 'varchar(10)', size: 10)).effectiveKind, MockKind.pattern);
  });
}
