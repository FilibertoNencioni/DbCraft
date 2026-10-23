// Phase 2: data checks, the constraint / index sheets, the actions run from
// the navigator and the object editor, the navigator nodes and menus.

import 'package:dbcraft/features/design/data_checks.dart';
import 'package:dbcraft/features/design/ui/constraint_dialogs.dart';
import 'package:dbcraft/features/design/ui/constraints_page.dart';
import 'package:dbcraft/features/design/ui/design_actions.dart' as design;
import 'package:dbcraft/features/design/ui/design_menu.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/navigator/nav_nodes.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const orders = TableDef(
  schema: 'app',
  name: 'orders',
  columns: [
    ColumnDef(name: 'id', type: 'integer', nullable: false),
    ColumnDef(name: 'code', type: 'varchar', size: 20),
    ColumnDef(name: 'qty', type: 'integer'),
    ColumnDef(name: 'customer_id', type: 'integer'),
  ],
  primaryKey: PrimaryKeyDef(name: 'orders_pkey', columns: ['id']),
);

const customers = TableDef(
  schema: 'app',
  name: 'customers',
  columns: [ColumnDef(name: 'id', type: 'integer', nullable: false)],
  primaryKey: PrimaryKeyDef(name: 'customers_pkey', columns: ['id']),
);

final ordersTable = DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE');

/// Rows of pg_constraint for orders: its primary key and UNIQUE uq_code.
Rows pgConstraints({bool withUnique = true}) => Rows(
  ['conname', 'contype', 'def', 'condeferrable', 'condeferred', 'convalidated', 'confmatchtype', 'cols', 'index_name'],
  [
    ['orders_pkey', 'p', 'PRIMARY KEY (id)', 'f', 'f', 't', null, 'id', 'orders_pkey'],
    if (withUnique) ['uq_code', 'u', 'UNIQUE (code)', 'f', 'f', 't', null, 'code', 'uq_code'],
  ],
);

Future<BuildContext> host(WidgetTester tester, {Widget? body, AppState? app}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext ctx;
  Widget child = MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (c) {
          ctx = c;
          return body ?? const SizedBox();
        },
      ),
    ),
  );
  if (app != null) child = AppScope(state: app, child: child);
  await tester.pumpWidget(child);
  return ctx;
}

/// Taps the buttons labelled [labels] in order, settling in between.
Future<void> tapAll(WidgetTester tester, List<String> labels) async {
  for (final l in labels) {
    await tester.pumpAndSettle();
    await tester.tap(find.text(l).last);
  }
  await tester.pumpAndSettle();
}

/// Result of [f] once the UI settles (fails instead of hanging when the
/// sheet did not close).
Future<T> settled<T>(WidgetTester tester, Future<T> f) async {
  var done = false;
  late T value;
  f.then((v) {
    value = v;
    done = true;
  });
  await tester.pumpAndSettle();
  expect(done, isTrue, reason: 'La finestra non si è chiusa');
  return value;
}

/// Lets toasts expire.
Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  group('data checks', () {
    test('queries per constraint', () {
      final c = DataChecks(sqlDialects['pg']!);
      const fk = ForeignKeyDef(columns: ['customer_id'], refSchema: 'app', refTable: 'customers', refColumns: ['id']);
      expect(
        c.foreignKey(orders, fk).countSql,
        'SELECT COUNT(*) FROM app.orders c WHERE c.customer_id IS NOT NULL AND NOT EXISTS '
        '(SELECT 1 FROM app.customers p WHERE p.id = c.customer_id)',
      );
      expect(
        c.duplicates(orders, ['code', 'qty']).countSql,
        'SELECT COUNT(*) FROM (SELECT code, qty FROM app.orders WHERE code IS NOT NULL AND qty IS NOT NULL '
        'GROUP BY code, qty HAVING COUNT(*) > 1) d',
      );
      expect(
        c.check(orders, const CheckDef(expression: 'qty > 0')).countSql,
        'SELECT COUNT(*) FROM app.orders WHERE NOT (qty > 0)',
      );
      expect(c.nulls(orders, ['code']).rowsSql, 'SELECT * FROM app.orders WHERE code IS NULL');
      expect(c.forConstraint(orders, const PrimaryKeyDef(columns: ['id'])), hasLength(2));
      expect(c.forConstraint(orders, const IndexDef(name: 'i', columns: ['code'])), isEmpty);
      expect(c.forConstraint(orders, const IndexDef(name: 'i', columns: ['code'], unique: true)), hasLength(1));
      final ms = DataChecks(sqlDialects['mssql']!).duplicates(orders, ['code']);
      expect(
        ms.rowsSql,
        'SELECT code, COUNT(*) AS righe FROM app.orders WHERE code IS NOT NULL GROUP BY code HAVING COUNT(*) > 1',
      );
    });

    test('count', () async {
      final s = ScriptedSession()
        ..on(
          'COUNT',
          Rows(
            ['n'],
            [
              [3],
            ],
          ),
        );
      expect(
        await countViolations(s, DataChecks(sqlDialects['pg']!).check(orders, const CheckDef(expression: 'x'))),
        3,
      );
    });
  });

  test('replacing constraints in a definition', () {
    const u = UniqueDef(name: 'uq_code', columns: ['code']);
    final a = design.replaceConstraint(orders, null, u);
    expect(a.uniques.single.name, 'uq_code');
    final b = design.replaceConstraint(
      a,
      const UniqueDef(name: 'UQ_CODE', columns: ['x']),
      u.copyWith(columns: ['code', 'qty']),
    );
    expect(b.uniques.single.columns, ['code', 'qty']);
    expect(design.replaceConstraint(b, u, null).uniques, isEmpty);
    expect(design.replaceConstraint(orders, orders.primaryKey, null).primaryKey, isNull);
    const ix = IndexDef(name: 'ix', columns: ['qty']);
    expect(design.replaceConstraint(orders, null, ix).indexes.single, ix);
  });

  group('sheets', () {
    testWidgets('primary key: proposed name and columns', (tester) async {
      final ctx = await host(tester);
      final f = showPrimaryKeyDialog(
        ctx,
        ConstraintContext(dialect: sqlDialects['pg']!, table: orders.copyWith(primaryKey: null)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nuova chiave primaria'), findsOneWidget);
      expect(find.text('pk_orders'), findsOneWidget);
      // Add a second column from the pull-down.
      await tester.tap(find.byTooltip('Aggiungi una colonna'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('code').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('ammettono NULL'), findsOneWidget);
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      final pk = (await settled(tester, f))!.value;
      expect(pk.name, 'pk_orders');
      expect(pk.columns, ['id', 'code']);
    });

    testWidgets('UNIQUE: no columns is an error, names must be free', (tester) async {
      final ctx = await host(tester);
      final f = showUniqueDialog(
        ctx,
        ConstraintContext(
          dialect: sqlDialects['pg']!,
          table: orders.copyWith(
            indexes: const [
              IndexDef(name: 'taken', columns: ['qty']),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      expect(find.text('Scegli almeno una colonna'), findsOneWidget);
      await tester.tap(find.byTooltip('Aggiungi una colonna'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('qty').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'taken');
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      expect(find.text('Il nome "taken" è già usato nella tabella'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'uq_qty');
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      expect((await settled(tester, f))!.value.columns, ['qty']);
    });

    testWidgets('CHECK: column links insert quoted names; NOT VALID option', (tester) async {
      final ctx = await host(tester);
      final f = showCheckDialog(ctx, ConstraintContext(dialect: sqlDialects['pg']!, table: orders));
      await tester.pumpAndSettle();
      expect(find.text('ck_orders_1'), findsOneWidget);
      await tester.tap(find.text('qty'));
      await tester.pumpAndSettle();
      expect(find.text('qty'), findsWidgets);
      await tester.enterText(find.byType(TextField).at(1), 'qty > 0');
      await tester.tap(find.text('Non verificare le righe già presenti'));
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      final c = (await settled(tester, f))!.value;
      expect(c.expression, 'qty > 0');
      expect(c.state.validated, isFalse);
    });

    testWidgets('foreign key: proposes the referenced key and warns', (tester) async {
      final ctx = await host(tester);
      final withText = customers.copyWith(
        columns: const [ColumnDef(name: 'id', type: 'varchar', size: 10, nullable: false)],
      );
      final f = showForeignKeyDialog(
        ctx,
        ConstraintContext(dialect: sqlDialects['pg']!, table: orders),
        tables: [customers.toDbTable()],
        loadTable: (_) async => withText,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scegli una tabella'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('app.customers').last);
      await tester.pumpAndSettle();
      // customers.id ← orders.customer_id, by name.
      expect(find.text('fk_orders_customers'), findsOneWidget);
      expect(find.text('customer_id'), findsOneWidget);
      expect(find.textContaining('Tipi diversi'), findsOneWidget);
      expect(find.textContaining('Nessun indice su customer_id'), findsOneWidget);
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      final fk = (await settled(tester, f))!.value;
      expect(fk.columns, ['customer_id']);
      expect(fk.refColumns, ['id']);
      expect(fk.refTable, 'customers');
    });

    testWidgets('foreign key rules follow the DBMS', (tester) async {
      final ctx = await host(tester);
      showForeignKeyDialog(
        ctx,
        ConstraintContext(dialect: sqlDialects['oracle']!, table: orders),
        tables: const [],
        loadTable: (_) async => null,
      );
      await tester.pumpAndSettle();
      // Oracle: no ON UPDATE actions.
      expect(find.text('Oracle non supporta questa operazione'), findsOneWidget);
      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();
    });

    testWidgets('index: automatic name, DESC, expressions', (tester) async {
      final ctx = await host(tester);
      final f = showIndexDialog(ctx, ConstraintContext(dialect: sqlDialects['pg']!, table: orders));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Aggiungi una colonna').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('qty').last);
      await tester.pumpAndSettle();
      expect(find.text('ix_orders_qty'), findsOneWidget);
      await tester.tap(find.text('DESC'));
      await tester.tap(find.text('Univoco (UNIQUE)'));
      await tester.pumpAndSettle();
      expect(find.text('Colonne incluse (INCLUDE)'), findsOneWidget);
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      final ix = (await settled(tester, f))!.value;
      expect(ix.name, 'ix_orders_qty');
      expect(ix.unique, isTrue);
      expect(ix.descending, {'qty'});
    });

    testWidgets('data check counts the offending rows', (tester) async {
      final s = ScriptedSession()
        ..on(
          'COUNT',
          Rows(
            ['n'],
            [
              [2],
            ],
          ),
        );
      final dc = scriptedConnection(s);
      final ctx = await host(tester, app: await testApp(tester));
      showCheckDialog(
        ctx,
        ConstraintContext(dialect: dc.dialect, table: orders, connection: dc),
        initial: const CheckDef(name: 'c', expression: 'qty > 0'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Verifica dati'));
      await tester.pumpAndSettle();
      expect(find.text('Righe che non rispettano il vincolo: 2'), findsOneWidget);
      expect(find.text('Apri le righe'), findsOneWidget);
      expect(s.executed.single, 'SELECT COUNT(*) FROM app.orders WHERE NOT (qty > 0)');
      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();
    });
  });

  group('actions', () {
    testWidgets('drop a UNIQUE: script, confirmation, statement', (tester) async {
      final s = ordersSession()..on('FROM pg_constraint', pgConstraints());
      final dc = scriptedConnection(s);
      final ctx = await host(tester, app: await testApp(tester));
      final f = design.dropConstraint(ctx, dc, ordersTable, const UniqueDef(name: 'uq_code', columns: ['code']));
      await tester.pumpAndSettle();
      expect(find.textContaining('ALTER TABLE app.orders DROP CONSTRAINT uq_code;'), findsOneWidget);
      await tapAll(tester, ['Esegui', 'Esegui']);
      expect(await settled(tester, f), isTrue);
      expect(s.executed.where((x) => x.startsWith('ALTER')), ['ALTER TABLE app.orders DROP CONSTRAINT uq_code']);
      expect(s.log, contains('commit'), reason: 'PostgreSQL runs the script in a transaction');
      await drain(tester);
    });

    testWidgets('create a CHECK through the sheet', (tester) async {
      final s = ordersSession()..on('FROM pg_constraint', pgConstraints());
      final dc = scriptedConnection(s);
      final ctx = await host(tester, app: await testApp(tester));
      final f = design.createConstraint(ctx, dc, ordersTable, ConstraintKind.check);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'qty >= 0');
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ADD CONSTRAINT ck_orders_1 CHECK (qty >= 0)'), findsOneWidget);
      await tapAll(tester, ['Esegui', 'Esegui']);
      expect(await settled(tester, f), isTrue);
      expect(s.executed, contains('ALTER TABLE app.orders ADD CONSTRAINT ck_orders_1 CHECK (qty >= 0)'));
      await drain(tester);
    });

    testWidgets('rename an index', (tester) async {
      final s = ordersSession()
        ..catalogs['statistics'] = [
          [null, 'app', 'orders', 1, null, 'ix_qty', 3, 1, 'qty', 'A', null, null, null],
        ];
      final dc = scriptedConnection(s);
      final ctx = await host(tester, app: await testApp(tester));
      final f = design.renameConstraint(ctx, dc, ordersTable, const IndexDef(name: 'ix_qty', columns: ['qty']));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'ix_orders_qty');
      await tapAll(tester, ['OK', 'Esegui', 'Esegui']);
      expect(await settled(tester, f), isTrue);
      expect(s.executed, contains('ALTER INDEX app.ix_qty RENAME TO ix_orders_qty'));
      await drain(tester);
    });
  });

  group('navigator', () {
    test('constraint nodes', () async {
      final s = ordersSession()..on('FROM pg_constraint', pgConstraints());
      final dc = scriptedConnection(s);
      final keys = await TablePartNode(dc, ordersTable, TablePart.keys).load();
      expect(keys.map((n) => n.label), ['orders_pkey', 'uq_code']);
      expect(keys.map((n) => n.detail), ['id', 'UNIQUE (code)']);
      final checks = await TablePartNode(dc, ordersTable, TablePart.checks).load();
      expect(checks, isEmpty);
      final n = ConstraintNode(
        dc,
        ordersTable,
        const CheckDef(name: 'ck', expression: 'qty > 0', state: ConstraintState(validated: false)),
      );
      expect(n.detail, 'qty > 0 · non validato');
      expect(
        ConstraintNode(
          dc,
          ordersTable,
          const IndexDef(name: 'ix', columns: ['qty'], descending: {'qty'}, enabled: false),
        ).detail,
        '(qty DESC) · disabilitato',
      );
      expect(partKinds(TablePart.indexes), {null});
    });

    testWidgets('menus follow the capabilities', (tester) async {
      final dc = scriptedConnection(ScriptedSession(), dbmsName: 'Microsoft SQL Server', dbmsVersion: '16.00.4135');
      final ctx = await host(tester, app: await testApp(tester));
      List<String> labels(Object def) => [
        for (final e in constraintMenu(ctx, ConstraintNode(dc, ordersTable, def), refresh: () {})) e.label,
      ];
      expect(
        labels(const CheckDef(name: 'ck', expression: 'x', state: ConstraintState(validated: false))),
        containsAll(['Modifica…', 'Disabilita', 'Valida i dati esistenti', 'Elimina…']),
      );
      expect(labels(const IndexDef(name: 'ix', columns: ['qty'])), containsAll(['Ricostruisci', 'Disabilita']));
      final pg = scriptedConnection(ScriptedSession());
      expect([
        for (final e in constraintMenu(
          ctx,
          ConstraintNode(pg, ordersTable, const CheckDef(name: 'ck', expression: 'x')),
          refresh: () {},
        ))
          e.label,
      ], isNot(contains('Disabilita')));
      final create = createConstraintMenu(ctx, dc, ordersTable, only: {ConstraintKind.foreignKey});
      expect(create.children.map((e) => e.label), ['Chiave esterna…']);
    });
  });

  testWidgets('object editor pages list and act on the constraints', (tester) async {
    final s = ordersSession()..on('FROM pg_constraint', pgConstraints());
    final dc = scriptedConnection(s);
    await host(
      tester,
      app: await testApp(tester),
      body: ConstraintsPage(connection: dc, table: ordersTable),
    );
    await tester.pumpAndSettle();
    expect(find.text('Chiave primaria'), findsOneWidget);
    expect(find.text('uq_code'), findsOneWidget);
    expect(find.text('Vincoli CHECK'), findsOneWidget);
    expect(find.byTooltip('Aggiungi un vincolo UNIQUE'), findsOneWidget);
    // The page reloads after DDL on the table.
    s.rulesClear();
    s.on('FROM pg_constraint', pgConstraints(withUnique: false));
    dc.schemaChanged(const SchemaScope.object(null, 'app', 'orders'));
    await tester.pumpAndSettle();
    expect(find.text('uq_code'), findsNothing);
  });
}
