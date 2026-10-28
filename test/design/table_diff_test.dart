// Phase 1: diff and migration of UNIQUE / CHECK constraints, constraint
// states, index attributes, renames and foreign keys referencing a changed
// key.

import 'package:dbcraft/features/schema/schema_diff.dart';
import 'package:dbcraft/features/schema/schema_migration.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:dbcraft/features/schema/schema_snapshot.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

final pg = sqlDialects['pg']!;
final mssql = sqlDialects['mssql']!;

const customers = TableDef(
  schema: 'app',
  name: 'customers',
  columns: [
    ColumnDef(name: 'id', type: 'integer', nullable: false),
    ColumnDef(name: 'code', type: 'varchar', size: 20, nullable: false),
    ColumnDef(name: 'qty', type: 'integer'),
  ],
  primaryKey: PrimaryKeyDef(name: 'pk_customers', columns: ['id']),
  uniques: [
    UniqueDef(name: 'uq_code', columns: ['code']),
  ],
  checks: [CheckDef(name: 'ck_qty', expression: 'qty > 0')],
  indexes: [
    IndexDef(name: 'ix_qty', columns: ['qty']),
  ],
);

const orders = TableDef(
  schema: 'app',
  name: 'orders',
  columns: [
    ColumnDef(name: 'id', type: 'integer', nullable: false),
    ColumnDef(name: 'customer_id', type: 'integer'),
  ],
  primaryKey: PrimaryKeyDef(name: 'pk_orders', columns: ['id']),
  foreignKeys: [
    ForeignKeyDef(
      name: 'fk_orders_customers',
      columns: ['customer_id'],
      refSchema: 'app',
      refTable: 'customers',
      refColumns: ['id'],
    ),
  ],
);

SchemaSnapshot snap(List<TableDef> tables, {DbFamily family = DbFamily.postgres}) =>
    SchemaSnapshot(schema: 'app', tables: tables, family: family);

/// Diff of the wanted [want] against the database [have] (editor options).
SchemaDiff diff(List<TableDef> want, List<TableDef> have, {bool names = true, DbFamily family = DbFamily.postgres}) =>
    SchemaDiff.compare(
      snap(want, family: family),
      snap(have, family: family),
      options: CompareOptions(ignoreCase: false, ignoreComments: false, compareConstraintNames: names),
    );

List<String> migrate(SchemaDiff d, SqlDialect dialect, {List<IncomingForeignKey> incoming = const []}) =>
    SchemaMigration(dialect)
        .generate(d, options: const MigrationOptions(dropExtra: true, relocate: false), incoming: incoming);

void main() {
  test('identical definitions read from different DBMS spellings', () {
    final mssqlRead = customers.copyWith(
      checks: const [CheckDef(name: 'CK_QTY', expression: '([qty]>(0))')],
    );
    final d = SchemaDiff.compare(snap([customers]), snap([mssqlRead]));
    expect(d.changes, isEmpty);
  });

  test('UNIQUE and CHECK added, changed and dropped', () {
    final want = customers.copyWith(
      uniques: const [
        UniqueDef(name: 'uq_code_qty', columns: ['code', 'qty']),
      ],
      checks: const [CheckDef(name: 'ck_qty', expression: 'qty >= 0')],
    );
    final d = diff([want], [customers]);
    final td = d.tables.single;
    expect(td.uniques.map((u) => u.status), [DiffStatus.onlyInSource, DiffStatus.onlyInTarget]);
    expect(td.checks.single.status, DiffStatus.different);
    expect(d.changes.map((c) => c.label), [
      'Aggiungi il vincolo UNIQUE uq_code_qty',
      'Elimina il vincolo UNIQUE uq_code',
      'Modifica il vincolo CHECK ck_qty',
    ]);
    expect(migrate(d, pg), [
      '-- Eliminazione vincoli',
      'ALTER TABLE app.customers DROP CONSTRAINT uq_code',
      'ALTER TABLE app.customers DROP CONSTRAINT ck_qty',
      '-- Nuovi vincoli',
      'ALTER TABLE app.customers ADD CONSTRAINT uq_code_qty UNIQUE (code, qty)',
      'ALTER TABLE app.customers ADD CONSTRAINT ck_qty CHECK (qty >= 0)',
    ]);
  });

  test('renames are found only when names are compared', () {
    final want = customers.copyWith(
      uniques: const [
        UniqueDef(name: 'uq_customers_code', columns: ['code']),
      ],
      indexes: const [
        IndexDef(name: 'ix_customers_qty', columns: ['qty']),
      ],
      primaryKey: const PrimaryKeyDef(name: 'customers_pk', columns: ['id']),
    );
    expect(SchemaDiff.compare(snap([want]), snap([customers])).changes, isEmpty);
    final d = diff([want], [customers]);
    expect(d.changes.map((c) => c.label), [
      'Rinomina la chiave primaria pk_customers in customers_pk',
      'Rinomina il vincolo UNIQUE uq_code in uq_customers_code',
      'Rinomina l\'indice ix_qty in ix_customers_qty',
    ]);
    expect(migrate(d, pg), [
      '-- Ridenominazione vincoli e indici',
      'ALTER TABLE app.customers RENAME CONSTRAINT pk_customers TO customers_pk',
      'ALTER TABLE app.customers RENAME CONSTRAINT uq_code TO uq_customers_code',
      'ALTER INDEX app.ix_qty RENAME TO ix_customers_qty',
    ]);
  });

  test('state only changes do not recreate the constraint', () {
    final have = customers.copyWith(
      checks: const [CheckDef(name: 'ck_qty', expression: 'qty > 0', state: ConstraintState(validated: false))],
      indexes: const [
        IndexDef(name: 'ix_qty', columns: ['qty'], enabled: false),
      ],
    );
    final want = customers.copyWith(
      checks: const [CheckDef(name: 'ck_qty', expression: 'qty > 0', state: ConstraintState(enabled: false))],
    );
    final d = diff([want], [have]);
    expect(d.tables.single.checks.single.stateOnly, isTrue);
    expect(d.tables.single.indexes.single.stateOnly, isTrue);
    expect(d.changes.map((c) => c.label), ['Disabilita il vincolo CHECK ck_qty', 'Abilita l\'indice ix_qty']);
    expect(migrate(d, mssql), [
      '-- Stato dei vincoli e degli indici',
      'ALTER TABLE app.customers NOCHECK CONSTRAINT ck_qty',
      'ALTER INDEX ix_qty ON app.customers REBUILD',
    ]);
    // Validating what was added NOT VALID.
    final v = diff([customers], [have.copyWith(indexes: customers.indexes)]);
    expect(migrate(v, pg), [
      '-- Stato dei vincoli e degli indici',
      'ALTER TABLE app.customers VALIDATE CONSTRAINT ck_qty',
    ]);
  });

  test('index attributes are part of its definition', () {
    for (final change in <IndexDef>[
      const IndexDef(name: 'ix_qty', columns: ['qty'], descending: {'qty'}),
      const IndexDef(name: 'ix_qty', columns: ['qty'], include: ['code']),
      const IndexDef(name: 'ix_qty', columns: ['qty'], where: 'qty > 0'),
      const IndexDef(name: 'ix_qty', columns: ['qty'], method: 'hash'),
      const IndexDef(name: 'ix_qty', columns: ['(abs(qty))']),
    ]) {
      final d = diff(
        [
          customers.copyWith(indexes: [change]),
        ],
        [customers],
      );
      expect(d.tables.single.indexes.single.recreate, isTrue, reason: change.signature());
    }
    // btree is the default method; filters compare normalized.
    final same = diff(
      [
        customers.copyWith(
          indexes: const [
            IndexDef(name: 'ix_qty', columns: ['qty'], method: 'btree', where: '(qty>0)'),
          ],
        ),
      ],
      [
        customers.copyWith(
          indexes: const [
            IndexDef(name: 'ix_qty', columns: ['qty'], where: 'qty > 0'),
          ],
        ),
      ],
    );
    expect(same.changes, isEmpty);
  });

  test('foreign keys referencing a changed primary key are dropped and added back', () {
    // Same columns, different definition (clustered): the reference survives.
    final want = customers.copyWith(
      primaryKey: const PrimaryKeyDef(name: 'pk_customers', columns: ['id'], clustered: false),
    );
    final have = customers.copyWith(
      primaryKey: const PrimaryKeyDef(name: 'pk_customers', columns: ['id'], clustered: true),
    );
    final d = diff([want, orders], [have, orders], family: DbFamily.sqlServer);
    expect(migrate(d, mssql), [
      '-- Eliminazione chiavi esterne',
      'ALTER TABLE app.orders DROP CONSTRAINT fk_orders_customers',
      '-- Eliminazione chiavi primarie',
      'ALTER TABLE app.customers DROP CONSTRAINT pk_customers',
      '-- Nuove chiavi primarie',
      'ALTER TABLE app.customers ADD CONSTRAINT pk_customers PRIMARY KEY NONCLUSTERED (id)',
      '-- Nuove chiavi esterne',
      'ALTER TABLE app.orders ADD CONSTRAINT fk_orders_customers FOREIGN KEY (customer_id) REFERENCES app.customers (id)',
    ]);

    // Other columns: the foreign key cannot be added back.
    final other = customers.copyWith(
      primaryKey: const PrimaryKeyDef(name: 'pk_customers', columns: ['code']),
    );
    final d2 = diff([other], [customers]);
    final out = migrate(d2, pg, incoming: const [IncomingForeignKey(orders, _fk)]);
    expect(out.take(2), [
      '-- Eliminazione chiavi esterne',
      'ALTER TABLE app.orders DROP CONSTRAINT fk_orders_customers',
    ]);
    expect(out.last, allOf(startsWith('--'), contains('non viene ricreata')));

    // A foreign key the diff changes anyway is not handled twice.
    final changedFk = orders.copyWith(foreignKeys: [_fk.copyWith(onDelete: FkRule.cascade)]);
    final d3 = diff([want, changedFk], [have, orders], family: DbFamily.sqlServer);
    final out3 = migrate(d3, mssql);
    expect(out3.where((s) => s.contains('DROP CONSTRAINT fk_orders_customers')), hasLength(1));
    expect(out3.where((s) => s.contains('ADD CONSTRAINT fk_orders_customers')), hasLength(1));
  });

  test('a dropped UNIQUE referenced by a foreign key', () {
    const fk = ForeignKeyDef(
      name: 'fk_code',
      columns: ['customer_code'],
      refSchema: 'app',
      refTable: 'customers',
      refColumns: ['code'],
    );
    final child = orders.copyWith(foreignKeys: [fk]);
    final d = diff([customers.copyWith(uniques: const []), child], [customers, child]);
    final out = migrate(d, pg);
    final dropFk = out.indexOf('ALTER TABLE app.orders DROP CONSTRAINT fk_code');
    expect(dropFk, greaterThanOrEqualTo(0));
    expect(dropFk, lessThan(out.indexOf('ALTER TABLE app.customers DROP CONSTRAINT uq_code')));
    // Dropped for good: not added back.
    expect(out.where((s) => s.contains('ADD CONSTRAINT fk_code')), isEmpty);
  });

  test('SQLite rebuilds the table to change constraints', () {
    final lite = sqlDialects['sqlite']!;
    final want = customers.copyWith(
      checks: const [CheckDef(name: 'ck_qty', expression: 'qty >= 0')],
    );
    final out = migrate(diff([want], [customers], family: DbFamily.sqlite), lite);
    expect(out, contains('PRAGMA foreign_keys = OFF'));
    expect(out.firstWhere((s) => s.startsWith('CREATE TABLE')), contains('CONSTRAINT ck_qty CHECK (qty >= 0)'));
    expect(out.firstWhere((s) => s.startsWith('CREATE TABLE')), contains('CONSTRAINT uq_code UNIQUE (code)'));
  });

  test('collation and computed columns', () {
    final want = customers.copyWith(
      columns: [
        customers.columns[0],
        customers.columns[1].copyWith(collation: 'C'),
        customers.columns[2].copyWith(computed: 'id * 2'),
      ],
    );
    final td = diff([want], [customers]).tables.single;
    expect(td.columns[1].aspects, {ColumnAspect.collation});
    expect(td.columns[2].aspects, {ColumnAspect.computed});
    // No collation wanted: the server one is fine.
    final read = customers.copyWith(
      columns: [
        customers.columns[0],
        customers.columns[1].copyWith(collation: 'en_US'),
        customers.columns[2],
      ],
    );
    expect(diff([customers], [read]).changes, isEmpty);
  });
}

const _fk = ForeignKeyDef(
  name: 'fk_orders_customers',
  columns: ['customer_id'],
  refSchema: 'app',
  refTable: 'customers',
  refColumns: ['id'],
);
