import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/services/storage.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the editor sends; `SELECT` returns one row, the rest a count.
class _Session implements DbSession {
  final sent = <(String, List<Object?>)>[];
  final List<String> batchErrors = [];

  @override
  Future<ResultPage> execute(String sql, {List<Object?> params = const [], int fetchSize = 200, int queryTimeoutSec = 0}) async {
    sent.add((sql, params));
    if (sql.contains('FAIL')) throw OdbcException('SQLExecute', [const OdbcDiag('42000', 1, 'boom')]);
    if (sql.contains('SELECT')) {
      return ResultPage(
        columns: const [ColumnInfo(index: 1, name: 'x', sqlType: 4)],
        rows: const [
          [1],
        ],
        errors: batchErrors,
      );
    }
    return ResultPage(columns: const [], rows: const [], rowsAffected: 1, errors: batchErrors);
  }

  @override
  dynamic noSuchMethod(Invocation i) => Future<dynamic>.value(null);
}

class _Ui implements ExecutionUi {
  @override
  Future<Map<String, Object?>?> askParameters(List<String> names, Map<String, Object?> previous) async => {
    for (final n in names) n: 'asked',
  };
  @override
  Future<bool> confirm(String title, String message) async => true;
  @override
  Future<bool> ensureConnected(DbConnection c) async => true;
}

void main() {
  late _Session session;
  late SqlEditorTab tab;

  setUp(() {
    session = _Session();
    final dc = DbConnection(ConnectionConfig(id: 'c', name: 'c'))..main = session;
    tab = SqlEditorTab(settings: AppSettings(), connection: dc, initialText: 'SELECT :id;\nUPDATE t SET a = :id WHERE b = ?');
  });

  test('a variable without a value stops the run before anything is sent', () async {
    await tab.execute(_Ui());
    expect(session.sent, isEmpty);
    expect(tab.blockedVariables, {'id'});
    expect(tab.showVariables, isTrue);
    expect(tab.stoppedByVariables, isTrue);
    expect(tab.log.last.message, 'Variabili senza valore: :id');
  });

  test('the panel value is bound in every statement, the ? still asked', () async {
    tab.variableFor('id').value = '5';
    tab.variablesChanged();
    await tab.execute(_Ui());
    expect(session.sent.map((e) => '${e.$1} ${e.$2}'), [
      'SELECT ? [5]',
      'UPDATE t SET a = ? WHERE b = ? [5, asked]',
    ]);
    expect(tab.blockedVariables, isEmpty);
    // "Aggiorna" runs the same text with the same values.
    final r = tab.results.firstWhere((r) => r.model != null);
    expect('${r.sql} ${r.params}', 'SELECT ? [5]');
  });

  test('errors of a batch that went on become error tabs', () async {
    tab.controller.text = 'SELECT 1';
    session.batchErrors.add('[22012] (8134) Divide by zero error encountered.');
    await tab.execute(_Ui());
    expect(tab.results.map((r) => r.title), ['Risultati', 'Errore']);
    expect(tab.results.last.error, contains('Divide by zero'));
    // The error tab is the one shown.
    expect(tab.selectedResult, 1);
  });
}
