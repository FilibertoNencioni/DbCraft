// Phase 8: DBMS specific objects (DDL, catalog readers, sheets).

import 'package:dbcraft/features/design/capabilities.dart';
import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/catalog/extras.dart';
import 'package:dbcraft/features/design/ddl/extra_ddl.dart';
import 'package:dbcraft/features/design/model/extra_defs.dart';
import 'package:dbcraft/features/schema/ddl_builder.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/features/design/ui/extra_objects.dart';
import 'package:dbcraft/features/design/ui/package_editor.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/navigator/nav_nodes.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

ExtraDdl _ddl(String key) => ExtraDdl(sqlDialects[key]!);

Matcher _note(String text) => allOf(hasLength(1), everyElement(allOf(startsWith('--'), contains(text))));

void main() {
  group('capabilities', () {
    test('each kind of object belongs to its DBMS', () {
      Map<String, Object?> only(List<String> keys) => {for (final k in sqlDialects.keys) k: keys.contains(k)};
      final kinds = {
        DesignFeature.extensions: ['pg'],
        DesignFeature.enumTypes: ['pg'],
        DesignFeature.rowSecurity: ['pg'],
        DesignFeature.exclusionConstraints: ['pg'],
        DesignFeature.domains: ['pg', 'firebird'],
        DesignFeature.synonyms: ['mssql', 'oracle'],
        DesignFeature.packages: ['oracle'],
        DesignFeature.events: ['mysql', 'mariadb'],
        DesignFeature.warehouses: ['snowflake'],
        DesignFeature.stages: ['snowflake'],
        DesignFeature.fileFormats: ['snowflake'],
      };
      for (final e in kinds.entries) {
        expectPerFamily((d) => DesignCapabilities.of(d).has(e.key), only(e.value));
      }
      expect(DesignCapabilities.of(dialectAt('pg', '9.4')).reason(DesignFeature.rowSecurity), contains('9.5'));
    });
  });

  group('PostgreSQL', () {
    final pg = _ddl('pg');

    test('extensions', () {
      expect(pg.createExtension(const ExtensionDef(name: 'uuid-ossp', schema: 'ext', version: '1.1'), cascade: true), [
        'CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA ext VERSION \'1.1\' CASCADE',
      ]);
      const e = ExtensionDef(name: 'postgis', schema: 'public', version: '3.3.2', defaultVersion: '3.4.0');
      expect(e.updatable, isTrue);
      expect(pg.updateExtension(e), ['ALTER EXTENSION postgis UPDATE']);
      expect(
        pg.alterExtension(e, const ExtensionDef(name: 'postgis', schema: 'gis', version: '3.4.0', comment: 'GIS')),
        [
          'ALTER EXTENSION postgis SET SCHEMA gis',
          "ALTER EXTENSION postgis UPDATE TO '3.4.0'",
          "COMMENT ON EXTENSION postgis IS 'GIS'",
        ],
      );
      expect(pg.dropExtension(e, cascade: true), ['DROP EXTENSION postgis CASCADE']);
      expect(_ddl('mysql').createExtension(e), _note('MySQL non ha questo tipo di oggetto'));
    });

    test('enum types: values are added and renamed, never removed', () {
      const t = EnumTypeDef(name: 'stato', schema: 'app', values: ['nuovo', 'chiuso']);
      expect(pg.createEnum(t), ["CREATE TYPE app.stato AS ENUM ('nuovo', 'chiuso')"]);
      expect(
        pg.alterEnum(
          t,
          const EnumTypeDef(name: 'stato', schema: 'app', values: ['bozza', 'nuovo', 'aperto', 'chiuso', 'archiviato']),
        ),
        [
          "ALTER TYPE app.stato ADD VALUE 'bozza' BEFORE 'nuovo'",
          "ALTER TYPE app.stato ADD VALUE 'aperto' AFTER 'nuovo'",
          "ALTER TYPE app.stato ADD VALUE 'archiviato' AFTER 'chiuso'",
        ],
      );
      expect(pg.alterEnum(t, const EnumTypeDef(name: 'fase', schema: 'app', values: ['nuovo', 'concluso'])), [
        'ALTER TYPE app.stato RENAME TO fase',
        "ALTER TYPE app.fase RENAME VALUE 'chiuso' TO 'concluso'",
      ]);
      expect(pg.alterEnum(t, const EnumTypeDef(name: 'stato', schema: 'app', values: ['nuovo'])), [
        allOf(startsWith('--'), contains('chiuso'), endsWith('(non supportato)')),
      ]);
      expect(pg.alterEnum(t, const EnumTypeDef(name: 'stato', schema: 'app', values: ['chiuso', 'nuovo'])), [
        allOf(startsWith('--'), contains('Riordino')),
      ]);
      expect(pg.dropEnum(t, cascade: true), ['DROP TYPE app.stato CASCADE']);
    });

    test('domains', () {
      const d = DomainDef(
        name: 'importo',
        schema: 'app',
        baseType: 'numeric(12,2)',
        notNull: true,
        defaultValue: '0',
        checks: [DomainCheck('VALUE >= 0', name: 'importo_positivo')],
        comment: 'Euro',
      );
      expect(pg.createDomain(d), [
        'CREATE DOMAIN app.importo AS numeric(12,2) DEFAULT 0 NOT NULL CONSTRAINT importo_positivo CHECK (VALUE >= 0)',
        "COMMENT ON DOMAIN app.importo IS 'Euro'",
      ]);
      expect(
        pg.alterDomain(
          d,
          const DomainDef(
            name: 'prezzo',
            schema: 'app',
            baseType: 'numeric(12,2)',
            checks: [
              DomainCheck('VALUE > 0', name: 'importo_positivo'),
              DomainCheck('VALUE < 1000000', name: 'massimo'),
            ],
          ),
        ),
        [
          'ALTER DOMAIN app.importo RENAME TO prezzo',
          'ALTER DOMAIN app.prezzo DROP DEFAULT',
          'ALTER DOMAIN app.prezzo DROP NOT NULL',
          'ALTER DOMAIN app.prezzo DROP CONSTRAINT importo_positivo',
          'ALTER DOMAIN app.prezzo ADD CONSTRAINT importo_positivo CHECK (VALUE > 0)',
          'ALTER DOMAIN app.prezzo ADD CONSTRAINT massimo CHECK (VALUE < 1000000)',
          'COMMENT ON DOMAIN app.prezzo IS NULL',
        ],
      );
      expect(
        pg.alterDomain(
          d,
          const DomainDef(
            name: 'importo',
            schema: 'app',
            baseType: 'bigint',
            notNull: true,
            defaultValue: '0',
            checks: [DomainCheck('VALUE >= 0', name: 'importo_positivo')],
            comment: 'Euro',
          ),
        ),
        [allOf(startsWith('--'), contains('tipo'))],
      );
    });

    test('row level security policies', () {
      const p = PolicyDef(
        name: 'solo_propri',
        table: 'ordini',
        schema: 'app',
        command: PolicyCommand.select,
        roles: ['venditori'],
        using: 'owner = current_user',
      );
      expect(pg.createPolicy(p), [
        'CREATE POLICY solo_propri ON app.ordini FOR SELECT TO venditori USING (owner = current_user)',
      ]);
      expect(
        pg.createPolicy(
          const PolicyDef(
            name: 'chiusi',
            table: 'ordini',
            schema: 'app',
            permissive: false,
            using: 'not chiuso',
            withCheck: 'not chiuso',
          ),
        ),
        ['CREATE POLICY chiusi ON app.ordini AS RESTRICTIVE USING (not chiuso) WITH CHECK (not chiuso)'],
      );
      expect(
        pg.alterPolicy(
          p,
          const PolicyDef(
            name: 'propri',
            table: 'ordini',
            schema: 'app',
            command: PolicyCommand.select,
            using: 'owner = session_user',
          ),
        ),
        [
          'ALTER POLICY solo_propri ON app.ordini RENAME TO propri',
          'ALTER POLICY propri ON app.ordini TO PUBLIC USING (owner = session_user)',
        ],
      );
      // The command cannot change: drop and create.
      expect(
        pg.alterPolicy(
          p,
          const PolicyDef(
            name: 'solo_propri',
            table: 'ordini',
            schema: 'app',
            command: PolicyCommand.update,
            roles: ['venditori'],
            using: 'true',
          ),
        ),
        [
          'DROP POLICY solo_propri ON app.ordini',
          'CREATE POLICY solo_propri ON app.ordini FOR UPDATE TO venditori USING (true)',
        ],
      );
      expect(
        pg.setRowSecurity(null, 'app', 'ordini', const RowSecurity(), const RowSecurity(enabled: true, forced: true)),
        ['ALTER TABLE app.ordini ENABLE ROW LEVEL SECURITY', 'ALTER TABLE app.ordini FORCE ROW LEVEL SECURITY'],
      );
    });

    test('exclusion constraints', () {
      const x = ExclusionDef(
        name: 'no_sovrapposte',
        table: 'prenotazioni',
        schema: 'app',
        elements: [ExclusionElement('sala', '='), ExclusionElement('periodo', '&&')],
        where: 'not annullata',
      );
      expect(pg.addExclusion(x), [
        'ALTER TABLE app.prenotazioni ADD CONSTRAINT no_sovrapposte EXCLUDE USING gist (sala WITH =, periodo WITH &&) WHERE (not annullata)',
      ]);
      expect(
        pg.alterExclusion(
          x,
          const ExclusionDef(
            name: 'no_sovrapp',
            table: 'prenotazioni',
            schema: 'app',
            elements: [ExclusionElement('sala', '='), ExclusionElement('periodo', '&&')],
            where: 'not annullata',
          ),
        ),
        ['ALTER TABLE app.prenotazioni RENAME CONSTRAINT no_sovrapposte TO no_sovrapp'],
      );
      final parsed = parseExclusion(
        'EXCLUDE USING gist (sala WITH =, tstzrange(inizio, fine) WITH &&) WHERE ((NOT annullata)) DEFERRABLE',
        name: 'x',
        table: 't',
      );
      expect(parsed.method, 'gist');
      expect(
        [for (final e in parsed.elements) '${e.expression}|${e.operator}'],
        ['sala|=', 'tstzrange(inizio, fine)|&&'],
      );
      expect(parsed.where, 'NOT annullata');
    });
  });

  group('domains on Firebird', () {
    final fb = _ddl('firebird');
    const d = DomainDef(
      name: 'IMPORTO',
      baseType: 'NUMERIC(12,2)',
      defaultValue: '0',
      checks: [DomainCheck('VALUE >= 0')],
    );

    test('create, alter, drop', () {
      expect(fb.createDomain(d), ['CREATE DOMAIN IMPORTO AS NUMERIC(12,2) DEFAULT 0 CHECK (VALUE >= 0)']);
      expect(
        fb.alterDomain(
          d,
          const DomainDef(name: 'PREZZO', baseType: 'NUMERIC(14,2)', notNull: true, checks: [DomainCheck('VALUE > 0')]),
        ),
        [
          'ALTER DOMAIN IMPORTO TO PREZZO',
          'ALTER DOMAIN PREZZO TYPE NUMERIC(14,2)',
          'ALTER DOMAIN PREZZO DROP DEFAULT',
          'ALTER DOMAIN PREZZO SET NOT NULL',
          'ALTER DOMAIN PREZZO DROP CONSTRAINT',
          'ALTER DOMAIN PREZZO ADD CHECK (VALUE > 0)',
        ],
      );
      expect(fb.dropDomain(d, cascade: true), ['DROP DOMAIN IMPORTO']);
      expect(firebirdType(8, scale: -2, precision: 9), 'NUMERIC(9,2)');
      expect(firebirdType(37, charLength: 40), 'VARCHAR(40)');
      expect(firebirdType(261, subType: 1), 'BLOB SUB_TYPE TEXT');
    });
  });

  group('synonyms', () {
    test('create and drop per DBMS', () {
      const s = SynonymDef(
        name: 'clienti',
        schema: 'app',
        targetCatalog: 'crm',
        targetSchema: 'dbo',
        targetObject: 'customers',
      );
      expectPerFamily((d) => ExtraDdl(d).createSynonym(s), {
        'pg': _note('PostgreSQL'),
        'mssql': 'CREATE SYNONYM app.clienti FOR crm.dbo.customers',
        'mysql': _note('MySQL'),
        'mariadb': _note('MariaDB'),
        'oracle': 'CREATE SYNONYM "app"."clienti" FOR "crm"."dbo"."customers"',
        'db2': _note('Db2'),
        'sqlite': _note('SQLite'),
        'firebird': _note('Firebird'),
        'snowflake': _note('Snowflake'),
      });
      final ora = _ddl('oracle');
      const p = SynonymDef(name: 'EMP', targetSchema: 'HR', targetObject: 'EMPLOYEES', dbLink: 'PROD', isPublic: true);
      expect(ora.createSynonym(p), ['CREATE PUBLIC SYNONYM EMP FOR HR.EMPLOYEES@PROD']);
      expect(ora.dropSynonym(p), ['DROP PUBLIC SYNONYM EMP']);
      const own = SynonymDef(name: 'EMP', schema: 'APP', targetSchema: 'HR', targetObject: 'EMPLOYEES');
      expect(
        ora.alterSynonym(own, const SynonymDef(name: 'EMP', schema: 'APP', targetSchema: 'HR', targetObject: 'STAFF')),
        ['CREATE OR REPLACE SYNONYM APP.EMP FOR HR.STAFF'],
      );
      final ms = _ddl('mssql');
      expect(
        ms.alterSynonym(
          s,
          const SynonymDef(name: 'clienti', schema: 'app', targetSchema: 'dbo', targetObject: 'clients'),
        ),
        ['DROP SYNONYM app.clienti', 'CREATE SYNONYM app.clienti FOR dbo.clients'],
      );
      expect(splitBracketed('[crm].[dbo].[a]]b]'), ['crm', 'dbo', 'a]b']);
    });
  });

  group('Oracle packages', () {
    final ora = _ddl('oracle');

    test('the editor saves both parts and follows a renamed package', () {
      final dc = scriptedConnection(ScriptedSession(), dbmsName: 'Oracle', dbmsVersion: '19.0');
      final tab = PackageEditorTab(dc, schema: 'APP', name: 'UTIL');
      addTearDown(tab.dispose);
      expect(tab.isNew, isTrue);
      expect(tab.statements, hasLength(2));
      tab.spec.text = 'CREATE OR REPLACE PACKAGE APP.STRUMENTI AS\nEND;';
      tab.body.text = '';
      expect(tab.declaredName, 'STRUMENTI');
      expect(tab.statements, ['CREATE OR REPLACE PACKAGE APP.STRUMENTI AS\nEND;']);
      final existing = PackageEditorTab(
        dc,
        package: const PackageDef(name: 'UTIL', schema: 'APP', hasBody: true),
        source: const PackageSource(
          'CREATE OR REPLACE PACKAGE APP.UTIL AS\nEND;',
          'CREATE OR REPLACE PACKAGE BODY APP.UTIL AS\nEND;',
        ),
      );
      addTearDown(existing.dispose);
      expect(existing.isDirty, isFalse);
      existing.body.text = '';
      expect(existing.isDirty, isTrue);
      expect(existing.statements.last, 'DROP PACKAGE BODY APP.UTIL');
    });

    test('spec and body are saved in order', () {
      final t = ora.packageTemplate('APP', 'UTIL');
      expect(t.spec, startsWith('CREATE OR REPLACE PACKAGE APP.UTIL AS'));
      expect(ora.savePackage('APP', 'UTIL', t), [
        allOf(startsWith('CREATE OR REPLACE PACKAGE APP.UTIL AS'), endsWith('END UTIL;')),
        allOf(startsWith('CREATE OR REPLACE PACKAGE BODY APP.UTIL AS'), endsWith('END UTIL;')),
      ]);
      expect(
        ora.savePackage('APP', 'UTIL', const PackageSource('CREATE PACKAGE APP.UTIL AS\nEND;', ''), hadBody: true),
        ['CREATE OR REPLACE PACKAGE APP.UTIL AS\nEND;', 'DROP PACKAGE BODY APP.UTIL'],
      );
      expect(ora.dropPackage(const PackageDef(name: 'UTIL', schema: 'APP')), ['DROP PACKAGE APP.UTIL']);
    });
  });

  group('MySQL events', () {
    final my = _ddl('mysql');
    const e = EventDef(
      name: 'pulizia',
      catalog: 'shop',
      every: 1,
      unit: 'DAY',
      starts: '2027-01-01 03:00:00',
      body: 'DELETE FROM log WHERE creato < NOW() - INTERVAL 30 DAY;',
      comment: 'Ogni notte',
    );

    test('create, alter, drop', () {
      expect(my.createEvent(e), [
        "CREATE EVENT shop.pulizia ON SCHEDULE EVERY 1 DAY STARTS '2027-01-01 03:00:00' COMMENT 'Ogni notte' "
            'DO DELETE FROM log WHERE creato < NOW() - INTERVAL 30 DAY',
      ]);
      expect(
        my.createEvent(
          const EventDef(
            name: 'una_volta',
            catalog: 'shop',
            at: '2027-06-01 00:00:00',
            preserve: true,
            status: EventStatus.disabled,
            body: 'BEGIN\n  CALL chiudi();\nEND',
          ),
        ),
        [
          "CREATE EVENT shop.una_volta ON SCHEDULE AT '2027-06-01 00:00:00' ON COMPLETION PRESERVE DISABLE DO BEGIN\n  CALL chiudi();\nEND",
        ],
      );
      expect(
        my.alterEvent(
          e,
          const EventDef(
            name: 'pulizia_log',
            catalog: 'shop',
            every: 6,
            unit: 'HOUR',
            body: 'DELETE FROM log WHERE creato < NOW() - INTERVAL 30 DAY;',
            status: EventStatus.disabled,
            comment: 'Ogni notte',
          ),
        ),
        ['ALTER EVENT shop.pulizia ON SCHEDULE EVERY 6 HOUR RENAME TO shop.pulizia_log DISABLE'],
      );
      expect(my.alterEvent(e, e), isEmpty);
      expect(my.dropEvent(e), ['DROP EVENT shop.pulizia']);
      expect(
        _ddl('mariadb').alterEvent(
          e,
          const EventDef(
            name: 'pulizia',
            catalog: 'shop',
            every: 1,
            unit: 'DAY',
            starts: '2027-01-01 03:00:00',
            body: 'DELETE FROM log WHERE creato < NOW() - INTERVAL 30 DAY;',
            comment: 'Ogni notte',
            status: EventStatus.replicaDisabled,
          ),
        ),
        ['ALTER EVENT shop.pulizia DISABLE ON SLAVE'],
      );
    });
  });

  group('Snowflake', () {
    final sf = _ddl('snowflake');

    test('warehouses', () {
      const w = WarehouseDef(
        name: 'ETL',
        size: 'XSMALL',
        autoSuspend: 60,
        initiallySuspended: true,
        comment: 'Caricamenti',
      );
      expect(sf.createWarehouse(w), [
        "CREATE WAREHOUSE ETL WITH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 INITIALLY_SUSPENDED = TRUE COMMENT = 'Caricamenti'",
      ]);
      expect(
        sf.alterWarehouse(
          w,
          const WarehouseDef(name: 'ETL_WH', size: 'MEDIUM', autoSuspend: 60, autoResume: false, maxClusters: 3),
        ),
        [
          'ALTER WAREHOUSE ETL RENAME TO ETL_WH',
          'ALTER WAREHOUSE ETL_WH SET WAREHOUSE_SIZE = MEDIUM AUTO_RESUME = FALSE MAX_CLUSTER_COUNT = 3',
          'ALTER WAREHOUSE ETL_WH UNSET COMMENT',
        ],
      );
      expect(sf.suspendWarehouse(w, suspend: true), ['ALTER WAREHOUSE ETL SUSPEND']);
      expect(sf.suspendWarehouse(w, suspend: false), ['ALTER WAREHOUSE ETL RESUME IF SUSPENDED']);
      expect(
        [
          for (final s in ['X-Small', 'Large', '2X-Large', '4X-Large']) warehouseSize(s),
        ],
        ['XSMALL', 'LARGE', 'XXLARGE', 'X4LARGE'],
      );
    });

    test('stages and file formats', () {
      const s = StageDef(
        name: 'IMPORT',
        catalog: 'DB',
        schema: 'APP',
        url: 's3://bucket/in/',
        storageIntegration: 'S3_INT',
        fileFormat: 'CSV_STD',
      );
      expect(sf.createStage(s), [
        "CREATE STAGE DB.APP.IMPORT URL = 's3://bucket/in/' STORAGE_INTEGRATION = S3_INT FILE_FORMAT = (FORMAT_NAME = 'CSV_STD')",
      ]);
      expect(
        sf.alterStage(
          s,
          const StageDef(
            name: 'IMPORT',
            catalog: 'DB',
            schema: 'APP',
            url: 's3://bucket/new/',
            storageIntegration: 'S3_INT',
            fileFormat: 'CSV_STD',
          ),
        ),
        ["ALTER STAGE DB.APP.IMPORT SET URL = 's3://bucket/new/'"],
      );
      expect(sf.createStage(const StageDef(name: 'TMP', catalog: 'DB', schema: 'APP')), ['CREATE STAGE DB.APP.TMP']);
      const f = FileFormatDef(
        name: 'CSV_STD',
        catalog: 'DB',
        schema: 'APP',
        options: {'FIELD_DELIMITER': ';', 'SKIP_HEADER': '1', 'EMPTY_FIELD_AS_NULL': 'TRUE'},
      );
      expect(sf.createFileFormat(f), [
        "CREATE FILE FORMAT DB.APP.CSV_STD TYPE = CSV FIELD_DELIMITER = ';' SKIP_HEADER = 1 EMPTY_FIELD_AS_NULL = TRUE",
      ]);
      expect(
        sf.alterFileFormat(
          f,
          const FileFormatDef(
            name: 'CSV_STD',
            catalog: 'DB',
            schema: 'APP',
            options: {'FIELD_DELIMITER': ',', 'SKIP_HEADER': '1'},
          ),
        ),
        [
          "ALTER FILE FORMAT DB.APP.CSV_STD SET FIELD_DELIMITER = ','",
          'ALTER FILE FORMAT DB.APP.CSV_STD UNSET EMPTY_FIELD_AS_NULL',
        ],
      );
      expect(sf.alterFileFormat(f, const FileFormatDef(name: 'CSV_STD', catalog: 'DB', schema: 'APP', type: 'JSON')), [
        'DROP FILE FORMAT DB.APP.CSV_STD',
        'CREATE FILE FORMAT DB.APP.CSV_STD TYPE = JSON',
      ]);
      expect(
        fileFormatOptionsFromJson(
          'CSV',
          '{"TYPE":"CSV","FIELD_DELIMITER":";","SKIP_HEADER":1,"TRIM_SPACE":false,"NULL_IF":["\\\\N"]}',
        ),
        {'FIELD_DELIMITER': ';', 'SKIP_HEADER': '1', 'TRIM_SPACE': 'FALSE'},
      );
    });
  });

  group('every object renders through the generic entry points', () {
    test('create, alter to itself and drop', () {
      final samples = <String, ExtraObjectDef>{
        'pg': const DomainDef(name: 'd', schema: 's', baseType: 'int'),
        'mssql': const SynonymDef(name: 'x', schema: 'dbo', targetObject: 't'),
        'mysql': const EventDef(name: 'e', catalog: 'db', every: 1, body: 'DO 1'),
        'oracle': const SynonymDef(name: 'X', schema: 'APP', targetObject: 'T'),
        'firebird': const DomainDef(name: 'D', baseType: 'INTEGER'),
        'snowflake': const WarehouseDef(name: 'W'),
      };
      for (final e in samples.entries) {
        final ddl = _ddl(e.key);
        expect(executableStatements(ddl.create(e.value)), hasLength(1), reason: e.key);
        expect(ddl.alter(e.value, e.value), isEmpty, reason: e.key);
        expect(executableStatements(ddl.drop(e.value)), hasLength(1), reason: e.key);
      }
    });
  });

  group('catalog', () {
    test('PostgreSQL enums, domains and policies', () async {
      final s = ScriptedSession()
        ..on(
          'pg_enum',
          Rows(
            ['typname', 'enumlabel', 'comment'],
            [
              ['stato', 'nuovo', null],
              ['stato', 'chiuso', null],
              ['priorita', 'bassa', 'Priorità'],
            ],
          ),
        )
        ..on(
          "typtype = 'd'",
          Rows(
            ['typname', 'base_type', 'typnotnull', 'typdefault', 'collname', 'conname', 'check_def', 'comment'],
            [
              ['importo', 'numeric(12,2)', true, '0', null, 'positivo', 'CHECK ((VALUE >= (0)::numeric))', null],
              ['importo', 'numeric(12,2)', true, '0', null, 'massimo', 'CHECK ((VALUE < 1000000))', null],
              ['codice', 'character varying(10)', false, null, 'C', null, null, null],
            ],
          ),
        )
        ..on(
          'pg_policies',
          Rows(
            ['policyname', 'permissive', 'roles', 'cmd', 'qual', 'with_check'],
            [
              ['propri', 'PERMISSIVE', '{venditori,"capi area"}', 'SELECT', '(owner = CURRENT_USER)', null],
              ['tutti', 'RESTRICTIVE', '{public}', 'ALL', null, 'true'],
            ],
          ),
        );
      final cat = DesignCatalog.of(scriptedConnection(s))!;
      final enums = (await cat.extras(ExtraKind.enumTypes, schema: 'app')).cast<EnumTypeDef>();
      expect([for (final e in enums) '${e.name}:${e.values.join(',')}'], ['stato:nuovo,chiuso', 'priorita:bassa']);
      final domains = (await cat.extras(ExtraKind.domains, schema: 'app')).cast<DomainDef>();
      expect(domains.first.checks.map((c) => '${c.name}: ${c.expression}'), [
        'positivo: VALUE >= (0)::numeric',
        'massimo: VALUE < 1000000',
      ]);
      expect(domains.last.collation, 'C');
      final t = DbTable(catalog: null, schema: 'app', name: 'ordini', type: 'TABLE');
      final policies = (await cat.extras(ExtraKind.policies, table: t)).cast<PolicyDef>();
      expect(policies.first.roles, ['venditori', 'capi area']);
      expect(policies.first.command, PolicyCommand.select);
      expect(policies.last.roles, isEmpty);
      expect(policies.last.permissive, isFalse);
    });

    test('SQL Server synonyms and MySQL events', () async {
      final ms = ScriptedSession()
        ..on(
          'sys.synonyms',
          Rows(
            ['name', 'base_object_name'],
            [
              ['clienti', '[crm].[dbo].[customers]'],
              ['locale', '[dbo].[t]'],
            ],
          ),
        );
      final mcat = DesignCatalog.of(
        scriptedConnection(ms, dbmsName: 'Microsoft SQL Server', dbmsVersion: '16.00.4135'),
      )!;
      final syn = (await mcat.extras(ExtraKind.synonyms, catalog: 'shop', schema: 'app')).cast<SynonymDef>();
      expect([for (final x in syn) x.target], ['crm.dbo.customers', 'dbo.t']);
      expect(ms.executed.single, contains("sc.name = N'app'"));

      final my = ScriptedSession()
        ..on(
          'information_schema.EVENTS',
          Rows(
            [
              'EVENT_NAME',
              'EVENT_DEFINITION',
              'EVENT_TYPE',
              'EXECUTE_AT',
              'INTERVAL_VALUE',
              'INTERVAL_FIELD',
              'STARTS',
              'ENDS',
              'STATUS',
              'ON_COMPLETION',
              'EVENT_COMMENT',
            ],
            [
              [
                'pulizia',
                'DELETE FROM log',
                'RECURRING',
                null,
                '1',
                'DAY',
                '2027-01-01 03:00:00',
                null,
                'ENABLED',
                'NOT PRESERVE',
                '',
              ],
              [
                'once',
                'CALL x()',
                'ONE TIME',
                '2027-06-01 00:00:00',
                null,
                null,
                null,
                null,
                'DISABLED',
                'PRESERVE',
                'una volta',
              ],
            ],
          ),
        );
      final ycat = DesignCatalog.of(scriptedConnection(my, dbmsName: 'MySQL', dbmsVersion: '8.4.0'))!;
      final events = (await ycat.extras(ExtraKind.events, catalog: 'shop')).cast<EventDef>();
      expect(events.first.recurring, isTrue);
      expect(events.first.every, 1);
      expect(events.last.at, '2027-06-01 00:00:00');
      expect(events.last.status, EventStatus.disabled);
      expect(events.last.preserve, isTrue);
      // Read back, unchanged: nothing to alter.
      expect(ExtraDdl(sqlDialects['mysql']!).alter(events.first, events.first), isEmpty);
    });

    test('Oracle packages and their source', () async {
      final s = ScriptedSession()
        ..on(
          'all_objects',
          Rows(
            ['object_name', 'object_type', 'status'],
            [
              ['UTIL', 'PACKAGE', 'VALID'],
              ['UTIL', 'PACKAGE BODY', 'INVALID'],
              ['COSTANTI', 'PACKAGE', 'VALID'],
            ],
          ),
        )
        ..on(
          'all_source',
          Rows(
            ['type', 'text'],
            [
              ['PACKAGE', 'PACKAGE util AS\n'],
              ['PACKAGE', '  x NUMBER;\n'],
              ['PACKAGE', 'END util;\n'],
              ['PACKAGE BODY', 'PACKAGE BODY util AS\n'],
              ['PACKAGE BODY', 'END util;\n'],
            ],
          ),
        );
      final cat = DesignCatalog.of(scriptedConnection(s, dbmsName: 'Oracle', dbmsVersion: '19.0'))!;
      final pkgs = (await cat.extras(ExtraKind.packages, schema: 'APP')).cast<PackageDef>();
      expect([for (final p in pkgs) '${p.name} ${p.hasBody} ${p.valid}'], ['UTIL true false', 'COSTANTI false true']);
      final src = (await cat.packageSource(pkgs.first))!;
      expect(src.spec, 'CREATE OR REPLACE PACKAGE util AS\n  x NUMBER;\nEND util;');
      expect(src.body, 'CREATE OR REPLACE PACKAGE BODY util AS\nEND util;');
    });

    test('Snowflake warehouses and file formats', () async {
      final s = ScriptedSession()
        ..on(
          'SHOW WAREHOUSES',
          Rows(
            [
              'name',
              'state',
              'type',
              'size',
              'auto_suspend',
              'auto_resume',
              'min_cluster_count',
              'max_cluster_count',
              'scaling_policy',
              'comment',
            ],
            [
              ['COMPUTE_WH', 'SUSPENDED', 'STANDARD', 'X-Small', 600, 'true', 1, 1, 'STANDARD', null],
            ],
          ),
        )
        ..on(
          'SHOW FILE FORMATS',
          Rows(
            ['name', 'type', 'format_options', 'comment'],
            [
              ['CSV_STD', 'CSV', '{"TYPE":"CSV","FIELD_DELIMITER":";","SKIP_HEADER":1}', ''],
            ],
          ),
        );
      final cat = DesignCatalog.of(scriptedConnection(s, dbmsName: 'Snowflake', dbmsVersion: '8.30.1'))!;
      final w = (await cat.extras(ExtraKind.warehouses)).single as WarehouseDef;
      expect(w.size, 'XSMALL');
      expect(w.suspended, isTrue);
      expect(w.autoResume, isTrue);
      final f = (await cat.extras(ExtraKind.fileFormats, catalog: 'DB', schema: 'APP')).single as FileFormatDef;
      expect(f.options, {'FIELD_DELIMITER': ';', 'SKIP_HEADER': '1'});
      expect(s.executed.last, 'SHOW FILE FORMATS IN SCHEMA DB.APP');
    });
  });
  group('navigator', () {
    test('folders appear where the DBMS has the objects', () async {
      final pg = scriptedConnection(ordersSession());
      final top = await ConnectionNode(pg).load();
      expect(top.whereType<ExtraFolderNode>().map((f) => f.label), ['Estensioni']);
      final schema = objectFolders(pg, null, 'app').whereType<ExtraFolderNode>().map((f) => f.label);
      expect(schema, ['Tipi enumerati', 'Domini']);
      final t = DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE');
      final parts = await TableNode(pg, t).load();
      expect(parts.whereType<ExtraFolderNode>().map((f) => f.label), ['Policy di sicurezza', 'Vincoli di esclusione']);
      final view = DbTable(catalog: null, schema: 'app', name: 'v', type: 'VIEW');
      expect((await TableNode(pg, view).load()).whereType<ExtraFolderNode>(), isEmpty);

      final ms = scriptedConnection(ScriptedSession(), dbmsName: 'Microsoft SQL Server', dbmsVersion: '16.00.4135');
      expect(objectFolders(ms, 'db', 'dbo').whereType<ExtraFolderNode>().map((f) => f.label), ['Sinonimi']);
      final sq = scriptedConnection(ScriptedSession(), dbmsName: 'SQLite', dbmsVersion: '3.45');
      expect(objectFolders(sq, null, null).whereType<ExtraFolderNode>(), isEmpty);
    });

    test('a schema change reloads the open folders of the schema', () {
      final dc = scriptedConnection(ordersSession());
      final root = ConnectionNode(dc);
      final ext = ExtraFolderNode(dc, ExtraKind.extensions)..children = [];
      final domains = ExtraFolderNode(dc, ExtraKind.domains, schema: 'app')..children = [];
      final t = DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE');
      final policies = ExtraFolderNode(dc, ExtraKind.policies, table: t)..children = [];
      root.children = [ext, domains, policies];
      expect(
        nodesForSchemaChanges(root, [extraScope(ExtraKind.domains, schema: 'app')]),
        containsAll([domains, policies]),
      );
      final hit = nodesForSchemaChanges(root, [extraScope(ExtraKind.policies, table: t)]);
      expect(hit, contains(policies));
      expect(hit, isNot(contains(ext)));
      expect(nodesForSchemaChanges(root, [extraScope(ExtraKind.extensions)]), contains(ext));
    });
  });

  group('sheets and actions', () {
    Future<BuildContext> host(WidgetTester tester) async {
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
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      return ctx;
    }

    Finder field(String label) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(FormRow)),
      matching: find.byType(EditableText),
    );

    Future<void> type(WidgetTester tester, Finder f, String text) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.enterText(f, text);
      await tester.pumpAndSettle();
    }

    Finder cell(int i) => find.descendant(of: find.byType(EditableGrid), matching: find.byType(EditableText)).at(i);

    Future<void> runScript(WidgetTester tester) async {
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esegui').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    testWidgets('creates an enum type from its sheet', (tester) async {
      final s = ordersSession();
      final dc = scriptedConnection(s);
      final ctx = await host(tester);
      final done = createExtra(ctx, dc, ExtraKind.enumTypes, schema: 'app');
      await tester.pumpAndSettle();
      expect(find.text('Nuovo tipo enumerato'), findsOneWidget);
      await type(tester, field('Nome'), 'stato');
      await type(tester, cell(0), 'nuovo');
      await tester.tap(find.text('Aggiungi valore'));
      await tester.pumpAndSettle();
      await type(tester, cell(1), 'chiuso');
      expect(find.textContaining("CREATE TYPE app.stato AS ENUM ('nuovo', 'chiuso');"), findsOneWidget);
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(await done, isTrue);
      expect(s.executed, contains("CREATE TYPE app.stato AS ENUM ('nuovo', 'chiuso')"));
    });

    testWidgets('a policy on a table without row security offers to turn it on', (tester) async {
      final s = ordersSession()
        ..on(
          'relrowsecurity',
          Rows(
            ['relrowsecurity', 'relforcerowsecurity'],
            [
              [false, false],
            ],
          ),
        )
        ..on(
          'FROM pg_roles r ORDER',
          Rows(
            ['rolname', 'rolcanlogin'],
            [
              ['venditori', false],
            ],
          ),
        );
      final dc = scriptedConnection(s);
      final ctx = await host(tester);
      final t = DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE');
      final done = createExtra(ctx, dc, ExtraKind.policies, table: t);
      await tester.pumpAndSettle();
      expect(find.textContaining('è disattivata su orders'), findsOneWidget);
      await type(tester, field('Nome'), 'propri');
      await type(tester, field('Righe visibili (USING)'), 'owner = current_user');
      await tester.ensureVisible(find.text('venditori'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('venditori'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(await done, isTrue);
      expect(
        s.executed,
        containsAllInOrder([
          'CREATE POLICY propri ON app.orders TO venditori USING (owner = current_user)',
          'ALTER TABLE app.orders ENABLE ROW LEVEL SECURITY',
        ]),
      );
    });

    testWidgets('a MySQL event warns when the scheduler is off', (tester) async {
      final s = ScriptedSession()
        ..on(
          'event_scheduler',
          Rows(
            ['state'],
            [
              ['OFF'],
            ],
          ),
        );
      final dc = scriptedConnection(s, dbmsName: 'MySQL', dbmsVersion: '8.4.0');
      final ctx = await host(tester);
      final done = createExtra(ctx, dc, ExtraKind.events, catalog: 'shop');
      await tester.pumpAndSettle();
      expect(find.textContaining('event_scheduler = OFF'), findsOneWidget);
      await type(tester, field('Nome'), 'pulizia');
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      expect(find.text('Scrivi l\'istruzione da eseguire'), findsOneWidget);
      await type(
        tester,
        find.byType(EditableText).at(find.byType(EditableText).evaluate().length - 2),
        'DELETE FROM log',
      );
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(await done, isTrue);
      expect(s.executed, contains('CREATE EVENT shop.pulizia ON SCHEDULE EVERY 1 DAY DO DELETE FROM log'));
    });

    testWidgets('drops a domain with CASCADE', (tester) async {
      final s = ordersSession();
      final dc = scriptedConnection(s);
      final ctx = await host(tester);
      final done = dropExtra(
        ctx,
        dc,
        ExtraKind.domains,
        const DomainDef(name: 'importo', schema: 'app', baseType: 'numeric'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('CASCADE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elimina').last);
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(await done, isTrue);
      expect(s.executed, contains('DROP DOMAIN app.importo CASCADE'));
    });
  });
}
