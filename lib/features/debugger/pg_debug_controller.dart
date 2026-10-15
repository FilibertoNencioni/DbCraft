// PostgreSQL debugger driven through the pldbgapi extension (pldebugger).
//
// Two extra sessions are used: the proxy session talks to the debugger
// (pldbg_* functions) and the target session runs the function call, which
// blocks until debugging ends. Every session runs in its own isolate, so the
// blocking calls on one never stop the other.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../drivers/db_session.dart';
import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../state/db_connection.dart';
import 'pg_debug_logic.dart';

/// Result of the pldbgapi availability check.
class PgDebuggerAvailability {
  const PgDebuggerAvailability({required this.available, this.version, this.preloadOk, this.superuser, this.error});
  final bool available;
  final String? version;

  /// shared_preload_libraries contains plugin_debugger (null = unknown).
  final bool? preloadOk;
  final bool? superuser;
  final String? error;
}

/// A pg_proc entry matching a DbProcedure.
class PgFunctionCandidate {
  const PgFunctionCandidate(this.oid, this.schema, this.name, this.identityArgs, this.kind, this.language);
  final int oid;
  final String schema;
  final String name;
  final String identityArgs;

  /// prokind: f function, p procedure, a aggregate, w window.
  final String kind;
  final String language;

  String get signature => '$schema.$name($identityArgs)';
}

/// Everything needed to call and display the debugged function.
class PgFunctionInfo {
  PgFunctionInfo({
    required this.oid,
    required this.schema,
    required this.name,
    required this.kind,
    required this.language,
    required this.returnType,
    required this.returnsSet,
    required this.args,
    required this.identityArgs,
    required this.source,
  });
  final int oid;
  final String schema;
  final String name;
  final String kind;
  final String language;
  final String returnType;
  final bool returnsSet;
  final List<PgArg> args;
  final String identityArgs;
  final String source;

  bool get isProcedure => kind == 'p';
  bool get isTrigger => returnType == 'trigger' || returnType == 'event_trigger';
  String get signature => '$schema.$name($identityArgs)';
}

class DebugMessage {
  DebugMessage(this.text, {this.error = false});
  final DateTime time = DateTime.now();
  final String text;
  final bool error;
}

/// Options chosen in the parameters dialog.
class PgDebugStart {
  PgDebugStart({required this.values, this.rollback = false, this.indirect = false});
  final List<PgArgValue> values;

  /// Run the target in a transaction rolled back at the end.
  final bool rollback;

  /// Do not run the call: wait for any session to call the function.
  final bool indirect;
}

class _TargetFinished implements Exception {}

String _msg(Object e) =>
    e is OdbcException ? e.message : e.toString().replaceFirst(RegExp(r'^(Bad state|Exception): '), '');

Future<ResultPage> _q(DbSession s, String sql, {int fetchSize = 1000}) async {
  final p = await s.execute(sql, fetchSize: fetchSize);
  if (p.cursorId != null) {
    try {
      await s.closeCursor(p.cursorId!);
    } catch (_) {}
  }
  return p;
}

List<String> _cols(ResultPage p) => p.columns.map((e) => e.name).toList();

String _lit(String s) => "'${s.replaceAll("'", "''")}'";

// ---------------------------------------------------------------------------
// Catalog helpers
// ---------------------------------------------------------------------------

Future<PgDebuggerAvailability> checkPgDebugger(DbSession s) async {
  try {
    final ext = await _q(s, "SELECT extname, extversion FROM pg_extension WHERE extname = 'pldbgapi'");
    final fn = await _q(s, "SELECT 1 FROM pg_proc WHERE proname IN ('pldbg_create_listener', 'pldbg_oid_debug')");
    final version = ext.rows.isEmpty ? null : ext.rows.first[1]?.toString();
    bool? preload;
    try {
      final r = await _q(s, "SELECT current_setting('shared_preload_libraries')");
      preload = (r.rows.firstOrNull?.firstOrNull?.toString() ?? '').contains('plugin_debugger');
    } catch (_) {}
    bool? su;
    try {
      final r = await _q(s, 'SELECT rolsuper FROM pg_roles WHERE rolname = current_user');
      su = asBool(r.rows.firstOrNull?.firstOrNull);
    } catch (_) {}
    return PgDebuggerAvailability(available: fn.rows.isNotEmpty, version: version, preloadOk: preload, superuser: su);
  } catch (e) {
    return PgDebuggerAvailability(available: false, error: _msg(e));
  }
}

/// pg_proc entries matching [p] (catalog / schema / name; the name may carry
/// overload information such as `f;1` or `f(integer, text)`).
Future<List<PgFunctionCandidate>> findPgFunctions(DbSession s, DbProcedure p) async {
  var name = p.name;
  final semi = name.lastIndexOf(';');
  if (semi > 0 && int.tryParse(name.substring(semi + 1)) != null) name = name.substring(0, semi);
  final schema = p.schema ?? '';
  String? exactOid;
  final paren = name.indexOf('(');
  if (paren > 0 && name.endsWith(')')) {
    final qn = schema.isEmpty ? name : '${_ident(schema)}.${_ident(name.substring(0, paren))}${name.substring(paren)}';
    try {
      final r = await _q(s, 'SELECT to_regprocedure(${_lit(qn)})::oid');
      final oid = asInt(r.rows.firstOrNull?.firstOrNull);
      if (oid != null && oid != 0) exactOid = '$oid';
    } catch (_) {}
    name = name.substring(0, paren);
  }
  final where = exactOid != null
      ? 'p.oid = $exactOid'
      : 'p.proname = ${_lit(name)}${schema.isEmpty ? '' : ' AND n.nspname = ${_lit(schema)}'}';
  String sql(String kind) =>
      'SELECT p.oid, n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), $kind, l.lanname '
      'FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang '
      'WHERE $where ORDER BY 4';
  ResultPage r;
  try {
    r = await _q(s, sql('p.prokind::text'));
  } catch (_) {
    // PostgreSQL < 11: no prokind.
    r = await _q(s, sql("CASE WHEN p.proisagg THEN 'a' ELSE 'f' END"));
  }
  return [
    for (final row in r.rows)
      PgFunctionCandidate(
        asInt(row[0]) ?? 0,
        row[1]?.toString() ?? '',
        row[2]?.toString() ?? '',
        row[3]?.toString() ?? '',
        row[4]?.toString() ?? 'f',
        row[5]?.toString() ?? '',
      ),
  ];
}

String _ident(String n) => RegExp(r'^[a-z_][a-z0-9_$]*$').hasMatch(n) ? n : '"${n.replaceAll('"', '""')}"';

Future<PgFunctionInfo> loadPgFunction(DbSession s, int oid) async {
  String sql(String kind) =>
      'SELECT n.nspname, p.proname, $kind, l.lanname, format_type(p.prorettype, NULL), p.proretset, '
      'pg_get_function_arguments(p.oid), pg_get_function_identity_arguments(p.oid), p.prosrc '
      'FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang '
      'WHERE p.oid = $oid';
  ResultPage r;
  try {
    r = await _q(s, sql('p.prokind::text'));
  } catch (_) {
    r = await _q(s, sql("'f'"));
  }
  if (r.rows.isEmpty) throw StateError('Funzione con OID $oid non trovata');
  final row = r.rows.first;
  final parsed = parseFunctionArguments(row[6]?.toString() ?? '');
  var catalog = <PgArg>[];
  try {
    final a = await _q(
      s,
      'SELECT a.ord, format_type(a.typ, NULL), COALESCE(p.proargnames[a.ord], \'\'), '
      'COALESCE(p.proargmodes[a.ord]::text, \'i\') '
      'FROM pg_proc p, unnest(COALESCE(p.proallargtypes, p.proargtypes::oid[])) WITH ORDINALITY AS a(typ, ord) '
      'WHERE p.oid = $oid ORDER BY a.ord',
    );
    catalog = [
      for (final x in a.rows)
        PgArg(name: x[2]?.toString() ?? '', type: x[1]?.toString() ?? 'text', mode: x[3]?.toString() ?? 'i'),
    ];
  } catch (_) {}
  return PgFunctionInfo(
    oid: oid,
    schema: row[0]?.toString() ?? '',
    name: row[1]?.toString() ?? '',
    kind: row[2]?.toString() ?? 'f',
    language: row[3]?.toString() ?? '',
    returnType: row[4]?.toString() ?? '',
    returnsSet: asBool(row[5]),
    args: mergeArgs(catalog, parsed),
    identityArgs: row[7]?.toString() ?? '',
    source: row[8]?.toString() ?? '',
  );
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

class PgDebugController extends ChangeNotifier {
  PgDebugController(this.dc, this.procedure);

  final DbConnection dc;
  final DbProcedure procedure;
  final DebugStateMachine sm = DebugStateMachine();

  // Preparation
  bool preparing = false;
  String? prepareError;
  PgDebuggerAvailability? availability;
  List<PgFunctionCandidate> candidates = const [];
  PgFunctionInfo? info;

  // Session
  DbSession? _proxy;
  DbSession? _target;
  int? _sid;
  int? targetPid;
  Completer<void>? _targetDone;
  Future<Object?>? _proxyCall;
  PgDebugStart? lastStart;
  String? callSql;
  bool _stopping = false;
  bool _disposed = false;

  // Debug state
  PgBreakpoint? current;
  int selectedFrame = 0;
  int? displayFunc;
  final Map<int, String> sources = {};
  final Map<int, String> funcNames = {};
  List<PgFrame> stack = const [];
  List<PgVariable> variables = const [];
  List<PgBreakpoint> serverBreakpoints = const [];

  /// Line breakpoints chosen while not paused (applied on attach).
  final Set<PgBreakpoint> pending = {};
  final List<DebugMessage> messages = [];

  // Target result
  ResultPage? result;
  String? resultError;

  DebugPhase get phase => sm.phase;
  bool get busy => _proxy?.isBusy ?? false;

  String get status => switch (sm.phase) {
    DebugPhase.idle => 'Pronto',
    DebugPhase.starting => 'Avvio…',
    DebugPhase.waitingTarget =>
      lastStart?.indirect ?? false ? 'In attesa di una chiamata da un\'altra sessione…' : 'In attesa del target…',
    DebugPhase.running => 'In esecuzione…',
    DebugPhase.paused => 'Fermo alla riga ${current?.line ?? '?'}${_frameLabel()}',
    DebugPhase.finished => 'Terminato',
    DebugPhase.failed => 'Errore',
  };

  String _frameLabel() {
    final f = current?.func;
    if (f == null || f == info?.oid) return '';
    return ' di ${funcNames[f] ?? f}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void log(String text, {bool error = false}) {
    messages.add(DebugMessage(text, error: error));
    if (messages.length > 1000) messages.removeRange(0, messages.length - 1000);
    _notify();
  }

  /// Checks the extension and resolves the function (picker callback when
  /// the name is overloaded).
  Future<void> prepare({required Future<PgFunctionCandidate?> Function(List<PgFunctionCandidate>) pick}) async {
    if (preparing) return;
    preparing = true;
    prepareError = null;
    _notify();
    DbSession? s;
    try {
      s = await dc.openSession(readOnly: true);
      availability = await checkPgDebugger(s);
      candidates = await findPgFunctions(s, procedure);
      if (candidates.isEmpty) throw StateError('Funzione "${procedure.cleanName}" non trovata in pg_proc');
      final c = candidates.length == 1 ? candidates.first : await pick(candidates);
      if (c == null) throw StateError('Nessuna funzione selezionata');
      info = await loadPgFunction(s, c.oid);
      sources[c.oid] = info!.source;
      funcNames[c.oid] = '${c.schema}.${c.name}';
      displayFunc = c.oid;
    } catch (e) {
      prepareError = _msg(e);
    } finally {
      preparing = false;
      await s?.close();
      _notify();
    }
  }

  String qualifiedName(PgFunctionInfo f) => '${_ident(f.schema)}.${_ident(f.name)}';

  String buildCall(PgFunctionInfo f, List<PgArgValue> values) =>
      buildPgCall(qualifiedName: qualifiedName(f), args: f.args, values: values, isProcedure: f.isProcedure);

  /// Waits for [call] on the proxy, unless the target statement completes
  /// first ([_TargetFinished]).
  Future<T> _race<T>(Future<T> call) async {
    _proxyCall = call;
    final done = _targetDone;
    try {
      if (done == null) return await call;
      final r = await Future.any<Object?>([call, done.future.then((_) => _TargetFinished())]);
      if (r is _TargetFinished) throw r;
      return r as T;
    } catch (e) {
      if (e is _TargetFinished) rethrow;
      // A proxy error right when the target ends is the end of debugging.
      if (done != null) {
        try {
          await done.future.timeout(const Duration(seconds: 3));
          throw _TargetFinished();
        } on TimeoutException {
          // fall through
        }
      }
      rethrow;
    } finally {
      _proxyCall = null;
    }
  }

  Future<ResultPage> _proxyQuery(String sql) => _race(_q(_proxy!, sql));

  Future<void> start(PgDebugStart opts) async {
    final f = info;
    if (f == null || !sm.canStart) return;
    lastStart = opts;
    sm.start();
    _stopping = false;
    current = null;
    stack = const [];
    variables = const [];
    serverBreakpoints = const [];
    result = null;
    resultError = null;
    selectedFrame = 0;
    targetPid = null;
    _sid = null;
    displayFunc = f.oid;
    messages.clear();
    _notify();
    try {
      callSql = opts.indirect ? null : buildCall(f, opts.values);
      _proxy = await dc.openSession();
      int? pid;
      if (!opts.indirect) {
        _target = await dc.openSession();
        pid = asInt((await _q(_target!, 'SELECT pg_backend_pid()')).rows.first.first);
        if (opts.rollback) await _target!.setAutoCommit(false);
      }
      final sid = asInt((await _q(_proxy!, 'SELECT pldbg_create_listener()')).rows.first.first);
      if (sid == null) throw StateError('pldbg_create_listener non ha restituito una sessione');
      _sid = sid;
      await _q(_proxy!, 'SELECT pldbg_set_global_breakpoint($sid, ${f.oid}, -1, ${pid ?? 'NULL'})');
      sm.listening();
      log(
        opts.indirect
            ? 'Breakpoint globale impostato su ${f.signature}: in attesa di una chiamata da qualsiasi sessione.'
            : 'Esecuzione: $callSql',
      );
      if (!opts.indirect) _runTarget(callSql!);

      final attached = await _proxyQuery('SELECT pldbg_wait_for_target($sid)');
      targetPid = asInt(attached.rows.firstOrNull?.firstOrNull);
      sm.attached();
      log('Target collegato (PID ${targetPid ?? '?'}).');
      _notify();
      final bp = await _proxyQuery('SELECT * FROM pldbg_wait_for_breakpoint($sid)');
      await _onBreakpoint(parseBreakpointRow(_cols(bp), bp.rows), firstStop: true);
    } on _TargetFinished {
      await _onTargetFinished(early: sm.phase == DebugPhase.waitingTarget);
    } catch (e) {
      await _fail(e);
    }
  }

  void _runTarget(String sql) {
    final done = _targetDone = Completer<void>();
    final t = _target!;
    t
        .execute(sql, fetchSize: 1000)
        .then(
          (page) async {
            result = page;
            if (page.messages.isNotEmpty) {
              for (final m in page.messages) {
                log(m);
              }
            }
            if (page.cursorId != null) {
              try {
                await t.closeCursor(page.cursorId!);
              } catch (_) {}
            }
          },
          onError: (Object e) {
            resultError = _msg(e);
          },
        )
        .whenComplete(() {
          if (!done.isCompleted) done.complete();
          _notify();
        });
  }

  Future<void> _onBreakpoint(PgBreakpoint? bp, {bool firstStop = false}) async {
    if (bp == null) {
      await _onTargetFinished();
      return;
    }
    current = bp;
    selectedFrame = 0;
    displayFunc = bp.func;
    sm.hit();
    if (firstStop && pending.isNotEmpty) {
      for (final b in pending) {
        try {
          await _q(_proxy!, 'SELECT pldbg_set_breakpoint($_sid, ${b.func}, ${b.line})');
        } catch (e) {
          log('Breakpoint alla riga ${b.line} non impostato: ${_msg(e)}', error: true);
        }
      }
    }
    await _refreshPaused();
  }

  Future<void> _refreshPaused() async {
    final p = _proxy!, sid = _sid!;
    try {
      final st = await _q(p, 'SELECT * FROM pldbg_get_stack($sid)');
      stack = parseStackRows(_cols(st), st.rows)..sort((a, b) => a.level.compareTo(b.level));
      for (final f in stack) {
        funcNames.putIfAbsent(f.func, () => f.target);
      }
    } catch (e) {
      log('Stack non disponibile: ${_msg(e)}', error: true);
    }
    await _loadVariables();
    await _loadBreakpoints();
    await _ensureSource(displayFunc);
    _notify();
  }

  Future<void> _loadVariables() async {
    final p = _proxy!, sid = _sid!;
    try {
      ResultPage v;
      try {
        v = await _q(
          p,
          'SELECT name, varclass, linenumber, isunique, isconst, isnotnull, dtype, '
          'format_type(dtype, NULL) AS typname, value FROM pldbg_get_variables($sid)',
        );
      } catch (_) {
        v = await _q(p, 'SELECT * FROM pldbg_get_variables($sid)');
      }
      variables = parseVariableRows(_cols(v), v.rows);
    } catch (e) {
      variables = const [];
      log('Variabili non disponibili: ${_msg(e)}', error: true);
    }
  }

  Future<void> _loadBreakpoints() async {
    try {
      final b = await _q(_proxy!, 'SELECT * FROM pldbg_get_breakpoints($_sid)');
      serverBreakpoints = [
        for (final r in b.rows) ?parseBreakpointRow(_cols(b), [r]),
      ];
    } catch (_) {}
  }

  Future<void> _ensureSource(int? func) async {
    if (func == null || sources.containsKey(func)) return;
    try {
      final s = await _q(_proxy!, 'SELECT pldbg_get_source($_sid, $func)');
      sources[func] = s.rows.firstOrNull?.firstOrNull?.toString() ?? '';
    } catch (e) {
      sources[func] = '';
      log('Sorgente non disponibile: ${_msg(e)}', error: true);
    }
  }

  Future<void> _step(String fn, String label) async {
    if (!sm.canStep || _sid == null) return;
    sm.step();
    _notify();
    try {
      final r = await _proxyQuery('SELECT * FROM $fn($_sid)');
      await _onBreakpoint(parseBreakpointRow(_cols(r), r.rows));
    } on _TargetFinished {
      await _onTargetFinished();
    } catch (e) {
      await _fail(e, context: label);
    }
  }

  Future<void> continueExecution() => _step('pldbg_continue', 'Continua');
  Future<void> stepInto() => _step('pldbg_step_into', 'Step into');
  Future<void> stepOver() => _step('pldbg_step_over', 'Step over');

  Future<void> selectFrame(int level) async {
    if (!sm.canStep || _sid == null) return;
    try {
      final r = await _q(_proxy!, 'SELECT * FROM pldbg_select_frame($_sid, $level)');
      final bp = parseBreakpointRow(_cols(r), r.rows);
      selectedFrame = level;
      if (bp != null) displayFunc = bp.func;
      await _loadVariables();
      await _ensureSource(displayFunc);
      _notify();
    } catch (e) {
      log('Selezione del frame non riuscita: ${_msg(e)}', error: true);
    }
  }

  /// Line of the selected frame (the highlighted line in the source).
  int? get displayLine {
    if (sm.phase != DebugPhase.paused && sm.phase != DebugPhase.running) return null;
    if (selectedFrame == 0) return current?.line;
    return stack.where((f) => f.level == selectedFrame).firstOrNull?.line;
  }

  Set<int> breakpointLines(int? func) {
    if (func == null) return const {};
    final list = sm.isActive && _sid != null && sm.phase != DebugPhase.waitingTarget
        ? serverBreakpoints
        : pending.toList();
    return {
      for (final b in list)
        if (b.func == func && b.line > 0) b.line,
    };
  }

  Future<void> toggleBreakpoint(int func, int line) async {
    final bp = PgBreakpoint(func, line);
    if (sm.canEditServerBreakpoints && _sid != null) {
      final exists = serverBreakpoints.contains(bp);
      try {
        await _q(
          _proxy!,
          exists
              ? 'SELECT pldbg_drop_breakpoint($_sid, $func, $line)'
              : 'SELECT pldbg_set_breakpoint($_sid, $func, $line)',
        );
        if (exists) {
          pending.remove(bp);
        } else {
          pending.add(bp);
        }
        await _loadBreakpoints();
      } catch (e) {
        log('Breakpoint alla riga $line: ${_msg(e)}', error: true);
      }
    } else if (sm.phase == DebugPhase.running) {
      return;
    } else if (!pending.remove(bp)) {
      pending.add(bp);
    }
    _notify();
  }

  Future<void> removeBreakpoint(PgBreakpoint bp) async {
    if (breakpointLines(bp.func).contains(bp.line)) await toggleBreakpoint(bp.func, bp.line);
  }

  /// Changes the value of a variable (pldbg_deposit_value).
  Future<void> deposit(PgVariable v, String value) async {
    if (!sm.canStep || _sid == null) return;
    final r = await _q(_proxy!, 'SELECT pldbg_deposit_value($_sid, ${_lit(v.name)}, ${v.depositLine}, ${_lit(value)})');
    final ok = r.rows.isEmpty || asBool(r.rows.first.first);
    if (!ok) throw StateError('Il debugger non ha accettato il valore per ${v.name}');
    log('${v.name} := $value');
    await _loadVariables();
    _notify();
  }

  Future<void> _onTargetFinished({bool early = false}) async {
    if (_stopping || sm.phase == DebugPhase.finished || sm.phase == DebugPhase.failed) return;
    // Let the target statement deliver its result.
    try {
      await _targetDone?.future.timeout(const Duration(seconds: 30));
    } catch (_) {}
    if (early && resultError == null) {
      log(
        'La funzione è terminata senza fermarsi al breakpoint: verifica che plugin_debugger sia in '
        'shared_preload_libraries e che la funzione sia scritta in PL/pgSQL.',
        error: true,
      );
    }
    if (resultError != null) {
      log('Errore del target: $resultError', error: true);
    } else if (result != null) {
      log(
        result!.isResultSet
            ? 'Terminato: ${result!.rows.length}${result!.hasMore ? '+' : ''} righe restituite.'
            : 'Terminato.',
      );
    } else {
      log('Terminato.');
    }
    sm.finish();
    current = null;
    await _cleanup();
    _notify();
  }

  Future<void> _fail(Object e, {String? context}) async {
    if (_stopping) return;
    log('${context == null ? '' : '$context: '}${_msg(e)}', error: true);
    final m = _msg(e).toLowerCase();
    if (m.contains('superuser')) {
      log('I breakpoint globali di pldebugger richiedono un utente superuser.', error: true);
    }
    sm.fail();
    current = null;
    await _cleanup();
    _notify();
  }

  /// Stops debugging: aborts the target and closes both sessions.
  Future<void> stop() async {
    if (!sm.canStop || _stopping) return;
    _stopping = true;
    log('Interruzione del debug…');
    await _cleanup(abort: true);
    sm.finish();
    current = null;
    _stopping = false;
    log('Debug interrotto.');
  }

  Future<void> restart() async {
    final opts = lastStart;
    if (opts == null) return;
    if (sm.isActive) await stop();
    await start(opts);
  }

  Future<void> _cleanup({bool abort = false}) async {
    final proxy = _proxy, target = _target, sid = _sid;
    final done = _targetDone;
    _proxy = null;
    _target = null;
    _sid = null;
    // Unblock a waiting proxy call (wait_for_target / wait_for_breakpoint).
    if (proxy != null && _proxyCall != null) {
      proxy.cancel();
      try {
        await _proxyCall!.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    final targetRunning = done != null && !done.isCompleted;
    if (proxy != null && sid != null && (abort || targetRunning) && targetPid != null) {
      try {
        await _q(proxy, 'SELECT * FROM pldbg_abort_target($sid)').timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    if (target != null && done != null && !done.isCompleted) {
      target.cancel();
      try {
        await done.future.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    if (target != null && (lastStart?.rollback ?? false)) {
      try {
        await target.rollback().timeout(const Duration(seconds: 5));
        log('Modifiche annullate (rollback).');
      } catch (_) {}
    }
    await Future.wait([if (proxy != null) proxy.close(), if (target != null) target.close()]);
    _targetDone = null;
  }

  @override
  void dispose() {
    _disposed = true;
    if (_proxy != null || _target != null) unawaited(_cleanup(abort: true));
    super.dispose();
  }
}
