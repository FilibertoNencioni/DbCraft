import 'package:dbcraft/features/charts/chart_data.dart';
import 'package:dbcraft/features/charts/chart_view.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _cols = [
  ChartColumn('id', sqlType: 4),
  ChartColumn('reparto', sqlType: 12),
  ChartColumn('stipendio', sqlType: 3),
  ChartColumn('assunto', sqlType: 12, typeName: 'TEXT'),
];

final _rows = <List<Object?>>[
  [1, 'IT', '1000.50', '2024-01-10'],
  [2, 'HR', '800', '2024-03-05'],
  [3, 'IT', '1200', '2023-12-01'],
  [4, null, '500', null],
  [5, 'HR', null, '2024-02-01'],
];

void main() {
  group('profiling', () {
    test('numeric, text, dates and keys', () {
      final p = profileColumns(_cols, _rows);
      expect(p[0].numeric, isTrue);
      expect(p[0].idLike, isTrue);
      expect(p[1].categorical, isTrue);
      expect(p[2].numeric, isTrue, reason: 'decimal strings are numbers');
      expect(p[3].date, isTrue, reason: 'ISO strings are dates');
      expect(p[3].numeric, isFalse);
    });

    test('date detection', () {
      expect(looksLikeDate('2024-01-31'), isTrue);
      expect(looksLikeDate('2024-01-31 10:22:01.123'), isTrue);
      expect(looksLikeDate('2024-01-31T10:22:01Z'), isTrue);
      expect(looksLikeDate('31/01/2024'), isFalse);
      expect(looksLikeDate('20240131'), isFalse);
      expect(looksLikeDate(20240131), isFalse);
    });

    test('auto config prefers dates for X and skips keys for Y', () {
      final p = profileColumns(_cols, _rows);
      final c = ChartConfig.auto(p, _rows.length);
      expect(c.x, 3);
      expect(c.y, [2]);
      expect(c.kind, ChartKind.line);
      expect(c.sort, ChartSort.x);
    });
  });

  group('aggregation', () {
    final p = profileColumns(_cols, _rows);

    test('sum grouped by category, nulls in their own group', () {
      final d = buildChartData(_cols, p, _rows, ChartConfig(x: 1, y: [2], agg: ChartAgg.sum));
      expect(d.labels, ['IT', 'HR', kNullLabel]);
      expect(d.series.single.values, [2200.5, 800, 500]);
      expect(d.series.single.name, 'Somma stipendio');
    });

    test('avg, min, max, count', () {
      ChartData run(ChartAgg a) => buildChartData(_cols, p, _rows, ChartConfig(x: 1, y: [2], agg: a));
      expect(run(ChartAgg.avg).series.single.values, [1100.25, 800, 500]);
      expect(run(ChartAgg.min).series.single.values, [1000.5, 800, 500]);
      expect(run(ChartAgg.max).series.single.values, [1200, 800, 500]);
      // COUNT of a column ignores NULL values.
      expect(run(ChartAgg.count).series.single.values, [2, 1, 1]);
      // COUNT without series counts the rows.
      final rows = buildChartData(_cols, p, _rows, ChartConfig(x: 1, agg: ChartAgg.count));
      expect(rows.series.single.values, [2, 2, 1]);
    });

    test('sorting by value and top N', () {
      final d = buildChartData(
        _cols,
        p,
        _rows,
        ChartConfig(x: 1, y: [2], agg: ChartAgg.sum, sort: ChartSort.valueAsc, topN: 2),
      );
      expect(d.labels, [kNullLabel, 'HR']);
      expect(d.notes, isNotEmpty);
    });

    test('no aggregation keeps one point per row; time axis when sorted by date', () {
      final d = buildChartData(_cols, p, _rows, ChartConfig(kind: ChartKind.line, x: 3, y: [2], sort: ChartSort.x));
      expect(d.labels.first, '2023-12-01');
      expect(d.timeAxis, isFalse, reason: 'a NULL date prevents the time axis');
      final rows = _rows.where((r) => r[3] != null).toList();
      final t = buildChartData(_cols, p, rows, ChartConfig(kind: ChartKind.line, x: 3, y: [2], sort: ChartSort.x));
      expect(t.timeAxis, isTrue);
      expect(t.positions, orderedEquals(List.of(t.positions!)..sort()));
      expect(t.series.single.values, [1200, 1000.5, null, 800], reason: 'NULL values stay as gaps');
    });

    test('large results are capped with a note', () {
      final many = [
        for (var i = 0; i < 2500; i++) <Object?>[i, 'c$i', i * 1.0, null],
      ];
      final d = buildChartData(_cols, profileColumns(_cols, many), many, ChartConfig(x: 1, y: [2]));
      expect(d.labels.length, kMaxPoints);
      expect(d.notes.single, contains('1000'));
    });

    test('pie folds the tail into Altro', () {
      final many = [
        for (var i = 0; i < 12; i++) <Object?>[i, 'c$i', (12 - i) * 1.0, null],
      ];
      final d = buildChartData(
        _cols,
        profileColumns(_cols, many),
        many,
        ChartConfig(kind: ChartKind.pie, x: 1, y: [2], agg: ChartAgg.sum, sort: ChartSort.valueDesc),
      );
      expect(d.labels.length, kMaxSlices + 1);
      expect(d.labels.last, kOtherLabel);
      expect(d.series.single.values.last, 5 + 4 + 3 + 2 + 1);
      expect(d.otherIndex, kMaxSlices);
    });
  });

  group('nice ticks', () {
    test('round steps', () {
      final s = niceScale(0, 97);
      expect(s.min, 0);
      expect(s.max, 100);
      expect(s.step, 20);
      expect(s.ticks, [0, 20, 40, 60, 80, 100]);
    });

    test('negative and fractional ranges', () {
      final s = niceScale(-3.2, 7.9);
      expect(s.min, lessThanOrEqualTo(-3.2));
      expect(s.max, greaterThanOrEqualTo(7.9));
      expect([1.0, 2.0, 2.5, 5.0].any((m) => (s.step / m) == (s.step / m).roundToDouble()), isTrue);
      final f = niceScale(0.01, 0.087);
      expect(f.step, closeTo(0.02, 1e-12));
      expect(f.ticks.last, 0.1);
      expect(f.decimals, 2);
    });

    test('degenerate range', () {
      expect(niceScale(0, 0).ticks, [0, 0.2, 0.4, 0.6, 0.8, 1]);
      final s = niceScale(50, 50);
      expect(s.min, lessThan(50));
      expect(s.max, greaterThan(50));
    });

    test('time ticks are calendar aligned', () {
      final a = DateTime(2024, 1, 15).millisecondsSinceEpoch.toDouble();
      final b = DateTime(2024, 12, 20).millisecondsSinceEpoch.toDouble();
      final t = timeTicks(a, b);
      expect(t.length, inInclusiveRange(2, 7));
      for (final x in t) {
        final d = DateTime.fromMillisecondsSinceEpoch(x.ms.round());
        expect(d.day, 1);
      }
    });
  });

  group('formatting', () {
    test('italian number format', () {
      expect(formatNumber(1234567.891), '1.234.567,89');
      expect(formatNumber(-1500), '-1.500');
      expect(formatNumber(0.5, decimals: 2), '0,50');
      expect(formatTick(2500000, niceScale(0, 3000000)), '2,5 Mln');
    });
  });

  group('rendering', () {
    for (final dark in [false, true]) {
      testWidgets('every chart kind paints (${dark ? 'dark' : 'light'})', (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const cols = [
          ColumnInfo(index: 0, name: 'id', sqlType: 4),
          ColumnInfo(index: 1, name: 'reparto', sqlType: 12),
          ColumnInfo(index: 2, name: 'stipendio', sqlType: 3),
          ColumnInfo(index: 3, name: 'bonus', sqlType: 8),
          ColumnInfo(index: 4, name: 'assunto', sqlType: 12),
        ];
        final rows = [
          for (var i = 0; i < 40; i++)
            <Object?>[
              i,
              'R${i % 9}',
              '${1000 + i * 37}',
              i.isEven ? -i * 2.5 : i * 3.0,
              '2024-${(i % 12 + 1).toString().padLeft(2, '0')}-01',
            ],
        ];
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(dark ? Brightness.dark : Brightness.light),
            home: Scaffold(
              body: ChartView.data(columns: cols, rows: rows),
            ),
          ),
        );
        await tester.pump();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        for (final k in ChartKind.values) {
          await tester.tap(find.byTooltip(k.label));
          await tester.pump();
          await mouse.moveTo(const Offset(400, 400));
          await tester.pump();
          expect(tester.takeException(), isNull, reason: k.label);
        }
        // Stacked bars and areas.
        await tester.tap(find.byTooltip(ChartKind.bar.label));
        await tester.pump();
        await tester.tap(find.byType(CheckboxRow).first);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
