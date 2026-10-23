// Phase 1: reading constraints, index attributes and column extras from the
// system catalog of each DBMS (scripted catalog rows).

import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/catalog/sqlite.dart';
import 'package:dbcraft/features/design/catalog/table_extras.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// What ODBC reports for the table: columns, primary key and the indexes
/// (including the ones backing constraints, as SQLStatistics does).
const base = TableDef(
  schema: 'app',
  name: 'orders',
  columns: [
    ColumnDef(name: 'id', type: 'integer', nullable: false, autoIncrement: true),
    ColumnDef(name: 'code', type: 'varchar', size: 20),
    ColumnDef(name: 'qty', type: 'integer'),
    ColumnDef(name: 'total', type: 'integer'),
  ],
  primaryKey: PrimaryKeyDef(columns: ['id']),
  foreignKeys: [
    ForeignKeyDef(name: 'fk_c', columns: ['qty'], refTable: 'customers', refColumns: ['id']),
  ],
  indexes: [
    IndexDef(name: 'uq_code', columns: ['code'], unique: true),
    IndexDef(name: 'ix_qty', columns: ['qty']),
  ],
);

final table = DbTable(catalog: 'db', schema: 'app', name: 'orders', type: 'TABLE');

Future<TableDef> read(ScriptedSession s, String dbms, {String version = ''}) async {
  final dc = scriptedConnection(s, dbmsName: dbms, dbmsVersion: version);
  final extras = await DesignCatalog.of(dc)!.tableExtras(table);
  return applyTableExtras(base, extras);
}

void main() {
  test('PostgreSQL', () async {
    final s = ScriptedSession()
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
            ['uq_code', 'u', 'UNIQUE (code)', 't', 't', 't', null, 'code', 'uq_code'],
            ['ck_qty', 'c', 'CHECK ((qty > 0)) NOT VALID', 'f', 'f', 'f', null, 'qty', null],
            ['fk_c', 'f', 'FOREIGN KEY (qty) REFERENCES customers(id) MATCH FULL', 'f', 'f', 't', 'f', 'qty', null],
          ],
        ),
      )
      ..on(
        'FROM pg_index',
        Rows(
          [
            'index_name',
            'indisunique',
            'indisclustered',
            'indisvalid',
            'amname',
            'filter',
            'key_count',
            'pos',
            'col',
            'descending',
            'is_expr',
          ],
          [
            ['ix_qty', 'f', 'f', 't', 'btree', 'qty > 0', 2, 1, 'qty', 1, 'f'],
            ['ix_qty', 'f', 'f', 't', 'btree', 'qty > 0', 2, 2, '"Code"', 0, 'f'],
            ['ix_qty', 'f', 'f', 't', 'btree', 'qty > 0', 2, 3, 'total', 0, 'f'],
            ['ix_lower', 'f', 'f', 'f', 'gin', null, 1, 1, 'lower(code)', 0, 't'],
            ['uq_code', 't', 'f', 't', 'btree', null, 1, 1, 'code', 0, 'f'],
          ],
        ),
      )
      ..on(
        'FROM pg_attribute',
        Rows(
          ['attname', 'collation', 'attgenerated', 'expr', 'seqstart', 'seqincrement'],
          [
            ['id', null, '', null, 100, 5],
            ['code', 'C', '', null, null, null],
            ['qty', null, '', null, null, null],
            ['total', null, 's', '(qty * 2)', null, null],
          ],
        ),
      );
    final t = await read(s, 'PostgreSQL', version: '16.4');
    expect(t.primaryKey!.name, 'orders_pkey');
    expect(t.uniques.single.name, 'uq_code');
    expect(t.uniques.single.state, const ConstraintState(deferrable: true, initiallyDeferred: true));
    expect(t.checks.single.expression, 'qty > 0');
    expect(t.checks.single.state.validated, isFalse);
    expect(t.foreignKeys.single.match, FkMatch.full);
    expect(t.indexes.map((i) => i.name), ['ix_qty', 'ix_lower']);
    final ix = t.indexes.first;
    expect(ix.columns, ['qty', 'Code']);
    expect(ix.include, ['total']);
    expect(ix.descending, {'qty'});
    expect(ix.where, 'qty > 0');
    expect(t.indexes.last.columns, ['(lower(code))']);
    expect(t.indexes.last.method, 'gin');
    expect(t.indexes.last.enabled, isFalse);
    expect(t.columns[0].identitySeed, 100);
    expect(t.columns[0].identityIncrement, 5);
    expect(t.columns[1].collation, 'C');
    expect(t.columns[3].computed, 'qty * 2');
    expect(t.columns[3].autoIncrement, isFalse);
  });

  test('SQL Server', () async {
    final s = ScriptedSession()
      ..on(
        'sys.key_constraints',
        Rows(
          ['name', 'type', 'type_desc', 'col', 'key_ordinal'],
          [
            ['PK_orders', 'PK', 'NONCLUSTERED', 'id', 1],
            ['uq_code', 'UQ', 'NONCLUSTERED', 'code', 1],
          ],
        ),
      )
      ..on(
        'sys.check_constraints',
        Rows(
          ['name', 'definition', 'is_disabled', 'is_not_trusted'],
          [
            ['ck_qty', '([qty]>(0))', 1, 1],
          ],
        ),
      )
      ..on(
        'sys.foreign_keys',
        Rows(
          ['name', 'is_disabled', 'is_not_trusted'],
          [
            ['fk_c', 0, 1],
          ],
        ),
      )
      ..on(
        r'FROM \[db\]\.sys\.indexes',
        Rows(
          [
            'name',
            'type_desc',
            'is_unique',
            'is_disabled',
            'filter_definition',
            'col',
            'is_descending_key',
            'is_included_column',
          ],
          [
            ['ix_qty', 'CLUSTERED', 0, 0, '([qty]>(0))', 'qty', 1, 0],
            ['ix_qty', 'CLUSTERED', 0, 0, '([qty]>(0))', 'total', 0, 1],
          ],
        ),
      )
      ..on(
        'sys.columns',
        Rows(
          ['name', 'collation_name', 'computed', 'is_persisted', 'seed', 'step', 'default_name'],
          [
            ['id', null, null, null, 1, 1, null],
            ['code', 'Latin1_General_BIN2', null, null, null, null, 'DF_code'],
            ['qty', null, null, null, null, null, null],
            ['total', null, '([qty]*(2))', 0, null, null, null],
          ],
        ),
      );
    final t = await read(s, 'Microsoft SQL Server', version: '16.00.4135');
    expect(s.executed.first, contains("OBJECT_ID(N'[db].[app].[orders]')"));
    expect(s.executed.first, contains('FROM [db].sys.key_constraints'));
    expect(t.primaryKey!.name, 'PK_orders');
    expect(t.primaryKey!.clustered, isFalse);
    expect(t.uniques.single.columns, ['code']);
    expect(t.checks.single.expression, '[qty]>(0)');
    expect(t.checks.single.normalized, 'qty>0');
    expect(t.checks.single.state, const ConstraintState(enabled: false, validated: false));
    expect(t.foreignKeys.single.state.validated, isFalse);
    expect(t.indexes.single.clustered, isTrue);
    expect(t.indexes.single.include, ['total']);
    expect(t.indexes.single.where, '[qty]>(0)');
    expect(t.columns[1].collation, 'Latin1_General_BIN2');
    expect(t.columns[1].defaultName, 'DF_code');
    expect(t.columns[3].computed, '[qty]*(2)');
    expect(t.columns[3].computedStored, isFalse);
  });

  test('MySQL: UNIQUE indexes are UNIQUE constraints', () async {
    final s = ScriptedSession()
      ..on(
        'CHECK_CONSTRAINTS',
        Rows(
          ['CONSTRAINT_NAME', 'CHECK_CLAUSE', 'ENFORCED'],
          [
            ['ck_qty', '(`qty` > 0)', 'YES'],
          ],
        ),
      )
      ..on(
        'STATISTICS',
        Rows(
          [
            'INDEX_NAME',
            'NON_UNIQUE',
            'SEQ_IN_INDEX',
            'COLUMN_NAME',
            'COLLATION',
            'INDEX_TYPE',
            'EXPRESSION',
            'IS_VISIBLE',
          ],
          [
            ['PRIMARY', 0, 1, 'id', 'A', 'BTREE', null, 'YES'],
            ['fk_c', 1, 1, 'qty', 'A', 'BTREE', null, 'YES'],
            ['ix_lower', 1, 1, null, 'D', 'BTREE', 'lower(`code`)', 'NO'],
            ['uq_code', 0, 1, 'code', 'A', 'BTREE', null, 'YES'],
          ],
        ),
      )
      ..on(
        'information_schema.TABLES',
        Rows(
          ['ENGINE', 'TABLE_COLLATION'],
          [
            ['InnoDB', 'utf8mb4_0900_ai_ci'],
          ],
        ),
      )
      ..on(
        'information_schema.COLUMNS',
        Rows(
          ['COLUMN_NAME', 'COLLATION_NAME', 'GENERATION_EXPRESSION', 'EXTRA'],
          [
            ['id', null, '', 'auto_increment'],
            ['code', 'utf8mb4_bin', '', ''],
            ['qty', null, '', ''],
            ['total', null, '(`qty` * 2)', 'VIRTUAL GENERATED'],
          ],
        ),
      )
      ..on(
        "CONSTRAINT_TYPE = 'FOREIGN KEY'",
        Rows(
          ['CONSTRAINT_NAME'],
          [
            ['fk_c'],
          ],
        ),
      );
    final t = await read(s, 'MySQL', version: '8.4.0');
    expect(s.executed.first, contains("TABLE_SCHEMA = 'db'"));
    expect(t.checks.single.normalized, 'qty>0');
    expect(t.uniques.map((u) => u.name), ['uq_code']);
    // fk_c is the index InnoDB created for the foreign key.
    expect(t.indexes.map((i) => i.name), ['ix_qty', 'ix_lower']);
    expect(t.indexes.last.columns, ['(lower(`code`))']);
    expect(t.indexes.last.enabled, isFalse);
    expect(t.columns[1].collation, 'utf8mb4_bin');
    expect(t.columns[0].collation, isNull);
    expect(t.columns[3].computed, '`qty` * 2');
    expect(t.columns[3].computedStored, isFalse);
    expect(t.options['engine'], 'InnoDB');
  });

  test('MariaDB uses its own CHECK_CONSTRAINTS layout', () async {
    final s = ScriptedSession()
      ..on(
        r'CHECK_CONSTRAINTS WHERE CONSTRAINT_SCHEMA',
        Rows(
          ['CONSTRAINT_NAME', 'CHECK_CLAUSE'],
          [
            ['ck_qty', '`qty` > 0'],
          ],
        ),
      )
      ..on(
        'STATISTICS',
        Rows(
          ['INDEX_NAME', 'NON_UNIQUE', 'SEQ_IN_INDEX', 'COLUMN_NAME', 'COLLATION', 'INDEX_TYPE', 'IGNORED'],
          [
            ['ix_qty', 1, 1, 'qty', 'A', 'BTREE', 'YES'],
          ],
        ),
      );
    final t = await read(s, 'MariaDB', version: '11.4.2-MariaDB');
    expect(t.checks.single.name, 'ck_qty');
    expect(t.indexes.single.enabled, isFalse);
  });

  test('Oracle', () async {
    final s = ScriptedSession()
      ..on(
        'FROM all_constraints',
        Rows(
          [
            'constraint_name',
            'constraint_type',
            'status',
            'validated',
            'deferrable',
            'deferred',
            'generated',
            'search_condition',
            'index_name',
            'column_name',
            'position',
          ],
          [
            [
              'PK_ORDERS',
              'P',
              'ENABLED',
              'VALIDATED',
              'NOT DEFERRABLE',
              'IMMEDIATE',
              'USER NAME',
              null,
              'PK_ORDERS',
              'id',
              1,
            ],
            [
              'SYS_C0012',
              'C',
              'ENABLED',
              'VALIDATED',
              'NOT DEFERRABLE',
              'IMMEDIATE',
              'GENERATED NAME',
              '"id" IS NOT NULL',
              null,
              'id',
              null,
            ],
            [
              'CK_QTY',
              'C',
              'DISABLED',
              'NOT VALIDATED',
              'NOT DEFERRABLE',
              'IMMEDIATE',
              'USER NAME',
              'qty > 0',
              null,
              'qty',
              null,
            ],
            ['FK_C', 'R', 'ENABLED', 'VALIDATED', 'DEFERRABLE', 'DEFERRED', 'USER NAME', null, null, 'qty', 1],
            [
              'UQ_CODE',
              'U',
              'ENABLED',
              'VALIDATED',
              'NOT DEFERRABLE',
              'IMMEDIATE',
              'USER NAME',
              null,
              'UQ_CODE',
              'code',
              1,
            ],
          ],
        ),
      )
      ..on(
        'FROM all_indexes',
        Rows(
          [
            'index_name',
            'index_type',
            'uniqueness',
            'status',
            'column_name',
            'column_position',
            'descend',
            'column_expression',
          ],
          [
            ['IX_QTY', 'FUNCTION-BASED NORMAL', 'NONUNIQUE', 'VALID', 'SYS_NC00005\$', 1, 'DESC', '"qty"'],
            ['IX_UP', 'FUNCTION-BASED NORMAL', 'NONUNIQUE', 'UNUSABLE', 'SYS_NC00006\$', 1, 'ASC', 'UPPER("code")'],
            ['UQ_CODE', 'NORMAL', 'UNIQUE', 'VALID', 'code', 1, 'ASC', null],
          ],
        ),
      )
      ..on(
        'FROM all_tab_cols',
        Rows(
          ['column_name', 'collation', 'virtual_column', 'data_default'],
          [
            ['total', null, 'YES', '"qty"*2'],
          ],
        ),
      )
      ..on(
        'all_tab_identity_cols',
        Rows(
          ['column_name', 'identity_options'],
          [
            ['id', 'START WITH: 10, INCREMENT BY: 1, MAX_VALUE: 9999'],
          ],
        ),
      );
    final t = await read(s, 'Oracle', version: '23.00.0000');
    expect(t.primaryKey!.name, 'PK_ORDERS');
    expect(t.checks.single.name, 'CK_QTY', reason: 'NOT NULL checks are left out');
    expect(t.checks.single.state, const ConstraintState(enabled: false, validated: false));
    expect(t.foreignKeys.single.state, const ConstraintState(deferrable: true, initiallyDeferred: true));
    expect(t.uniques.single.name, 'UQ_CODE');
    final ixs = {for (final i in t.indexes) i.name.toUpperCase(): i};
    expect(ixs['IX_QTY']!.columns, ['qty']);
    expect(ixs['IX_QTY']!.descending, {'qty'});
    expect(ixs['IX_UP']!.columns, ['(UPPER("code"))']);
    expect(ixs['IX_UP']!.enabled, isFalse);
    expect(t.columns[3].computed, '"qty"*2');
    expect(t.columns[0].identitySeed, 10);
  });

  test('Db2', () async {
    final s = ScriptedSession()
      ..on(
        'syscat.tabconst',
        Rows(
          ['constname', 'type', 'enforced', 'colname', 'colseq'],
          [
            ['PK_ORDERS', 'P', 'Y', 'id', 1],
            ['UQ_CODE', 'U', 'Y', 'code', 1],
            ['CK_QTY', 'K', 'N', null, null],
          ],
        ),
      )
      ..on(
        'syscat.checks',
        Rows(
          ['constname', 'text'],
          [
            ['CK_QTY', 'qty > 0'],
          ],
        ),
      )
      ..on(
        'syscat.indexes',
        Rows(
          ['indname', 'uniquerule', 'colname', 'colseq', 'colorder', 'expr'],
          [
            ['SQL240101', 'P', 'id', 1, 'A', null],
            ['UQ_CODE', 'U', 'code', 1, 'A', null],
            ['IX_QTY', 'U', 'qty', 1, 'D', null],
            ['IX_QTY', 'U', 'total', 2, 'I', null],
          ],
        ),
      )
      ..on(
        'syscat.columns',
        Rows(
          ['colname', 'generated', 'identity', 'text'],
          [
            ['total', 'A', 'N', 'AS (qty * 2)'],
          ],
        ),
      );
    final t = await read(s, 'DB2/LINUXX8664', version: '11.05.0900');
    expect(t.checks.single.state.enabled, isFalse);
    expect(t.uniques.single.name, 'UQ_CODE');
    expect(t.indexes.map((i) => i.name), ['ix_qty']);
    expect(t.indexes.single.descending, {'qty'});
    expect(t.indexes.single.include, ['total']);
    expect(t.columns[3].computed, 'qty * 2');
  });

  test('Firebird', () async {
    final s = ScriptedSession()
      ..on(
        r'RDB\$CHECK_CONSTRAINTS',
        Rows(
          ['name', 'source'],
          [
            ['CK_QTY      ', 'CHECK (qty > 0)'],
            ['CK_QTY      ', 'CHECK (qty > 0)'],
          ],
        ),
      )
      ..on(
        r'FROM RDB\$RELATION_CONSTRAINTS',
        Rows(
          ['name', 'kind', 'index_name', 'col', 'pos'],
          [
            ['PK_ORDERS   ', 'PRIMARY KEY', 'RDB\$PRIMARY1', 'id ', 0],
            ['FK_C        ', 'FOREIGN KEY', 'RDB\$FOREIGN2', 'qty', 0],
            ['UQ_CODE     ', 'UNIQUE', 'UQ_CODE', 'code', 0],
          ],
        ),
      )
      ..on(
        r'FROM RDB\$INDICES',
        Rows(
          ['name', 'is_unique', 'descending', 'inactive', 'expr', 'filter', 'col', 'pos'],
          [
            ['IX_QTY  ', 0, 1, 1, null, 'WHERE qty > 0', 'qty', 0],
            ['RDB\$FOREIGN2', 0, 0, 0, null, null, 'qty', 0],
          ],
        ),
      )
      ..on(
        r'RDB\$RELATION_FIELDS',
        Rows(
          ['name', 'collation', 'computed'],
          [
            ['code   ', 'UNICODE_CI ', null],
            ['total  ', null, '(qty * 2)'],
          ],
        ),
      );
    final t = await read(s, 'Firebird', version: 'WI-V5.0.0.1306 Firebird 5.0');
    expect(t.checks.single.expression, 'qty > 0');
    expect(t.uniques.single.name, 'UQ_CODE');
    expect(t.indexes.map((i) => i.name), ['ix_qty']);
    expect(t.indexes.single.descending, {'qty'});
    expect(t.indexes.single.where, 'qty > 0');
    expect(t.indexes.single.enabled, isFalse);
    expect(t.columns[1].collation, 'UNICODE_CI');
    expect(t.columns[3].computed, 'qty * 2');
  });

  test('Snowflake', () async {
    final s = ScriptedSession()
      ..on(
        'SHOW UNIQUE KEYS',
        Rows(
          ['constraint_name', 'column_name', 'key_sequence'],
          [
            ['UQ_CODE_SITE', 'site', 2],
            ['UQ_CODE_SITE', 'code', 1],
          ],
        ),
      )
      ..on(
        'SHOW PRIMARY KEYS',
        Rows(
          ['constraint_name', 'column_name'],
          [
            ['PK_ORDERS', 'id'],
          ],
        ),
      )
      ..on(
        'information_schema.COLUMNS',
        Rows(
          ['COLUMN_NAME', 'COLLATION_NAME'],
          [
            ['code', 'en-ci'],
          ],
        ),
      );
    final t = await read(s, 'Snowflake', version: '8.30.1');
    expect(t.uniques.single.columns, ['code', 'site']);
    expect(t.primaryKey!.name, 'PK_ORDERS');
    expect(t.columns[1].collation, 'en-ci');
  });

  group('SQLite', () {
    test('constraints and columns from CREATE TABLE', () {
      final x = parseSqliteCreateTable('''
CREATE TABLE "orders" (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT COLLATE NOCASE CONSTRAINT uq_code UNIQUE,
  qty INTEGER CHECK (qty > 0),
  "total" INTEGER GENERATED ALWAYS AS (qty * 2) STORED,
  note TEXT AS (upper(code)),
  CONSTRAINT ck_pair CHECK (qty < 100 AND code <> 'a,b'),
  UNIQUE (code, qty),
  FOREIGN KEY (qty) REFERENCES customers (id)
)''');
      expect(x.uniques.map((u) => '${u.name}:${u.columns.join(',')}'), ['uq_code:code', 'null:code,qty']);
      expect(x.checks.map((c) => (c.name, c.expression)), [
        (null, 'qty > 0'),
        ('ck_pair', "qty < 100 AND code <> 'a,b'"),
      ]);
      expect(x.columns['code']!.collation, 'NOCASE');
      expect(x.columns['total']!.computed, 'qty * 2');
      expect(x.columns['total']!.computedStored, isTrue);
      expect(x.columns['note']!.computed, 'upper(code)');
      expect(x.columns['note']!.computedStored, isFalse);
    });

    test('indexes from CREATE INDEX', () {
      final a = parseSqliteCreateIndex(
        'CREATE UNIQUE INDEX IF NOT EXISTS main."ix a" ON orders (qty DESC, lower(code)) WHERE qty > 0',
      )!;
      expect(a.name, 'ix a');
      expect(a.unique, isTrue);
      expect(a.columns, ['qty', '(lower(code))']);
      expect(a.descending, {'qty'});
      expect(a.where, 'qty > 0');
      final b = parseSqliteCreateIndex('CREATE INDEX ix_b ON orders(code COLLATE NOCASE ASC)')!;
      expect(b.columns, ['code']);
      expect(parseSqliteCreateIndex('SELECT 1'), isNull);
    });

    test('reader', () async {
      final s = ScriptedSession()
        ..on(
          'sqlite_master',
          Rows(
            ['type', 'name', 'sql'],
            [
              [
                'table',
                'orders',
                'CREATE TABLE orders (id INTEGER PRIMARY KEY, code TEXT UNIQUE, qty INT, CHECK (qty > 0))',
              ],
              ['index', 'ix_qty', 'CREATE INDEX ix_qty ON orders (qty DESC)'],
            ],
          ),
        );
      final dc = scriptedConnection(s, dbmsName: 'SQLite', dbmsVersion: '3.45.1');
      final x = await DesignCatalog.of(dc)!
          .tableExtras(DbTable(catalog: null, schema: null, name: 'orders', type: 'TABLE'));
      expect(x.uniques.single.columns, ['code']);
      expect(x.checks.single.expression, 'qty > 0');
      expect(x.indexes['ix_qty']!.descending, {'qty'});
      expect(s.executed.single, contains('FROM sqlite_master'));
    });
  });

  test('a catalog that cannot be read leaves the ODBC definition', () async {
    final s = ScriptedSession()..on('.', StateError('permission denied'));
    final dc = scriptedConnection(s, dbmsName: 'PostgreSQL', dbmsVersion: '16.4');
    final t = await DesignCatalog.of(dc)!.loadTable(table);
    expect(t.name, 'orders');
    expect(t.checks, isEmpty);
  });

  test('helpers', () {
    expect(stripParens('(a > 0)'), 'a > 0');
    expect(stripParens('(a) and (b)'), '(a) and (b)');
    expect(unquoteIdent('"a""b"'), 'a"b');
    expect(unquoteIdent('[x]'), 'x');
    expect(rowBool({'v': 'Y'}, 'v'), isTrue);
    expect(rowBool({'v': 0}, 'v'), isFalse);
    expect(rowText({'v': 'X   '}, 'v'), 'X');
    expect(
      groupRows([
        {'k': 'b'},
        {'k': 'a'},
        {'k': 'b'},
      ], 'k').keys,
      ['b', 'a'],
    );
  });
}
