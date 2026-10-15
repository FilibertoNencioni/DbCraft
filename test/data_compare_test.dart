import 'dart:typed_data';

import 'package:dbcraft/features/data_compare/compare_engine.dart';
import 'package:dbcraft/features/data_compare/sql_values.dart';
import 'package:dbcraft/features/data_compare/sync_script.dart';
import 'package:dbcraft/odbc/odbc_ffi.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:flutter_test/flutter_test.dart';

const _kinds = [ValueKind.numeric, ValueKind.text, ValueKind.numeric];

DataComparer _cmp({CompareOptions options = const CompareOptions(), int cap = 0, List<ValueKind> kinds = _kinds}) =>
    DataComparer(columns: const ['id', 'name', 'price'], keyCount: 1, options: options, rowCap: cap, kinds: kinds);

void main() {
  group('normalization', () {
    const n = ValueNormalizer();

    test('numbers vs numeric strings', () {
      expect(n.equal(12, '12'), isTrue);
      expect(n.equal('12.50', 12.5), isTrue);
      expect(n.equal('012.500', '12.5', ValueKind.numeric), isTrue);
      expect(n.equal(1.0, 1), isTrue);
      expect(n.equal('-0.00', 0), isTrue);
      expect(n.equal(12, '12.01'), isFalse);
      expect(canonicalDecimal('-000123.4500'), '-123.45');
      expect(canonicalDecimal('0.000'), '0');
    });

    test('text columns keep leading zeros', () {
      expect(n.equal('00100', '100', ValueKind.text), isFalse);
      expect(n.equal('00100', '100'), isFalse);
    });

    test('trim and case options', () {
      expect(n.equal('abc  ', 'abc'), isTrue);
      expect(const ValueNormalizer(CompareOptions(trimStrings: false)).equal('abc  ', 'abc'), isFalse);
      expect(n.equal('ABC', 'abc'), isFalse);
      expect(const ValueNormalizer(CompareOptions(ignoreCase: true)).equal('ABC', 'abc'), isTrue);
    });

    test('null handling', () {
      expect(n.equal(null, null), isTrue);
      expect(n.equal(null, ''), isFalse);
      expect(n.equal(null, 0), isFalse);
      expect(const ValueNormalizer(CompareOptions(nullEqualsEmpty: true)).equal(null, ''), isTrue);
    });

    test('float tolerance', () {
      expect(n.equal(0.1 + 0.2, 0.3), isFalse);
      expect(const ValueNormalizer(CompareOptions(floatTolerance: 1e-9)).equal(0.1 + 0.2, 0.3), isTrue);
      expect(const ValueNormalizer(CompareOptions(floatTolerance: 0.01)).equal('10.004', 10), isTrue);
    });

    test('date/time normalization', () {
      expect(n.equal('2024-01-02 00:00:00.000', '2024-01-02'), isTrue);
      expect(n.equal('2024-01-02T10:30:00', '2024-01-02 10:30:00.000'), isTrue);
      expect(n.equal('2024-01-02 10:30', '2024-01-02 10:30:00'), isTrue);
      expect(n.equal('2024-01-02 10:30:00.120', '2024-01-02 10:30:00.12'), isTrue);
      expect(n.equal('2024-01-02 10:30:01', '2024-01-02 10:30:00'), isFalse);
      expect(
        const ValueNormalizer(CompareOptions(normalizeDates: false)).equal('2024-01-02 00:00:00', '2024-01-02'),
        isFalse,
      );
    });

    test('binary', () {
      expect(n.equal(Uint8List.fromList([1, 2]), Uint8List.fromList([1, 2])), isTrue);
      expect(n.equal(Uint8List.fromList([1, 2]), Uint8List.fromList([1, 3])), isFalse);
    });

    test('key ordering and hashing', () {
      expect(n.compare(2, '10'), lessThan(0));
      expect(n.compare('10', 10), 0);
      expect(n.compare(null, 1), lessThan(0));
      expect(n.compare('b', 'a'), greaterThan(0));
      expect(
        n.compare(BigInt.parse('9007199254740993').toString(), '9007199254740992', ValueKind.numeric),
        greaterThan(0),
      );
      expect(n.keyPart(10), n.keyPart('10.0', ValueKind.numeric));
      expect(n.keyPart('a'), isNot(n.keyPart('A')));
      expect(
        const ValueNormalizer(CompareOptions(ignoreCase: true)).keyPart('a'),
        const ValueNormalizer(CompareOptions(ignoreCase: true)).keyPart('A'),
      );
    });
  });

  group('merge join', () {
    final src = [
      [1, 'Anna', '10.00'],
      [2, 'Bruno', '20.00'],
      [3, 'Carla', '30.00'],
      [5, 'Elena', null],
    ];
    final tgt = [
      [1, 'Anna', 10],
      [2, 'Bruna', '20.0'],
      [4, 'Dario', '40'],
      [5, 'Elena', null],
      [6, 'Franco', '60'],
    ];

    test('classifies rows', () async {
      final r = await _cmp().mergeJoin(ListRowSource(src, pageSize: 2), ListRowSource(tgt, pageSize: 3));
      expect(r.rows.map((e) => e.kind).toList(), [
        RowDiff.identical,
        RowDiff.different,
        RowDiff.onlySource,
        RowDiff.onlyTarget,
        RowDiff.identical,
        RowDiff.onlyTarget,
      ]);
      expect(r.rows[1].diffColumns, [1]);
      expect(r.count(RowDiff.identical), 2);
      expect(r.count(RowDiff.onlyTarget), 2);
      expect(r.sourceRows, 4);
      expect(r.targetRows, 5);
      expect(r.truncated, isFalse);
      expect(r.inSync, isFalse);
    });

    test('detects ordering mismatches', () async {
      final unordered = [
        ['b', 1, 1],
        ['a', 1, 1],
      ];
      expect(
        () => _cmp().mergeJoin(ListRowSource(unordered), ListRowSource(const [])),
        throwsA(isA<CompareOrderException>()),
      );
    });

    test('detects duplicate keys', () async {
      final dup = [
        [1, 'a', 1],
        [1, 'b', 1],
      ];
      expect(
        () => _cmp().mergeJoin(ListRowSource(const []), ListRowSource(dup)),
        throwsA(isA<CompareDuplicateKeyException>()),
      );
    });

    test('row cap stops without misclassifying', () async {
      final r = await _cmp(cap: 2).mergeJoin(ListRowSource(src), ListRowSource(tgt));
      expect(r.truncated, isTrue);
      expect(r.rows.length, 2);
      expect(r.rows.every((e) => e.kind != RowDiff.onlyTarget), isTrue);
    });

    test('cancellation', () async {
      final c = DataComparer(columns: const ['id', 'name', 'price'], keyCount: 1, isCancelled: () => true);
      expect(() => c.mergeJoin(ListRowSource(src), ListRowSource(tgt)), throwsA(isA<CompareCancelledException>()));
    });
  });

  group('hash join', () {
    test('order independent and same classification as merge', () async {
      final src = [
        ['B', 'x', 1],
        ['a', 'y', 2],
        ['c', 'z', 3],
      ];
      final tgt = [
        ['c', 'z', '3'],
        ['B', 'x', 9],
        ['d', 'w', 4],
      ];
      final r = await _cmp(kinds: const [ValueKind.text, ValueKind.text, ValueKind.numeric])
          .hashJoin(ListRowSource(src, pageSize: 1), ListRowSource(tgt, pageSize: 2));
      final byKey = {for (final row in r.rows) row.values[0]: row};
      expect(byKey['B']!.kind, RowDiff.different);
      expect(byKey['B']!.diffColumns, [2]);
      expect(byKey['a']!.kind, RowDiff.onlySource);
      expect(byKey['c']!.kind, RowDiff.identical);
      expect(byKey['d']!.kind, RowDiff.onlyTarget);
      expect(r.hashJoin, isTrue);
      // Sorted by key with the comparator.
      expect(r.rows.map((e) => e.values[0]).toList(), ['B', 'a', 'c', 'd']);
    });

    test('case-insensitive keys', () async {
      final r =
          await _cmp(
            options: const CompareOptions(ignoreCase: true),
            kinds: const [ValueKind.text, ValueKind.text, ValueKind.numeric],
          ).hashJoin(
            ListRowSource([
              ['ABC', 'x', 1],
            ]),
            ListRowSource([
              ['abc', 'x', 1],
            ]),
          );
      expect(r.rows.single.kind, RowDiff.identical);
    });

    test('duplicate keys', () async {
      expect(
        () => _cmp().hashJoin(
          ListRowSource([
            [1, 'a', 1],
            ['1', 'b', 1],
          ]),
          ListRowSource(const []),
        ),
        throwsA(isA<CompareDuplicateKeyException>()),
      );
    });
  });

  group('sync script', () {
    final pg = SqlDialect(dbmsName: 'PostgreSQL');
    final ms = SqlDialect(dbmsName: 'Microsoft SQL Server', quote: '[');

    Future<CompareResult> result() => _cmp().mergeJoin(
      ListRowSource([
        [1, 'Anna', '10.00'],
        [2, 'Bruno', '20.00'],
        [3, "O'Hara", null],
      ]),
      ListRowSource([
        [1, 'Anna', '10'],
        [2, 'Bruna', '25'],
        [4, 'Dario', '40'],
      ]),
    );

    test('insert / update / delete with literals and parameters', () async {
      final b = SyncScriptBuilder(
        dialect: pg,
        tableName: 'public.people',
        columns: const ['id', 'name', 'price'],
        keyCount: 1,
        sqlTypes: const [SQL_INTEGER, SQL_VARCHAR, SQL_DECIMAL],
      );
      final r = await result();
      final s = b.build(r, SyncScriptOptions(delete: true));
      expect(s.map((e) => e.kind).toList(), [RowDiff.onlyTarget, RowDiff.different, RowDiff.onlySource]);
      expect(s[0].literal, 'DELETE FROM public.people WHERE id = 4');
      expect(s[1].literal, "UPDATE public.people SET name = 'Bruno', price = 20.00 WHERE id = 2");
      expect(s[1].sql, 'UPDATE public.people SET name = ?, price = ? WHERE id = ?');
      expect(s[1].params, ['Bruno', '20.00', 2]);
      expect(s[2].literal, "INSERT INTO public.people (id, name, price) VALUES (3, 'O''Hara', NULL)");
      expect(s[2].params.last, isA<SqlParam>());
      final text = b.script(s, header: 'Sincronizzazione');
      expect(text, startsWith('-- Sincronizzazione'));
      expect(text, contains('DELETE FROM public.people WHERE id = 4;'));
    });

    test('options select statement kinds; delete off by default', () async {
      final b = SyncScriptBuilder(dialect: pg, tableName: 't', columns: const ['id', 'name', 'price'], keyCount: 1);
      final r = await result();
      expect(b.build(r, SyncScriptOptions()).any((e) => e.kind == RowDiff.onlyTarget), isFalse);
      expect(b.build(r, SyncScriptOptions(insert: false, update: false, delete: false)), isEmpty);
    });

    test('null keys and target key values in WHERE', () {
      final b = SyncScriptBuilder(dialect: pg, tableName: 't', columns: const ['a', 'b', 'v'], keyCount: 2);
      final u = b.update(['x', null, 1], ['X ', null, 2], [2]);
      expect(u.literal, "UPDATE t SET v = 1 WHERE a = 'X ' AND b IS NULL");
      expect(u.params, [1, 'X ']);
    });

    test('dialect specific temporal and boolean literals', () {
      expect(typedLiteral(ms, SQL_TYPE_TIMESTAMP, '2024-03-01 10:20:30.500'), "'2024-03-01T10:20:30.500'");
      expect(typedLiteral(ms, SQL_TYPE_DATE, '2024-03-01'), "'2024-03-01'");
      expect(
        typedLiteral(SqlDialect(dbmsName: 'Oracle'), SQL_TYPE_TIMESTAMP, '2024-03-01 10:20:30'),
        "TIMESTAMP '2024-03-01 10:20:30'",
      );
      expect(typedLiteral(SqlDialect(dbmsName: 'Oracle'), SQL_TYPE_DATE, '2024-03-01'), "DATE '2024-03-01'");
      expect(typedLiteral(pg, SQL_BIT, 1), 'TRUE');
      expect(typedLiteral(pg, null, true), 'TRUE');
      expect(typedLiteral(ms, SQL_BIT, 1), '1');
      expect(typedLiteral(ms, SQL_WVARCHAR, 'città'), "N'città'");
      expect(typedLiteral(pg, SQL_VARCHAR, '00100'), "'00100'");
      final p = bindValue(pg, SQL_TYPE_TIMESTAMP, '2024-03-01 10:20');
      expect(p, isA<SqlParam>());
      expect((p as SqlParam).value, '2024-03-01 10:20:00');
      expect(bindValue(ms, SQL_TYPE_TIMESTAMP, '2024-03-01 10:20:00'), '2024-03-01T10:20:00');
      expect(bindValue(pg, SQL_TYPE_TIMESTAMP, '2024-03-01 10:20:00.123'), '2024-03-01 10:20:00.123');
    });
  });
}
