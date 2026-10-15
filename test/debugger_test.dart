import 'package:dbcraft/features/debugger/pg_debug_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pg_get_function_arguments parser', () {
    test('modes, names, multi-word types and defaults', () {
      final a = parseFunctionArguments(
        "p_id integer, INOUT p_name character varying(20) DEFAULT 'a, b'::character varying, "
        'OUT total numeric(10,2), VARIADIC vals integer[], ts timestamp with time zone DEFAULT now()',
      );
      expect(a.map((e) => e.name), ['p_id', 'p_name', 'total', 'vals', 'ts']);
      expect(a.map((e) => e.mode), ['i', 'b', 'o', 'v', 'i']);
      expect(a[1].type, 'character varying(20)');
      expect(a[1].defaultExpr, "'a, b'::character varying");
      expect(a[2].type, 'numeric(10,2)');
      expect(a[3].type, 'integer[]');
      expect(a[4].type, 'timestamp with time zone');
      expect(a[4].defaultExpr, 'now()');
      expect(a.where((e) => e.isInput).length, 4);
    });

    test('unnamed arguments and quoted names', () {
      final a = parseFunctionArguments('integer, double precision, "My Arg" text, character varying');
      expect(a.map((e) => e.name), ['', '', 'My Arg', '']);
      expect(a.map((e) => e.type), ['integer', 'double precision', 'text', 'character varying']);
      expect(parseFunctionArguments(''), isEmpty);
    });

    test('merge with catalog rows keeps TABLE columns aside', () {
      final catalog = [
        PgArg(name: 'a', type: 'integer'),
        PgArg(name: 'b', type: 'text'),
        PgArg(name: 'r', type: 'bigint', mode: 't'),
      ];
      final merged = mergeArgs(catalog, parseFunctionArguments("a integer, b text DEFAULT 'x'::text"));
      expect(merged[1].defaultExpr, "'x'::text");
      expect(merged[2].hasDefault, isFalse);
    });

    test('splitTopLevel and arrays', () {
      expect(splitTopLevel("a(1,2), 'x,y', \"q,\"\"r\""), ['a(1,2)', "'x,y'", '"q,""r"']);
      expect(parsePgArray('{a,b,NULL}'), ['a', 'b', null]);
      expect(parsePgArray('{"x y","z\\"w"}'), ['x y', 'z"w']);
      expect(parsePgArray('{}'), isEmpty);
    });
  });

  group('call builder', () {
    final args = [
      PgArg(name: 'p_id', type: 'integer'),
      PgArg(name: 'p_name', type: 'text', defaultExpr: "'x'::text"),
      PgArg(name: 'p_flag', type: 'boolean', defaultExpr: 'false'),
      PgArg(name: 'total', type: 'numeric', mode: 'o'),
    ];

    test('function with literals and casts', () {
      final sql = buildPgCall(
        qualifiedName: 'public.f',
        args: args,
        values: [
          PgArgValue(text: '5'),
          PgArgValue(text: "O'Brien"),
          PgArgValue(isNull: true),
          PgArgValue(),
        ],
        isProcedure: false,
      );
      expect(sql, "SELECT * FROM public.f('5'::integer, 'O''Brien'::text, NULL::boolean)");
    });

    test('skipped default switches to named notation; trailing defaults omitted', () {
      final sql = buildPgCall(
        qualifiedName: 'public.f',
        args: args,
        values: [
          PgArgValue(text: '1'),
          PgArgValue(useDefault: true),
          PgArgValue(text: 'true'),
          PgArgValue(),
        ],
        isProcedure: false,
      );
      expect(sql, "SELECT * FROM public.f('1'::integer, p_flag => 'true'::boolean)");
      final trailing = buildPgCall(
        qualifiedName: 'public.f',
        args: args,
        values: [
          PgArgValue(text: '1'),
          PgArgValue(useDefault: true),
          PgArgValue(useDefault: true),
          PgArgValue(),
        ],
        isProcedure: false,
      );
      expect(trailing, "SELECT * FROM public.f('1'::integer)");
    });

    test('procedures receive NULL for OUT arguments; expressions and variadic', () {
      final sql = buildPgCall(
        qualifiedName: 's."Proc"',
        args: [
          PgArg(name: 'd', type: 'date'),
          PgArg(name: 'res', type: 'integer', mode: 'o'),
          PgArg(name: 'v', type: 'integer[]', mode: 'v'),
        ],
        values: [
          PgArgValue(text: 'current_date', expression: true),
          PgArgValue(),
          PgArgValue(text: '{1,2}'),
        ],
        isProcedure: true,
      );
      expect(sql, "CALL s.\"Proc\"(current_date, NULL::integer, VARIADIC '{1,2}'::integer[])");
    });

    test('unnamed argument after a default is rejected', () {
      expect(
        () => buildPgCall(
          qualifiedName: 'f',
          args: [
            PgArg(name: '', type: 'int', defaultExpr: '1'),
            PgArg(name: '', type: 'int'),
          ],
          values: [
            PgArgValue(useDefault: true),
            PgArgValue(text: '2'),
          ],
          isProcedure: false,
        ),
        throwsArgumentError,
      );
    });

    test('backslashes use an escape string', () {
      expect(pgArgLiteral(PgArg(name: 'p', type: 'text'), PgArgValue(text: r'a\b')), r"E'a\\b'::text");
    });
  });

  group('protocol rows', () {
    test('breakpoint row, NULL composite and text composite', () {
      expect(
        parseBreakpointRow(
          ['func', 'linenumber', 'targetname'],
          [
            [16384, '12', 'f'],
          ],
        ),
        const PgBreakpoint(16384, 12, 'f'),
      );
      expect(
        parseBreakpointRow(
          ['func', 'linenumber', 'targetname'],
          [
            [null, null, null],
          ],
        ),
        isNull,
      );
      expect(parseBreakpointRow(['func'], const []), isNull);
      final t = parseBreakpointRow(
        ['pldbg_step_over'],
        [
          ['(16384,7,"f")'],
        ],
      );
      expect(t?.line, 7);
      expect(t?.target, 'f');
    });

    test('stack and variables', () {
      final s = parseStackRows(
        ['level', 'targetname', 'func', 'linenumber', 'args'],
        [
          [0, 'f(integer)', 100, 4, 'p_id=5'],
          [1, 'g()', 101, 9, ''],
        ],
      );
      expect(s.map((f) => f.func), [100, 101]);
      expect(s.first.args, 'p_id=5');
      final v = parseVariableRows(
        ['name', 'varclass', 'linenumber', 'isunique', 'isconst', 'isnotnull', 'dtype', 'typname', 'value'],
        [
          ['p_id', 'A', 0, 't', 'f', 'f', 23, 'integer', '5'],
          ['x', 'L', 6, '0', '1', '0', 25, 'text', null],
        ],
      );
      expect(v.first.isUnique, isTrue);
      expect(v.first.depositLine, -1);
      expect(v.first.type, 'integer');
      expect(v.last.isConst, isTrue);
      expect(v.last.depositLine, 6);
      expect(v.last.value, isNull);
      expect(v.last.classLabel, 'locale');
    });

    test('value helpers', () {
      expect(asInt('42'), 42);
      expect(asInt(3.0), 3);
      expect(asInt(null), isNull);
      expect(asBool('t'), isTrue);
      expect(asBool('0'), isFalse);
      expect(asBool(1), isTrue);
    });
  });

  group('state machine', () {
    test('normal session', () {
      final m = DebugStateMachine();
      expect(m.canStart, isTrue);
      expect(m.canRestart, isFalse);
      m.start();
      expect(m.isActive, isTrue);
      expect(m.canStep, isFalse);
      m.listening();
      expect(m.phase, DebugPhase.waitingTarget);
      m.attached();
      m.hit();
      expect(m.canStep, isTrue);
      expect(m.canEditServerBreakpoints, isTrue);
      m.step();
      expect(m.phase, DebugPhase.running);
      expect(m.canStep, isFalse);
      m.hit();
      m.finish();
      expect(m.phase, DebugPhase.finished);
      expect(m.canStart, isTrue);
      expect(m.canRestart, isTrue);
      expect(m.canStop, isFalse);
    });

    test('invalid transitions throw', () {
      final m = DebugStateMachine();
      expect(m.step, throwsStateError);
      expect(m.attached, throwsStateError);
      m.start();
      expect(m.start, throwsStateError);
      m.fail();
      expect(m.phase, DebugPhase.failed);
      expect(m.canStart, isTrue);
      m.start();
      expect(m.phase, DebugPhase.starting);
    });
  });
}
