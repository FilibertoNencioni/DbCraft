// Phase 6: sequences, triggers, procedures and functions.

import 'package:dbcraft/features/design/catalog/code.dart';
import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/ddl/code_ddl.dart';
import 'package:dbcraft/features/design/ddl/object_ddl.dart';
import 'package:dbcraft/features/design/model/object_defs.dart';
import 'package:dbcraft/features/design/ui/code_editor.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Matcher note(String text) => allOf(hasLength(1), everyElement(allOf(startsWith('--'), contains(text))));

const seq = SequenceDef(
  schema: 'app',
  name: 'seq_ord',
  dataType: 'bigint',
  start: 100,
  increment: 5,
  minValue: 1,
  maxValue: 1000000,
  cycle: true,
  cache: 20,
);

const trg = TriggerDef(
  schema: 'app',
  table: 'orders',
  name: 'trg_o',
  events: {TriggerEvent.insert, TriggerEvent.update},
);

void main() {
  group('sequences', () {
    test('create', () {
      const opts = 'START WITH 100 INCREMENT BY 5 MINVALUE 1 MAXVALUE 1000000 CACHE 20 CYCLE';
      expectPerFamily((d) => ObjectDdl(d).createSequence(seq), {
        'pg': 'CREATE SEQUENCE app.seq_ord AS bigint $opts',
        'mssql': 'CREATE SEQUENCE app.seq_ord AS bigint $opts',
        'mysql': note('MySQL'),
        'mariadb': 'CREATE SEQUENCE app.seq_ord $opts',
        'oracle': 'CREATE SEQUENCE "app"."seq_ord" $opts',
        'db2': 'CREATE SEQUENCE "app"."seq_ord" AS bigint $opts',
        'sqlite': note('SQLite'),
        'firebird': 'CREATE SEQUENCE "app"."seq_ord" START WITH 100 INCREMENT BY 5',
        'snowflake': 'CREATE SEQUENCE "app"."seq_ord" START = 100 INCREMENT = 5',
      });
      expect(
        ObjectDdl(sqlDialects['pg']!).createSequence(seq.copyWith(ownedBy: 'app.orders.id')).single,
        endsWith('OWNED BY app.orders.id'),
      );
      expect(ObjectDdl(sqlDialects['oracle']!).createSequence(const SequenceDef(name: 's', cache: 1)), [
        'CREATE SEQUENCE "s" NOCACHE',
      ]);
    });

    test('alter only what changed, restart, rename', () {
      final to = seq.copyWith(increment: 10, cache: 1, cycle: false);
      expect(ObjectDdl(sqlDialects['pg']!).alterSequence(seq, to), [
        'ALTER SEQUENCE app.seq_ord INCREMENT BY 10 CACHE 1 NO CYCLE',
      ]);
      expect(ObjectDdl(sqlDialects['mssql']!).alterSequence(seq, to), [
        'ALTER SEQUENCE app.seq_ord INCREMENT BY 10 NO CACHE NO CYCLE',
      ]);
      expect(ObjectDdl(sqlDialects['snowflake']!).alterSequence(seq, to), [
        'ALTER SEQUENCE "app"."seq_ord" SET INCREMENT = 10',
      ]);
      expect(ObjectDdl(sqlDialects['pg']!).alterSequence(seq, seq), isEmpty);
      expect(ObjectDdl(sqlDialects['pg']!).restartSequence(seq, 500), ['ALTER SEQUENCE app.seq_ord RESTART WITH 500']);
      expect(ObjectDdl(sqlDialects['oracle']!).restartSequence(seq, 500), [
        'ALTER SEQUENCE "app"."seq_ord" RESTART START WITH 500',
      ]);
      expect(ObjectDdl(dialectAt('oracle', '12.2.0')).restartSequence(seq, 500), note('18c'));
      expect(ObjectDdl(sqlDialects['mssql']!).renameSequence(seq, 'n'), [
        "EXEC sp_rename N'app.seq_ord', N'n', N'OBJECT'",
      ]);
      expect(ObjectDdl(sqlDialects['mariadb']!).renameSequence(seq, 'n'), ['RENAME TABLE app.seq_ord TO app.n']);
    });

    test('catalog', () async {
      final s = ScriptedSession()
        ..on(
          'pg_sequences',
          Rows(
            ['name', 'type', 'start', 'inc', 'min', 'max', 'cycle', 'cache', 'cur_value'],
            [
              ['seq_ord', 'bigint', 100, 5, 1, 1000000, 't', 20, 115],
            ],
          ),
        );
      final list = await DesignCatalog.of(scriptedConnection(s))!.sequences(null, 'app');
      expect(list.single.name, 'seq_ord');
      expect(list.single.cycle, isTrue);
      expect(list.single.currentValue, 115);
      final ms = ScriptedSession()
        ..on(
          'sys.sequences',
          Rows(
            ['name', 'type', 'start', 'inc', 'min', 'max', 'cycle', 'cache', 'cur_value'],
            [
              ['s', 'bigint', 1, 1, 1, 9, 0, 1, 3],
            ],
          ),
        );
      final dc = scriptedConnection(ms, dbmsName: 'Microsoft SQL Server', dbmsVersion: '16.00.4135');
      expect((await DesignCatalog.of(dc)!.sequences('shop', 'dbo')).single.maxValue, 9);
      expect(ms.executed.single, contains('shop.sys.sequences'));
    });
  });

  group('code objects', () {
    test('sources become statements', () {
      final pg = CodeDdl(sqlDialects['pg']!);
      expect(
        pg.statementsOf(
          'CREATE FUNCTION f() RETURNS trigger AS \$\$ BEGIN RETURN NEW; END; \$\$ LANGUAGE plpgsql;\n\nCREATE TRIGGER t BEFORE INSERT ON a FOR EACH ROW EXECUTE FUNCTION f();',
        ),
        hasLength(2),
      );
      expect(CodeDdl(sqlDialects['oracle']!).statementsOf('CREATE TRIGGER t BEFORE INSERT ON a BEGIN NULL; END\n/'), [
        'CREATE TRIGGER t BEFORE INSERT ON a BEGIN NULL; END;',
      ]);
      expect(CodeDdl(sqlDialects['mysql']!).statementsOf('CREATE PROCEDURE p() BEGIN SELECT 1; END;'), [
        'CREATE PROCEDURE p() BEGIN SELECT 1; END',
      ]);
      expect(CodeDdl(sqlDialects['mssql']!).statementsOf('CREATE PROCEDURE p AS\n  SELECT 1;\n  SELECT 2;'), [
        'CREATE PROCEDURE p AS\n  SELECT 1;\n  SELECT 2',
      ]);
    });

    test('SQLite: line comments become block comments', () {
      expect(
        blockComments("SELECT '--x' -- nota */ qui\nFROM t -- fine"),
        "SELECT '--x' /* nota * / qui */\nFROM t /* fine */",
      );
      expect(
        CodeDdl(sqlDialects['sqlite']!)
            .statementsOf('CREATE TRIGGER t AFTER INSERT ON a BEGIN\n  SELECT 1; -- c\nEND;'),
        ['CREATE TRIGGER t AFTER INSERT ON a BEGIN\n  SELECT 1; /* c */\nEND'],
      );
    });

    test('headers rewritten to replace in place', () {
      const src = 'CREATE PROCEDURE p AS SELECT 1';
      expectPerFamily((d) => CodeDdl(d).withReplace(src, 'PROCEDURE'), {
        'pg': 'CREATE OR REPLACE PROCEDURE p AS SELECT 1',
        'mssql': 'CREATE OR ALTER PROCEDURE p AS SELECT 1',
        'mysql': 'CREATE PROCEDURE p AS SELECT 1',
        'mariadb': 'CREATE OR REPLACE PROCEDURE p AS SELECT 1',
        'oracle': 'CREATE OR REPLACE PROCEDURE p AS SELECT 1',
        'db2': 'CREATE OR REPLACE PROCEDURE p AS SELECT 1',
        'sqlite': 'CREATE PROCEDURE p AS SELECT 1',
        'firebird': 'CREATE OR ALTER PROCEDURE p AS SELECT 1',
        'snowflake': 'CREATE OR REPLACE PROCEDURE p AS SELECT 1',
      });
      expect(
        CodeDdl(sqlDialects['oracle']!)
            .withReplace('CREATE OR REPLACE EDITIONABLE PROCEDURE p IS BEGIN NULL; END;', 'PROCEDURE'),
        'CREATE OR REPLACE PROCEDURE p IS BEGIN NULL; END;',
      );
      expect(CodeDdl(dialectAt('pg', '13.4')).withReplace('CREATE TRIGGER t', 'TRIGGER'), 'CREATE TRIGGER t');
    });

    test('saving a trigger drops it first where it cannot be replaced', () {
      const src = 'CREATE TRIGGER trg_o BEFORE INSERT ON orders FOR EACH ROW BEGIN SELECT 1; END';
      expect(CodeDdl(sqlDialects['mysql']!).saveTrigger(trg, 'trg_o', src), ['DROP TRIGGER trg_o', src]);
      expect(CodeDdl(sqlDialects['sqlite']!).saveTrigger(trg, 'trg_o', src), ['DROP TRIGGER trg_o', src]);
      expect(
        CodeDdl(sqlDialects['mssql']!).saveTrigger(trg, 'trg_o', src).single,
        startsWith('CREATE OR ALTER TRIGGER'),
      );
      // Renamed: the old one goes.
      expect(CodeDdl(sqlDialects['mssql']!).saveTrigger(trg, 'trg_x', src).first, 'DROP TRIGGER app.trg_o');
      // New: as written.
      expect(CodeDdl(sqlDialects['mssql']!).saveTrigger(null, 'trg_o', src), [src]);
      expect(CodeDdl(sqlDialects['snowflake']!).saveTrigger(null, 'trg_o', src), note('Snowflake'));
    });

    test('a comment before CREATE does not prevent the replace (D-018)', () {
      const src = '-- modificato\n/* note */\nCREATE TRIGGER trg_o ON orders AFTER UPDATE AS BEGIN SET NOCOUNT ON; END';
      expect(
        CodeDdl(sqlDialects['mssql']!).saveTrigger(trg, 'trg_o', src).single,
        '-- modificato\n/* note */\nCREATE OR ALTER TRIGGER trg_o ON orders AFTER UPDATE AS BEGIN SET NOCOUNT ON; END',
      );
      expect(
        CodeDdl(sqlDialects['mariadb']!)
            .saveRoutine('-- c\nCREATE PROCEDURE p() BEGIN END', RoutineKind.procedure, existing: (catalog: 'd', schema: null, name: 'p'))
            .single,
        '-- c\nCREATE OR REPLACE PROCEDURE p() BEGIN END',
      );
    });

    test('PostgreSQL: function and trigger are both replaced (D-013)', () {
      final pgTemplate = CodeDdl(sqlDialects['pg']!).triggerTemplate(trg).replaceFirst('CREATE OR REPLACE', 'CREATE');
      final out = CodeDdl(dialectAt('pg', '17.1')).saveTrigger(trg, 'trg_o', pgTemplate);
      expect(out, hasLength(2));
      expect(out[0], startsWith('CREATE OR REPLACE FUNCTION app.trg_o_fn()'));
      expect(out[1], startsWith('CREATE OR REPLACE TRIGGER trg_o'));
      final old = CodeDdl(dialectAt('pg', '13.4')).saveTrigger(trg, 'trg_o', pgTemplate);
      expect(old.first, 'DROP TRIGGER trg_o ON app.orders');
      expect(old[1], startsWith('CREATE OR REPLACE FUNCTION'));
      expect(old[2], startsWith('CREATE TRIGGER trg_o'));
      expect(
        CodeDdl(dialectAt('pg', '17.1')).withReplace('CREATE CONSTRAINT TRIGGER t AFTER INSERT ON a', 'TRIGGER'),
        'CREATE CONSTRAINT TRIGGER t AFTER INSERT ON a',
      );
    });

    test('enable, drop, templates', () {
      expect(CodeDdl(sqlDialects['pg']!).setTriggerEnabled(trg, false), [
        'ALTER TABLE app.orders DISABLE TRIGGER trg_o',
      ]);
      expect(CodeDdl(sqlDialects['mssql']!).setTriggerEnabled(trg, true), ['ENABLE TRIGGER app.trg_o ON app.orders']);
      expect(CodeDdl(sqlDialects['oracle']!).setTriggerEnabled(trg, false), ['ALTER TRIGGER "app"."trg_o" DISABLE']);
      expect(CodeDdl(sqlDialects['firebird']!).setTriggerEnabled(trg, false), ['ALTER TRIGGER "trg_o" INACTIVE']);
      expect(CodeDdl(sqlDialects['mysql']!).canDisableTriggers, isFalse);
      expect(CodeDdl(sqlDialects['pg']!).dropTrigger(trg), ['DROP TRIGGER trg_o ON app.orders']);
      final pgTemplate = CodeDdl(sqlDialects['pg']!).triggerTemplate(trg);
      expect(pgTemplate, contains('CREATE OR REPLACE FUNCTION app.trg_o_fn() RETURNS trigger'));
      expect(
        pgTemplate,
        contains(
          'CREATE TRIGGER trg_o BEFORE INSERT OR UPDATE ON app.orders\nFOR EACH ROW EXECUTE FUNCTION app.trg_o_fn();',
        ),
      );
      expect(
        CodeDdl(sqlDialects['mssql']!).triggerTemplate(trg),
        startsWith('CREATE TRIGGER app.trg_o ON app.orders\nAFTER INSERT, UPDATE'),
      );
      for (final d in sqlDialects.values) {
        final t = CodeDdl(d).routineTemplate(RoutineKind.function, null, 'app', 'f');
        expect(createdName(t, kind: 'ROUTINE'), 'f', reason: d.dbmsName);
      }
      expect(CodeDdl(sqlDialects['pg']!).dropRoutine(RoutineKind.function, null, 'app', 'f', arguments: 'integer'), [
        'DROP FUNCTION app.f(integer)',
      ]);
      expect(
        CodeDdl(sqlDialects['mysql']!).saveRoutine(
          'CREATE PROCEDURE p() BEGIN END',
          RoutineKind.procedure,
          existing: (catalog: 'shop', schema: null, name: 'p'),
        ),
        ['DROP PROCEDURE IF EXISTS shop.p', 'CREATE PROCEDURE p() BEGIN END'],
      );
    });

    test('names and headers parsed from sources', () {
      expect(createdName('CREATE OR ALTER TRIGGER [dbo].[My Trg] ON t AFTER INSERT AS BEGIN END'), 'My Trg');
      expect(
        createdName(
          'CREATE FUNCTION f() RETURNS trigger AS \$\$\$\$;\nCREATE TRIGGER "Trg" AFTER INSERT ON a EXECUTE FUNCTION f();',
        ),
        'Trg',
      );
      expect(createdName('CREATE DEFINER=`root`@`%` PROCEDURE `shop`.`p`() BEGIN END', kind: 'ROUTINE'), 'p');
      final h = parseTriggerHeader(
        'CREATE TRIGGER t BEFORE INSERT OR UPDATE OF qty ON a FOR EACH ROW EXECUTE FUNCTION f()',
      );
      expect(h.timing, TriggerTiming.before);
      expect(h.events, {TriggerEvent.insert, TriggerEvent.update});
      expect(h.row, isTrue);
      final ms = parseTriggerHeader('CREATE TRIGGER t ON a INSTEAD OF DELETE, UPDATE AS BEGIN END');
      expect(ms.timing, TriggerTiming.insteadOf);
      expect(ms.events, {TriggerEvent.delete, TriggerEvent.update});
      expect(
        parseTriggerHeader('CREATE TRIGGER t AFTER INSERT ON a FOR EACH STATEMENT EXECUTE FUNCTION f()').row,
        isFalse,
      );
    });
  });

  group('catalog', () {
    final orders = DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE');

    test('PostgreSQL triggers carry their function', () async {
      final s = ScriptedSession()
        ..on(
          'FROM pg_trigger',
          Rows(
            ['tgname', 'def', 'tgenabled', 'fn', 'fdef'],
            [
              [
                'trg_o',
                'CREATE TRIGGER trg_o BEFORE INSERT ON app.orders FOR EACH ROW EXECUTE FUNCTION app.f()',
                'D',
                'app.f()',
                'CREATE OR REPLACE FUNCTION app.f()\n RETURNS trigger\nAS \$function\$ BEGIN RETURN NEW; END \$function\$\n',
              ],
            ],
          ),
        );
      final t = (await DesignCatalog.of(scriptedConnection(s))!.triggers(orders)).single;
      expect(t.enabled, isFalse);
      expect(t.timing, TriggerTiming.before);
      expect(t.source, startsWith('CREATE OR REPLACE FUNCTION app.f()'));
      expect(t.source, endsWith('EXECUTE FUNCTION app.f();'));
      expect(CodeDdl(sqlDialects['pg']!).statementsOf(t.source), hasLength(2));
    });

    test('MySQL triggers are rebuilt from information_schema', () async {
      final s = ScriptedSession()
        ..on(
          'information_schema.TRIGGERS',
          Rows(
            ['TRIGGER_NAME', 'EVENT_MANIPULATION', 'ACTION_TIMING', 'ACTION_STATEMENT', 'ACTION_ORIENTATION'],
            [
              ['trg_o', 'UPDATE', 'AFTER', 'BEGIN SET @x = 1; END', 'ROW'],
            ],
          ),
        );
      final dc = scriptedConnection(s, dbmsName: 'MySQL', dbmsVersion: '8.4.0');
      final t = (await DesignCatalog.of(dc)!.triggers(orders)).single;
      expect(t.source, 'CREATE TRIGGER trg_o AFTER UPDATE ON app.orders\nFOR EACH ROW\nBEGIN SET @x = 1; END');
      expect(t.events, {TriggerEvent.update});
    });

    test('routine sources', () async {
      final p = DbProcedure(catalog: null, schema: 'app', name: 'f', type: 2);
      final pg = ScriptedSession()
        ..on(
          'pg_get_functiondef',
          Rows(
            ['def', 'args', 'prokind'],
            [
              ['CREATE OR REPLACE FUNCTION app.f(x integer)\n RETURNS integer ...', 'x integer', 'f'],
            ],
          ),
        );
      final src = (await DesignCatalog.of(scriptedConnection(pg))!.routineSource(p))!;
      expect(src.kind, RoutineKind.function);
      expect(src.arguments, 'x integer');
      final my = ScriptedSession()
        ..on(
          'SHOW CREATE FUNCTION',
          Rows(
            ['Function', 'sql_mode', 'Create Function'],
            [
              ['f', '', 'CREATE DEFINER=`root`@`%` FUNCTION `f`() RETURNS int BEGIN RETURN 1; END'],
            ],
          ),
        )
        ..on('SHOW CREATE PROCEDURE', StateError('not a procedure'));
      final m = (await DesignCatalog.of(scriptedConnection(my, dbmsName: 'MySQL', dbmsVersion: '8.4.0'))!
          .routineSource(p))!;
      expect(m.source, startsWith('CREATE DEFINER'));
      expect(m.kind, RoutineKind.function);
      expect(await DesignCatalog.of(scriptedConnection(ScriptedSession()))!.routineSource(p), isNull);
    });
  });

  group('code editor', () {
    Future<void> host(WidgetTester tester, Widget body) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = await testApp(tester);
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(body: body),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> runScript(WidgetTester tester) async {
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    testWidgets('a new trigger is created from its template', (tester) async {
      final s = ordersSession();
      final dc = scriptedConnection(s);
      final tab = CodeEditorTab.trigger(
        dc,
        table: DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE'),
        template: trg,
      );
      await host(tester, Builder(builder: tab.buildView));
      expect(tab.isNew, isTrue);
      expect(find.text('trigger'), findsOneWidget);
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(s.executed.first, startsWith('CREATE OR REPLACE FUNCTION app.trg_o_fn()'));
      expect(s.executed[1], startsWith('CREATE TRIGGER trg_o BEFORE INSERT OR UPDATE ON app.orders'));
      expect(s.log, contains('commit'), reason: 'function and trigger in one transaction');
    });

    testWidgets('an edited procedure is replaced in place', (tester) async {
      final s = ScriptedSession();
      final dc = scriptedConnection(s, dbmsName: 'Microsoft SQL Server', dbmsVersion: '16.00.4135');
      final tab = CodeEditorTab.routine(
        dc,
        kind: RoutineKind.procedure,
        procedure: DbProcedure(catalog: 'shop', schema: 'dbo', name: 'p', type: 1),
        source: const RoutineSource('CREATE PROCEDURE dbo.p AS SELECT 1', RoutineKind.procedure),
      );
      await host(tester, Builder(builder: tab.buildView));
      expect(tab.isDirty, isFalse);
      tab.controller.text = 'CREATE PROCEDURE dbo.p AS SELECT 2';
      await tester.pumpAndSettle();
      expect(tab.isDirty, isTrue);
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(s.log, containsAllInOrder(['use shop', 'exec: CREATE OR ALTER PROCEDURE dbo.p AS SELECT 2']));
      expect(tab.isDirty, isFalse);
    });
  });
}
