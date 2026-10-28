// Phase 9: NoSQL databases (MongoDB, Cassandra, Redis) and BigQuery:
// generated commands, catalog readers, security, sheets.

import 'package:dbcraft/features/design/capabilities.dart';
import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/catalog/nosql.dart';
import 'package:dbcraft/features/design/catalog/security.dart';
import 'package:dbcraft/features/design/ddl/nosql_ddl.dart';
import 'package:dbcraft/features/design/ddl/object_ddl.dart';
import 'package:dbcraft/features/design/ddl/security/security_ddl.dart';
import 'package:dbcraft/features/design/model/nosql_defs.dart';
import 'package:dbcraft/features/design/model/object_defs.dart';
import 'package:dbcraft/features/design/model/security_defs.dart';
import 'package:dbcraft/features/design/security_design.dart';
import 'package:dbcraft/features/design/ui/nosql_actions.dart';
import 'package:dbcraft/features/design/ui/security_tab.dart';
import 'package:dbcraft/features/schema/ddl_builder.dart';
import 'package:dbcraft/features/schema/schema_model.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/navigator/nav_nodes.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

final mongo = SqlDialect(dbmsName: 'MongoDB', dbmsVersion: '8.0.4');
final cassandra = SqlDialect(dbmsName: 'Apache Cassandra', dbmsVersion: '5.0.2');
final redis = SqlDialect(dbmsName: 'Redis', dbmsVersion: '7.4.1');
final bigquery = SqlDialect(dbmsName: 'Google BigQuery', quote: '`');

void main() {
  group('capabilities', () {
    test('each NoSQL database offers its own tools', () {
      Set<DesignFeature> of(SqlDialect d) => DesignCapabilities.of(d).features;
      expect(of(mongo), containsAll([DesignFeature.createTable, DesignFeature.indexes, DesignFeature.users]));
      expect(of(mongo), isNot(contains(DesignFeature.checkConstraints)));
      expect(
        of(cassandra),
        containsAll([DesignFeature.userTypes, DesignFeature.materializedViews, DesignFeature.roles]),
      );
      expect(of(redis), {DesignFeature.users});
      expect(
        DesignCapabilities.of(SqlDialect(dbmsName: 'Redis', dbmsVersion: '5.0.7')).has(DesignFeature.users),
        isFalse,
      );
      expect(of(bigquery), containsAll([DesignFeature.createTable, DesignFeature.schemas, DesignFeature.grants]));
      expect(of(bigquery), isNot(contains(DesignFeature.indexes)));
      // The SQL designer stays away from Cassandra (its own sheets) and
      // the document / key-value stores.
      expect(sqlDesign(cassandra), isFalse);
      expect(sqlDesign(mongo), isFalse);
      expect(sqlDesign(bigquery), isTrue);
    });
  });

  group('MongoDB commands', () {
    const ddl = MongoDdl();

    test('collections', () {
      expect(
        ddl.createCollection(
          const MongoCollectionDef(
            database: 'shop',
            name: 'ordini',
            collation: 'it',
            validator: r'{$jsonSchema: {required: ["codice"]}}',
            validationLevel: 'moderate',
          ),
        ),
        [
          'db.getSiblingDB("shop").createCollection("ordini", {collation: {locale: "it"}, '
              r'validator: {$jsonSchema: {required: ["codice"]}}, validationLevel: "moderate"})',
        ],
      );
      expect(
        ddl.createCollection(
          const MongoCollectionDef(
            database: 'shop',
            name: 'misure',
            type: MongoCollectionType.timeseries,
            timeField: 't',
            metaField: 'sensore',
            granularity: 'hours',
            expireAfterSeconds: 86400,
          ),
        ),
        [
          'db.getSiblingDB("shop").createCollection("misure", {timeseries: {timeField: "t", metaField: "sensore", '
              'granularity: "hours"}, expireAfterSeconds: 86400})',
        ],
      );
      expect(
        ddl.createCollection(
          const MongoCollectionDef(database: 'shop', name: 'log', type: MongoCollectionType.capped, cappedSize: 4096),
        ),
        ['db.getSiblingDB("shop").createCollection("log", {capped: true, size: 4096})'],
      );
      const c = MongoCollectionDef(database: 'shop', name: 'ordini', validator: '{a: 1}');
      expect(
        ddl.alterCollection(c, const MongoCollectionDef(database: 'shop', name: 'storico', validationAction: 'warn')),
        [
          'db.getSiblingDB("shop").getCollection("ordini").renameCollection("storico")',
          'db.getSiblingDB("shop").runCommand({collMod: "storico", validator: {}, validationAction: "warn"})',
        ],
      );
      expect(ddl.alterCollection(c, c), isEmpty);
      expect(
        ddl.alterCollection(
          c,
          const MongoCollectionDef(database: 'shop', name: 'ordini', validator: '{a: 1}', collation: 'en'),
        ),
        [allOf(startsWith('--'), contains('collation'))],
      );
      expect(ddl.dropDatabase('shop'), ['db.getSiblingDB("shop").dropDatabase()']);
      expect(ddl.createDatabase('nuovo', 'prima'), ['db.getSiblingDB("nuovo").createCollection("prima")']);
      expect(shellKey('a.b'), '"a.b"');
    });

    test('indexes and views', () {
      const i = MongoIndexDef(
        database: 'shop',
        collection: 'ordini',
        keys: [MongoIndexKey('codice'), MongoIndexKey('data', '-1'), MongoIndexKey('note', 'text')],
        unique: true,
        partialFilter: r'{codice: {$exists: true}}',
      );
      expect(i.effectiveName, 'codice_1_data_-1_note_text');
      expect(ddl.createIndex(i), [
        'db.getSiblingDB("shop").getCollection("ordini").createIndex({codice: 1, data: -1, note: "text"}, '
            r'{unique: true, partialFilterExpression: {codice: {$exists: true}}})',
      ]);
      final hidden = MongoIndexDef(
        database: 'shop',
        collection: 'ordini',
        keys: i.keys,
        unique: true,
        partialFilter: i.partialFilter,
        hidden: true,
      );
      expect(ddl.alterIndex(i, hidden), [
        'db.getSiblingDB("shop").runCommand({collMod: "ordini", index: {name: "codice_1_data_-1_note_text", hidden: true}})',
      ]);
      expect(
        ddl.alterIndex(i, const MongoIndexDef(database: 'shop', collection: 'ordini', keys: [MongoIndexKey('codice')])),
        [
          'db.getSiblingDB("shop").getCollection("ordini").dropIndex("codice_1_data_-1_note_text")',
          'db.getSiblingDB("shop").getCollection("ordini").createIndex({codice: 1})',
        ],
      );
      const v = MongoViewDef(
        database: 'shop',
        name: 'aperti',
        viewOn: 'ordini',
        pipeline: r'[{$match: {stato: "aperto"}}]',
      );
      expect(ddl.createView(v), [
        r'db.getSiblingDB("shop").createView("aperti", "ordini", [{$match: {stato: "aperto"}}])',
      ]);
      expect(ddl.alterView(v, const MongoViewDef(database: 'shop', name: 'aperti', viewOn: 'ordini', pipeline: '[]')), [
        'db.getSiblingDB("shop").runCommand({collMod: "aperti", viewOn: "ordini", pipeline: []})',
      ]);
    });
  });

  group('Cassandra CQL', () {
    final ddl = CassandraDdl(cassandra);

    test('keyspaces', () {
      expect(ddl.createKeyspace(const KeyspaceDef(name: 'shop', replicationFactor: 3)), [
        "CREATE KEYSPACE shop WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 3}",
      ]);
      const nts = KeyspaceDef(name: 'shop', strategy: 'NetworkTopologyStrategy', datacenters: {'dc1': 3, 'dc2': 2});
      expect(ddl.createKeyspace(nts), [
        "CREATE KEYSPACE shop WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3, 'dc2': 2}",
      ]);
      expect(ddl.alterKeyspace(const KeyspaceDef(name: 'shop'), nts), [
        "ALTER KEYSPACE shop WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3, 'dc2': 2}",
        startsWith('-- Dopo aver cambiato la replica'),
      ]);
      expect(
        ddl.alterKeyspace(const KeyspaceDef(name: 'shop'), const KeyspaceDef(name: 'shop', durableWrites: false)),
        ['ALTER KEYSPACE shop WITH durable_writes = false'],
      );
    });

    test('tables', () {
      const t = CqlTableDef(
        keyspace: 'iot',
        name: 'letture',
        columns: [
          CqlColumn('sensore', 'text', kind: CqlColumnKind.partition),
          CqlColumn('ora', 'timestamp', kind: CqlColumnKind.clustering, descending: true),
          CqlColumn('luogo', 'text', kind: CqlColumnKind.static),
          CqlColumn('valore', 'double'),
        ],
        defaultTtl: 3600,
        compaction: 'TimeWindowCompactionStrategy',
      );
      expect(ddl.createTable(t), [
        'CREATE TABLE iot.letture (\n  sensore text,\n  ora timestamp,\n  luogo text STATIC,\n  valore double,\n'
            "  PRIMARY KEY (sensore, ora)\n) WITH CLUSTERING ORDER BY (ora DESC) AND default_time_to_live = 3600 AND "
            "compaction = {'class': 'TimeWindowCompactionStrategy'}",
      ]);
      expect(
        ddl
            .createTable(
              const CqlTableDef(
                keyspace: 'iot',
                name: 'k',
                columns: [
                  CqlColumn('a', 'int', kind: CqlColumnKind.partition),
                  CqlColumn('b', 'int', kind: CqlColumnKind.partition),
                ],
              ),
            )
            .single,
        contains('PRIMARY KEY ((a, b))'),
      );
      final changed = CqlTableDef(
        keyspace: 'iot',
        name: 'letture',
        columns: [...t.columns.where((c) => c.name != 'luogo'), const CqlColumn('unita', 'text')],
        defaultTtl: 0,
        compaction: 'TimeWindowCompactionStrategy',
        comment: 'Sensori',
      );
      expect(ddl.alterTable(t, changed), [
        'ALTER TABLE iot.letture DROP luogo',
        'ALTER TABLE iot.letture ADD unita text',
        "ALTER TABLE iot.letture WITH comment = 'Sensori' AND default_time_to_live = 0",
      ]);
      final rekeyed = CqlTableDef(
        keyspace: 'iot',
        name: 'letture',
        columns: [
          for (final c in t.columns)
            c.name == 'ora' ? const CqlColumn('ora', 'timestamp', kind: CqlColumnKind.clustering) : c,
        ],
        defaultTtl: 3600,
        compaction: 'TimeWindowCompactionStrategy',
      );
      expect(ddl.alterTable(t, rekeyed), [allOf(startsWith('--'), contains('chiave primaria'))]);
    });

    test('indexes, types, materialized views', () {
      expect(
        ddl.createIndex(
          const CqlIndexDef(keyspace: 'iot', table: 'letture', name: 'ix_v', column: 'valore', using: 'sai'),
        ),
        ["CREATE INDEX ix_v ON iot.letture (valore) USING 'sai'"],
      );
      expect(ddl.dropIndex(const CqlIndexDef(keyspace: 'iot', table: 'letture', name: 'ix_v', column: '')), [
        'DROP INDEX iot.ix_v',
      ]);
      const u = UdtDef(keyspace: 'iot', name: 'indirizzo', fields: [('via', 'text'), ('cap', 'text')]);
      expect(ddl.createType(u), ['CREATE TYPE iot.indirizzo (via text, cap text)']);
      expect(
        ddl.alterType(
          u,
          const UdtDef(
            keyspace: 'iot',
            name: 'indirizzo',
            fields: [('strada', 'text'), ('cap', 'text'), ('citta', 'text')],
          ),
        ),
        ['ALTER TYPE iot.indirizzo RENAME via TO strada', 'ALTER TYPE iot.indirizzo ADD citta text'],
      );
      expect(
        ddl.createMaterializedView(
          const CqlMaterializedViewDef(
            keyspace: 'iot',
            name: 'per_ora',
            baseTable: 'letture',
            where: 'ora IS NOT NULL AND sensore IS NOT NULL',
            primaryKey: '(ora, sensore)',
          ),
        ),
        [
          'CREATE MATERIALIZED VIEW iot.per_ora AS SELECT * FROM iot.letture WHERE ora IS NOT NULL AND sensore IS NOT NULL PRIMARY KEY (ora, sensore)',
        ],
      );
    });
  });

  group('security', () {
    test('MongoDB users, roles and privileges', () {
      final ddl = SecurityDdl.forFamily(mongo);
      const u = PrincipalDef(name: 'mario', kind: PrincipalKind.user, host: 'admin');
      const r = PrincipalDef(name: 'lettori', kind: PrincipalKind.role, host: 'shop');
      expect(ddl.createPrincipal(u, password: 'x'), [
        'db.getSiblingDB("admin").runCommand({createUser: "mario", pwd: ⟦secret:1⟧, roles: []})',
      ]);
      expect(ddl.secrets.values.values, ['"x"']);
      expect(ddl.createPrincipal(r), [
        'db.getSiblingDB("shop").runCommand({createRole: "lettori", privileges: [], roles: []})',
      ]);
      expect(
        ddl.membershipChanges(u, const [], const [
          RoleMembership('readWrite', 'mario', roleHost: 'shop', memberHost: 'admin'),
        ]),
        ['db.getSiblingDB("admin").runCommand({grantRolesToUser: "mario", roles: [{role: "readWrite", db: "shop"}]})'],
      );
      expect(
        ddl.grantChanges(r, const [], const [
          GrantDef(privilege: 'find', target: GrantTarget.table, catalog: 'shop', object: 'ordini'),
          GrantDef(privilege: 'insert', target: GrantTarget.table, catalog: 'shop', object: 'ordini'),
        ]),
        [
          'db.getSiblingDB("shop").runCommand({grantPrivilegesToRole: "lettori", privileges: '
              '[{resource: {db: "shop", collection: "ordini"}, actions: ["find", "insert"]}]})',
        ],
      );
      expect(
        ddl.grantChanges(u, const [], const [
          GrantDef(privilege: 'find', target: GrantTarget.database, catalog: 'shop'),
        ]),
        [allOf(startsWith('--'), contains('ruoli'))],
      );
      expect(ddl.dropPrincipal(u), ['db.getSiblingDB("admin").runCommand({dropUser: "mario"})']);
      expect(PrincipalDesign.create(mongo, PrincipalKind.user).working.host, 'admin');
      expect(mongoBuiltinRoles(const ['shop']), containsAll([('root', 'admin'), ('readWrite', 'shop')]));
    });

    test('Cassandra roles and permissions', () {
      final ddl = SecurityDdl.forFamily(cassandra);
      const u = PrincipalDef(name: 'mario', kind: PrincipalKind.user);
      expect(ddl.createPrincipal(u, password: 'x'), ['CREATE ROLE mario WITH PASSWORD = ⟦secret:1⟧ AND LOGIN = true']);
      expect(ddl.alterPrincipal(u, u.copyWith(superuser: true)), ['ALTER ROLE mario WITH SUPERUSER = true']);
      expect(
        ddl.grantChanges(u, const [], const [
          GrantDef(privilege: 'SELECT', target: GrantTarget.database, catalog: 'iot'),
          GrantDef(privilege: 'MODIFY', target: GrantTarget.database, catalog: 'iot'),
          GrantDef(privilege: 'SELECT', target: GrantTarget.system),
        ]),
        [
          'GRANT SELECT ON KEYSPACE iot TO mario',
          'GRANT MODIFY ON KEYSPACE iot TO mario',
          'GRANT SELECT ON ALL KEYSPACES TO mario',
        ],
      );
      expect(ddl.membershipChanges(u, const [], const [RoleMembership('lettori', 'mario')]), [
        'GRANT lettori TO mario',
      ]);
    });

    test('Redis ACL users', () {
      final ddl = SecurityDdl.forFamily(redis);
      const u = PrincipalDef(name: 'app', kind: PrincipalKind.user, aclRules: '~app:*  +@read');
      expect(ddl.createPrincipal(u, password: 'pa ss"'), ['ACL SETUSER app on ⟦secret:1⟧ ~app:* +@read']);
      expect(ddl.secrets.values.values, [r'">pa ss\""']);
      expect(ddl.alterPrincipal(u, u.copyWith(locked: true, aclRules: '~cache:* +get')), [
        'ACL SETUSER app off resetkeys resetchannels -@all ~cache:* +get',
      ]);
      expect(ddl.dropPrincipal(u), ['ACL DELUSER app']);
      final parsed = parseAclUser(
        'user app off #2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b ~app:* resetchannels -@all +get',
      )!;
      expect(parsed.name, 'app');
      expect(parsed.locked, isTrue);
      expect(parsed.aclRules, '~app:* resetchannels -@all +get');
      expect(parseAclUser('not a user'), isNull);
    });

    test('BigQuery grants of IAM roles', () {
      final ddl = SecurityDdl.forFamily(bigquery);
      const who = PrincipalDef(name: 'user:mario@example.com', kind: PrincipalKind.user);
      expect(ddl.canCreate(PrincipalKind.user), isFalse);
      expect(
        ddl.grantChanges(who, const [], const [
          GrantDef(
            privilege: 'roles/bigquery.dataViewer',
            target: GrantTarget.table,
            catalog: 'prj',
            schema: 'ds',
            object: 't',
          ),
        ]),
        ['GRANT `roles/bigquery.dataViewer` ON TABLE prj.ds.t TO "user:mario@example.com"'],
      );
      expect(
        ddl.grantChanges(who, const [
          GrantDef(privilege: 'roles/bigquery.dataEditor', target: GrantTarget.schema, catalog: 'my-prj', schema: 'ds'),
        ], const []),
        ['REVOKE `roles/bigquery.dataEditor` ON SCHEMA `my-prj`.ds FROM "user:mario@example.com"'],
      );
    });
  });

  group('BigQuery DDL', () {
    test('tables with partitioning, clustering and descriptions', () {
      final b = DdlBuilder(bigquery);
      const t = TableDef(
        catalog: 'prj',
        schema: 'ds',
        name: 'ordini',
        comment: 'Ordini',
        columns: [
          ColumnDef(name: 'id', type: 'INT64', nullable: false, comment: 'chiave'),
          ColumnDef(name: 'creato', type: 'TIMESTAMP'),
        ],
        primaryKey: PrimaryKeyDef(columns: ['id']),
        options: {'partitionBy': 'DATE(creato)', 'clusterBy': 'id'},
      );
      expect(b.createTable(t), [
        "CREATE TABLE prj.ds.ordini (\n\tid INT64 NOT NULL OPTIONS(description = 'chiave'),\n\tcreato TIMESTAMP,\n"
            "\tPRIMARY KEY (id) NOT ENFORCED\n) PARTITION BY DATE(creato) CLUSTER BY id OPTIONS(description = 'Ordini')",
      ]);
      expect(b.tableComment(t, ''), ['ALTER TABLE prj.ds.ordini SET OPTIONS (description = NULL)']);
      expect(b.columnComment(t, const ColumnDef(name: 'id', type: 'INT64', comment: 'x')), [
        "ALTER TABLE prj.ds.ordini ALTER COLUMN id SET OPTIONS (description = 'x')",
      ]);
      expect(commonTypes(DbFamily.bigquery), contains('INT64'));
      final o = ObjectDdl(bigquery);
      expect(o.createSchema(const SchemaDef(name: 'ds', catalog: 'prj', comment: 'Dati')), [
        "CREATE SCHEMA prj.ds OPTIONS(description = 'Dati')",
      ]);
      expect(o.dropSchema(const SchemaDef(name: 'ds', catalog: 'prj'), cascade: true), ['DROP SCHEMA prj.ds CASCADE']);
      expect(o.canDropSchemaCascade, isTrue);
    });
  });

  group('catalog', () {
    test('MongoDB collection options and indexes', () async {
      final s = ScriptedSession()
        ..on(
          'getCollectionInfos',
          Rows(
            ['name', 'type', 'options'],
            [
              [
                'ordini',
                'collection',
                r'{collation: {locale: "it"}, validator: {$jsonSchema: {required: ["codice"]}}, validationLevel: "moderate"}',
              ],
            ],
          ),
        )
        ..on(
          r'getIndexes\(\)',
          Rows(
            ['v', 'key', 'name', 'unique', 'expireAfterSeconds'],
            [
              [2, '{_id: 1}', '_id_', null, null],
              [2, '{codice: 1, data: -1}', 'ix', 'true', null],
              [2, '{scade: 1}', 'scade_1', null, 3600],
            ],
          ),
        );
      final q = DesignCatalog.of(scriptedConnection(s, dbmsName: 'MongoDB', dbmsVersion: '8.0.4'))!.queries;
      final c = (await readMongoCollection(q, 'shop', 'ordini'))! as MongoCollectionDef;
      expect(c.collation, 'it');
      expect(c.validationLevel, 'moderate');
      expect(c.validator, contains('codice'));
      expect(const MongoDdl().alterCollection(c, c), isEmpty);
      final ix = await readMongoIndexes(q, 'shop', 'ordini');
      expect(
        [
          for (final i in ix) '${i.name}:${[for (final k in i.keys) '${k.field}${k.kind}'].join(',')}',
        ],
        ['_id_:_id1', 'ix:codice1,data-1', 'scade_1:scade1'],
      );
      expect(ix[1].unique, isTrue);
      expect(ix[2].ttlSeconds, 3600);
    });

    test('Cassandra tables and keyspaces', () async {
      final s = ScriptedSession()
        ..on(
          'system_schema.keyspaces',
          Rows(
            ['keyspace_name', 'durable_writes', 'replication'],
            [
              ['iot', 'true', '{"class":"org.apache.cassandra.locator.NetworkTopologyStrategy","dc1":"3"}'],
            ],
          ),
        )
        ..on(
          'system_schema.tables',
          Rows(
            ['comment', 'default_time_to_live', 'gc_grace_seconds', 'compaction'],
            [
              ['', 0, 864000, '{"class":"org.apache.cassandra.db.compaction.SizeTieredCompactionStrategy"}'],
            ],
          ),
        )
        ..on(
          'system_schema.columns',
          Rows(
            ['column_name', 'clustering_order', 'kind', 'position', 'type'],
            [
              ['valore', 'none', 'regular', -1, 'double'],
              ['ora', 'desc', 'clustering', 0, 'timestamp'],
              ['sensore', 'none', 'partition_key', 0, 'text'],
            ],
          ),
        );
      final q = DesignCatalog.of(scriptedConnection(s, dbmsName: 'Apache Cassandra', dbmsVersion: '5.0.2'))!.queries;
      final k = (await readKeyspace(q, 'iot'))!;
      expect(k.networkTopology, isTrue);
      expect(k.datacenters, {'dc1': 3});
      final t = (await readCqlTable(q, 'iot', 'letture'))!;
      expect([for (final c in t.columns) c.name], ['sensore', 'ora', 'valore']);
      expect(t.columns[1].descending, isTrue);
      expect(t.compaction, 'SizeTieredCompactionStrategy');
    });

    test('Redis users from ACL LIST', () async {
      final s = ScriptedSession()
        ..on(
          'ACL LIST',
          Rows(
            ['#', 'value'],
            [
              [1, 'user default on nopass sanitize-payload ~* &* +@all'],
              [2, 'user app off #abc ~app:* &* -@all +@read'],
            ],
          ),
        );
      final ps = await DesignCatalog.of(scriptedConnection(s, dbmsName: 'Redis', dbmsVersion: '7.4.1'))!.principals();
      expect(
        [for (final p in ps) '${p.name}:${p.locked}:${p.aclRules}'],
        ['default:false:~* &* +@all', 'app:true:~app:* &* -@all +@read'],
      );
    });
  });

  group('UI', () {
    Future<BuildContext> host(WidgetTester tester, {Widget? body}) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = await testApp(tester);
      late BuildContext ctx;
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  ctx = c;
                  return body ?? const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return ctx;
    }

    Future<void> runScript(WidgetTester tester) async {
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    Finder field(String label) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(FormRow)),
      matching: find.byType(EditableText),
    );

    testWidgets('creates a Cassandra table from its sheet', (tester) async {
      final s = ScriptedSession();
      final dc = scriptedConnection(s, dbmsName: 'Apache Cassandra', dbmsVersion: '5.0.2');
      final ctx = await host(tester);
      final done = createNosqlTable(ctx, dc, 'iot');
      await tester.pumpAndSettle();
      expect(find.text('Nuova tabella'), findsOneWidget);
      await tester.enterText(field('Nome'), 'letture');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aggiungi colonna'));
      await tester.pumpAndSettle();
      final cells = find.descendant(of: find.byType(EditableGrid), matching: find.byType(EditableText));
      await tester.enterText(cells.at(2), 'valore');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(await done, isTrue);
      expect(
        s.executed.last,
        startsWith('CREATE TABLE iot.letture (\n  id uuid,\n  valore text,\n  PRIMARY KEY (id)\n)'),
      );
    });

    testWidgets('a Redis user is edited with its ACL rules', (tester) async {
      final s = ScriptedSession()
        ..on(
          'ACL LIST',
          Rows(
            ['#', 'value'],
            [
              [1, 'user app on #abc ~app:* +@read'],
            ],
          ),
        );
      final dc = scriptedConnection(s, dbmsName: 'Redis', dbmsVersion: '7.4.1');
      expect(hasSecurity(dc), isTrue);
      final tab = SecurityTab(dc);
      addTearDown(tab.dispose);
      await host(tester, body: Builder(builder: tab.buildView));
      await tester.tap(find.text('app'));
      await tester.pumpAndSettle();
      expect(find.text('Regole ACL'), findsOneWidget);
      expect(find.text('Ruoli'), findsNothing);
      await tester.enterText(field('Regole'), '~app:* +@read +@write');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(s.executed, contains('ACL SETUSER app resetkeys resetchannels -@all ~app:* +@read +@write'));
    });

    test('navigator: security for the NoSQL stores, not for BigQuery', () async {
      expect(hasSecurity(scriptedConnection(ScriptedSession(), dbmsName: 'MongoDB', dbmsVersion: '8.0')), isTrue);
      expect(hasSecurity(scriptedConnection(ScriptedSession(), dbmsName: 'Google BigQuery')), isFalse);
      final cass = scriptedConnection(ScriptedSession(), dbmsName: 'Apache Cassandra', dbmsVersion: '5.0.2');
      expect(objectFolders(cass, 'iot', null).whereType<ExtraFolderNode>().map((f) => f.label), [
        'Tipi definiti dall\'utente',
      ]);
      expect(nosqlDesign(cass), isTrue);
    });
  });
}
