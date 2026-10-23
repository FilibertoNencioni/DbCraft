// A DDL script ready for preview and execution (see runDdlScript).
//
// Statements follow the DdlBuilder conventions: no terminators, entries made
// only of `--` lines are comments. Passwords never appear in them: builders
// put a [SecretBag] token in their place, which the preview, the clipboard,
// the SQL editor and the query history only ever show masked; the real SQL
// fragment is substituted right before the statement is sent to the server.

import '../../state/db_connection.dart';
import '../schema/ddl_builder.dart';

/// Collects the secrets (passwords) of a script and hands out the tokens
/// that stand for them in the statements.
class SecretBag {
  final Map<String, String> _values = {};

  /// Token that stands for the SQL fragment [sql] (e.g. `'p@ss'` or, on
  /// Oracle, `"p@ss"`): already quoted for the dialect.
  String add(String sql) {
    final token = '⟦secret:${_values.length + 1}⟧';
    _values[token] = sql;
    return token;
  }

  Map<String, String> get values => Map.unmodifiable(_values);
}

class DdlScript {
  const DdlScript(
    this.statements, {
    this.secrets = const {},
    this.autocommitOnly = false,
    this.transactional = false,
    this.scope = SchemaScope.connection,
  });

  /// Text shown in place of a secret.
  static const mask = "'••••••'";

  static final _token = RegExp(r'⟦secret:\d+⟧');

  final List<String> statements;

  /// Secret token → SQL fragment (see [SecretBag]).
  final Map<String, String> secrets;

  /// Statements that cannot run inside a transaction (CREATE / DROP
  /// DATABASE, PostgreSQL CREATE INDEX CONCURRENTLY): with manual commit they
  /// run on a separate auto-commit session.
  final bool autocommitOnly;

  /// Run the script in one transaction, rolled back at the first error, when
  /// the DBMS has transactional DDL. Off for scripts that toggle settings
  /// ignored inside a transaction (SQLite `PRAGMA foreign_keys`).
  final bool transactional;

  /// What the script changes: the navigator and the open editors refresh it.
  final SchemaScope scope;

  bool get isEmpty => executable.isEmpty;

  /// Statements to send to the server (comments left out), still masked.
  List<String> get executable => executableStatements(statements);

  bool hasSecret(String statement) => _token.hasMatch(statement);

  /// [statement] with every secret masked (preview, history, errors).
  static String masked(String statement) => statement.replaceAll(_token, mask);

  /// [statement] with the secrets substituted: only for the server.
  String resolve(String statement) => statement.replaceAllMapped(_token, (m) => secrets[m[0]] ?? mask);

  /// Whole script with `;` terminators and masked secrets.
  String render(DdlBuilder builder) => masked(builder.render(statements));
}

/// Outcome of running a [DdlScript].
class DdlResult {
  const DdlResult({required this.total, required this.executed, this.failedIndex, this.error, this.rolledBack = false});

  /// Not run (cancelled, read-only connection, nothing to do).
  const DdlResult.skipped() : total = 0, executed = 0, failedIndex = null, error = null, rolledBack = false;

  final int total;
  final int executed;

  /// Index (in the executable statements) of the statement that failed.
  final int? failedIndex;
  final String? error;

  /// The statements run before the failure were rolled back.
  final bool rolledBack;

  bool get ok => failedIndex == null && error == null && total > 0 && executed == total;
}
