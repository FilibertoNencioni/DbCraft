// Phase 3: the table designer (TableDesign model, EditableGrid, the editable
// object editor, new tables).

import 'package:dbcraft/features/design/table_design.dart';
import 'package:dbcraft/features/design/ui/table_designer.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/state/editor_tabs.dart';
import 'package:dbcraft/ui/editors/table_editor_view.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';

import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

final pg = sqlDialects['pg']!;

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
  foreignKeys: [
    ForeignKeyDef(name: 'fk_c', columns: ['customer_id'], refSchema: 'app', refTable: 'customers', refColumns: ['id']),
  ],
  indexes: [
    IndexDef(name: 'ix_code_qty', columns: ['code', 'qty'], descending: {'qty'}),
  ],
);

/// The page [label] of the object editor's page switcher.
Finder page(String label) => find.descendant(of: find.byType(PageSwitcher<int>), matching: find.text(label));

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  group('TableDesign', () {
    test('a renamed column follows into keys and indexes', () {
      final d = TableDesign.existing(pg, orders);
      expect(d.isDirty, isFalse);
      d.setColumn(2, d.working.columns[2].copyWith(name: 'quantity'));
      expect(d.working.indexes.single.columns, ['code', 'quantity']);
      expect(d.working.indexes.single.descending, {'quantity'});
      expect(d.statements, contains('ALTER TABLE app.orders RENAME COLUMN qty TO quantity'));
      expect(d.statements.where((s) => s.contains('INDEX')), isEmpty, reason: 'the index follows the rename');
      expect(d.changes.map((c) => c.label), ['Rinomina la colonna qty in quantity']);
    });

    test('a removed column takes its constraints along', () {
      final d = TableDesign.existing(pg, orders);
      d.removeColumn(3);
      expect(d.working.foreignKeys, isEmpty);
      d.removeColumn(2);
      expect(d.working.indexes.single.columns, ['code']);
      expect(d.removedColumns.map((c) => c.name), ['qty', 'customer_id']);
      expect(d.statements.first, '-- Eliminazione chiavi esterne');
      d.restoreColumn(d.removedColumns.first);
      expect(d.working.columns.map((c) => c.name), contains('qty'));
    });

    test('undo coalesces typing in one field', () {
      final d = TableDesign.existing(pg, orders);
      for (final n in ['c', 'co', 'cod', 'codice']) {
        d.setColumn(1, d.working.columns[1].copyWith(name: n), coalesce: 'col:1:name');
      }
      d.setColumn(2, d.working.columns[2].copyWith(nullable: false), coalesce: 'col:2:null');
      d.undo();
      expect(d.working.columns[1].name, 'codice');
      expect(d.working.columns[2].nullable, isTrue);
      d.undo();
      expect(d.working.columns[1].name, 'code');
      expect(d.canUndo, isFalse);
      d.redo();
      expect(d.working.columns[1].name, 'codice');
      d.discard();
      expect(d.isDirty, isFalse);
    });

    test('primary key from the column grid', () {
      final d = TableDesign.existing(pg, orders);
      d.togglePrimaryKey('code', true);
      expect(d.working.primaryKey!.columns, ['id', 'code']);
      expect(d.working.column('code')!.nullable, isFalse);
      d.togglePrimaryKey('id', false);
      d.togglePrimaryKey('code', false);
      expect(d.working.primaryKey, isNull);
      expect(d.statements, contains('ALTER TABLE app.orders DROP CONSTRAINT orders_pkey'));
    });

    test('marks and validation', () {
      final d = TableDesign.existing(pg, orders);
      final i = d.addColumn();
      expect(d.working.columns[i].name, 'colonna');
      expect(d.columnMark(d.working.columns[i]), ColumnMark.added);
      d.setColumn(1, d.working.columns[1].copyWith(size: 40));
      expect(d.columnMark(d.working.columns[1]), ColumnMark.changed);
      expect(d.columnMark(d.working.columns[0]), ColumnMark.none);
      d.replace(d.working.indexes.single, d.working.indexes.single.copyWith(unique: true));
      expect(d.constraintMark(d.working.indexes.single), ColumnMark.changed);
      expect(d.constraintMark(d.working.primaryKey!), ColumnMark.none);
      d.setColumn(i, d.working.columns[i].copyWith(name: 'code'));
      expect(d.errors, contains('Colonna "code" duplicata'));
      d.update(d.working.copyWith(name: ''));
      expect(d.errors, contains('Inserisci il nome della tabella'));
    });

    test('excluded changes stay pending after a partial save', () {
      final d = TableDesign.existing(pg, orders);
      d.setColumn(2, d.working.columns[2].copyWith(name: 'quantity'));
      d.setColumn(1, d.working.columns[1].copyWith(size: 40));
      final size = d.changes.firstWhere((c) => c.label.contains('Modifica la colonna'));
      d.setExcluded(size.id, true);
      expect(d.statements.where((s) => s.contains('TYPE')), isEmpty);
      // The rename ran: the database now has "quantity".
      final now = orders.copyWith(
        columns: [
          orders.columns[0],
          orders.columns[1],
          orders.columns[2].copyWith(name: 'quantity'),
          orders.columns[3],
        ],
        indexes: [
          orders.indexes.single.copyWith(columns: ['code', 'quantity'], descending: {'quantity'}),
        ],
      );
      d.saved(now, keepPending: true);
      expect(d.changes.map((c) => c.label), ['Modifica la colonna code (tipo)']);
    });

    test('new tables and copies', () {
      final d = TableDesign.create(pg, schema: 'app');
      expect(d.isNew, isTrue);
      expect(d.errors, ['Inserisci il nome della tabella']);
      d.update(d.working.copyWith(name: 'invoices'));
      expect(
        d.statements.single,
        startsWith('CREATE TABLE app.invoices (\n\tid integer GENERATED BY DEFAULT AS IDENTITY NOT NULL'),
      );
      final my = TableDesign.create(sqlDialects['mysql']!);
      expect(my.working.primaryKey!.name, isNull, reason: 'MySQL always names it PRIMARY');

      final copy = TableDesign.copyOf(pg, orders, 'orders_2024');
      expect(copy.isNew, isTrue);
      expect(copy.working.name, 'orders_2024');
      expect(copy.working.primaryKey!.name, 'orders_2024_pkey');
      expect(copy.working.foreignKeys.single.name, 'fk_orders_2024_customers');
      expect(copy.working.indexes.single.name, 'ix_orders_2024_code_qty');
      expect(copy.working.columns.every((c) => c.originalName == null), isTrue);
    });
  });

  group('EditableGrid', () {
    testWidgets('selection, keyboard moves and removal', (tester) async {
      final rows = ['a', 'b', 'c'];
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => EditableGrid(
                columns: const [EditableGridColumn('Nome')],
                rowCount: rows.length,
                selected: selected,
                onSelect: (i) => setState(() => selected = i),
                mark: (i) => rows[i] == 'b' ? EditableRowMark.added : EditableRowMark.none,
                onAdd: () => setState(() => rows.add('nuova')),
                onRemove: (i) => setState(() => rows.removeAt(i)),
                onMove: (a, b) => setState(() => rows.insert(b, rows.removeAt(a))),
                cellBuilder: (context, r, c) => Text(rows[r]),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('b'));
      await tester.pump();
      expect(selected, 1);
      // Focus the grid itself, then ⌘↓ (Ctrl↓ elsewhere) and ⌫.
      await tester.tap(find.text('Aggiungi'));
      await tester.pump();
      expect(rows, ['a', 'b', 'c', 'nuova']);
      final mac = Theme.of(tester.element(find.byType(EditableGrid))).platform == TargetPlatform.macOS;
      await tester.sendKeyDownEvent(mac ? LogicalKeyboardKey.meta : LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(mac ? LogicalKeyboardKey.meta : LogicalKeyboardKey.control);
      await tester.pump();
      expect(rows, ['a', 'c', 'b', 'nuova']);
      expect(selected, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(rows, ['a', 'c', 'nuova']);
      await tester.tap(find.byTooltip('Sposta su').first);
      await tester.pump();
      expect(rows, ['a', 'c', 'nuova'], reason: 'the first row cannot move up');
    });

    testWidgets('rows and cells are announced to assistive technologies', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: EditableGrid(
              columns: const [EditableGridColumn('Nome'), EditableGridColumn('Tipo')],
              rowCount: 2,
              selected: 1,
              mark: (i) => i == 1 ? EditableRowMark.added : EditableRowMark.none,
              onRemove: (_) {},
              cellBuilder: (context, r, c) => Text('r$r c$c'),
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel('Tabella modificabile, 2 righe'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Riga 1 di 2')), findsOneWidget);
      final second = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Riga 2 di 2, nuova')));
      expect(second.flagsCollection.isSelected, Tristate.isTrue);
      expect(find.bySemanticsLabel(RegExp(r'^Tipo')), findsNWidgets(2));
      semantics.dispose();
    });
  });

  group('designer in the object editor', () {
    Future<(TableEditorTab, ScriptedSession)> open(
      WidgetTester tester, {
      TableEditorTab Function(ScriptedSession, AppState)? make,
    }) async {
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = ordersSession()
        ..on(
          'FROM pg_constraint',
          Rows(
            [
              'conname',
              'contype',
              'def',
              'condeferrable',
              'condeferred',
              'convalidated',
              'confmatchtype',
              'cols',
              'index_name',
            ],
            [
              ['orders_pkey', 'p', 'PRIMARY KEY (id)', 'f', 'f', 't', null, 'id', 'orders_pkey'],
            ],
          ),
        );
      final app = await testApp(tester);
      final dc = scriptedConnection(s);
      final tab =
          make?.call(s, app) ??
          TableEditorTab(dc, DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE'));
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(body: TableEditorView(tab: tab)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (tab, s);
    }

    testWidgets('edit a column and save', (tester) async {
      final (tab, s) = await open(tester);
      expect(tab.design, isNotNull, reason: 'the editor opens a design session');
      await tester.tap(page('Colonne'));
      await tester.pumpAndSettle();
      expect(find.byType(EditableGrid), findsOneWidget);
      // Rename qty.
      final field = find.widgetWithText(TextField, 'qty');
      await tester.enterText(field, 'quantity');
      await tester.pumpAndSettle();
      expect(tab.isDirty, isTrue);
      expect(page('Modifiche (1)'), findsOneWidget);
      await tester.tap(page('Modifiche (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Rinomina la colonna qty in quantity'), findsOneWidget);
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      expect(find.textContaining('RENAME COLUMN qty TO quantity;'), findsOneWidget);
      // The database now has the new name.
      s.catalogs['columns'] = [
        for (final r in s.catalogs['columns']!) r[3] == 'qty' ? (List.of(r)..[3] = 'quantity') : r,
      ];
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      expect(s.executed, contains('ALTER TABLE app.orders RENAME COLUMN qty TO quantity'));
      expect(tab.design!.isDirty, isFalse);
      expect(tab.design!.original!.column('quantity'), isNotNull);
      await drain(tester);
    });

    testWidgets('create a new table', (tester) async {
      final (tab, s) = await open(
        tester,
        make: (s, app) {
          final dc = scriptedConnection(s);
          return TableEditorTab.create(dc, schema: 'app');
        },
      );
      expect(find.text('Nuova tabella'), findsWidgets);
      expect(page('Dati'), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, '').first, 'invoices');
      await tester.pumpAndSettle();
      expect(tab.title, 'invoices');
      s.on('CREATE TABLE', (String sql) {
        s.catalogs['tables']!.add([null, 'app', 'invoices', 'TABLE', null]);
        s.catalogs['columns']!.add(catalogColumn('invoices', 'id', 'int4', 1, nullable: false));
        return Rows(const [], const []);
      });
      await tester.tap(find.text('Crea tabella'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      expect(s.executed.first, startsWith('CREATE TABLE app.invoices'));
      expect(tab.isNew, isFalse);
      expect(tab.table.name, 'invoices');
      await drain(tester);
    });

    test('size parsing', () {
      expect(parseColumnSize('10,2'), (10, 2));
      expect(parseColumnSize('max'), (-1, null));
      expect(parseColumnSize(''), (null, null));
      expect(parseColumnSize('abc'), isNull);
    });
  });
}
