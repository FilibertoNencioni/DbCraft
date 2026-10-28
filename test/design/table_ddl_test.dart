// Phase 1: DDL of constraints, keys, indexes and column attributes for every
// supported DBMS (golden statements).

import 'package:dbcraft/features/schema/ddl_builder.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const t = TableDef(
  schema: 'app',
  name: 'orders',
  columns: [
    ColumnDef(name: 'id', type: 'integer', nullable: false),
    ColumnDef(name: 'qty', type: 'integer'),
  ],
);

const fk = ForeignKeyDef(name: 'fk_c', columns: ['cid'], refSchema: 'app', refTable: 'customers', refColumns: ['id']);
const check = CheckDef(name: 'ck_qty', expression: 'qty > 0');
const ix = IndexDef(name: 'ix_o', columns: ['qty']);

/// The statement is a note (comment-only) mentioning [text].
Matcher note(String text) => allOf(hasLength(1), everyElement(allOf(startsWith('--'), contains(text))));

const _notSupported = 'non supportato';

void main() {
  group('constraints', () {
    test('add and drop UNIQUE', () {
      const u = UniqueDef(name: 'uq_code', columns: ['code', 'site']);
      expectPerFamily((d) => DdlBuilder(d).addUnique(t, u), {
        'pg': 'ALTER TABLE app.orders ADD CONSTRAINT uq_code UNIQUE (code, site)',
        'mssql': 'ALTER TABLE app.orders ADD CONSTRAINT uq_code UNIQUE (code, site)',
        'mysql': 'ALTER TABLE app.orders ADD CONSTRAINT uq_code UNIQUE (code, site)',
        'mariadb': 'ALTER TABLE app.orders ADD CONSTRAINT uq_code UNIQUE (code, site)',
        'oracle': 'ALTER TABLE "app"."orders" ADD CONSTRAINT "uq_code" UNIQUE ("code", "site")',
        'db2': 'ALTER TABLE "app"."orders" ADD CONSTRAINT "uq_code" UNIQUE ("code", "site")',
        'sqlite': note('ricostruire la tabella'),
        'firebird': 'ALTER TABLE "app"."orders" ADD CONSTRAINT "uq_code" UNIQUE ("code", "site")',
        'snowflake': 'ALTER TABLE "app"."orders" ADD CONSTRAINT "uq_code" UNIQUE ("code", "site")',
      });
      expectPerFamily((d) => DdlBuilder(d).dropUnique(t, u), {
        'pg': 'ALTER TABLE app.orders DROP CONSTRAINT uq_code',
        'mssql': 'ALTER TABLE app.orders DROP CONSTRAINT uq_code',
        'mysql': 'ALTER TABLE app.orders DROP INDEX uq_code',
        'mariadb': 'ALTER TABLE app.orders DROP INDEX uq_code',
        'oracle': 'ALTER TABLE "app"."orders" DROP CONSTRAINT "uq_code"',
        'db2': 'ALTER TABLE "app"."orders" DROP CONSTRAINT "uq_code"',
        'sqlite': note('ricostruire la tabella'),
        'firebird': 'ALTER TABLE "app"."orders" DROP CONSTRAINT "uq_code"',
        'snowflake': 'ALTER TABLE "app"."orders" DROP CONSTRAINT "uq_code"',
      });
    });

    test('add CHECK without validating the existing rows', () {
      final warned = [
        allOf(startsWith('--'), contains('i dati esistenti vengono verificati')),
        'ALTER TABLE app.orders ADD CONSTRAINT ck_qty CHECK (qty > 0)',
      ];
      expectPerFamily((d) => DdlBuilder(d).addCheck(t, check, noValidate: true), {
        'pg': 'ALTER TABLE app.orders ADD CONSTRAINT ck_qty CHECK (qty > 0) NOT VALID',
        'mssql': 'ALTER TABLE app.orders WITH NOCHECK ADD CONSTRAINT ck_qty CHECK (qty > 0)',
        'mysql': warned,
        'mariadb': warned,
        'oracle': 'ALTER TABLE "app"."orders" ADD CONSTRAINT "ck_qty" CHECK (qty > 0) ENABLE NOVALIDATE',
        'db2': 'ALTER TABLE "app"."orders" ADD CONSTRAINT "ck_qty" CHECK (qty > 0) NOT ENFORCED',
        'sqlite': note('ricostruire la tabella'),
        'firebird': [
          allOf(startsWith('--'), contains('i dati esistenti vengono verificati')),
          'ALTER TABLE "app"."orders" ADD CONSTRAINT "ck_qty" CHECK (qty > 0)',
        ],
        'snowflake': note(_notSupported),
      });
      expectPerFamily((d) => DdlBuilder(d).dropCheck(t, check), {
        'pg': 'ALTER TABLE app.orders DROP CONSTRAINT ck_qty',
        'mssql': 'ALTER TABLE app.orders DROP CONSTRAINT ck_qty',
        'mysql': 'ALTER TABLE app.orders DROP CHECK ck_qty',
        'mariadb': 'ALTER TABLE app.orders DROP CONSTRAINT ck_qty',
        'oracle': 'ALTER TABLE "app"."orders" DROP CONSTRAINT "ck_qty"',
        'db2': 'ALTER TABLE "app"."orders" DROP CONSTRAINT "ck_qty"',
        'sqlite': note('ricostruire la tabella'),
        'firebird': 'ALTER TABLE "app"."orders" DROP CONSTRAINT "ck_qty"',
        'snowflake': 'ALTER TABLE "app"."orders" DROP CONSTRAINT "ck_qty"',
      });
    });

    test('foreign key options follow the DBMS', () {
      final full = fk.copyWith(
        onDelete: FkRule.setDefault,
        onUpdate: FkRule.cascade,
        match: FkMatch.full,
        state: const ConstraintState(deferrable: true, initiallyDeferred: true),
      );
      final my = [
        allOf(startsWith('--'), contains('i dati esistenti vengono verificati')),
        'ALTER TABLE app.orders ADD CONSTRAINT fk_c FOREIGN KEY (cid) REFERENCES app.customers (id) ON UPDATE CASCADE',
      ];
      expectPerFamily((d) => DdlBuilder(d).addForeignKey(t, full, noValidate: true), {
        'pg':
            'ALTER TABLE app.orders ADD CONSTRAINT fk_c FOREIGN KEY (cid) REFERENCES app.customers (id) MATCH FULL '
            'ON DELETE SET DEFAULT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED NOT VALID',
        'mssql':
            'ALTER TABLE app.orders WITH NOCHECK ADD CONSTRAINT fk_c FOREIGN KEY (cid) REFERENCES app.customers (id) '
            'ON DELETE SET DEFAULT ON UPDATE CASCADE',
        'mysql': my,
        'mariadb': my,
        'oracle':
            'ALTER TABLE "app"."orders" ADD CONSTRAINT "fk_c" FOREIGN KEY ("cid") REFERENCES "app"."customers" ("id") '
            'DEFERRABLE INITIALLY DEFERRED ENABLE NOVALIDATE',
        'db2':
            'ALTER TABLE "app"."orders" ADD CONSTRAINT "fk_c" FOREIGN KEY ("cid") REFERENCES "app"."customers" ("id") '
            'NOT ENFORCED',
        'sqlite': note('ricostruire la tabella'),
        'firebird': [
          allOf(startsWith('--'), contains('i dati esistenti vengono verificati')),
          'ALTER TABLE "app"."orders" ADD CONSTRAINT "fk_c" FOREIGN KEY ("cid") REFERENCES "app"."customers" ("id") '
              'ON DELETE SET DEFAULT ON UPDATE CASCADE',
        ],
        'snowflake':
            'ALTER TABLE "app"."orders" ADD CONSTRAINT "fk_c" FOREIGN KEY ("cid") REFERENCES "app"."customers" ("id") '
            'ON DELETE SET DEFAULT ON UPDATE CASCADE',
      });
    });

    test('rename a constraint, with drop and add where RENAME CONSTRAINT is missing', () {
      expectPerFamily((d) => DdlBuilder(d).renameConstraint(t, fk, 'fk_new'), {
        'pg': 'ALTER TABLE app.orders RENAME CONSTRAINT fk_c TO fk_new',
        'mssql': "EXEC sp_rename N'app.fk_c', N'fk_new', N'OBJECT'",
        'mysql': [
          'ALTER TABLE app.orders DROP FOREIGN KEY fk_c',
          'ALTER TABLE app.orders ADD CONSTRAINT fk_new FOREIGN KEY (cid) REFERENCES app.customers (id)',
        ],
        'mariadb': [
          'ALTER TABLE app.orders DROP FOREIGN KEY fk_c',
          'ALTER TABLE app.orders ADD CONSTRAINT fk_new FOREIGN KEY (cid) REFERENCES app.customers (id)',
        ],
        'oracle': 'ALTER TABLE "app"."orders" RENAME CONSTRAINT "fk_c" TO "fk_new"',
        'db2': [
          'ALTER TABLE "app"."orders" DROP CONSTRAINT "fk_c"',
          'ALTER TABLE "app"."orders" ADD CONSTRAINT "fk_new" FOREIGN KEY ("cid") REFERENCES "app"."customers" ("id")',
        ],
        'sqlite': note('ricostruire la tabella'),
        'firebird': [
          'ALTER TABLE "app"."orders" DROP CONSTRAINT "fk_c"',
          'ALTER TABLE "app"."orders" ADD CONSTRAINT "fk_new" FOREIGN KEY ("cid") REFERENCES "app"."customers" ("id")',
        ],
        'snowflake': 'ALTER TABLE "app"."orders" RENAME CONSTRAINT "fk_c" TO "fk_new"',
      });
      expect(
        DdlBuilder(sqlDialects['mysql']!)
            .renameConstraint(t, const PrimaryKeyDef(name: 'PRIMARY', columns: ['id']), 'pk'),
        note('PRIMARY'),
      );
    });

    test('disable, enable and validate', () {
      expectPerFamily((d) => DdlBuilder(d).setConstraintEnabled(t, check, false), {
        'pg': note('NOT VALID'),
        'mssql': 'ALTER TABLE app.orders NOCHECK CONSTRAINT ck_qty',
        'mysql': note(_notSupported),
        'mariadb': note(_notSupported),
        'oracle': 'ALTER TABLE "app"."orders" DISABLE CONSTRAINT "ck_qty"',
        'db2': 'ALTER TABLE "app"."orders" ALTER CHECK "ck_qty" NOT ENFORCED',
        'sqlite': note(_notSupported),
        'firebird': note(_notSupported),
        'snowflake': note('non applica i vincoli'),
      });
      expectPerFamily((d) => DdlBuilder(d).setConstraintEnabled(t, fk, true, validate: false), {
        'pg': note('NOT VALID'),
        'mssql': 'ALTER TABLE app.orders CHECK CONSTRAINT fk_c',
        'mysql': note(_notSupported),
        'mariadb': note(_notSupported),
        'oracle': 'ALTER TABLE "app"."orders" ENABLE NOVALIDATE CONSTRAINT "fk_c"',
        'db2': 'ALTER TABLE "app"."orders" ALTER FOREIGN KEY "fk_c" ENFORCED',
        'sqlite': note(_notSupported),
        'firebird': note(_notSupported),
        'snowflake': note('non applica i vincoli'),
      });
      expectPerFamily((d) => DdlBuilder(d).validateConstraint(t, fk), {
        'pg': 'ALTER TABLE app.orders VALIDATE CONSTRAINT fk_c',
        'mssql': 'ALTER TABLE app.orders WITH CHECK CHECK CONSTRAINT fk_c',
        'mysql': note(_notSupported),
        'mariadb': note(_notSupported),
        'oracle': 'ALTER TABLE "app"."orders" ENABLE VALIDATE CONSTRAINT "fk_c"',
        'db2': 'ALTER TABLE "app"."orders" ALTER FOREIGN KEY "fk_c" ENFORCED',
        'sqlite': note(_notSupported),
        'firebird': note(_notSupported),
        'snowflake': note(_notSupported),
      });
      // SQL Server and Db2 only disable foreign keys and checks.
      const pk = PrimaryKeyDef(name: 'pk_orders', columns: ['id']);
      expect(DdlBuilder(sqlDialects['mssql']!).setConstraintEnabled(t, pk, false), note('SQL Server'));
      expect(DdlBuilder(sqlDialects['oracle']!).setConstraintEnabled(t, pk, false), [
        'ALTER TABLE "app"."orders" DISABLE CONSTRAINT "pk_orders"',
      ]);
    });

    test('create table with UNIQUE, CHECK and a disabled constraint', () {
      final def = t.copyWith(
        primaryKey: const PrimaryKeyDef(name: 'pk_orders', columns: ['id'], clustered: false),
        uniques: const [
          UniqueDef(name: 'uq_qty', columns: ['qty']),
        ],
        checks: const [CheckDef(name: 'ck_qty', expression: 'qty > 0', state: ConstraintState(enabled: false))],
      );
      const plain =
          'CREATE TABLE app.orders (\n'
          '\tid integer NOT NULL,\n'
          '\tqty integer,\n'
          '\tCONSTRAINT pk_orders PRIMARY KEY (id),\n'
          '\tCONSTRAINT uq_qty UNIQUE (qty),\n'
          '\tCONSTRAINT ck_qty CHECK (qty > 0)\n'
          ')';
      const quoted =
          'CREATE TABLE "app"."orders" (\n'
          '\t"id" integer NOT NULL,\n'
          '\t"qty" integer,\n'
          '\tCONSTRAINT "pk_orders" PRIMARY KEY ("id"),\n'
          '\tCONSTRAINT "uq_qty" UNIQUE ("qty"),\n'
          '\tCONSTRAINT "ck_qty" CHECK (qty > 0)\n'
          ')';
      expectPerFamily((d) => DdlBuilder(d).createTable(def), {
        'pg': plain,
        'mssql': [
          plain.replaceFirst('PRIMARY KEY (id)', 'PRIMARY KEY NONCLUSTERED (id)'),
          'ALTER TABLE app.orders NOCHECK CONSTRAINT ck_qty',
        ],
        'mysql': plain,
        'mariadb': plain,
        'oracle': [quoted, 'ALTER TABLE "app"."orders" DISABLE CONSTRAINT "ck_qty"'],
        'db2': [quoted, 'ALTER TABLE "app"."orders" ALTER CHECK "ck_qty" NOT ENFORCED'],
        'sqlite': plain,
        'firebird': quoted,
        'snowflake': [
          allOf(startsWith('--'), contains('ck_qty')),
          quoted.replaceFirst(',\n\tCONSTRAINT "ck_qty" CHECK (qty > 0)', ''),
        ],
      });
    });

    test('table options', () {
      final def = t.copyWith(
        options: {'engine': 'InnoDB', 'charset': 'utf8mb4', 'unlogged': 'true', 'filegroup': 'fg'},
      );
      expect(
        DdlBuilder(sqlDialects['mysql']!).createTable(def).single,
        endsWith(') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4'),
      );
      expect(DdlBuilder(sqlDialects['pg']!).createTable(def).single, startsWith('CREATE UNLOGGED TABLE'));
      expect(DdlBuilder(sqlDialects['mssql']!).createTable(def).single, endsWith(') ON fg'));
    });
  });

  group('indexes', () {
    test('every option, or a note where it is not supported', () {
      const full = IndexDef(
        name: 'ix_o',
        columns: ['qty', 'id'],
        descending: {'qty'},
        include: ['note'],
        where: 'qty > 0',
        unique: true,
      );
      Matcher noted(int notes, String statement) => allOf(
        hasLength(notes + 1),
        predicate<List<String>>((l) => l.take(notes).every((s) => s.startsWith('--')) && l.last == statement),
      );
      expectPerFamily((d) => DdlBuilder(d).createIndex(t, full), {
        'pg': 'CREATE UNIQUE INDEX ix_o ON app.orders (qty DESC, id) INCLUDE (note) WHERE qty > 0',
        'mssql': 'CREATE UNIQUE INDEX ix_o ON app.orders (qty DESC, id) INCLUDE (note) WHERE qty > 0',
        'mysql': noted(2, 'CREATE UNIQUE INDEX ix_o ON app.orders (qty DESC, id)'),
        'mariadb': noted(2, 'CREATE UNIQUE INDEX ix_o ON app.orders (qty DESC, id)'),
        'oracle': noted(2, 'CREATE UNIQUE INDEX "app"."ix_o" ON "app"."orders" ("qty" DESC, "id")'),
        'db2': noted(1, 'CREATE UNIQUE INDEX "app"."ix_o" ON "app"."orders" ("qty" DESC, "id") INCLUDE ("note")'),
        'sqlite': noted(1, 'CREATE UNIQUE INDEX ix_o ON app.orders (qty DESC, id) WHERE qty > 0'),
        'firebird': noted(2, 'CREATE UNIQUE INDEX "ix_o" ON "app"."orders" ("qty", "id") WHERE qty > 0'),
        'snowflake': note('non ha indici'),
      });
    });

    test('expressions and online creation', () {
      const expr = IndexDef(name: 'ix_l', columns: ['(lower(code))']);
      Matcher noted(String statement) => allOf(hasLength(2), predicate<List<String>>((l) => l.last == statement));
      expectPerFamily((d) => DdlBuilder(d).createIndex(t, expr, online: true), {
        'pg': 'CREATE INDEX CONCURRENTLY ix_l ON app.orders ((lower(code)))',
        'mssql': note('colonna calcolata'),
        'mysql': 'CREATE INDEX ix_l ON app.orders ((lower(code))) ALGORITHM=INPLACE LOCK=NONE',
        'mariadb': 'CREATE INDEX ix_l ON app.orders ((lower(code))) ALGORITHM=INPLACE LOCK=NONE',
        'oracle': 'CREATE INDEX "app"."ix_l" ON "app"."orders" (lower(code)) ONLINE',
        'db2': noted('CREATE INDEX "app"."ix_l" ON "app"."orders" (lower(code))'),
        'sqlite': noted('CREATE INDEX ix_l ON app.orders ((lower(code)))'),
        'firebird': noted('CREATE INDEX "ix_l" ON "app"."orders" COMPUTED BY (lower(code))'),
        'snowflake': note('non ha indici'),
      });
      expect(
        DdlBuilder(sqlDialects['pg']!).createIndex(t, const IndexDef(name: 'g', columns: ['tags'], method: 'gin')),
        ['CREATE INDEX g ON app.orders USING gin (tags)'],
      );
      expect(
        DdlBuilder(sqlDialects['oracle']!)
            .createIndex(t, const IndexDef(name: 'b', columns: ['qty'], method: 'bitmap')),
        ['CREATE BITMAP INDEX "app"."b" ON "app"."orders" ("qty")'],
      );
      expect(
        DdlBuilder(sqlDialects['mssql']!).createIndex(t, const IndexDef(name: 'c', columns: ['qty'], clustered: true)),
        ['CREATE CLUSTERED INDEX c ON app.orders (qty)'],
      );
      expect(
        DdlBuilder(sqlDialects['firebird']!)
            .createIndex(t, const IndexDef(name: 'd', columns: ['qty'], descending: {'qty'})),
        ['CREATE DESCENDING INDEX "d" ON "app"."orders" ("qty")'],
      );
    });

    test('rename, rebuild, disable', () {
      expectPerFamily((d) => DdlBuilder(d).renameIndex(t, ix, 'ix_p'), {
        'pg': 'ALTER INDEX app.ix_o RENAME TO ix_p',
        'mssql': "EXEC sp_rename N'app.orders.ix_o', N'ix_p', N'INDEX'",
        'mysql': 'ALTER TABLE app.orders RENAME INDEX ix_o TO ix_p',
        'mariadb': 'ALTER TABLE app.orders RENAME INDEX ix_o TO ix_p',
        'oracle': 'ALTER INDEX "app"."ix_o" RENAME TO "ix_p"',
        'db2': 'RENAME INDEX "app"."ix_o" TO "ix_p"',
        'sqlite': ['DROP INDEX app.ix_o', 'CREATE INDEX ix_p ON app.orders (qty)'],
        'firebird': ['DROP INDEX "ix_o"', 'CREATE INDEX "ix_p" ON "app"."orders" ("qty")'],
        'snowflake': note('non ha indici'),
      });
      expect(DdlBuilder(dialectAt('mariadb', '10.4.0-MariaDB')).renameIndex(t, ix, 'ix_p'), [
        'DROP INDEX ix_o ON app.orders',
        'CREATE INDEX ix_p ON app.orders (qty)',
      ]);
      final optimize = [startsWith('--'), 'OPTIMIZE TABLE app.orders'];
      expectPerFamily((d) => DdlBuilder(d).rebuildIndex(t, ix), {
        'pg': 'REINDEX INDEX app.ix_o',
        'mssql': 'ALTER INDEX ix_o ON app.orders REBUILD',
        'mysql': optimize,
        'mariadb': optimize,
        'oracle': 'ALTER INDEX "app"."ix_o" REBUILD',
        'db2': "CALL SYSPROC.ADMIN_CMD('REORG INDEXES ALL FOR TABLE \"app\".\"orders\"')",
        'sqlite': 'REINDEX app.ix_o',
        'firebird': 'ALTER INDEX "ix_o" ACTIVE',
        'snowflake': note(_notSupported),
      });
      expectPerFamily((d) => DdlBuilder(d).setIndexEnabled(t, ix, false), {
        'pg': note(_notSupported),
        'mssql': 'ALTER INDEX ix_o ON app.orders DISABLE',
        'mysql': 'ALTER TABLE app.orders ALTER INDEX ix_o INVISIBLE',
        'mariadb': 'ALTER TABLE app.orders ALTER INDEX ix_o IGNORED',
        'oracle': 'ALTER INDEX "app"."ix_o" UNUSABLE',
        'db2': note(_notSupported),
        'sqlite': note(_notSupported),
        'firebird': 'ALTER INDEX "ix_o" INACTIVE',
        'snowflake': note('non ha indici'),
      });
    });
  });

  group('columns', () {
    test('collation, computed and identity options', () {
      const columns = [
        ColumnDef(name: 'code', type: 'varchar', size: 20, collation: 'C', nullable: false),
        ColumnDef(name: 'total', type: 'numeric', size: 10, scale: 2, computed: 'qty * price'),
        ColumnDef(
          name: 'n',
          type: 'integer',
          autoIncrement: true,
          identitySeed: 100,
          identityIncrement: 10,
          nullable: false,
        ),
      ];
      expectPerFamily((d) => [for (final c in columns) DdlBuilder(d).columnDefinition(c)], {
        'pg': [
          'code varchar(20) COLLATE "C" NOT NULL',
          'total numeric(10,2) GENERATED ALWAYS AS (qty * price) STORED',
          'n integer GENERATED BY DEFAULT AS IDENTITY (START WITH 100 INCREMENT BY 10) NOT NULL',
        ],
        'mssql': [
          'code varchar(20) COLLATE C NOT NULL',
          'total AS (qty * price) PERSISTED',
          'n integer IDENTITY(100,10) NOT NULL',
        ],
        'mysql': [
          'code varchar(20) COLLATE C NOT NULL',
          'total numeric(10,2) GENERATED ALWAYS AS (qty * price) STORED',
          'n integer NOT NULL AUTO_INCREMENT',
        ],
        'mariadb': [
          'code varchar(20) COLLATE C NOT NULL',
          'total numeric(10,2) GENERATED ALWAYS AS (qty * price) STORED',
          'n integer NOT NULL AUTO_INCREMENT',
        ],
        'oracle': [
          '"code" varchar(20) COLLATE C NOT NULL',
          '"total" numeric(10,2) GENERATED ALWAYS AS (qty * price) VIRTUAL',
          '"n" integer GENERATED BY DEFAULT AS IDENTITY (START WITH 100 INCREMENT BY 10) NOT NULL',
        ],
        'db2': [
          '"code" varchar(20) NOT NULL',
          '"total" numeric(10,2) GENERATED ALWAYS AS (qty * price)',
          '"n" integer GENERATED BY DEFAULT AS IDENTITY (START WITH 100 INCREMENT BY 10) NOT NULL',
        ],
        'sqlite': [
          'code varchar(20) COLLATE C NOT NULL',
          'total numeric(10,2) GENERATED ALWAYS AS (qty * price) STORED',
          'n integer NOT NULL',
        ],
        'firebird': [
          '"code" varchar(20) NOT NULL COLLATE C',
          '"total" numeric(10,2) COMPUTED BY (qty * price)',
          '"n" integer GENERATED BY DEFAULT AS IDENTITY (START WITH 100 INCREMENT BY 10) NOT NULL',
        ],
        'snowflake': [
          '"code" varchar(20) COLLATE \'C\' NOT NULL',
          '"total" numeric(10,2) AS (qty * price)',
          '"n" integer AUTOINCREMENT START 100 INCREMENT 10 NOT NULL',
        ],
      });
      // A named SQL Server default.
      expect(
        DdlBuilder(sqlDialects['mssql']!)
            .columnDefinition(const ColumnDef(name: 'a', type: 'bit', defaultValue: '0', defaultName: 'df_a')),
        'a bit CONSTRAINT df_a DEFAULT 0',
      );
    });

    test('add identity to an existing column', () {
      const from = ColumnDef(name: 'id', type: 'integer', nullable: false);
      final to = from.copyWith(autoIncrement: true);
      expectPerFamily((d) => DdlBuilder(d).alterColumn(t, from, to), {
        'pg': 'ALTER TABLE app.orders ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY',
        'mssql': note('ricreare la colonna'),
        'mysql': 'ALTER TABLE app.orders MODIFY COLUMN id integer NOT NULL AUTO_INCREMENT',
        'mariadb': 'ALTER TABLE app.orders MODIFY COLUMN id integer NOT NULL AUTO_INCREMENT',
        'oracle': 'ALTER TABLE "app"."orders" MODIFY ("id" GENERATED BY DEFAULT AS IDENTITY)',
        'db2': 'ALTER TABLE "app"."orders" ALTER COLUMN "id" SET GENERATED BY DEFAULT AS IDENTITY',
        'sqlite': allOf(hasLength(2), everyElement(startsWith('--'))),
        'firebird': note('ricreare la colonna'),
        'snowflake': note('ricreare la colonna'),
      });
      expect(DdlBuilder(sqlDialects['pg']!).alterColumn(t, to, from), [
        'ALTER TABLE app.orders ALTER COLUMN id DROP IDENTITY IF EXISTS',
      ]);
      expect(DdlBuilder(dialectAt('oracle', '11.2.0')).alterColumn(t, from, to), note('ricreare la colonna'));
    });

    test('collation change and computed columns recreated', () {
      const from = ColumnDef(name: 'code', type: 'varchar', size: 20);
      final to = from.copyWith(collation: 'C');
      expectPerFamily((d) => DdlBuilder(d).alterColumn(t, from, to), {
        'pg': 'ALTER TABLE app.orders ALTER COLUMN code TYPE varchar(20) COLLATE "C"',
        'mssql': 'ALTER TABLE app.orders ALTER COLUMN code varchar(20) COLLATE C NULL',
        'mysql': 'ALTER TABLE app.orders MODIFY COLUMN code varchar(20) COLLATE C',
        'mariadb': 'ALTER TABLE app.orders MODIFY COLUMN code varchar(20) COLLATE C',
        'oracle': 'ALTER TABLE "app"."orders" MODIFY ("code" COLLATE C)',
        'db2': note(_notSupported),
        'sqlite': note(_notSupported),
        'firebird': note(_notSupported),
        'snowflake': note(_notSupported),
      });
      const c1 = ColumnDef(name: 'total', type: 'integer', computed: 'qty * 2');
      expect(DdlBuilder(sqlDialects['mssql']!).alterColumn(t, c1, c1.copyWith(computed: 'qty * 3')), [
        'ALTER TABLE app.orders DROP COLUMN total',
        'ALTER TABLE app.orders ADD total AS (qty * 3) PERSISTED',
      ]);
      // A regular column becoming computed loses its data: say so.
      final out = DdlBuilder(sqlDialects['pg']!).alterColumn(t, const ColumnDef(name: 'total', type: 'integer'), c1);
      expect(out.first, allOf(startsWith('--'), contains('vanno persi')));
      expect(out.sublist(1), [
        'ALTER TABLE app.orders DROP COLUMN total',
        'ALTER TABLE app.orders ADD COLUMN total integer GENERATED ALWAYS AS (qty * 2) STORED',
      ]);
    });
  });

  group('names', () {
    test('automatic names follow the convention and the length limits', () {
      final b = DdlBuilder(sqlDialects['pg']!);
      expect(b.autoName(t, ConstraintKind.primaryKey), 'pk_orders');
      expect(b.autoName(t, ConstraintKind.unique, columns: ['code', 'site']), 'uq_orders_code_site');
      expect(b.autoName(t, ConstraintKind.check, n: 2), 'ck_orders_2');
      expect(b.autoName(t, ConstraintKind.foreignKey, refTable: 'customers'), 'fk_orders_customers');
      expect(b.autoName(t, null, columns: ['qty']), 'ix_orders_qty');
      expect(b.autoName(t.copyWith(name: 'righe ordine'), null, columns: ['q']), 'ix_righe_ordine_q');
      final long = t.copyWith(name: 'a_very_long_table_name_for_orders');
      final ora11 = DdlBuilder(dialectAt('oracle', '12.1.0'))
          .autoName(long, null, columns: ['customer_id', 'created_at']);
      expect(ora11.length, 30);
      expect(ora11, startsWith('ix_a_very_long_table_nam_'));
      expect(
        DdlBuilder(dialectAt('oracle', '12.1.0')).autoName(long, null, columns: ['customer_id', 'x']),
        isNot(ora11),
      );
      expect(DdlBuilder(sqlDialects['oracle']!).autoName(long, null, columns: ['customer_id']).length, lessThan(128));
      final custom = DdlBuilder(sqlDialects['pg']!, naming: const NamingConvention(index: 'idx_'));
      expect(custom.autoName(t, null, columns: ['qty']), 'idx_orders_qty');
    });

    test('expressions compare across the DBMS spellings', () {
      for (final e in [
        '([qty]>(0))', // SQL Server
        '(qty > 0)', // PostgreSQL
        '(`qty` > 0)', // MySQL
        'qty > 0',
        '"QTY" > 0',
      ]) {
        expect(normalizeExpression(e), 'qty>0', reason: e);
      }
      expect(normalizeExpression("((status)::text = 'A'::text)"), "status='A'");
      expect(normalizeExpression('lower(email)'), 'lower(email)');
      expect(normalizeExpression("name <> 'A  B'"), "name<>'A  B'");
    });
  });
}
