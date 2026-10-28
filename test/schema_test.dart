import 'package:dbcraft/features/design/ui/constraint_dialogs.dart';
import 'package:dbcraft/features/schema/ddl_builder.dart';
import 'package:dbcraft/features/schema/ddl_execution.dart';
import 'package:dbcraft/features/schema/erd_dialogs.dart';
import 'package:dbcraft/features/schema/schema_compare_view.dart';
import 'package:dbcraft/features/schema/schema_diff.dart';
import 'package:dbcraft/features/schema/schema_migration.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/features/schema/schema_snapshot.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/services/metadata_service.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:dbcraft/ui/editors/er_diagram_view.dart';
import 'package:dbcraft/ui/editors/sql_code_editor.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final pg = SqlDialect(dbmsName: 'PostgreSQL');
final mssql = SqlDialect(dbmsName: 'Microsoft SQL Server', quote: '[');
final mysql = SqlDialect(dbmsName: 'MySQL', quote: '`');
final oracle = SqlDialect(dbmsName: 'Oracle');
final sqlite = SqlDialect(dbmsName: 'SQLite');
final db2 = SqlDialect(dbmsName: 'DB2/LINUXX8664');
final firebird = SqlDialect(dbmsName: 'Firebird');

const customers = TableDef(
  schema: 'app',
  name: 'customers',
  columns: [
    ColumnDef(name: 'id', type: 'integer', nullable: false, autoIncrement: true),
    ColumnDef(name: 'name', type: 'varchar', size: 100, nullable: false),
    ColumnDef(name: 'active', type: 'boolean', defaultValue: 'true'),
  ],
  primaryKey: PrimaryKeyDef(name: 'pk_customers', columns: ['id']),
);

const orders = TableDef(
  schema: 'app',
  name: 'orders',
  columns: [
    ColumnDef(name: 'id', type: 'integer', nullable: false),
    ColumnDef(name: 'customer_id', type: 'integer', nullable: false),
    ColumnDef(name: 'total', type: 'numeric', size: 10, scale: 2),
  ],
  primaryKey: PrimaryKeyDef(columns: ['id']),
  foreignKeys: [
    ForeignKeyDef(
      name: 'fk_orders_customers',
      columns: ['customer_id'],
      refSchema: 'app',
      refTable: 'customers',
      refColumns: ['id'],
      onDelete: FkRule.cascade,
    ),
  ],
  indexes: [
    IndexDef(name: 'ix_orders_customer', columns: ['customer_id']),
  ],
);

/// In-memory catalog: customers(id pk, name) and orders(id pk, customer_id fk).
class FakeSession implements DbSession {
  FakeSession({this.variant = false});

  /// Variant schema: no orders table, customers.name is varchar(50) and has
  /// an extra column.
  final bool variant;
  final executed = <String>[];

  List<Object?> col(String t, String c, String type, int pos, {bool nullable = true}) => [
    null,
    'app',
    t,
    c,
    4,
    type,
    10,
    null,
    0,
    10,
    nullable ? 1 : 0,
    null,
    null,
    null,
    null,
    null,
    pos,
    null,
  ];

  @override
  Future<ResultPage> catalog(String function, List<String?> args) async {
    switch (function) {
      case 'tables':
        return catalogResult(CatalogColumns.tables, [
          [null, 'app', 'customers', 'TABLE', null],
          if (!variant) [null, 'app', 'orders', 'TABLE', null],
        ]);
      case 'columns':
        final t = args[2];
        return catalogResult(CatalogColumns.columns, [
          if (t == 'customers') ...[
            col('customers', 'id', 'int4', 1, nullable: false),
            col('customers', 'name', 'varchar', 2),
            if (variant) col('customers', 'legacy', 'text', 3),
          ],
          if (t == 'orders') ...[
            col('orders', 'id', 'int4', 1, nullable: false),
            col('orders', 'customer_id', 'int4', 2),
          ],
        ]);
      case 'primaryKeys':
        return catalogResult(CatalogColumns.primaryKeys, [
          [null, 'app', args[2], 'id', 1, '${args[2]}_pkey'],
        ]);
      case 'foreignKeys':
        if (args[5] != 'orders') return catalogResult(CatalogColumns.foreignKeys, []);
        return catalogResult(CatalogColumns.foreignKeys, [
          [
            null,
            'app',
            'customers',
            'id',
            null,
            'app',
            'orders',
            'customer_id',
            1,
            3,
            3,
            'fk_orders_customers',
            null,
            7,
          ],
        ]);
      default:
        return catalogResult(CatalogColumns.statistics, []);
    }
  }

  @override
  Future<ResultPage> execute(
    String sql, {
    List<Object?> params = const [],
    int fetchSize = 200,
    int queryTimeoutSec = 0,
  }) async {
    executed.add(sql);
    return ResultPage(columns: const [], rows: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DbConnection fakeConnection(FakeSession s, {String name = 'Fake'}) {
  final dc = DbConnection(ConnectionConfig(id: name, name: name))
    ..status = ConnectionStatus.connected
    ..main = s
    ..meta = s;
  dc.metadata = MetadataService(s, {'dbmsName': 'PostgreSQL', 'identifierQuote': '"', 'schemaUsage': 1});
  return dc;
}

SchemaSnapshot snap(List<TableDef> tables, {String? schema = 'app', DbFamily family = DbFamily.postgres}) =>
    SchemaSnapshot(schema: schema, tables: tables, family: family);

void main() {
  group('schema model', () {
    test('canonical types', () {
      expect(canonicalType('int4'), 'integer');
      expect(canonicalType('INT'), 'integer');
      expect(canonicalType('int identity'), 'integer');
      expect(canonicalType('character varying'), 'varchar');
      expect(canonicalType('VARCHAR2'), 'varchar');
      expect(canonicalType('timestamp(6) without time zone'), 'timestamp');
      expect(canonicalType('int unsigned'), 'integer unsigned');
      expect(canonicalType('geometry'), 'geometry');
    });

    test('default normalization', () {
      expect(normalizeDefault('((0))'), '0');
      expect(normalizeDefault("'abc'::character varying"), "'abc'");
      expect(normalizeDefault('NULL'), isNull);
      expect(normalizeDefault('(getdate())'), 'getdate()');
      expect(normalizeDefault('CURRENT_TIMESTAMP'), 'current_timestamp');
    });

    test('from metadata', () {
      final t = TableDef.fromMetadata(
        DbTable(catalog: null, schema: 'dbo', name: 't', type: 'TABLE'),
        [
          DbColumn(
            name: 'id',
            dataType: 4,
            typeName: 'int identity',
            size: 10,
            decimals: 0,
            nullable: false,
            position: 1,
          ),
          DbColumn(
            name: 'v',
            dataType: 12,
            typeName: 'varchar',
            size: 2147483647,
            decimals: null,
            nullable: true,
            position: 2,
          ),
          DbColumn(
            name: 's',
            dataType: 4,
            typeName: 'int4',
            size: 10,
            decimals: 0,
            nullable: false,
            position: 3,
            defaultValue: "nextval('s_seq'::regclass)",
          ),
          DbColumn(name: 'p', dataType: 3, typeName: 'numeric', size: 12, decimals: 3, nullable: true, position: 4),
        ],
        primaryKey: DbPrimaryKey('PK_t', ['id']),
        indexes: [
          DbIndex(name: 'PK_t', unique: true, columns: ['id']),
          DbIndex(name: 'ix_v', unique: false, columns: ['v']),
        ],
      );
      expect(t.columns[0].type, 'int');
      expect(t.columns[0].autoIncrement, isTrue);
      expect(t.columns[0].size, isNull);
      expect(t.columns[1].size, -1);
      expect(t.columns[1].fullType, 'varchar(MAX)');
      expect(t.columns[2].autoIncrement, isTrue);
      expect(t.columns[2].defaultValue, isNull);
      expect(t.columns[3].fullType, 'numeric(12,3)');
      expect(t.indexes.map((e) => e.name), ['ix_v']);
    });

    test('type mapping across dialects', () {
      const c = ColumnDef(name: 'a', type: 'int4');
      expect(mapColumnType(c, DbFamily.postgres, DbFamily.sqlServer).type, 'int');
      expect(mapColumnType(c, DbFamily.postgres, DbFamily.oracle).fullType, 'NUMBER(10)');
      const v = ColumnDef(name: 'b', type: 'character varying', size: 20);
      expect(mapColumnType(v, DbFamily.postgres, DbFamily.oracle).fullType, 'VARCHAR2(20)');
      expect(
        mapColumnType(const ColumnDef(name: 'x', type: 'bool'), DbFamily.postgres, DbFamily.mysql).fullType,
        'tinyint(1)',
      );
      expect(
        mapColumnType(const ColumnDef(name: 'x', type: 'text'), DbFamily.postgres, DbFamily.sqlServer).fullType,
        'nvarchar(MAX)',
      );
      expect(mapColumnType(c, DbFamily.postgres, DbFamily.postgres), same(c));
    });
  });

  group('DdlBuilder', () {
    test('create table per dialect', () {
      expect(
        DdlBuilder(pg).createTable(customers).single,
        'CREATE TABLE app.customers (\n'
        '\tid integer GENERATED BY DEFAULT AS IDENTITY NOT NULL,\n'
        '\tname varchar(100) NOT NULL,\n'
        '\tactive boolean DEFAULT true,\n'
        '\tCONSTRAINT pk_customers PRIMARY KEY (id)\n'
        ')',
      );
      final ms = DdlBuilder(mssql).createTable(customers).single;
      expect(ms, contains('id integer IDENTITY(1,1) NOT NULL'));
      final my = DdlBuilder(mysql).createTable(customers).single;
      expect(my, contains('id integer NOT NULL AUTO_INCREMENT'));
      final lite = DdlBuilder(sqlite).createTable(customers).single;
      expect(lite, contains('id INTEGER PRIMARY KEY AUTOINCREMENT'));
      expect(lite, isNot(contains('CONSTRAINT pk_customers')));
      final ora = DdlBuilder(oracle).createTable(customers).single;
      expect(ora, contains('"id" integer GENERATED BY DEFAULT AS IDENTITY NOT NULL'));
    });

    test('create table with indexes, inline fks for sqlite and comments', () {
      final withComment = orders.copyWith(comment: 'Ordini');
      final p = DdlBuilder(pg).createTable(withComment);
      expect(p, hasLength(3));
      expect(p[0], isNot(contains('FOREIGN KEY')));
      expect(p[1], 'CREATE INDEX ix_orders_customer ON app.orders (customer_id)');
      expect(p[2], "COMMENT ON TABLE app.orders IS 'Ordini'");
      final s = DdlBuilder(sqlite).createTable(orders);
      expect(s[0], contains('FOREIGN KEY (customer_id) REFERENCES app.customers (id) ON DELETE CASCADE'));
      final m = DdlBuilder(mysql).createTable(withComment);
      expect(m[0], endsWith(") COMMENT='Ordini'"));
    });

    test('SQL Server fills a new nullable column with its default (D-019)', () {
      const note = ColumnDef(name: 'note', type: 'varchar', size: 200, defaultValue: "'n/d'");
      expect(DdlBuilder(mssql).addColumn(customers, note).single, endsWith("DEFAULT 'n/d' WITH VALUES"));
      expect(DdlBuilder(pg).addColumn(customers, note).single, isNot(contains('WITH VALUES')));
      expect(
        DdlBuilder(mssql).addColumn(customers, note.copyWith(defaultValue: null)).single,
        isNot(contains('WITH VALUES')),
      );
    });

    test('PostgreSQL never writes catalog.name without the schema (D-016)', () {
      expect(pg.qualified('dbcraft', null, 'dbc_menu'), 'dbc_menu');
      expect(pg.qualified('dbcraft', 'public', 'dbc_menu'), 'dbcraft.public.dbc_menu');
      expect(mysql.qualified('dbcraft', null, 't'), 'dbcraft.t');
    });

    test('rename table', () {
      expect(DdlBuilder(pg).renameTable(customers, 'clients'), ['ALTER TABLE app.customers RENAME TO clients']);
      expect(DdlBuilder(mssql).renameTable(customers, 'clients'), ["EXEC sp_rename N'app.customers', N'clients'"]);
      expect(DdlBuilder(mysql).renameTable(customers, 'clients'), ['RENAME TABLE app.customers TO app.clients']);
      expect(isCommentOnly(DdlBuilder(firebird).renameTable(customers, 'clients').single), isTrue);
    });

    test('add, drop and rename column', () {
      const c = ColumnDef(name: 'email', type: 'varchar', size: 200);
      expect(DdlBuilder(pg).addColumn(customers, c), ['ALTER TABLE app.customers ADD COLUMN email varchar(200)']);
      expect(DdlBuilder(mssql).addColumn(customers, c), ['ALTER TABLE app.customers ADD email varchar(200)']);
      expect(DdlBuilder(oracle).addColumn(customers, c), ['ALTER TABLE "app"."customers" ADD "email" varchar(200)']);
      final nn = DdlBuilder(pg).addColumn(customers, c.copyWith(nullable: false));
      expect(nn, hasLength(2));
      expect(isCommentOnly(nn.first), isTrue);
      expect(DdlBuilder(firebird).dropColumn(customers, 'name').single, contains(' DROP '));
      expect(DdlBuilder(pg).dropColumn(customers, 'name'), ['ALTER TABLE app.customers DROP COLUMN name']);
      expect(DdlBuilder(pg).renameColumn(customers, 'name', 'full_name'), [
        'ALTER TABLE app.customers RENAME COLUMN name TO full_name',
      ]);
      expect(DdlBuilder(mssql).renameColumn(customers, 'name', 'full_name'), [
        "EXEC sp_rename N'app.customers.name', N'full_name', 'COLUMN'",
      ]);
      expect(DdlBuilder(firebird).renameColumn(customers, 'name', 'full_name').single, contains('ALTER COLUMN'));
    });

    test('alter column per dialect', () {
      const from = ColumnDef(name: 'name', type: 'varchar', size: 100, nullable: true);
      final to = from.copyWith(size: 200, nullable: false, defaultValue: "'x'");
      expect(DdlBuilder(pg).alterColumn(customers, from, to), [
        'ALTER TABLE app.customers ALTER COLUMN name TYPE varchar(200) USING name::varchar(200)',
        'ALTER TABLE app.customers ALTER COLUMN name SET NOT NULL',
        "ALTER TABLE app.customers ALTER COLUMN name SET DEFAULT 'x'",
      ]);
      expect(DdlBuilder(mssql).alterColumn(customers, from, to), [
        'ALTER TABLE app.customers ALTER COLUMN name varchar(200) NOT NULL',
        "ALTER TABLE app.customers ADD DEFAULT 'x' FOR name",
      ]);
      expect(DdlBuilder(mysql).alterColumn(customers, from, to), [
        "ALTER TABLE app.customers MODIFY COLUMN name varchar(200) DEFAULT 'x' NOT NULL",
      ]);
      final ora = DdlBuilder(oracle).alterColumn(customers, from, to).single;
      expect(ora, endsWith("MODIFY (\"name\" varchar(200) DEFAULT 'x' NOT NULL)"));
      // Oracle: only the changed parts (NOT NULL twice raises ORA-01442).
      final ora2 = DdlBuilder(oracle).alterColumn(customers, from, from.copyWith(nullable: false)).single;
      expect(ora2, endsWith('MODIFY ("name" NOT NULL)'));
      expect(
        DdlBuilder(db2).alterColumn(customers, from, from.copyWith(size: 150)).first,
        contains('ALTER COLUMN "name" SET DATA TYPE varchar(150)'),
      );
      final lite = DdlBuilder(sqlite).alterColumn(customers, from, to);
      expect(lite.every(isCommentOnly), isTrue);
      expect(lite.single, contains('non supportato'));
    });

    test('sql server drop default looks up the constraint', () {
      const from = ColumnDef(name: 'active', type: 'bit', defaultValue: '((1))');
      final out = DdlBuilder(mssql).alterColumn(customers, from, from.copyWith(defaultValue: null));
      expect(out.single, contains('sys.default_constraints'));
      expect(out.single, isNot(contains(';')));
    });

    test('primary and foreign keys', () {
      final b = DdlBuilder(pg);
      const pk = PrimaryKeyDef(name: 'pk_x', columns: ['id']);
      expect(b.addPrimaryKey(customers, pk), ['ALTER TABLE app.customers ADD CONSTRAINT pk_x PRIMARY KEY (id)']);
      expect(b.dropPrimaryKey(customers, const PrimaryKeyDef(columns: ['id'])), [
        'ALTER TABLE app.customers DROP CONSTRAINT customers_pkey',
      ]);
      expect(DdlBuilder(mysql).dropPrimaryKey(customers, pk), ['ALTER TABLE app.customers DROP PRIMARY KEY']);
      expect(
        isCommentOnly(DdlBuilder(mssql).dropPrimaryKey(customers, const PrimaryKeyDef(columns: ['id'])).single),
        isTrue,
      );
      final fk = orders.foreignKeys.single.copyWith(onUpdate: FkRule.setNull);
      expect(b.addForeignKey(orders, fk), [
        'ALTER TABLE app.orders ADD CONSTRAINT fk_orders_customers FOREIGN KEY (customer_id) '
            'REFERENCES app.customers (id) ON DELETE CASCADE ON UPDATE SET NULL',
      ]);
      // Oracle has no ON UPDATE.
      expect(DdlBuilder(oracle).addForeignKey(orders, fk).single, isNot(contains('ON UPDATE')));
      expect(DdlBuilder(mysql).dropForeignKey(orders, fk), [
        'ALTER TABLE app.orders DROP FOREIGN KEY fk_orders_customers',
      ]);
      expect(b.dropForeignKey(orders, fk), ['ALTER TABLE app.orders DROP CONSTRAINT fk_orders_customers']);
      expect(isCommentOnly(DdlBuilder(sqlite).addForeignKey(orders, fk).single), isTrue);
    });

    test('indexes', () {
      const ix = IndexDef(name: 'ux_name', columns: ['name'], unique: true);
      expect(DdlBuilder(pg).createIndex(customers, ix), ['CREATE UNIQUE INDEX ux_name ON app.customers (name)']);
      expect(DdlBuilder(pg).dropIndex(customers, ix), ['DROP INDEX app.ux_name']);
      expect(DdlBuilder(mssql).dropIndex(customers, ix), ['DROP INDEX ux_name ON app.customers']);
      expect(DdlBuilder(mysql).dropIndex(customers, ix), ['DROP INDEX ux_name ON app.customers']);
    });

    test('comments', () {
      final b = DdlBuilder(pg);
      expect(b.tableComment(customers, 'Clienti'), ["COMMENT ON TABLE app.customers IS 'Clienti'"]);
      expect(b.tableComment(customers, ''), ['COMMENT ON TABLE app.customers IS NULL']);
      expect(b.columnComment(customers, customers.columns[1].copyWith(comment: "L'utente")), [
        "COMMENT ON COLUMN app.customers.name IS 'L''utente'",
      ]);
      expect(DdlBuilder(mssql).tableComment(customers, 'x').single, startsWith('EXEC sp_addextendedproperty'));
      expect(
        DdlBuilder(mssql).tableComment(customers, 'x', previous: 'y').single,
        startsWith('EXEC sp_updateextendedproperty'),
      );
      expect(DdlBuilder(sqlite).tableComment(customers, 'x'), isEmpty);
    });

    test('render and ordering helpers', () {
      final b = DdlBuilder(pg);
      final script = b.render(['-- titolo', 'SELECT 1', 'SELECT 2']);
      expect(script, '-- titolo\nSELECT 1;\n\nSELECT 2;');
      expect(executableStatements(['-- a', 'X', '  -- b\n']), ['X']);
      final sorted = DdlBuilder.sortByDependencies([orders, customers]);
      expect(sorted.map((t) => t.name), ['customers', 'orders']);
      final create = b.createSchema([orders, customers]);
      expect(create.first, startsWith('CREATE TABLE app.customers'));
      expect(create.last, contains('FOREIGN KEY'));
      final drop = b.dropSchema([orders, customers]);
      expect(drop.first, contains('DROP CONSTRAINT fk_orders_customers'));
      expect(drop.last, 'DROP TABLE app.customers');
    });

    test('sqlite rebuild', () {
      final to = customers.copyWith(columns: [customers.columns[0], customers.columns[1].copyWith(size: 200)]);
      final out = DdlBuilder(sqlite).rebuildTable(customers, to, {'id': 'id', 'name': 'name'});
      expect(out[1], 'PRAGMA foreign_keys = OFF');
      expect(out, contains('INSERT INTO app.customers__new (id, name)\nSELECT id, name FROM app.customers'));
      expect(out, contains('DROP TABLE app.customers'));
      expect(out, contains('ALTER TABLE app.customers__new RENAME TO customers'));
    });
  });

  group('SchemaDiff', () {
    test('identical across dialect type spellings', () {
      final target = customers.copyWith(
        columns: [
          const ColumnDef(name: 'ID', type: 'int4', nullable: false, autoIncrement: true),
          const ColumnDef(name: 'name', type: 'character varying', size: 100, nullable: false),
          const ColumnDef(name: 'active', type: 'bool', defaultValue: 'TRUE'),
        ],
      );
      final d = SchemaDiff.compare(snap([customers]), snap([target]));
      expect(d.tables.single.status, DiffStatus.identical);
      final cs = SchemaDiff.compare(
        snap([customers]),
        snap([target]),
        options: const CompareOptions(ignoreCase: false),
      );
      expect(cs.tables.single.status, DiffStatus.different);
    });

    test('tables only in source / target and changed columns', () {
      final changed = customers.copyWith(
        columns: [
          customers.columns[0],
          customers.columns[1].copyWith(size: 50),
          const ColumnDef(name: 'legacy', type: 'text'),
        ],
      );
      final d = SchemaDiff.compare(
        snap([customers, orders]),
        snap([changed, const TableDef(name: 'old', columns: [])]),
      );
      expect(d.withStatus(DiffStatus.onlyInSource).single.name, 'orders');
      expect(d.withStatus(DiffStatus.onlyInTarget).single.name, 'old');
      final t = d.withStatus(DiffStatus.different).single;
      expect(t.columns.firstWhere((c) => c.name == 'name').aspects, {ColumnAspect.type});
      expect(t.columns.firstWhere((c) => c.name == 'active').status, DiffStatus.onlyInSource);
      expect(t.columns.firstWhere((c) => c.name == 'legacy').status, DiffStatus.onlyInTarget);
      expect(d.changeCount(), 5);
      expect(d.changeCount(includeDestructive: false), 3);
    });

    test('options: defaults, comments, column order', () {
      final other = customers.copyWith(
        comment: 'x',
        columns: [
          customers.columns[1],
          customers.columns[0],
          customers.columns[2].copyWith(defaultValue: 'false'),
        ],
      );
      final loose = SchemaDiff.compare(
        snap([customers]),
        snap([other]),
        options: const CompareOptions(ignoreDefaults: true),
      );
      expect(loose.tables.single.status, DiffStatus.identical);
      final strict = SchemaDiff.compare(
        snap([customers]),
        snap([other]),
        options: const CompareOptions(ignoreColumnOrder: false, ignoreComments: false),
      );
      final t = strict.tables.single;
      expect(t.commentChanged, isTrue);
      expect(t.columns.first.aspects, contains(ColumnAspect.position));
      expect(t.columns.last.aspects, {ColumnAspect.defaultValue});
    });

    test('pk, fk and index changes', () {
      final target = orders.copyWith(
        primaryKey: const PrimaryKeyDef(name: 'other_name', columns: ['id', 'customer_id']),
        foreignKeys: [orders.foreignKeys.single.copyWith(name: 'generated_123', onDelete: FkRule.noAction)],
        indexes: [
          const IndexDef(name: 'ix_other', columns: ['customer_id']),
          const IndexDef(name: 'ix_t', columns: ['total']),
        ],
      );
      final d = SchemaDiff.compare(snap([customers, orders]), snap([customers, target]));
      final t = d.tables.firstWhere((t) => t.name == 'orders');
      expect(t.primaryKey!.status, DiffStatus.different);
      expect(t.foreignKeys.single.status, DiffStatus.different);
      // Same structure with a different name: identical.
      expect(t.indexes.firstWhere((i) => i.source?.name == 'ix_orders_customer').status, DiffStatus.identical);
      expect(t.indexes.firstWhere((i) => i.target?.name == 'ix_t').status, DiffStatus.onlyInTarget);
    });

    test('renames from an editor are matched through originalName', () {
      final edited = customers.copyWith(
        name: 'clients',
        originalName: 'customers',
        columns: [
          customers.columns[0],
          customers.columns[1].copyWith(name: 'full_name', originalName: 'name'),
          customers.columns[2],
        ],
      );
      final ord = orders.copyWith(foreignKeys: [orders.foreignKeys.single.copyWith(refTable: 'clients')]);
      final d = SchemaDiff.compare(
        snap([edited, ord]),
        snap([customers, orders]),
        options: const CompareOptions(ignoreCase: false),
      );
      final t = d.tables.firstWhere((t) => t.name == 'clients');
      expect(t.renamed, isTrue);
      expect(t.columns[1].aspects, {ColumnAspect.name});
      // The foreign key follows the rename: no change.
      expect(d.tables.firstWhere((t) => t.name == 'orders').status, DiffStatus.identical);
    });
  });

  group('SchemaMigration', () {
    test('creates missing tables in dependency order with fks last', () {
      final d = SchemaDiff.compare(snap([orders, customers]), snap([], schema: 'prod'));
      final s = executableStatements(SchemaMigration(pg).generate(d));
      expect(s[0], startsWith('CREATE TABLE prod.customers'));
      expect(s[1], startsWith('CREATE TABLE prod.orders'));
      expect(s[2], 'CREATE INDEX ix_orders_customer ON prod.orders (customer_id)');
      expect(s[3], contains('REFERENCES prod.customers (id)'));
      expect(s, hasLength(4));
    });

    test('migration between DBMS adapts types, defaults and names (D-030)', () {
      // SQL Server → PostgreSQL: defaults translated, generated names left out.
      const audit = TableDef(
        schema: 'dbo',
        name: 'audit',
        columns: [
          ColumnDef(name: 'id', type: 'int', nullable: false, autoIncrement: true),
          ColumnDef(name: 'quando', type: 'datetime2', defaultValue: '(sysdatetime())'),
          ColumnDef(name: 'attivo', type: 'bit', defaultValue: '((1))'),
          ColumnDef(name: 'chi', type: 'nvarchar', size: 50, defaultValue: "(N'sistema')"),
          ColumnDef(name: 'calc', type: 'int', defaultValue: '(datepart(year,getdate()))'),
        ],
        primaryKey: PrimaryKeyDef(name: 'PK__audit__3213E83F0A1B2C3D', columns: ['id']),
      );
      final toPg = SchemaMigration(pg).generate(
        SchemaDiff.compare(snap([audit], schema: 'dbo', family: DbFamily.sqlServer), snap([], schema: 'da_mssql')),
      );
      final create = executableStatements(toPg).single;
      expect(create, contains('quando timestamp DEFAULT CURRENT_TIMESTAMP'));
      expect(create, contains('attivo boolean DEFAULT true'));
      expect(create, contains("chi varchar(50) DEFAULT 'sistema'"));
      expect(create, isNot(contains('PK__audit')));
      expect(create, isNot(contains('datepart')));
      expect(toPg.where((e) => e.startsWith('-- audit.calc')), hasLength(1), reason: 'the dropped default is noted');

      // PostgreSQL → MySQL: TEXT in a unique index becomes VARCHAR(255).
      const reparti = TableDef(
        schema: 'public',
        name: 'reparti',
        columns: [
          ColumnDef(name: 'id', type: 'integer', nullable: false),
          ColumnDef(name: 'nome', type: 'text', nullable: false),
        ],
        primaryKey: PrimaryKeyDef(name: 'reparti_pkey', columns: ['id']),
        indexes: [IndexDef(name: 'reparti_nome_key', columns: ['nome'], unique: true)],
      );
      final toMy = executableStatements(
        SchemaMigration(mysql).generate(SchemaDiff.compare(snap([reparti], schema: 'public'), snap([], schema: null))),
      );
      expect(toMy.first, contains('nome varchar(255) NOT NULL'));

      // MariaDB → SQLite: index names unique per table get the table name;
      // ENUM / SET / BIT(n) become valid types.
      const progetti = TableDef(
        name: 'progetti',
        columns: [
          ColumnDef(name: 'id', type: 'int', nullable: false),
          ColumnDef(name: 'reparto_id', type: 'int'),
          ColumnDef(name: 'e', type: "enum('felice','triste')"),
          ColumnDef(name: 'st', type: "set('a','b','c')"),
          ColumnDef(name: 'bit8', type: 'bit', size: 8, defaultValue: "b'101'"),
        ],
        primaryKey: PrimaryKeyDef(name: 'PRIMARY', columns: ['id']),
        indexes: [IndexDef(name: 'reparto_id', columns: ['reparto_id'])],
      );
      final toLite = executableStatements(
        SchemaMigration(sqlite).generate(
          SchemaDiff.compare(snap([progetti], schema: null, family: DbFamily.mysql), snap([], schema: null)),
        ),
      );
      expect(toLite.first, isNot(contains('CONSTRAINT')));
      expect(toLite.first, contains('e TEXT'));
      expect(toLite.first, contains('bit8 INTEGER DEFAULT 5'));
      expect(toLite[1], 'CREATE INDEX ix_progetti_reparto_id ON progetti (reparto_id)');
      final toPg2 = SchemaMigration(pg).generate(
        SchemaDiff.compare(snap([progetti], schema: null, family: DbFamily.mysql), snap([], schema: 'x')),
      );
      expect(executableStatements(toPg2).first, allOf(contains('e varchar(6)'), contains('st varchar(6)'), contains('bit8 bit(8)')));
    });

    test('key columns read through ODBC are NOT NULL', () {
      final t = TableDef.fromMetadata(
        DbTable(catalog: 'd', schema: null, name: 'audit', type: 'TABLE'),
        [
          DbColumn(
            name: 'id',
            dataType: 4,
            typeName: 'int',
            size: 10,
            decimals: 0,
            nullable: true,
            position: 1,
            autoIncrement: true,
          ),
        ],
        primaryKey: DbPrimaryKey('PRIMARY', ['id']),
      );
      expect(t.columns.single.nullable, isFalse);
    });

    test('drops only when requested and in the right order', () {
      final d = SchemaDiff.compare(snap([]), snap([customers, orders]));
      expect(executableStatements(SchemaMigration(pg).generate(d)), isEmpty);
      final s = executableStatements(SchemaMigration(pg).generate(d, options: const MigrationOptions(dropExtra: true)));
      expect(s, [
        'ALTER TABLE app.orders DROP CONSTRAINT fk_orders_customers',
        'DROP TABLE app.orders',
        'DROP TABLE app.customers',
      ]);
    });

    test('alters changed tables only for the reported aspects', () {
      final target = customers.copyWith(
        columns: [
          const ColumnDef(name: 'id', type: 'int4', nullable: false, autoIncrement: true),
          const ColumnDef(name: 'name', type: 'varchar', size: 50, nullable: false),
          const ColumnDef(name: 'old', type: 'text'),
        ],
      );
      final d = SchemaDiff.compare(snap([customers]), snap([target]));
      final gen = SchemaMigration(pg);
      final s = executableStatements(gen.generate(d));
      expect(s, [
        'ALTER TABLE app.customers ADD COLUMN active boolean DEFAULT true',
        'ALTER TABLE app.customers ALTER COLUMN name TYPE varchar(100) USING name::varchar(100)',
      ]);
      final all = executableStatements(gen.generate(d, options: const MigrationOptions(dropExtra: true)));
      expect(all.last, 'ALTER TABLE app.customers DROP COLUMN old');
      // Excluded changes are skipped.
      final td = d.tables.single;
      final some = executableStatements(gen.generate(d, excluded: {td.columnId('active')}));
      expect(some, hasLength(1));
    });

    test('fk and pk changes are dropped before and recreated after', () {
      final target = orders.copyWith(
        primaryKey: const PrimaryKeyDef(name: 'orders_pk', columns: ['id', 'customer_id']),
        foreignKeys: [orders.foreignKeys.single.copyWith(onDelete: FkRule.noAction)],
      );
      final d = SchemaDiff.compare(snap([customers, orders]), snap([customers, target]));
      final s = executableStatements(SchemaMigration(pg).generate(d));
      expect(s, [
        'ALTER TABLE app.orders DROP CONSTRAINT fk_orders_customers',
        'ALTER TABLE app.orders DROP CONSTRAINT orders_pk',
        'ALTER TABLE app.orders ADD PRIMARY KEY (id)',
        'ALTER TABLE app.orders ADD CONSTRAINT fk_orders_customers FOREIGN KEY (customer_id) '
            'REFERENCES app.customers (id) ON DELETE CASCADE',
      ]);
    });

    test('editor renames generate rename statements', () {
      final edited = customers.copyWith(
        name: 'clients',
        originalName: 'customers',
        columns: [
          customers.columns[0],
          customers.columns[1].copyWith(name: 'full_name', originalName: 'name', size: 150),
          customers.columns[2],
        ],
      );
      final d = SchemaDiff.compare(snap([edited]), snap([customers]), options: const CompareOptions(ignoreCase: false));
      final s = executableStatements(
        SchemaMigration(pg).generate(d, options: const MigrationOptions(dropExtra: true, relocate: false)),
      );
      expect(s, [
        'ALTER TABLE app.customers RENAME TO clients',
        'ALTER TABLE app.clients RENAME COLUMN name TO full_name',
        'ALTER TABLE app.clients ALTER COLUMN full_name TYPE varchar(150) USING full_name::varchar(150)',
      ]);
    });

    test('cross dialect migration maps types', () {
      final d = SchemaDiff.compare(snap([customers]), snap([], schema: 'dbo', family: DbFamily.sqlServer));
      final s = executableStatements(SchemaMigration(mssql).generate(d));
      expect(s.single, contains('id int IDENTITY(1,1) NOT NULL'));
      expect(s.single, contains('active bit DEFAULT 1'));
      expect(s.single, startsWith('CREATE TABLE dbo.customers'));
    });

    test('sqlite rebuilds tables for unsupported alterations', () {
      final target = customers.copyWith(
        columns: [customers.columns[0], customers.columns[1].copyWith(nullable: true), customers.columns[2]],
      );
      final d = SchemaDiff.compare(
        snap([customers], schema: null, family: DbFamily.sqlite),
        snap([target], schema: null, family: DbFamily.sqlite),
      );
      final s = executableStatements(SchemaMigration(sqlite).generate(d));
      expect(s.first, 'PRAGMA foreign_keys = OFF');
      expect(s[1], contains('name varchar(100) NOT NULL'));
      expect(
        s,
        contains('INSERT INTO app.customers__new (id, name, active)\nSELECT id, name, active FROM app.customers'),
      );
      expect(s.last, 'PRAGMA foreign_keys = ON');
    });
  });

  group('dialogs', () {
    Future<BuildContext> host(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return ctx;
    }

    testWidgets('table dialog creates a table with a default id column', (tester) async {
      final ctx = await host(tester);
      final f = showTableDefDialog(ctx, dialect: pg, schema: 'app', takenNames: {'customers'});
      await tester.pumpAndSettle();
      expect(find.text('Nuova tabella'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'customers');
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      expect(find.text('Esiste già una tabella "customers"'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'invoices');
      await tester.tap(find.byTooltip('Aggiungi una colonna'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(6), 'amount');
      await tester.enterText(find.byType(TextField).at(7), 'numeric');
      await tester.enterText(find.byType(TextField).at(8), '10,2');
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      final r = (await f)!;
      expect(r.table.name, 'invoices');
      expect(r.table.schema, 'app');
      expect(r.table.primaryKey!.columns, ['id']);
      expect(r.table.columns.first.autoIncrement, isTrue);
      expect(r.table.columns.last.fullType, 'numeric(10,2)');
    });

    testWidgets('table dialog reports renamed and removed columns', (tester) async {
      final ctx = await host(tester);
      final working = customers.copyWith(
        originalName: 'customers',
        columns: [for (final c in customers.columns) c.copyWith(originalName: c.name)],
      );
      final f = showTableDefDialog(ctx, dialect: pg, initial: working);
      await tester.pumpAndSettle();
      expect(find.text('Modifica tabella'), findsOneWidget);
      // Fields: table name, comment, then 4 per column (name, type, size, default).
      await tester.enterText(find.byType(TextField).at(6), 'full_name');
      await tester.tap(find.byTooltip('Elimina colonna').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Applica'));
      await tester.pumpAndSettle();
      final r = (await f)!;
      expect(r.renamedColumns, {'name': 'full_name'});
      expect(r.removedColumns, {'active'});
      expect(r.table.columns[1].originalName, 'name');
      final d = SchemaDiff.compare(
        snap([r.table]),
        snap([customers]),
        options: const CompareOptions(ignoreCase: false),
      );
      final s = executableStatements(
        SchemaMigration(pg).generate(d, options: const MigrationOptions(dropExtra: true, relocate: false)),
      );
      expect(s, [
        'ALTER TABLE app.customers RENAME COLUMN name TO full_name',
        'ALTER TABLE app.customers DROP COLUMN active',
      ]);
    });

    testWidgets('relation dialog builds the foreign key', (tester) async {
      final ctx = await host(tester);
      final child = orders.copyWith(foreignKeys: const []);
      final f = showForeignKeyDialog(
        ctx,
        ConstraintContext(dialect: pg, table: child, isNew: true),
        prefill: const ForeignKeyDef(
          columns: ['customer_id'],
          refSchema: 'app',
          refTable: 'customers',
          refColumns: ['id'],
        ),
        tables: [customers.toDbTable()],
        loadTable: (_) async => customers,
      );
      await tester.pumpAndSettle();
      expect(find.text('fk_orders_customers'), findsOneWidget);
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      final fk = (await f)!.value;
      expect(fk.refTable, 'customers');
      expect(fk.refSchema, 'app');
      expect(fk.columns, ['customer_id']);
    });

    testWidgets('script dialog renders the DDL', (tester) async {
      final ctx = await host(tester);
      final dc = DbConnection(ConnectionConfig(id: 'x', name: 'Prova', readOnly: true));
      showDdlScriptDialog(ctx, dc: dc, statements: ['-- Nuove tabelle', 'CREATE TABLE t (id int)']);
      await tester.pumpAndSettle();
      expect(find.textContaining('CREATE TABLE t (id int);'), findsOneWidget);
      expect(find.text('1 istruzioni · Prova ()'), findsOneWidget);
      await tester.tap(find.text('Chiudi'));
      await tester.pumpAndSettle();
    });
  });

  test('snapshot loads tables through the metadata service', () async {
    final dc = fakeConnection(FakeSession());
    final progress = <int>[];
    final s = await SchemaSnapshot.load(dc.metadata!, schema: 'app', onProgress: (d, n, _) => progress.add(d));
    expect(s.tables.map((t) => t.name), ['customers', 'orders']);
    expect(s.family, DbFamily.postgres);
    expect(s.tables[1].foreignKeys.single.refTable, 'customers');
    expect(s.tables[0].primaryKey!.columns, ['id']);
    expect(progress.last, 2);
    final cancel = CancelToken()..cancel();
    expect(SchemaSnapshot.load(dc.metadata!, schema: 'app', cancel: cancel), throwsA(isA<SnapshotCancelled>()));
  });

  testWidgets('ER diagram edit mode: new table, pending changes and script', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = FakeSession();
    final dc = fakeConnection(session);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: ErDiagramView(connection: dc, catalog: null, schema: 'app', positions: {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // View mode unchanged.
    expect(find.text('2 tabelle · 1 relazioni'), findsOneWidget);
    expect(find.text('Trascina le tabelle · doppio clic per aprire'), findsOneWidget);
    await tester.tap(find.byTooltip('Modifica lo schema nel diagramma'));
    await tester.pumpAndSettle();
    expect(find.text('Nessuna modifica'), findsOneWidget);
    await tester.tap(find.byTooltip('Crea una nuova tabella'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'invoices');
    await tester.tap(find.text('Crea'));
    await tester.pumpAndSettle();
    expect(find.text('1 modifica'), findsOneWidget);
    expect(find.text('nuova'), findsOneWidget);
    expect(find.text('3 tabelle · 1 relazioni'), findsOneWidget);
    // Delete an existing table: crossed out, its relationship removed.
    await tester.tap(find.text('customers'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Elimina la tabella o la relazione selezionata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina'));
    await tester.pumpAndSettle();
    expect(find.text('eliminata'), findsOneWidget);
    expect(find.text('modificata'), findsOneWidget);
    expect(find.text('3 modifiche'), findsOneWidget);
    await tester.tap(find.text('Rivedi script…'));
    await tester.pumpAndSettle();
    final script = tester.widget<SelectableText>(find.byType(SelectableText).last).data!;
    expect(script, contains('ALTER TABLE app.orders DROP CONSTRAINT fk_orders_customers;'));
    expect(script, contains('CREATE TABLE app.invoices'));
    expect(script, contains('DROP TABLE app.customers;'));
    await tester.tap(find.text('Chiudi'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Scarta tutte le modifiche non applicate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scarta'));
    await tester.pumpAndSettle();
    expect(find.text('Nessuna modifica'), findsOneWidget);
    expect(find.text('2 tabelle · 1 relazioni'), findsOneWidget);
  });

  testWidgets('ER diagram edit mode: relationship by drag and table edit', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dc = fakeConnection(FakeSession());
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: ErDiagramView(connection: dc, catalog: null, schema: 'app', positions: {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Modifica lo schema nel diagramma'));
    await tester.pumpAndSettle();
    // Drag from orders.id to customers.name.
    final from = tester.getCenter(find.text('customer_id'));
    final to = tester.getCenter(find.text('name'));
    final g = await tester.startGesture(from);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('Nuova chiave esterna'), findsOneWidget);
    expect(find.textContaining('non sono chiave primaria né univoche'), findsOneWidget);
    await tester.tap(find.text('Crea'));
    await tester.pumpAndSettle();
    expect(find.text('1 modifica'), findsOneWidget);
    expect(find.text('2 tabelle · 2 relazioni'), findsOneWidget);
    // Double click edits the table.
    await tester.tap(find.text('customers'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('customers'));
    await tester.pumpAndSettle();
    expect(find.text('Modifica tabella'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'clients');
    await tester.tap(find.text('Applica'));
    await tester.pumpAndSettle();
    expect(find.text('clients'), findsOneWidget);
    expect(find.text('modificata'), findsNWidgets(2));
    await tester.tap(find.text('Rivedi script…'));
    await tester.pumpAndSettle();
    final script = tester.widget<SelectableText>(find.byType(SelectableText).last).data!;
    expect(script, contains('ALTER TABLE app.customers RENAME TO clients;'));
    expect(
      script,
      contains(
        'ALTER TABLE app.orders ADD CONSTRAINT fk_orders_customers_2 FOREIGN KEY (customer_id) '
        'REFERENCES app.clients (name);',
      ),
    );
  });

  testWidgets('schema compare tab compares two connections and builds the migration', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final src = fakeConnection(FakeSession(), name: 'Sviluppo');
    final dst = fakeConnection(FakeSession(variant: true), name: 'Collaudo');
    final tab = SchemaCompareTab(source: src, sourceSchema: 'app');
    expect(tab.title, 'Confronto schemi');
    tab.target.connection = dst;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SchemaCompareView(tab: tab, connections: [src, dst]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tab.target.schema, 'app');
    await tester.tap(find.text('Confronta'));
    await tester.pumpAndSettle();
    expect(tab.diff, isNotNull);
    expect(find.text('Solo in origine'), findsOneWidget);
    expect(find.text('Differenti'), findsOneWidget);
    var script = tester.widget<SqlCodeView>(find.byType(SqlCodeView)).text;
    expect(script, contains('CREATE TABLE app.orders'));
    expect(script, isNot(contains('DROP COLUMN legacy')));
    // Dangerous drops only on request.
    await tester.tap(find.text('Elimina oggetti in più'));
    await tester.pumpAndSettle();
    script = tester.widget<SqlCodeView>(find.byType(SqlCodeView)).text;
    expect(script, contains('ALTER TABLE app.customers DROP COLUMN legacy;'));
    // Excluding the new table removes it from the script.
    await tester.tap(find.text('orders'));
    await tester.pumpAndSettle();
    // The checkbox label in the detail pane toggles the change.
    await tester.tap(find.text('Crea la tabella orders'));
    await tester.pumpAndSettle();
    script = tester.widget<SqlCodeView>(find.byType(SqlCodeView)).text;
    expect(script, isNot(contains('CREATE TABLE app.orders')));
    // Swap clears the results.
    await tester.tap(find.byTooltip('Scambia origine e destinazione'));
    await tester.pumpAndSettle();
    expect(tab.diff, isNull);
    expect(tab.source.connection, dst);
  });
}
