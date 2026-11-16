// Script variables: references (`@x`, `$x`, `:x`) and declarations found in
// a SQL script, the values kept in the Variabili panel and the preparation
// of what is sent to the server.
//
// The script is the truth: a variable the script declares (DECLARE @x on
// SQL Server, SET @x on MySQL, SET x on Snowflake) uses the value written
// there. Only the variables the script references without declaring them
// take their value from the panel, delivered in the way of the dialect:
//
// - SQL Server: `DECLARE @x <type> = <literal>;` in front of the batch
//   (variables live in the batch); `:x` becomes a literal.
// - MySQL / MariaDB, Snowflake: a `SET` run before the execution (session
//   variables).
// - everyone else (and `:x` on MySQL / Snowflake, `@x` on BigQuery): bound
//   as a positional parameter `?`.
import '../odbc/odbc_ffi.dart' show SQL_TYPE_DATE, SQL_TYPE_TIMESTAMP;
import '../odbc/odbc_types.dart' show SqlParam;
import 'sql_dialect.dart';
import 'sql_splitter.dart';

/// Kind of value of a panel variable.
enum VarType {
  auto('Auto'),
  text('Testo'),
  number('Numero'),
  date('Data'),
  dateTime('Data e ora'),
  boolean('Booleano');

  const VarType(this.label);
  final String label;
}

/// A variable whose value lives in the panel (saved per script, locally).
class ScriptVariable {
  ScriptVariable(this.name, {this.type = VarType.auto, this.value, this.isNull = false, this.sqlType = ''});

  /// Name without the sigil (`da` for `@da`).
  String name;
  VarType type;

  /// Text typed by the user; null when never given.
  String? value;

  /// Explicit NULL.
  bool isNull;

  /// SQL Server type of the DECLARE (`DECIMAL(10,2)`); empty: from the value.
  String sqlType;

  String get key => name.toLowerCase();

  /// A value was given (an empty text is a value only for [VarType.text]).
  bool get hasValue => isNull || (value != null && (type == VarType.text || value!.trim().isNotEmpty));

  /// Why the value cannot be used; null when it can (or is missing).
  String? get error {
    if (isNull || !hasValue) return null;
    final s = value!.trim();
    return switch (type) {
      VarType.number when _number(s) == null => 'Non è un numero',
      VarType.date when _date.matchAsPrefix(s)?.end != s.length => 'Data attesa come AAAA-MM-GG',
      VarType.dateTime when _dateTime.matchAsPrefix(s)?.end != s.length => 'Data e ora attese come AAAA-MM-GG hh:mm[:ss]',
      VarType.boolean when _bool(s) == null => 'Valori ammessi: vero/falso, true/false, 1/0',
      _ => null,
    };
  }

  /// Ready to be sent.
  bool get isUsable => hasValue && error == null;

  static final _date = RegExp(r'\d{4}-\d{2}-\d{2}');
  static final _dateTime = RegExp(r'\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2}(\.\d{1,7})?)?');

  static num? _number(String s) {
    final t = s.replaceAll(',', '.');
    if (RegExp(r'^[-+]?\d+$').hasMatch(t)) return int.tryParse(t) ?? double.tryParse(t);
    if (RegExp(r'^[-+]?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?$|^[-+]?\d+[eE][-+]?\d+$').hasMatch(t)) return double.tryParse(t);
    return null;
  }

  static bool? _bool(String s) => switch (s.toLowerCase()) {
    'true' || 'vero' || 'sì' || 'si' || '1' => true,
    'false' || 'falso' || 'no' || '0' => false,
    _ => null,
  };

  /// The value as a Dart object: null, int, double, bool or String.
  Object? get typed {
    if (isNull || !hasValue) return null;
    final s = type == VarType.text ? value! : value!.trim();
    switch (type) {
      case VarType.text:
      case VarType.date:
      case VarType.dateTime:
        return s;
      case VarType.number:
        return _number(s);
      case VarType.boolean:
        return _bool(s);
      case VarType.auto:
        if (RegExp(r'^-?[1-9][0-9]{0,17}$|^0$').hasMatch(s)) return int.parse(s);
        if (RegExp(r'^-?[0-9]+\.[0-9]+$').hasMatch(s)) return double.parse(s);
        return s;
    }
  }

  /// Value to bind as a parameter ([SqlParam] for dates on ODBC).
  Object? bindValue({required bool odbc}) {
    final v = typed;
    if (!odbc || v == null) return v;
    return switch (type) {
      VarType.date => SqlParam(v, sqlType: SQL_TYPE_DATE),
      VarType.dateTime => SqlParam((v as String).replaceFirst('T', ' '), sqlType: SQL_TYPE_TIMESTAMP),
      _ => v,
    };
  }

  /// Short description of the value for lists and the log.
  String get display {
    if (isNull) return 'NULL';
    if (!hasValue) return '';
    final v = typed;
    return v is String && type != VarType.number ? "'$v'" : '$v';
  }

  ScriptVariable copy() => ScriptVariable(name, type: type, value: value, isNull: isNull, sqlType: sqlType);

  Map<String, Object?> toJson() => {
    'name': name,
    if (type != VarType.auto) 'type': type.name,
    if (value != null) 'value': value,
    if (isNull) 'null': true,
    if (sqlType.isNotEmpty) 'sqlType': sqlType,
  };

  static ScriptVariable? fromJson(Object? j) {
    if (j is! Map || j['name'] is! String) return null;
    return ScriptVariable(
      j['name'] as String,
      type: VarType.values.asNameMap()[j['type']] ?? VarType.auto,
      value: j['value'] as String?,
      isNull: j['null'] == true,
      sqlType: j['sqlType'] as String? ?? '',
    );
  }

  static List<ScriptVariable> listFromJson(Object? j) =>
      j is List ? [for (final e in j) ?ScriptVariable.fromJson(e)] : <ScriptVariable>[];
}

// ---------------------------------------------------------------------------
// Syntax of each dialect
// ---------------------------------------------------------------------------

/// How variables are written in a dialect.
class VarSyntax {
  const VarSyntax({this.at = false, this.dollar = false, this.colon = true});

  /// `@name` (SQL Server, MySQL, BigQuery).
  final bool at;

  /// `$name` (Snowflake session variables).
  final bool dollar;

  /// `:name` (bind parameters, every SQL dialect).
  final bool colon;

  /// Sigil shown for new variables of the dialect.
  String get sigil => at ? '@' : (dollar ? r'$' : ':');

  /// The syntax of [family]; null for the stores without variables
  /// (MongoDB, Redis).
  static VarSyntax? of(DbFamily? family) => switch (family) {
    DbFamily.mongodb || DbFamily.redis => null,
    DbFamily.sqlServer || DbFamily.mysql || DbFamily.bigquery => const VarSyntax(at: true),
    DbFamily.snowflake => const VarSyntax(dollar: true),
    _ => const VarSyntax(),
  };
}

/// A variable referenced in the script.
class VarRef {
  const VarRef(this.sigil, this.name, this.start, this.end);
  final String sigil;
  final String name;
  final int start;
  final int end;
  String get key => name.toLowerCase();
  String get display => '$sigil$name';
}

/// A variable declared in the script (DECLARE @x …, SET @x = …, SET x = …).
class VarDecl {
  const VarDecl({
    required this.sigil,
    required this.name,
    required this.nameStart,
    required this.start,
    required this.end,
    this.sqlType,
    this.init,
    this.initStart,
    this.initEnd,
    this.editable = false,
  });

  final String sigil;
  final String name;
  final int nameStart;

  /// The whole declaring statement (DECLARE … up to its end).
  final int start;
  final int end;

  /// Declared type (SQL Server).
  final String? sqlType;

  /// Initial value as written; null when absent.
  final String? init;

  /// Where the value is (or, without one, where `= value` goes).
  final int? initStart;
  final int? initEnd;

  /// The initial value is a plain literal (or absent): the panel can
  /// rewrite it.
  final bool editable;

  String get key => name.toLowerCase();
  String get display => '$sigil$name';
}

/// References and declarations of a script.
class VariableScan {
  const VariableScan(this.refs, this.decls, this.positional);
  final List<VarRef> refs;
  final List<VarDecl> decls;

  /// Offsets of the positional `?` markers.
  final List<int> positional;

  static const empty = VariableScan([], [], []);

  Set<String> get declared => {for (final d in decls) d.key};
}

/// Statements whose `@x` / `:x` belong to a routine being created, not to
/// the script.
final _routine = RegExp(
  r'^(?:\s|--[^\n]*\n|/\*[\s\S]*?\*/)*(create|alter|create\s+or\s+(replace|alter))\s+((no)?editionable\s+)?'
  r'(definer\s*=\s*\S+\s+)?(proc|procedure|function|trigger|package|type\s+body|event|view)\b',
  caseSensitive: false,
);

/// Statement-starting words of T-SQL: a DECLARE without `;` ends there.
const _tsqlStatementWords = {
  'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'SET', 'DECLARE', 'IF', 'WHILE', 'EXEC', 'EXECUTE', 'PRINT', //
  'BEGIN', 'END', 'RETURN', 'WITH', 'MERGE', 'CREATE', 'DROP', 'ALTER', 'TRUNCATE', 'USE', 'RAISERROR', 'THROW',
  'GOTO', 'WAITFOR', 'OPEN', 'FETCH', 'CLOSE', 'DEALLOCATE', 'GO',
};

bool _isWordStart(int u) => (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95;
bool _isWordPart(int u) => _isWordStart(u) || (u >= 48 && u <= 57) || u == 36 || u == 35;

final _literal = RegExp(
  r"^(N?'(?:[^']|'')*'|[-+]?\d+(\.\d+)?([eE][-+]?\d+)?|[-+]?\.\d+|NULL|TRUE|FALSE|0x[0-9A-Fa-f]*)$",
  caseSensitive: false,
);

/// Whether [init] is a plain literal the panel can rewrite.
bool isPlainLiteral(String init) => _literal.hasMatch(init.trim());

/// Scans [sql] for the variables of [family].
VariableScan scanVariables(String sql, DbFamily? family, {SqlSplitter? splitter}) {
  final syntax = VarSyntax.of(family);
  if (syntax == null) return VariableScan.empty;
  final refs = <VarRef>[];
  final decls = <VarDecl>[];
  final positional = <int>[];
  final sp = splitter ?? SqlSplitter(family: family);
  for (final st in sp.split(sql)) {
    if (_routine.hasMatch(st.text)) continue;
    // Snowflake Scripting: `:x` inside a block is a block variable.
    final snowBlock = family == DbFamily.snowflake &&
        RegExp(r'^\s*(declare|begin)\b', caseSensitive: false).hasMatch(st.text);
    _Scanner(sql, st.start, st.end, family, syntax, refs, decls, positional, colon: !snowBlock).run();
  }
  return VariableScan(refs, decls, positional);
}

class _Scanner {
  _Scanner(
    this.s,
    this.from,
    this.to,
    this.family,
    this.syntax,
    this.refs,
    this.decls,
    this.positional, {
    this.colon = true,
  });

  final String s;
  final int from;
  final int to;
  final DbFamily? family;
  final VarSyntax syntax;
  final List<VarRef> refs;
  final List<VarDecl> decls;
  final List<int> positional;
  final bool colon;

  /// Name offsets of declarations (not references).
  final Set<int> _declNames = {};

  /// T-SQL: inside EXEC, `@param =` names a parameter of the procedure
  /// (but `EXEC @ret = p` assigns the return value to a variable).
  bool _exec = false;
  int _execAfter = 0;
  bool _firstWord = true;

  int _skipQuoted(int i, String q) {
    var j = i + 1;
    while (j < to) {
      if (s[j] == q) {
        if (j + 1 < to && s[j + 1] == q) {
          j += 2;
          continue;
        }
        return j + 1;
      }
      if (s[j] == r'\' && q != '"' && family == DbFamily.mysql && j + 1 < to) {
        j += 2;
        continue;
      }
      j++;
    }
    return to;
  }

  /// Skips comments, strings and quoted identifiers at [i]; returns the next
  /// offset or -1 when [i] starts none of them.
  int _skipOpaque(int i) {
    final c = s[i];
    if (c == '-' && i + 1 < to && s[i + 1] == '-') {
      final e = s.indexOf('\n', i);
      return e < 0 || e > to ? to : e;
    }
    if (c == '#' && family == DbFamily.mysql) {
      final e = s.indexOf('\n', i);
      return e < 0 || e > to ? to : e;
    }
    if (c == '/' && i + 1 < to && s[i + 1] == '*') {
      final e = s.indexOf('*/', i + 2);
      return e < 0 || e + 2 > to ? to : e + 2;
    }
    if (c == "'" || c == '"' || c == '`') return _skipQuoted(i, c);
    if (c == '[' && family != DbFamily.postgres) {
      final e = s.indexOf(']', i + 1);
      return e < 0 || e > to ? to : e + 1;
    }
    if (c == r'$') {
      final m = RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)?\$').matchAsPrefix(s, i);
      if (m != null && (family != DbFamily.snowflake || m[1] == null)) {
        final e = s.indexOf(m[0]!, i + m[0]!.length);
        return e < 0 || e + m[0]!.length > to ? to : e + m[0]!.length;
      }
    }
    return -1;
  }

  int _skipSpace(int i) {
    while (i < to) {
      final c = s[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        i++;
        continue;
      }
      if ((c == '-' && i + 1 < to && s[i + 1] == '-') || (c == '/' && i + 1 < to && s[i + 1] == '*')) {
        i = _skipOpaque(i);
        continue;
      }
      break;
    }
    return i;
  }

  int _wordEnd(int i) {
    var j = i;
    while (j < to && _isWordPart(s.codeUnitAt(j))) {
      j++;
    }
    return j;
  }

  static final _name = RegExp(r'[A-Za-z_][A-Za-z0-9_#$]*');

  bool _identBefore(int i) {
    if (i <= 0) return false;
    final p = s.codeUnitAt(i - 1);
    return _isWordPart(p) || p == 39 || p == 34 || p == 96 || p == 93; // ' " ` ]
  }

  void run() {
    var i = from;
    while (i < to) {
      final skipped = _skipOpaque(i);
      if (skipped >= 0) {
        i = skipped;
        continue;
      }
      final c = s[i];
      final u = c.codeUnitAt(0);
      if (_isWordStart(u)) {
        final j = _wordEnd(i);
        final word = s.substring(i, j).toUpperCase();
        final first = _firstWord;
        _firstWord = false;
        if (family == DbFamily.sqlServer) {
          if (word == 'EXEC' || word == 'EXECUTE') {
            _exec = true;
            _execAfter = _skipSpace(j);
          } else if (_tsqlStatementWords.contains(word)) {
            _exec = false;
          }
          if (word == 'DECLARE') {
            i = _tsqlDeclare(i, j);
            continue;
          }
        } else if (word == 'SET' && first && family == DbFamily.mysql) {
          _mysqlSet(i, j);
        } else if (word == 'SET' && first && family == DbFamily.snowflake) {
          _snowflakeSet(i, j);
        } else if (word == 'INTO' && family == DbFamily.mysql) {
          _mysqlInto(j);
        }
        i = j;
        continue;
      }
      if (c == ';') {
        _firstWord = true;
        _exec = false;
        i++;
        continue;
      }
      if (c == '@' && syntax.at) {
        if (i + 1 < to && s[i + 1] == '@') {
          // @@system_variable
          i = _wordEnd(i + 2);
          continue;
        }
        final m = _name.matchAsPrefix(s, i + 1);
        if (m != null && m.end <= to && !_identBefore(i)) {
          if (!_declNames.contains(i) && !(_exec && i != _execAfter && _assignedParam(m.end))) {
            refs.add(VarRef('@', m[0]!, i, m.end));
            if (family == DbFamily.mysql && _assignment(m.end)) _mysqlAssign(i, m);
          }
          i = m.end;
          continue;
        }
      }
      if (c == r'$' && syntax.dollar) {
        final m = RegExp(r'[A-Za-z_][A-Za-z0-9_]*').matchAsPrefix(s, i + 1);
        if (m != null && m.end <= to && !_identBefore(i)) {
          refs.add(VarRef(r'$', m[0]!, i, m.end));
          i = m.end;
          continue;
        }
      }
      if (c == ':' && colon && syntax.colon && i + 1 < to) {
        final next = s[i + 1];
        if (next == ':' || next == '=' || (i > 0 && s[i - 1] == ':')) {
          i += 2;
          continue;
        }
        final m = RegExp(r'[A-Za-z_][A-Za-z0-9_]*').matchAsPrefix(s, i + 1);
        if (m != null && m.end <= to && !_identBefore(i)) {
          final n = m[0]!.toLowerCase();
          if (n != 'new' && n != 'old') refs.add(VarRef(':', m[0]!, i, m.end));
          i = m.end;
          continue;
        }
      }
      if (c == '?') {
        positional.add(i);
      }
      i++;
    }
  }

  /// `@param = …` inside EXEC (not `==`).
  bool _assignedParam(int after) {
    final k = _skipSpace(after);
    return k < to && s[k] == '=' && (k + 1 >= to || s[k + 1] != '=');
  }

  /// `@x :=` (MySQL assignment in an expression).
  bool _assignment(int after) {
    final k = _skipSpace(after);
    return k + 1 < to && s[k] == ':' && s[k + 1] == '=';
  }

  /// End of an expression starting at [i]: a `,` or `;` at depth 0, a T-SQL
  /// statement word at depth 0 (DECLARE without `;`) or [to].
  int _exprEnd(int i, {bool tsql = false}) {
    var depth = 0;
    var caseDepth = 0;
    while (i < to) {
      final skipped = _skipOpaque(i);
      if (skipped >= 0) {
        i = skipped;
        continue;
      }
      final c = s[i];
      final u = c.codeUnitAt(0);
      if (_isWordStart(u)) {
        final j = _wordEnd(i);
        final w = s.substring(i, j).toUpperCase();
        if (w == 'CASE') caseDepth++;
        if (w == 'END' && caseDepth > 0) {
          caseDepth--;
        } else if (tsql && depth == 0 && caseDepth == 0 && _tsqlStatementWords.contains(w)) {
          return i;
        }
        i = j;
        continue;
      }
      if (c == '(') depth++;
      if (c == ')') {
        if (depth == 0) return i;
        depth--;
      }
      if ((c == ',' || c == ';') && depth == 0) return i;
      i++;
    }
    return to;
  }

  int _trimEnd(int a, int b) {
    while (b > a && ' \t\r\n'.contains(s[b - 1])) {
      b--;
    }
    return b;
  }

  /// DECLARE @a [AS] type [= init] [, @b …]; returns where scanning goes on
  /// (right after DECLARE: the initial values may reference variables).
  int _tsqlDeclare(int start, int afterWord) {
    final local = <VarDecl>[];
    var i = _skipSpace(afterWord);
    var end = afterWord;
    while (i < to && s[i] == '@') {
      final m = _name.matchAsPrefix(s, i + 1);
      if (m == null) break;
      final nameStart = i;
      _declNames.add(i);
      var k = _skipSpace(m.end);
      final asEnd = _wordEnd(k);
      if (s.substring(k, asEnd).toUpperCase() == 'AS') k = _skipSpace(asEnd);
      // Type: up to `=`, `,` or the end of the declaration.
      final typeStart = k;
      var depth = 0;
      while (k < to) {
        final skipped = _skipOpaque(k);
        if (skipped >= 0) {
          k = skipped;
          continue;
        }
        final c = s[k];
        if (_isWordStart(c.codeUnitAt(0))) {
          final e = _wordEnd(k);
          if (depth == 0 && k > typeStart && _tsqlStatementWords.contains(s.substring(k, e).toUpperCase())) break;
          k = e;
          continue;
        }
        if (c == '(') depth++;
        if (c == ')') depth--;
        if (depth == 0 && (c == '=' || c == ',' || c == ';')) break;
        k++;
      }
      final typeEnd = _trimEnd(typeStart, k);
      final type = s.substring(typeStart, typeEnd);
      String? init;
      int? initStart, initEnd;
      if (k < to && s[k] == '=') {
        initStart = _skipSpace(k + 1);
        final e = _exprEnd(initStart, tsql: true);
        initEnd = _trimEnd(initStart, e);
        init = s.substring(initStart, initEnd);
        k = e;
      } else {
        initStart = initEnd = typeEnd;
      }
      final upperType = type.toUpperCase();
      final isTable = upperType.startsWith('TABLE') || upperType.startsWith('CURSOR');
      local.add(VarDecl(
        sigil: '@',
        name: m[0]!,
        nameStart: nameStart,
        start: start,
        end: 0,
        sqlType: type,
        init: init,
        initStart: initStart,
        initEnd: initEnd,
        editable: !isTable && (init == null || isPlainLiteral(init)),
      ));
      end = initEnd;
      k = _skipSpace(k);
      if (k < to && s[k] == ',') {
        i = _skipSpace(k + 1);
        continue;
      }
      break;
    }
    for (final d in local) {
      decls.add(VarDecl(
        sigil: d.sigil,
        name: d.name,
        nameStart: d.nameStart,
        start: d.start,
        end: end,
        sqlType: d.sqlType,
        init: d.init,
        initStart: d.initStart,
        initEnd: d.initEnd,
        editable: d.editable,
      ));
    }
    return afterWord;
  }

  /// MySQL `SET @a = …, @b := …` at the start of a statement.
  void _mysqlSet(int start, int afterWord) {
    var i = _skipSpace(afterWord);
    while (i < to) {
      if (s[i] != '@' || (i + 1 < to && s[i + 1] == '@')) {
        // SET @@x / SET NAMES …: skip this item.
        final e = _exprEnd(i);
        if (e >= to || s[e] != ',') return;
        i = _skipSpace(e + 1);
        continue;
      }
      final m = _name.matchAsPrefix(s, i + 1);
      if (m == null) return;
      _declNames.add(i);
      var k = _skipSpace(m.end);
      if (k < to && s[k] == ':') k++;
      if (k >= to || s[k] != '=') return;
      final initStart = _skipSpace(k + 1);
      final e = _exprEnd(initStart);
      final initEnd = _trimEnd(initStart, e);
      final init = s.substring(initStart, initEnd);
      decls.add(VarDecl(
        sigil: '@',
        name: m[0]!,
        nameStart: i,
        start: start,
        end: initEnd,
        init: init,
        initStart: initStart,
        initEnd: initEnd,
        editable: isPlainLiteral(init),
      ));
      if (e >= to || s[e] != ',') return;
      i = _skipSpace(e + 1);
    }
  }

  /// MySQL `@x := …` inside an expression: declared, computed.
  void _mysqlAssign(int at, Match m) {
    if (decls.any((d) => d.nameStart == at)) return;
    decls.add(VarDecl(sigil: '@', name: m[0]!, nameStart: at, start: at, end: m.end));
  }

  /// MySQL `… INTO @a, @b`: declared, computed.
  void _mysqlInto(int afterWord) {
    var i = _skipSpace(afterWord);
    while (i < to && s[i] == '@' && !(i + 1 < to && s[i + 1] == '@')) {
      final m = _name.matchAsPrefix(s, i + 1);
      if (m == null) return;
      _declNames.add(i);
      decls.add(VarDecl(sigil: '@', name: m[0]!, nameStart: i, start: i, end: m.end));
      final k = _skipSpace(m.end);
      if (k >= to || s[k] != ',') return;
      i = _skipSpace(k + 1);
    }
  }

  /// Snowflake `SET x = …` / `SET (x, y) = (…)` at the start of a statement.
  void _snowflakeSet(int start, int afterWord) {
    var i = _skipSpace(afterWord);
    if (i < to && s[i] == '(') {
      final close = s.indexOf(')', i);
      if (close < 0 || close > to) return;
      for (final m in RegExp(r'[A-Za-z_][A-Za-z0-9_]*').allMatches(s.substring(i + 1, close))) {
        decls.add(VarDecl(sigil: r'$', name: m[0]!, nameStart: i + 1 + m.start, start: start, end: to));
      }
      return;
    }
    final m = RegExp(r'[A-Za-z_][A-Za-z0-9_]*').matchAsPrefix(s, i);
    if (m == null) return;
    final k = _skipSpace(m.end);
    if (k >= to || s[k] != '=') return;
    final initStart = _skipSpace(k + 1);
    final initEnd = _trimEnd(initStart, to);
    final init = s.substring(initStart, initEnd);
    decls.add(VarDecl(
      sigil: r'$',
      name: m[0]!,
      nameStart: i,
      start: start,
      end: initEnd,
      init: init,
      initStart: initStart,
      initEnd: initEnd,
      editable: isPlainLiteral(init),
    ));
  }
}

// ---------------------------------------------------------------------------
// Values as SQL
// ---------------------------------------------------------------------------

/// SQL Server type of the DECLARE of [v] (its own when given).
String tsqlTypeOf(ScriptVariable v) {
  if (v.sqlType.trim().isNotEmpty) return v.sqlType.trim();
  final t = v.typed;
  switch (v.type) {
    case VarType.date:
      return 'DATE';
    case VarType.dateTime:
      return 'DATETIME2';
    case VarType.boolean:
      return 'BIT';
    default:
  }
  if (t is int) return t.abs() <= 0x7FFFFFFF ? 'INT' : 'BIGINT';
  if (t is double || (t is num)) {
    final s = v.value!.trim().replaceAll(',', '.');
    if (s.contains(RegExp('[eE]'))) return 'FLOAT';
    final dot = s.indexOf('.');
    final scale = dot < 0 ? 0 : s.length - dot - 1;
    return 'DECIMAL(38, ${scale.clamp(0, 18)})';
  }
  if (t is String) {
    final ascii = t.runes.every((r) => r < 128);
    if (ascii && t.length <= 8000) return 'VARCHAR(8000)';
    if (t.length <= 4000) return 'NVARCHAR(4000)';
    return 'NVARCHAR(MAX)';
  }
  return 'NVARCHAR(4000)';
}

/// [v] as a literal of [dialect].
String variableLiteral(ScriptVariable v, SqlDialect dialect) {
  final t = v.typed;
  if (t == null) return 'NULL';
  final family = dialect.family;
  if (t is bool) {
    return family == DbFamily.sqlServer || family == DbFamily.sqlite ? (t ? '1' : '0') : (t ? 'TRUE' : 'FALSE');
  }
  if (t is num) return v.type == VarType.number ? v.value!.trim().replaceAll(',', '.') : '$t';
  final s = (t as String);
  if (v.type == VarType.date || v.type == VarType.dateTime) {
    final text = dialect.stringLiteral(v.type == VarType.dateTime ? s.replaceFirst('T', ' ') : s);
    return switch (family) {
      DbFamily.snowflake => '$text::${v.type == VarType.date ? 'DATE' : 'TIMESTAMP_NTZ'}',
      DbFamily.mysql || DbFamily.sqlServer || DbFamily.sqlite => text,
      _ => '${v.type == VarType.date ? 'DATE' : 'TIMESTAMP'} $text',
    };
  }
  if (family == DbFamily.sqlServer) {
    return s.runes.any((r) => r > 127) ? 'N${dialect.stringLiteral(s)}' : dialect.stringLiteral(s);
  }
  return dialect.literal(s);
}

// ---------------------------------------------------------------------------
// Preparation of what runs
// ---------------------------------------------------------------------------

/// A unit ready to be sent.
class PreparedUnit {
  PreparedUnit({required this.sql, required this.params, this.positional = const []});

  /// Text sent to the server (panel DECLAREs included).
  final String sql;

  /// Values of the `?` markers bound from the panel, by position; the
  /// [positional] ones (null entries here) are asked to the user.
  final List<Object?> params;

  /// Indexes in [params] of the user's own `?` markers.
  final List<int> positional;
}

/// What the variables of a run need.
class VariablePlan {
  VariablePlan({
    required this.units,
    required this.setup,
    required this.missing,
    required this.invalid,
    required this.carried,
    required this.used,
  });

  final List<PreparedUnit> units;

  /// Statements to run before the units (MySQL / Snowflake SET).
  final List<String> setup;

  /// Keys of the variables without a value (nothing runs).
  final List<String> missing;

  /// Keys of the variables whose value is not valid (nothing runs).
  final List<String> invalid;

  /// Declarations of the script repeated in front of a statement run alone
  /// (SQL Server: `@x` declared earlier in the same batch).
  final List<String> carried;

  /// Panel variables the run uses (display names), for the log.
  final List<String> used;

  bool get ready => missing.isEmpty && invalid.isEmpty;
}

/// Prepares [units] (offsets in [script], or a selection starting at
/// [base]) with the panel [variables]. Variables declared anywhere in
/// [script] belong to the script: on SQL Server those declared earlier in
/// the batch of a unit run alone are carried in front of it.
VariablePlan prepareVariables({
  required String script,
  required List<SqlUnit> units,
  required String Function(SqlUnit) textOf,
  required SqlDialect dialect,
  required List<ScriptVariable> variables,
  required bool odbc,
  List<SqlUnit> scriptUnits = const [],
  int base = 0,
}) {
  final family = dialect.family;
  final syntax = VarSyntax.of(family);
  final scriptScan = scanVariables(script, family);
  final declaredInScript = scriptScan.declared;
  final panel = {for (final v in variables) v.key: v};
  final missing = <String>[];
  final invalid = <String>[];
  final carried = <String>[];
  final used = <String>[];
  final setupVars = <String, ScriptVariable>{};
  final setupSigil = family == DbFamily.snowflake ? r'$' : '@';
  final out = <PreparedUnit>[];

  ScriptVariable? valueOf(VarRef r) {
    final v = panel[r.key];
    if (v == null || !v.hasValue) {
      if (!missing.contains(r.key)) missing.add(r.key);
      return null;
    }
    if (v.error != null) {
      if (!invalid.contains(r.key)) invalid.add(r.key);
      return null;
    }
    if (!used.contains(r.display)) used.add(r.display);
    return v;
  }

  for (final u in units) {
    final text = textOf(u);
    if (syntax == null) {
      out.add(PreparedUnit(sql: text, params: const []));
      continue;
    }
    final scan = scanVariables(text, family);
    final declaredHere = scan.declared;

    // SQL Server, a statement run alone: the declarations of the batch that
    // precede it come along.
    var carry = '';
    final carriedNames = <String>{};
    if (family == DbFamily.sqlServer) {
      final need = {for (final r in scan.refs) if (r.sigil == '@' && !declaredHere.contains(r.key)) r.key}
        ..removeWhere((k) => !declaredInScript.contains(k));
      if (need.isNotEmpty) {
        final at = base + u.start;
        final batch = scriptUnits.where((b) => b.start <= at && at <= b.end).firstOrNull;
        if (batch != null) {
          final before = scriptScan.decls.where((d) => d.start >= batch.start && d.end <= at).toList();
          // Declarations whose variables are needed, with what they need.
          final pick = <VarDecl>{};
          var grow = true;
          while (grow) {
            grow = false;
            for (final d in before) {
              if (pick.contains(d) || !need.contains(d.key)) continue;
              pick.add(d);
              carriedNames.add(d.key);
              for (final r in scanVariables(d.init ?? '', family).refs) {
                if (r.sigil == '@' && need.add(r.key)) grow = true;
              }
            }
          }
          final stmts = <int, String>{};
          for (final d in pick) {
            stmts.putIfAbsent(d.start, () => _oneLine(script.substring(d.start, d.end)));
          }
          final ordered = stmts.keys.toList()..sort();
          if (ordered.isNotEmpty) {
            carry = '${ordered.map((k) => stmts[k]!).join('; ')}; ';
            carried.addAll(pick.map((d) => d.display).where((n) => !carried.contains(n)));
          }
        }
      }
    }

    final sb = StringBuffer();
    final params = <Object?>[];
    final positional = <int>[];
    final declare = <String, ScriptVariable>{};
    var last = 0;
    // References in text order, `?` markers among them.
    final marks = [
      for (final r in scan.refs) (r.start, r),
      for (final p in scan.positional) (p, null),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (pos, r) in marks) {
      if (r == null) {
        positional.add(params.length);
        params.add(null);
        continue;
      }
      if (declaredHere.contains(r.key) || carriedNames.contains(r.key)) continue;
      final session = (r.sigil == '@' && (family == DbFamily.sqlServer || family == DbFamily.mysql)) ||
          (r.sigil == r'$' && family == DbFamily.snowflake);
      if (session && declaredInScript.contains(r.key)) continue; // the script's own
      final v = valueOf(r);
      if (v == null) continue;
      if (r.sigil == '@' && family == DbFamily.sqlServer) {
        declare[r.key] = v;
      } else if (session) {
        setupVars[r.key] = v;
      } else if (family == DbFamily.sqlServer) {
        sb
          ..write(text.substring(last, pos))
          ..write(variableLiteral(v, dialect));
        last = r.end;
      } else {
        sb
          ..write(text.substring(last, pos))
          ..write('?');
        params.add(v.bindValue(odbc: odbc));
        last = r.end;
      }
    }
    sb.write(text.substring(last));
    var sql = sb.toString();
    if (declare.isNotEmpty) {
      final names = {for (final r in scan.refs) if (declare.containsKey(r.key)) r.key: r.display};
      final items = [
        for (final e in declare.entries) '${names[e.key]} ${tsqlTypeOf(e.value)} = ${variableLiteral(e.value, dialect)}',
      ];
      // On the first line: line numbers of the batch stay those of the script.
      sql = 'DECLARE ${items.join(', ')}; $carry$sql';
    } else if (carry.isNotEmpty) {
      sql = '$carry$sql';
    }
    out.add(PreparedUnit(sql: sql, params: params, positional: positional));
  }

  final setup = <String>[];
  if (setupVars.isNotEmpty) {
    if (family == DbFamily.snowflake) {
      for (final v in setupVars.values) {
        setup.add('SET ${v.name} = ${variableLiteral(v, dialect)}');
      }
    } else {
      setup.add('SET ${setupVars.values.map((v) => '$setupSigil${v.name} = ${variableLiteral(v, dialect)}').join(', ')}');
    }
  }
  return VariablePlan(units: out, setup: setup, missing: missing, invalid: invalid, carried: carried, used: used);
}

/// [sql] on one line, comments dropped (carried declarations).
String _oneLine(String sql) => sql
    .replaceAll(RegExp(r'--[^\n]*'), ' ')
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceFirst(RegExp(r';$'), '');

// ---------------------------------------------------------------------------
// The panel's view of a script
// ---------------------------------------------------------------------------

/// A row of the Variabili panel.
class VariableInfo {
  VariableInfo({required this.key, required this.display, this.panel, this.decl, this.refs = const []});

  final String key;

  /// Name with the sigil, as written in the script (`@da`).
  final String display;

  /// The value kept in the panel (null: never given).
  final ScriptVariable? panel;

  /// First declaration in the script: the script's value wins.
  final VarDecl? decl;

  /// References in the script.
  final List<VarRef> refs;

  bool get inScript => decl != null;
  bool get used => refs.isNotEmpty;

  /// Referenced, not declared and without a usable value.
  bool get needsValue => used && !inScript && !(panel?.isUsable ?? false);
}

/// The rows of the panel: the variables of [scan] and the [variables] kept
/// in the panel (unused ones too), in order of first appearance.
List<VariableInfo> buildVariableRows(VariableScan scan, List<ScriptVariable> variables, VarSyntax syntax) {
  final order = <String>[];
  final display = <String, String>{};
  final refs = <String, List<VarRef>>{};
  final decl = <String, VarDecl>{};
  final events = [
    for (final r in scan.refs) (r.start, r.key, r.display),
    for (final d in scan.decls) (d.nameStart, d.key, d.display),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  for (final (_, k, d) in events) {
    if (!display.containsKey(k)) {
      order.add(k);
      display[k] = d;
    }
  }
  for (final r in scan.refs) {
    (refs[r.key] ??= []).add(r);
  }
  for (final d in scan.decls) {
    decl.putIfAbsent(d.key, () => d);
  }
  final panel = {for (final v in variables) v.key: v};
  for (final v in variables) {
    if (!display.containsKey(v.key)) {
      order.add(v.key);
      display[v.key] = '${syntax.sigil}${v.name}';
    }
  }
  return [
    for (final k in order)
      VariableInfo(key: k, display: display[k]!, panel: panel[k], decl: decl[k], refs: refs[k] ?? const []),
  ];
}
