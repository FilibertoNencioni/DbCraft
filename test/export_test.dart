import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/dialogs/export_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake session whose every statement returns [sets] as consecutive result
/// sets, [pageSize] rows per page (like a stored procedure with two SELECT).
class _MultiResultSession implements DbSession {
  _MultiResultSession(this.sets, {this.pageSize = 2});

  final List<List<List<Object?>>> sets;
  final int pageSize;
  bool closed = false;

  // cursor id → (result set index, next row offset)
  final _cursors = <int, (int, int)>{};
  var _next = 1;

  static final _cols = [ColumnInfo(index: 1, name: 'v', sqlType: 4, typeName: 'int')];

  ResultPage _page(int id, int set, int offset, int count) {
    final rows = sets[set];
    final end = (offset + count).clamp(0, rows.length);
    final more = end < rows.length;
    final nextSet = set + 1 < sets.length;
    if (more || nextSet) {
      _cursors[id] = (set, end);
    } else {
      _cursors.remove(id);
    }
    return ResultPage(
      columns: _cols,
      rows: rows.sublist(offset, end),
      hasMore: more,
      cursorId: more || nextSet ? id : null,
      hasNextResultSet: !more && nextSet,
    );
  }

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) async => _page(_next++, 0, 0, pageSize);

  @override
  Future<ResultPage> fetchMore(int cursorId, int count) async {
    final (set, offset) = _cursors[cursorId]!;
    return _page(cursorId, set, offset, count == 0 ? 1 << 30 : pageSize);
  }

  @override
  Future<ResultPage?> nextResultSet(int cursorId, int fetchSize) async {
    final c = _cursors.remove(cursorId);
    if (c == null || c.$1 + 1 >= sets.length) return null;
    return _page(cursorId, c.$1 + 1, 0, pageSize);
  }

  @override
  Future<void> close() async => closed = true;

  @override
  bool get isClosed => closed;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('streamQuery', () {
    late _MultiResultSession session;
    late DbConnection dc;

    setUp(() {
      session = _MultiResultSession([
        [[1], [2], [3]],
        [[10], [20], [30], [40], [50]],
      ]);
      dc = DbConnection(ConnectionConfig(id: 'multi', name: 'multi'))..sessionOpener = (_) async => session;
    });

    Future<List<Object?>> read(int index) async => [
      await for (final p in streamQuery(dc, 'EXEC p', const [], resultSetIndex: index))
        for (final r in p) r.single,
    ];

    test('reads every page of the first result set', () async {
      expect(await read(0), [1, 2, 3]);
      expect(session.closed, isTrue);
    });

    test('skips to the requested result set, even when the earlier one has more pages', () async {
      expect(await read(1), [10, 20, 30, 40, 50]);
      expect(session.closed, isTrue);
    });

    test('a result set that no longer exists is an error, not the wrong rows', () async {
      await expectLater(read(2), throwsA(isA<Exception>()));
      expect(session.closed, isTrue);
    });
  });

  group('exportFileNames', () {
    test('uses the tab titles and numbers duplicates', () {
      expect(
        exportFileNames(['clienti', 'ordini', 'clienti', 'Clienti'], 'csv'),
        ['clienti.csv', 'ordini.csv', 'clienti (2).csv', 'Clienti (3).csv'],
      );
    });

    test('keeps titles that are already numbered apart from the generated ones', () {
      expect(
        exportFileNames(['Risultati', 'Risultati (2)', 'Risultati'], 'json'),
        ['Risultati.json', 'Risultati (2).json', 'Risultati (3).json'],
      );
    });

    test('replaces characters not allowed in file names', () {
      expect(exportFileNames(['dbo/ordini: 2024?', ' . ', 'a.'], 'csv'), [
        'dbo_ordini_ 2024_.csv',
        'risultato.csv',
        'a.csv',
      ]);
    });
  });
}
