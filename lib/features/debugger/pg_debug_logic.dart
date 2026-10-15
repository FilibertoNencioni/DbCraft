// Pure logic of the PostgreSQL (pldbgapi) debugger: argument parsing, call
// builder, protocol rows and the debugger state machine.

/// Argument of a PostgreSQL function / procedure.
class PgArg {
  PgArg({required this.name, required this.type, this.mode = 'i', this.defaultExpr});

  final String name;

  /// SQL type as printed by format_type (integer, character varying(20)…).
  final String type;

  /// proargmodes code: i IN, o OUT, b INOUT, v VARIADIC, t TABLE column.
  final String mode;

  /// DEFAULT expression (from pg_get_function_arguments).
  String? defaultExpr;

  bool get isInput => mode == 'i' || mode == 'b' || mode == 'v';
  bool get hasDefault => defaultExpr != null;

  String get modeLabel => switch (mode) {
    'o' => 'OUT',
    'b' => 'INOUT',
    'v' => 'VARIADIC',
    't' => 'TABLE',
    _ => 'IN',
  };

  @override
  String toString() => '$modeLabel ${name.isEmpty ? '' : '$name '}$type${hasDefault ? ' DEFAULT $defaultExpr' : ''}';
}

/// Splits [s] on top level [sep] (outside parentheses, brackets and quotes).
List<String> splitTopLevel(String s, [String sep = ',']) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quote != null) {
      if (ch == quote) {
        if (i + 1 < s.length && s[i + 1] == quote) {
          i++;
        } else {
          quote = null;
        }
      }
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
    } else if (ch == '(' || ch == '[') {
      depth++;
    } else if (ch == ')' || ch == ']') {
      depth--;
    } else if (ch == sep && depth == 0) {
      out.add(s.substring(start, i));
      start = i + 1;
    }
  }
  out.add(s.substring(start));
  return out.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}

/// Index of the first top level, case-insensitive occurrence of [word]
/// surrounded by spaces, or -1.
int _topLevelWord(String s, String word) {
  final lower = s.toLowerCase();
  final w = ' ${word.toLowerCase()} ';
  var depth = 0;
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quote != null) {
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
    } else if (ch == '(' || ch == '[') {
      depth++;
    } else if (ch == ')' || ch == ']') {
      depth--;
    } else if (depth == 0 && lower.startsWith(w, i)) {
      return i;
    }
  }
  return -1;
}

/// Types made of several words that must not be split into name + type.
final _multiWordType = RegExp(
  r'^(double precision|character varying(\(\d+\))?|character(\(\d+\))?|national character( varying)?(\(\d+\))?|'
  r'bit varying(\(\d+\))?|bit(\(\d+\))?|'
  r'time(stamp)?(\(\d+\))? with(out)? time zone|interval( \w+( to \w+)?)?(\(\d+\))?)(\[\])*$',
  caseSensitive: false,
);

/// Parses the output of `pg_get_function_arguments(oid)`, e.g.
/// `a integer, INOUT b text DEFAULT 'x'::text, OUT c numeric, VARIADIC d integer[]`.
List<PgArg> parseFunctionArguments(String s) {
  final out = <PgArg>[];
  for (var part in splitTopLevel(s)) {
    var mode = 'i';
    final m = RegExp(r'^(IN|OUT|INOUT|VARIADIC)\s+', caseSensitive: false).firstMatch(part);
    if (m != null) {
      mode = switch (m[1]!.toUpperCase()) {
        'OUT' => 'o',
        'INOUT' => 'b',
        'VARIADIC' => 'v',
        _ => 'i',
      };
      part = part.substring(m.end).trim();
    }
    String? def;
    var d = _topLevelWord(part, 'DEFAULT');
    var dLen = ' DEFAULT '.length;
    if (d < 0) {
      d = part.indexOf(' = ');
      dLen = 3;
    }
    if (d >= 0) {
      def = part.substring(d + dLen).trim();
      part = part.substring(0, d).trim();
    }
    var name = '';
    var type = part;
    if (part.startsWith('"')) {
      var i = 1;
      final b = StringBuffer();
      while (i < part.length) {
        if (part[i] == '"') {
          if (i + 1 < part.length && part[i + 1] == '"') {
            b.write('"');
            i += 2;
            continue;
          }
          break;
        }
        b.write(part[i]);
        i++;
      }
      name = b.toString();
      type = part.substring(i + 1).trim();
    } else {
      final sp = part.indexOf(' ');
      if (sp > 0 && !_multiWordType.hasMatch(part)) {
        name = part.substring(0, sp);
        type = part.substring(sp + 1).trim();
      }
    }
    out.add(PgArg(name: name, type: type, mode: mode, defaultExpr: def));
  }
  return out;
}

/// Parses a PostgreSQL array literal as returned in text form (`{a,"b c"}`).
List<String?> parsePgArray(Object? v) {
  if (v == null) return const [];
  if (v is List) return v.map((e) => e?.toString()).toList();
  var s = v.toString().trim();
  if (!s.startsWith('{') || !s.endsWith('}')) return [s];
  s = s.substring(1, s.length - 1);
  if (s.isEmpty) return const [];
  final out = <String?>[];
  var i = 0;
  while (i <= s.length) {
    if (i < s.length && s[i] == '"') {
      final b = StringBuffer();
      i++;
      while (i < s.length && s[i] != '"') {
        if (s[i] == '\\' && i + 1 < s.length) i++;
        b.write(s[i]);
        i++;
      }
      out.add(b.toString());
      i += 2; // closing quote + comma
    } else {
      final e = s.indexOf(',', i);
      final tok = s.substring(i, e < 0 ? s.length : e).trim();
      out.add(tok.toUpperCase() == 'NULL' ? null : tok);
      if (e < 0) break;
      i = e + 1;
    }
  }
  return out;
}

/// Merges the arguments read from the catalog (exact types and modes) with
/// the defaults parsed from pg_get_function_arguments (which omits TABLE
/// columns).
List<PgArg> mergeArgs(List<PgArg> catalog, List<PgArg> parsed) {
  if (catalog.isEmpty) return parsed;
  final visible = catalog.where((a) => a.mode != 't').toList();
  for (var i = 0; i < visible.length && i < parsed.length; i++) {
    visible[i].defaultExpr = parsed[i].defaultExpr;
  }
  return catalog;
}

/// Value typed by the user for an argument.
class PgArgValue {
  PgArgValue({this.text = '', this.isNull = false, this.useDefault = false, this.expression = false});
  String text;
  bool isNull;
  bool useDefault;

  /// [text] is a SQL expression used as is (e.g. `now()`, `ARRAY[1,2]`).
  bool expression;
}

String pgStringLiteral(String s) {
  final escaped = s.replaceAll("'", "''");
  // E'' literals would be needed for backslashes only with
  // standard_conforming_strings off; quote them conservatively.
  return s.contains(r'\') ? "E'${escaped.replaceAll(r'\', r'\\')}'" : "'$escaped'";
}

/// SQL literal of [v] cast to the type of [a].
String pgArgLiteral(PgArg a, PgArgValue v) {
  if (v.isNull) return 'NULL::${a.type}';
  if (v.expression) return v.text.trim().isEmpty ? 'NULL::${a.type}' : v.text.trim();
  return '${pgStringLiteral(v.text)}::${a.type}';
}

/// Builds the statement run by the target session:
/// `SELECT * FROM schema.func(…)` or `CALL schema.proc(…)`.
///
/// Arguments left to their default switch the following ones to named
/// notation (`name => value`). Procedures receive NULL for OUT arguments
/// (PostgreSQL 14+ requires them in CALL).
String buildPgCall({
  required String qualifiedName,
  required List<PgArg> args,
  required List<PgArgValue> values,
  required bool isProcedure,
}) {
  assert(values.length == args.length);
  final parts = <String>[];
  var named = false;
  final pending = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    final v = values[i];
    String? expr;
    if (a.isInput) {
      if (v.useDefault && a.hasDefault) {
        named = true;
        continue;
      }
      expr = pgArgLiteral(a, v);
      if (a.mode == 'v') expr = 'VARIADIC $expr';
    } else if (a.mode == 'o' && isProcedure) {
      expr = 'NULL::${a.type}';
    } else {
      continue;
    }
    if (named) {
      if (a.name.isEmpty) {
        throw ArgumentError(
          'L\'argomento ${i + 1} non ha nome: non è possibile usare il default degli argomenti precedenti',
        );
      }
      if (a.mode == 'v') {
        throw ArgumentError('Un argomento VARIADIC non può seguire un argomento lasciato al default');
      }
      pending.add('${_quoteName(a.name)} => $expr');
    } else {
      parts.add(expr);
    }
  }
  parts.addAll(pending);
  final call = '$qualifiedName(${parts.join(', ')})';
  return isProcedure ? 'CALL $call' : 'SELECT * FROM $call';
}

String _quoteName(String n) => RegExp(r'^[a-z_][a-z0-9_$]*$').hasMatch(n) ? n : '"${n.replaceAll('"', '""')}"';

// ---------------------------------------------------------------------------
// Protocol rows
// ---------------------------------------------------------------------------

int? asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.round();
  final s = v.toString().trim();
  return int.tryParse(s) ?? double.tryParse(s)?.round();
}

bool asBool(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v.toString().trim().toLowerCase();
  return s == 't' || s == 'true' || s == '1' || s == 'y' || s == 'yes';
}

/// Row of the `breakpoint` composite type (func, linenumber, targetname).
class PgBreakpoint {
  const PgBreakpoint(this.func, this.line, [this.target = '']);
  final int func;
  final int line;
  final String target;

  @override
  bool operator ==(Object other) => other is PgBreakpoint && other.func == func && other.line == line;

  @override
  int get hashCode => Object.hash(func, line);

  @override
  String toString() => '$target:$line';
}

int _col(List<String> columns, String name, int fallback) {
  final i = columns.indexWhere((c) => c.toLowerCase() == name);
  return i >= 0 ? i : fallback;
}

/// Parses the first row of a breakpoint result; null when the target has
/// finished (NULL composite: all columns null, or no row).
PgBreakpoint? parseBreakpointRow(List<String> columns, List<List<Object?>> rows) {
  if (rows.isEmpty) return null;
  final r = rows.first;
  if (r.length == 1 && columns.length == 1 && r.first is String) {
    // Composite returned as text: (func,line,"target").
    final s = (r.first as String).trim();
    if (!s.startsWith('(')) return null;
    final parts = splitTopLevel(s.substring(1, s.length - 1));
    if (parts.length < 2) return null;
    final f = asInt(parts[0]), l = asInt(parts[1]);
    if (f == null || l == null) return null;
    return PgBreakpoint(f, l, parts.length > 2 ? parts[2].replaceAll('"', '') : '');
  }
  final f = asInt(r[_col(columns, 'func', 0)]);
  final l = asInt(r[_col(columns, 'linenumber', 1)]);
  if (f == null || l == null) return null;
  final ti = _col(columns, 'targetname', 2);
  return PgBreakpoint(f, l, ti < r.length ? (r[ti]?.toString() ?? '') : '');
}

class PgFrame {
  const PgFrame(this.level, this.target, this.func, this.line, this.args);
  final int level;
  final String target;
  final int func;
  final int line;
  final String args;
}

List<PgFrame> parseStackRows(List<String> columns, List<List<Object?>> rows) => [
  for (final r in rows)
    PgFrame(
      asInt(r[_col(columns, 'level', 0)]) ?? 0,
      r[_col(columns, 'targetname', 1)]?.toString() ?? '',
      asInt(r[_col(columns, 'func', 2)]) ?? 0,
      asInt(r[_col(columns, 'linenumber', 3)]) ?? 0,
      r[_col(columns, 'args', 4)]?.toString() ?? '',
    ),
];

class PgVariable {
  const PgVariable({
    required this.name,
    required this.varClass,
    required this.line,
    required this.isUnique,
    required this.isConst,
    required this.isNotNull,
    required this.type,
    required this.value,
  });
  final String name;

  /// A argument, L local, P package / other.
  final String varClass;
  final int line;
  final bool isUnique;
  final bool isConst;
  final bool isNotNull;
  final String type;
  final String? value;

  String get classLabel => switch (varClass) {
    'A' => 'argomento',
    'L' => 'locale',
    'P' => 'package',
    _ => varClass,
  };

  /// Line number passed to pldbg_deposit_value (-1 when the name is unique).
  int get depositLine => isUnique ? -1 : line;
}

List<PgVariable> parseVariableRows(List<String> columns, List<List<Object?>> rows) {
  final iType = columns.indexWhere((c) => c.toLowerCase() == 'typname');
  return [
    for (final r in rows)
      PgVariable(
        name: r[_col(columns, 'name', 0)]?.toString() ?? '',
        varClass: r[_col(columns, 'varclass', 1)]?.toString() ?? '',
        line: asInt(r[_col(columns, 'linenumber', 2)]) ?? -1,
        isUnique: asBool(r[_col(columns, 'isunique', 3)]),
        isConst: asBool(r[_col(columns, 'isconst', 4)]),
        isNotNull: asBool(r[_col(columns, 'isnotnull', 5)]),
        type: iType >= 0 ? (r[iType]?.toString() ?? '') : (r[_col(columns, 'dtype', 6)]?.toString() ?? ''),
        value: r[_col(columns, 'value', 7)]?.toString(),
      ),
  ];
}

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

enum DebugPhase {
  /// Not started.
  idle,

  /// Opening the sessions and creating the listener.
  starting,

  /// Global breakpoint set, waiting for the target to call the function.
  waitingTarget,

  /// Target stopped at a breakpoint: stepping and inspection allowed.
  paused,

  /// A step / continue command is running.
  running,

  /// Target completed (or debugging stopped).
  finished,

  /// Debugging failed.
  failed,
}

/// Allowed transitions of a debugging session.
class DebugStateMachine {
  DebugPhase phase = DebugPhase.idle;

  bool get isActive =>
      phase == DebugPhase.starting ||
      phase == DebugPhase.waitingTarget ||
      phase == DebugPhase.paused ||
      phase == DebugPhase.running;

  bool get canStart => !isActive;
  bool get canStep => phase == DebugPhase.paused;
  bool get canStop => isActive;
  bool get canRestart => phase != DebugPhase.idle && phase != DebugPhase.starting;

  /// Server side breakpoints can be changed only while paused; otherwise the
  /// gutter edits the breakpoints applied at the next start.
  bool get canEditServerBreakpoints => phase == DebugPhase.paused;

  void _expect(Set<DebugPhase> from, String event) {
    if (!from.contains(phase)) throw StateError('Evento "$event" non valido nello stato ${phase.name}');
  }

  void start() {
    _expect({DebugPhase.idle, DebugPhase.finished, DebugPhase.failed}, 'start');
    phase = DebugPhase.starting;
  }

  void listening() {
    _expect({DebugPhase.starting}, 'listening');
    phase = DebugPhase.waitingTarget;
  }

  /// Target attached: waiting for the first breakpoint.
  void attached() {
    _expect({DebugPhase.waitingTarget}, 'attached');
    phase = DebugPhase.running;
  }

  void hit() {
    _expect({DebugPhase.running, DebugPhase.waitingTarget, DebugPhase.paused}, 'breakpoint');
    phase = DebugPhase.paused;
  }

  void step() {
    _expect({DebugPhase.paused}, 'step');
    phase = DebugPhase.running;
  }

  void finish() {
    if (phase == DebugPhase.idle) return;
    phase = DebugPhase.finished;
  }

  void fail() => phase = DebugPhase.failed;
}
