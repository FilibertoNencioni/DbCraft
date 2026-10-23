// Phase 7: users, roles and privileges (DDL per DBMS, edit session,
// catalog readers, password protection).

import 'package:dbcraft/features/design/catalog/design_catalog.dart';
import 'package:dbcraft/features/design/catalog/security.dart';
import 'package:dbcraft/features/design/ddl/security/security_ddl.dart';
import 'package:dbcraft/features/design/model/security_defs.dart';
import 'package:dbcraft/features/design/security_design.dart';
import 'package:dbcraft/features/design/ui/security_tab.dart';
import 'package:dbcraft/features/design/ui/table_permissions.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/navigator/nav_nodes.dart';
import 'package:dbcraft/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:dbcraft/features/schema/ddl_builder.dart';
import 'package:dbcraft/odbc/odbc_types.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:dbcraft/state/db_connection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

OdbcException odbcError(String message, {String state = '42000'}) =>
    OdbcException('SQLExecDirect', [OdbcDiag(state, 0, message)]);

bool _mysql(SqlDialect d) => d.family == DbFamily.mysql;

/// The user of the examples (a login on SQL Server).
PrincipalDef _user(SqlDialect d) => PrincipalDef(
  name: 'mario',
  kind: d.family == DbFamily.sqlServer ? PrincipalKind.login : PrincipalKind.user,
  host: _mysql(d) ? '%' : null,
);

const _role = PrincipalDef(name: 'lettori', kind: PrincipalKind.role);

GrantDef _on(SqlDialect d, String privilege, {bool option = false}) => GrantDef(
  privilege: privilege,
  target: GrantTarget.table,
  catalog: 'vendite',
  schema: _mysql(d) || d.family == DbFamily.firebird ? null : 'app',
  object: 'ordini',
  withGrantOption: option,
);

Matcher _note(String text) => allOf(hasLength(1), everyElement(allOf(startsWith('--'), contains(text))));

void main() {
  group('SecurityDdl', () {
    test('creates a user with the password as a secret', () {
      expectPerFamily((d) => SecurityDdl.forFamily(d).createPrincipal(_user(d), password: 'p@ss'), {
        'pg': 'CREATE ROLE mario WITH LOGIN PASSWORD ⟦secret:1⟧',
        'mssql': 'CREATE LOGIN mario WITH PASSWORD = ⟦secret:1⟧',
        'mysql': "CREATE USER 'mario'@'%' IDENTIFIED BY ⟦secret:1⟧",
        'mariadb': "CREATE USER 'mario'@'%' IDENTIFIED BY ⟦secret:1⟧",
        'oracle': 'CREATE USER "mario" IDENTIFIED BY ⟦secret:1⟧',
        'db2': _note('sistema operativo'),
        'sqlite': _note('SQLite non ha utenti'),
        'firebird': 'CREATE USER "mario" PASSWORD ⟦secret:1⟧',
        'snowflake': 'CREATE USER "mario" PASSWORD = ⟦secret:1⟧',
      });
      expectPerFamily(
        (d) {
          final ddl = SecurityDdl.forFamily(d);
          ddl.createPrincipal(_user(d), password: "it's");
          return ddl.secrets.values.values.toList();
        },
        {
          'pg': ["'it''s'"],
          'mssql': ["N'it''s'"],
          'mysql': ["'it''s'"],
          'mariadb': ["'it''s'"],
          'oracle': ['"it\'s"'],
          'db2': isEmpty,
          'sqlite': isEmpty,
          'firebird': ["'it''s'"],
          'snowflake': ["'it''s'"],
        },
      );
    });

    test('user attributes', () {
      final pg = SecurityDdl.forFamily(sqlDialects['pg']!);
      expect(
        pg.createPrincipal(
          const PrincipalDef(
            name: 'app',
            kind: PrincipalKind.user,
            createDb: true,
            inherit: false,
            connectionLimit: 5,
            validUntil: '2027-01-01',
            comment: 'servizio',
          ),
        ),
        [
          "CREATE ROLE app WITH LOGIN CREATEDB NOINHERIT CONNECTION LIMIT 5 VALID UNTIL '2027-01-01'",
          "COMMENT ON ROLE app IS 'servizio'",
        ],
      );
      final ms = SecurityDdl.forFamily(sqlDialects['mssql']!);
      expect(
        ms.createPrincipal(
          const PrincipalDef(
            name: 'app',
            kind: PrincipalKind.user,
            auth: PrincipalAuth.login,
            defaultSchema: 'vendite',
          ),
        ),
        ['CREATE USER app FOR LOGIN app WITH DEFAULT_SCHEMA = vendite'],
      );
      expect(ms.createPrincipal(const PrincipalDef(name: 'bot', kind: PrincipalKind.user, auth: PrincipalAuth.none)), [
        'CREATE USER bot WITHOUT LOGIN',
      ]);
      expect(
        ms.createPrincipal(
          const PrincipalDef(
            name: r'DOM\mario',
            kind: PrincipalKind.login,
            auth: PrincipalAuth.windows,
            defaultDatabase: 'vendite',
          ),
        ),
        [r'CREATE LOGIN [DOM\mario] FROM WINDOWS WITH DEFAULT_DATABASE = vendite'],
      );
      final ora = SecurityDdl.forFamily(sqlDialects['oracle']!);
      expect(
        ora.createPrincipal(
          const PrincipalDef(
            name: 'APP',
            kind: PrincipalKind.user,
            defaultTablespace: 'USERS',
            temporaryTablespace: 'TEMP',
            passwordExpired: true,
            locked: true,
          ),
          password: 'x',
        ),
        [
          'CREATE USER APP IDENTIFIED BY ⟦secret:1⟧ DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE "TEMP" PASSWORD EXPIRE ACCOUNT LOCK',
        ],
      );
      final sf = SecurityDdl.forFamily(sqlDialects['snowflake']!);
      expect(
        sf.createPrincipal(
          const PrincipalDef(
            name: 'APP',
            kind: PrincipalKind.user,
            defaultRole: 'LETTORI',
            defaultWarehouse: 'WH',
            mustChangePassword: true,
            comment: 'nuovo',
          ),
        ),
        ["CREATE USER APP DEFAULT_ROLE = LETTORI DEFAULT_WAREHOUSE = WH MUST_CHANGE_PASSWORD = TRUE COMMENT = 'nuovo'"],
      );
      final my = SecurityDdl.forFamily(sqlDialects['mysql']!);
      expect(
        my.createPrincipal(const PrincipalDef(name: 'app', kind: PrincipalKind.user, host: 'localhost', locked: true)),
        ["CREATE USER 'app'@'localhost' ACCOUNT LOCK"],
      );
    });

    test('alters a user: rename, new password, lock', () {
      expectPerFamily(
        (d) =>
            SecurityDdl.forFamily(d)
                .alterPrincipal(_user(d), _user(d).copyWith(name: 'mario2', locked: true), password: 'x'),
        {
          'pg': ['ALTER ROLE mario RENAME TO mario2', 'ALTER ROLE mario2 WITH PASSWORD ⟦secret:1⟧'],
          'mssql': [
            'ALTER LOGIN mario WITH NAME = mario2',
            'ALTER LOGIN mario2 WITH PASSWORD = ⟦secret:1⟧',
            'ALTER LOGIN mario2 DISABLE',
          ],
          'mysql': [
            "RENAME USER 'mario'@'%' TO 'mario2'@'%'",
            "ALTER USER 'mario2'@'%' IDENTIFIED BY ⟦secret:1⟧",
            "ALTER USER 'mario2'@'%' ACCOUNT LOCK",
          ],
          'mariadb': [
            "RENAME USER 'mario'@'%' TO 'mario2'@'%'",
            "ALTER USER 'mario2'@'%' IDENTIFIED BY ⟦secret:1⟧",
            "ALTER USER 'mario2'@'%' ACCOUNT LOCK",
          ],
          'oracle': [
            '-- Ridenominazione di mario in Oracle (non supportato)',
            'ALTER USER "mario" IDENTIFIED BY ⟦secret:1⟧ ACCOUNT LOCK',
          ],
          'db2': ['-- Ridenominazione di mario in Db2 (non supportato)'],
          'sqlite': _note('SQLite'),
          'firebird': [
            '-- Ridenominazione di mario in Firebird (non supportato)',
            'ALTER USER "mario" PASSWORD ⟦secret:1⟧ INACTIVE',
          ],
          'snowflake': [
            'ALTER USER "mario" RENAME TO "mario2"',
            'ALTER USER "mario2" SET PASSWORD = ⟦secret:1⟧ DISABLED = TRUE',
          ],
        },
      );
    });

    test('a renamed PostgreSQL role without a new password gets a note', () {
      final pg = SecurityDdl.forFamily(sqlDialects['pg']!);
      const u = PrincipalDef(name: 'mario', kind: PrincipalKind.user);
      expect(pg.alterPrincipal(u, u.copyWith(name: 'luigi')), [
        'ALTER ROLE mario RENAME TO luigi',
        startsWith('-- Rinominando'),
      ]);
      expect(pg.alterPrincipal(u, u.copyWith(kind: PrincipalKind.role, superuser: true)), [
        'ALTER ROLE mario WITH NOLOGIN SUPERUSER',
      ]);
      expect(pg.alterPrincipal(u.copyWith(validUntil: '2027-01-01'), u), [
        "ALTER ROLE mario WITH VALID UNTIL 'infinity'",
      ]);
    });

    test('drops a principal, with its objects where the DBMS can', () {
      expectPerFamily((d) => SecurityDdl.forFamily(d).dropPrincipal(_user(d)), {
        'pg': 'DROP ROLE mario',
        'mssql': 'DROP LOGIN mario',
        'mysql': "DROP USER 'mario'@'%'",
        'mariadb': "DROP USER 'mario'@'%'",
        'oracle': 'DROP USER "mario"',
        'db2': _note('sistema operativo'),
        'sqlite': _note('SQLite'),
        'firebird': 'DROP USER "mario"',
        'snowflake': 'DROP USER "mario"',
      });
      expect(
        SecurityDdl.forFamily(sqlDialects['pg']!)
            .dropPrincipal(const PrincipalDef(name: 'app', kind: PrincipalKind.user), cascade: true),
        ['REASSIGN OWNED BY app TO CURRENT_USER', 'DROP OWNED BY app', 'DROP ROLE app'],
      );
      expect(
        SecurityDdl.forFamily(sqlDialects['oracle']!)
            .dropPrincipal(const PrincipalDef(name: 'APP', kind: PrincipalKind.user), cascade: true),
        ['DROP USER APP CASCADE'],
      );
    });

    test('creates a role', () {
      expectPerFamily((d) => SecurityDdl.forFamily(d).createPrincipal(_role), {
        'pg': 'CREATE ROLE lettori',
        'mssql': 'CREATE ROLE lettori',
        'mysql': "CREATE ROLE 'lettori'",
        'mariadb': "CREATE ROLE 'lettori'",
        'oracle': 'CREATE ROLE "lettori"',
        'db2': 'CREATE ROLE "lettori"',
        'sqlite': _note('SQLite'),
        'firebird': 'CREATE ROLE "lettori"',
        'snowflake': 'CREATE ROLE "lettori"',
      });
    });

    test('grants privileges on one object in one statement per grant option', () {
      expectPerFamily(
        (d) =>
            SecurityDdl.forFamily(d).grantChanges(_role, const [], [_on(d, 'SELECT'), _on(d, 'INSERT', option: true)]),
        {
          'pg': [
            'GRANT SELECT ON TABLE app.ordini TO lettori',
            'GRANT INSERT ON TABLE app.ordini TO lettori WITH GRANT OPTION',
          ],
          'mssql': [
            'GRANT SELECT ON OBJECT::app.ordini TO lettori',
            'GRANT INSERT ON OBJECT::app.ordini TO lettori WITH GRANT OPTION',
          ],
          'mysql': [
            "GRANT SELECT ON vendite.ordini TO 'lettori'",
            "GRANT INSERT ON vendite.ordini TO 'lettori' WITH GRANT OPTION",
          ],
          'mariadb': [
            "GRANT SELECT ON vendite.ordini TO 'lettori'",
            "GRANT INSERT ON vendite.ordini TO 'lettori' WITH GRANT OPTION",
          ],
          'oracle': [
            'GRANT SELECT ON "app"."ordini" TO "lettori"',
            'GRANT INSERT ON "app"."ordini" TO "lettori" WITH GRANT OPTION',
          ],
          'db2': [
            'GRANT SELECT ON TABLE "app"."ordini" TO ROLE "lettori"',
            'GRANT INSERT ON TABLE "app"."ordini" TO ROLE "lettori" WITH GRANT OPTION',
          ],
          'sqlite': everyElement(startsWith('--')),
          'firebird': [
            'GRANT SELECT ON TABLE "ordini" TO ROLE "lettori"',
            'GRANT INSERT ON TABLE "ordini" TO ROLE "lettori" WITH GRANT OPTION',
          ],
          'snowflake': [
            'GRANT SELECT ON TABLE "vendite"."app"."ordini" TO ROLE "lettori"',
            'GRANT INSERT ON TABLE "vendite"."app"."ordini" TO ROLE "lettori" WITH GRANT OPTION',
          ],
        },
      );
      final pg = SecurityDdl.forFamily(sqlDialects['pg']!);
      final d = sqlDialects['pg']!;
      expect(pg.grantChanges(_role, const [], [_on(d, 'SELECT'), _on(d, 'UPDATE')]), [
        'GRANT SELECT, UPDATE ON TABLE app.ordini TO lettori',
      ]);
    });

    test('revokes privileges', () {
      expectPerFamily((d) => SecurityDdl.forFamily(d).grantChanges(_role, [_on(d, 'SELECT', option: true)], const []), {
        'pg': 'REVOKE SELECT ON TABLE app.ordini FROM lettori CASCADE',
        'mssql': 'REVOKE SELECT ON OBJECT::app.ordini FROM lettori CASCADE',
        'mysql': "REVOKE SELECT ON vendite.ordini FROM 'lettori'",
        'mariadb': "REVOKE SELECT ON vendite.ordini FROM 'lettori'",
        'oracle': 'REVOKE SELECT ON "app"."ordini" FROM "lettori"',
        'db2': 'REVOKE SELECT ON TABLE "app"."ordini" FROM ROLE "lettori"',
        'sqlite': everyElement(startsWith('--')),
        'firebird': 'REVOKE SELECT ON TABLE "ordini" FROM ROLE "lettori"',
        'snowflake': 'REVOKE SELECT ON TABLE "vendite"."app"."ordini" FROM ROLE "lettori" CASCADE',
      });
    });

    test('takes the grant option away', () {
      expectPerFamily(
        (d) => SecurityDdl.forFamily(d).grantChanges(_role, [_on(d, 'SELECT', option: true)], [_on(d, 'SELECT')]),
        {
          'pg': 'REVOKE GRANT OPTION FOR SELECT ON TABLE app.ordini FROM lettori CASCADE',
          'mssql': 'REVOKE GRANT OPTION FOR SELECT ON OBJECT::app.ordini FROM lettori CASCADE',
          'mysql': [startsWith('--'), "REVOKE GRANT OPTION ON vendite.ordini FROM 'lettori'"],
          'mariadb': [startsWith('--'), "REVOKE GRANT OPTION ON vendite.ordini FROM 'lettori'"],
          'oracle': ['REVOKE SELECT ON "app"."ordini" FROM "lettori"', 'GRANT SELECT ON "app"."ordini" TO "lettori"'],
          'db2': [
            'REVOKE SELECT ON TABLE "app"."ordini" FROM ROLE "lettori"',
            'GRANT SELECT ON TABLE "app"."ordini" TO ROLE "lettori"',
          ],
          'sqlite': everyElement(startsWith('--')),
          'firebird': 'REVOKE GRANT OPTION FOR SELECT ON TABLE "ordini" FROM ROLE "lettori"',
          'snowflake': 'REVOKE GRANT OPTION FOR SELECT ON TABLE "vendite"."app"."ordini" FROM ROLE "lettori" CASCADE',
        },
      );
      // MySQL drops the option for all the privileges of the object: the
      // ones that keep it get it back.
      final d = sqlDialects['mysql']!;
      expect(
        SecurityDdl.forFamily(d).grantChanges(
          _role,
          [_on(d, 'SELECT', option: true), _on(d, 'INSERT', option: true)],
          [_on(d, 'SELECT'), _on(d, 'INSERT', option: true)],
        ),
        [
          startsWith('--'),
          "REVOKE GRANT OPTION ON vendite.ordini FROM 'lettori'",
          "GRANT INSERT ON vendite.ordini TO 'lettori' WITH GRANT OPTION",
        ],
      );
    });

    test('privileges on schemas, databases, routines and the system', () {
      final pg = SecurityDdl.forFamily(sqlDialects['pg']!);
      expect(
        pg.grantChanges(_role, const [], const [
          GrantDef(privilege: 'USAGE', target: GrantTarget.schema, schema: 'app'),
          GrantDef(privilege: 'CONNECT', target: GrantTarget.database, catalog: 'vendite'),
          GrantDef(
            privilege: 'EXECUTE',
            target: GrantTarget.routine,
            schema: 'app',
            object: 'totale',
            isFunction: true,
          ),
        ]),
        [
          'GRANT USAGE ON SCHEMA app TO lettori',
          'GRANT CONNECT ON DATABASE vendite TO lettori',
          'GRANT EXECUTE ON FUNCTION app.totale TO lettori',
        ],
      );
      final ms = SecurityDdl.forFamily(sqlDialects['mssql']!);
      expect(
        ms.grantChanges(_role, const [], const [
          GrantDef(privilege: 'SELECT', target: GrantTarget.schema, schema: 'app'),
          GrantDef(privilege: 'CREATE TABLE', target: GrantTarget.system),
        ]),
        ['GRANT SELECT ON SCHEMA::app TO lettori', 'GRANT CREATE TABLE TO lettori'],
      );
      final my = SecurityDdl.forFamily(sqlDialects['mysql']!);
      expect(
        my.grantChanges(_role, const [], const [
          GrantDef(privilege: 'SELECT', target: GrantTarget.database, catalog: 'vendite'),
          GrantDef(privilege: 'PROCESS', target: GrantTarget.system),
          GrantDef(privilege: 'EXECUTE', target: GrantTarget.routine, catalog: 'vendite', object: 'chiudi'),
        ]),
        [
          "GRANT SELECT ON vendite.* TO 'lettori'",
          "GRANT PROCESS ON *.* TO 'lettori'",
          "GRANT EXECUTE ON PROCEDURE vendite.chiudi TO 'lettori'",
        ],
      );
      final ora = SecurityDdl.forFamily(sqlDialects['oracle']!);
      const app = PrincipalDef(name: 'APP', kind: PrincipalKind.user);
      expect(
        ora.grantChanges(app, const [], const [
          GrantDef(privilege: 'CREATE SESSION', target: GrantTarget.system, withGrantOption: true),
        ]),
        ['GRANT CREATE SESSION TO APP WITH ADMIN OPTION'],
      );
      expect(
        ora.grantChanges(app, const [], const [GrantDef(privilege: 'USAGE', target: GrantTarget.schema, schema: 'X')]),
        _note('Permessi su schema X'),
      );
      final db2 = SecurityDdl.forFamily(sqlDialects['db2']!);
      expect(
        db2.grantChanges(const PrincipalDef(name: 'MARIO', kind: PrincipalKind.user), const [], const [
          GrantDef(privilege: 'CONNECT', target: GrantTarget.database, withGrantOption: true),
        ]),
        ['GRANT CONNECT ON DATABASE TO USER MARIO'],
      );
      expect(
        db2.grantChanges(const PrincipalDef(name: 'DEV', kind: PrincipalKind.group), const [
          GrantDef(privilege: 'EXECUTE', target: GrantTarget.routine, schema: 'APP', object: 'CHIUDI'),
        ], const []),
        ['REVOKE EXECUTE ON PROCEDURE APP.CHIUDI FROM GROUP DEV RESTRICT'],
      );
      final sf = SecurityDdl.forFamily(sqlDialects['snowflake']!);
      expect(
        sf.grantChanges(const PrincipalDef(name: 'R', kind: PrincipalKind.role), const [], const [
          GrantDef(privilege: 'CREATE DATABASE', target: GrantTarget.system),
          GrantDef(privilege: 'USAGE', target: GrantTarget.schema, catalog: 'DB', schema: 'S'),
        ]),
        ['GRANT CREATE DATABASE ON ACCOUNT TO ROLE R', 'GRANT USAGE ON SCHEMA DB.S TO ROLE R'],
      );
      // Snowflake privileges go to roles.
      expect(
        sf.grantChanges(const PrincipalDef(name: 'U', kind: PrincipalKind.user), const [], const [
          GrantDef(privilege: 'CREATE DATABASE', target: GrantTarget.system),
        ]),
        _note('Permessi diretti a utente U'),
      );
    });

    test('role memberships', () {
      expectPerFamily(
        (d) => SecurityDdl.forFamily(d).membershipChanges(_user(d), const [], [
          RoleMembership('lettori', 'mario', memberHost: _mysql(d) ? '%' : null, withAdmin: true),
        ]),
        {
          'pg': 'GRANT lettori TO mario WITH ADMIN OPTION',
          'mssql': 'ALTER ROLE lettori ADD MEMBER mario',
          'mysql': ["GRANT 'lettori' TO 'mario'@'%' WITH ADMIN OPTION", "SET DEFAULT ROLE ALL TO 'mario'@'%'"],
          'mariadb': "GRANT 'lettori' TO 'mario'@'%' WITH ADMIN OPTION",
          'oracle': 'GRANT "lettori" TO "mario" WITH ADMIN OPTION',
          'db2': 'GRANT ROLE "lettori" TO USER "mario" WITH ADMIN OPTION',
          'sqlite': _note('SQLite'),
          'firebird': 'GRANT "lettori" TO USER "mario" WITH ADMIN OPTION',
          'snowflake': 'GRANT ROLE "lettori" TO USER "mario"',
        },
      );
      expectPerFamily(
        (d) => SecurityDdl.forFamily(d).membershipChanges(_user(d), [
          RoleMembership('lettori', 'mario', memberHost: _mysql(d) ? '%' : null),
        ], const []),
        {
          'pg': 'REVOKE lettori FROM mario',
          'mssql': 'ALTER ROLE lettori DROP MEMBER mario',
          'mysql': "REVOKE 'lettori' FROM 'mario'@'%'",
          'mariadb': "REVOKE 'lettori' FROM 'mario'@'%'",
          'oracle': 'REVOKE "lettori" FROM "mario"',
          'db2': 'REVOKE ROLE "lettori" FROM USER "mario"',
          'sqlite': _note('SQLite'),
          'firebird': 'REVOKE "lettori" FROM USER "mario"',
          'snowflake': 'REVOKE ROLE "lettori" FROM USER "mario"',
        },
      );
      final ms = SecurityDdl.forFamily(sqlDialects['mssql']!);
      expect(
        ms.membershipChanges(const PrincipalDef(name: 'mario', kind: PrincipalKind.login), const [], const [
          RoleMembership('sysadmin', 'mario', serverRole: true),
        ]),
        ['ALTER SERVER ROLE sysadmin ADD MEMBER mario'],
      );
      final pg = SecurityDdl.forFamily(sqlDialects['pg']!);
      const m = RoleMembership('lettori', 'mario', withAdmin: true);
      expect(pg.membershipChanges(_user(sqlDialects['pg']!), const [m], [m.copyWith(withAdmin: false)]), [
        'REVOKE ADMIN OPTION FOR lettori FROM mario',
      ]);
      final ora = SecurityDdl.forFamily(sqlDialects['oracle']!);
      const om = RoleMembership('R', 'U', withAdmin: true);
      expect(
        ora.membershipChanges(
          const PrincipalDef(name: 'U', kind: PrincipalKind.user),
          const [om],
          [om.copyWith(withAdmin: false)],
        ),
        ['REVOKE R FROM U', 'GRANT R TO U'],
      );
    });

    test('offers only what the DBMS has', () {
      expectPerFamily((d) => SecurityDdl.forFamily(d).kinds, {
        'pg': [PrincipalKind.user, PrincipalKind.role],
        'mssql': [PrincipalKind.login, PrincipalKind.user, PrincipalKind.role],
        'mysql': [PrincipalKind.user, PrincipalKind.role],
        'mariadb': [PrincipalKind.user, PrincipalKind.role],
        'oracle': [PrincipalKind.user, PrincipalKind.role],
        'db2': [PrincipalKind.user, PrincipalKind.group, PrincipalKind.role],
        'sqlite': isEmpty,
        'firebird': [PrincipalKind.user, PrincipalKind.role],
        'snowflake': [PrincipalKind.user, PrincipalKind.role],
      });
      expect(SecurityDdl.forFamily(dialectAt('mysql', '5.7.40')).kinds, [PrincipalKind.user]);
      final fb2 = SecurityDdl.forFamily(dialectAt('firebird', 'WI-V2.5.9 Firebird 2.5'));
      expect(fb2.canCreate(PrincipalKind.user), isFalse);
      expect(fb2.createReason(PrincipalKind.user), contains('3.0'));
      final db2 = SecurityDdl.forFamily(sqlDialects['db2']!);
      expect(db2.canCreate(PrincipalKind.role), isTrue);
      expect(db2.canCreate(PrincipalKind.group), isFalse);
      // Every listed privilege of every target renders.
      for (final e in sqlDialects.entries) {
        final ddl = SecurityDdl.forFamily(e.value);
        for (final k in ddl.kinds) {
          for (final t in ddl.objectTargets(k)) {
            expect(ddl.privileges(t), isNotEmpty, reason: '${e.key} ${t.name}');
            final g = GrantDef(
              privilege: ddl.privileges(t).first,
              target: t,
              catalog: 'db',
              schema: 's',
              object: t == GrantTarget.schema || t == GrantTarget.database ? null : 'o',
            );
            final p = PrincipalDef(
              name: 'r',
              kind: k == PrincipalKind.login ? PrincipalKind.login : PrincipalKind.role,
            );
            expect(
              executableStatements(ddl.grantChanges(p, const [], [g])),
              hasLength(1),
              reason: '${e.key} ${t.name}',
            );
          }
        }
      }
    });
  });

  group('PrincipalDesign', () {
    final pg = sqlDialects['pg']!;
    const p = PrincipalDef(name: 'mario', kind: PrincipalKind.user);
    const table = GrantDef(privilege: '', target: GrantTarget.table, schema: 'app', object: 'ordini');
    const view = GrantDef(privilege: '', target: GrantTarget.view, schema: 'app', object: 'v');

    test('privilege edits become GRANT and REVOKE', () {
      final d = PrincipalDesign.existing(
        pg,
        p,
        const PrincipalAccess(
          grants: [GrantDef(privilege: 'SELECT', target: GrantTarget.table, schema: 'app', object: 'ordini')],
        ),
      );
      expect(d.isDirty, isFalse);
      expect(d.grantOf(table, 'SELECT'), isNotNull);
      d.setGrants([table, view], ['INSERT', 'SELECT'], true);
      d.setGrant(table, 'SELECT', false);
      expect(d.statements, [
        'REVOKE SELECT ON TABLE app.ordini FROM mario',
        'GRANT INSERT ON TABLE app.ordini TO mario',
        'GRANT INSERT, SELECT ON TABLE app.v TO mario',
      ]);
      d.setGrantOption(view, true);
      expect(d.grantOptionOf(view), isTrue);
      expect(d.grantOptionOf(table), isFalse);
      expect(d.statements.last, 'GRANT INSERT, SELECT ON TABLE app.v TO mario WITH GRANT OPTION');
      d.setGrantOption(view, false, privilege: 'SELECT');
      expect(d.grantOptionOf(view), isNull);
    });

    test('roles follow a rename', () {
      final d = PrincipalDesign.existing(pg, p, const PrincipalAccess(memberOf: [RoleMembership('lettori', 'mario')]));
      d.update(p.copyWith(name: 'luigi', originalName: 'mario'));
      d.setRole('scrittori', true);
      d.setAdmin('lettori', true);
      expect(d.statements, [
        'ALTER ROLE mario RENAME TO luigi',
        startsWith('-- Rinominando'),
        'GRANT lettori TO luigi WITH ADMIN OPTION',
        'GRANT scrittori TO luigi',
      ]);
      d.setRole('lettori', false);
      expect(d.statements, contains('REVOKE lettori FROM luigi'));
    });

    test('new principals: validation and starting privileges', () {
      final d = PrincipalDesign.create(sqlDialects['oracle']!, PrincipalKind.user);
      expect(d.errors, containsAll(['Il nome è obbligatorio', 'La password è obbligatoria']));
      d.update(d.working.copyWith(name: 'APP'));
      d.setPassword('a"b');
      expect(d.errors, [contains('virgolette')]);
      d.setPassword('segreta');
      expect(d.errors, isEmpty);
      final script = d.script();
      expect(script.statements, ['CREATE USER APP IDENTIFIED BY ⟦secret:1⟧', 'GRANT CREATE SESSION TO APP']);
      expect(script.secrets.values, ['"segreta"']);
      expect(script.render(DdlBuilder(sqlDialects['oracle']!)), isNot(contains('segreta')));
      expect(script.render(DdlBuilder(sqlDialects['oracle']!)), contains('••••••'));
      expect(script.scope.level, SchemaLevel.security);
      expect(PrincipalDesign.create(sqlDialects['mysql']!, PrincipalKind.user).working.host, '%');
      expect(PrincipalDesign.create(sqlDialects['mariadb']!, PrincipalKind.role).working.host, isNull);
      expect(PrincipalDesign.create(sqlDialects['mssql']!, PrincipalKind.user).working.auth, PrincipalAuth.login);
      expect(
        PrincipalDesign.create(sqlDialects['db2']!, PrincipalKind.user).errors,
        contains(contains('sistema operativo')),
      );
    });

    test('SQL Server users run in their database, logins on the server', () {
      final ms = sqlDialects['mssql']!;
      final user = PrincipalDesign.create(ms, PrincipalKind.user, catalog: 'vendite', name: 'app');
      expect(user.script().catalog, 'vendite');
      expect(user.script().statements, ['CREATE USER app FOR LOGIN app']);
      final login = PrincipalDesign.create(ms, PrincipalKind.login, catalog: 'vendite', name: 'app')..setPassword('x');
      expect(login.script().catalog, isNull);
    });

    test('the DDL page masks the password', () {
      final d = PrincipalDesign.existing(
        sqlDialects['mssql']!,
        const PrincipalDef(name: 'app', kind: PrincipalKind.login),
        const PrincipalAccess(
          memberOf: [RoleMembership('sysadmin', 'app', serverRole: true)],
          grants: [GrantDef(privilege: 'VIEW SERVER STATE', target: GrantTarget.system)],
        ),
      );
      expect(d.ddlScript, [
        "CREATE LOGIN app WITH PASSWORD = '••••••'",
        'ALTER SERVER ROLE sysadmin ADD MEMBER app',
        'GRANT VIEW SERVER STATE TO app',
      ]);
    });
  });

  group('catalog', () {
    DesignCatalog catalogOf(ScriptedSession s, {String dbmsName = 'PostgreSQL', String version = '16.4'}) =>
        DesignCatalog.of(scriptedConnection(s, dbmsName: dbmsName, dbmsVersion: version))!;

    test('PostgreSQL roles, memberships and privileges', () async {
      final s = ScriptedSession()
        ..on(
          'FROM pg_roles r ORDER',
          Rows(
            [
              'rolname', 'rolcanlogin', 'rolsuper', 'rolcreatedb', 'rolcreaterole', 'rolinherit', 'rolreplication', //
              'rolconnlimit', 'rolvaliduntil', 'comment',
            ],
            [
              ['mario', true, false, true, false, true, false, -1, null, 'sviluppo'],
              ['lettori', false, false, false, false, true, false, -1, 'infinity', null],
              ['pg_monitor', false, false, false, false, true, false, -1, null, null],
            ],
          ),
        )
        ..on(
          'pg_auth_members',
          Rows(
            ['role_name', 'member_name', 'admin_option'],
            [
              ['lettori', 'mario', true],
            ],
          ),
        )
        ..on(
          'aclexplode',
          Rows(
            ['kind', 'schema_name', 'object_name', 'sub', 'privilege_type', 'is_grantable'],
            [
              ['rel', 'app', 'ordini', 'r', 'SELECT', false],
              ['rel', 'app', 'v_ordini', 'v', 'SELECT', true],
              ['rel', 'app', 'seq', 'S', 'USAGE', false],
              ['proc', 'app', 'chiudi', 'p', 'EXECUTE', false],
              ['schema', 'app', null, null, 'USAGE', false],
              ['db', 'vendite', null, null, 'CONNECT', false],
            ],
          ),
        );
      final cat = catalogOf(s);
      final ps = await cat.principals();
      expect(
        [for (final p in ps) (p.name, p.kind, p.builtIn)],
        [
          ('mario', PrincipalKind.user, false),
          ('lettori', PrincipalKind.role, false),
          ('pg_monitor', PrincipalKind.role, true),
        ],
      );
      expect(ps.first.createDb, isTrue);
      expect(ps.first.comment, 'sviluppo');
      expect(ps[1].validUntil, isNull);
      final a = await cat.access(ps.first);
      expect(a.memberOf.single.role, 'lettori');
      expect(a.memberOf.single.withAdmin, isTrue);
      expect(
        [for (final g in a.grants) '${g.target.name} ${g.objectLabel} ${g.privilege}${g.withGrantOption ? '+' : ''}'],
        [
          'table app.ordini SELECT',
          'view app.v_ordini SELECT+',
          'sequence app.seq USAGE',
          'routine app.chiudi EXECUTE',
          'schema app USAGE',
          'database vendite CONNECT',
        ],
      );
      expect(a.grants[3].isFunction, isFalse);
      expect(s.executed.last, contains("rolname = 'mario'"));
    });

    test('SQL Server logins, database users and permissions', () async {
      final s = ScriptedSession()
        ..on(
          'FROM sys.server_principals WHERE',
          Rows(
            ['name', 'type', 'is_disabled', 'default_database_name'],
            [
              ['sa', 'S', 0, 'master'],
              [r'DOM\mario', 'U', 1, 'vendite'],
            ],
          ),
        )
        ..on(
          r'vendite.?\.sys\.database_principals dp',
          Rows(
            [
              'name',
              'type',
              'authentication_type_desc',
              'default_schema_name',
              'is_fixed_role',
              'principal_id',
              'login_name',
            ],
            [
              ['dbo', 'S', 'INSTANCE', 'dbo', 0, 1, 'sa'],
              ['app', 'S', 'INSTANCE', 'app', 0, 5, 'app'],
              ['bot', 'S', 'NONE', null, 0, 6, null],
              ['db_owner', 'R', 'NONE', null, 1, 16384, null],
              ['lettori', 'R', 'NONE', null, 0, 7, null],
            ],
          ),
        )
        ..on(
          'sys.server_role_members',
          Rows(
            ['role_name', 'member_name'],
            [
              ['sysadmin', 'sa'],
            ],
          ),
        )
        ..on(
          'database_role_members',
          Rows(
            ['role_name', 'member_name'],
            [
              ['lettori', 'app'],
            ],
          ),
        )
        ..on(
          'database_permissions',
          Rows(
            ['class', 'permission_name', 'state', 'schema_name', 'object_name', 'object_type', 'class_schema'],
            [
              [0, 'CONNECT', 'G', null, null, null, null],
              [1, 'SELECT', 'W', 'dbo', 'ordini', 'U ', null],
              [1, 'EXECUTE', 'G', 'dbo', 'chiudi', 'P ', null],
              [3, 'SELECT', 'G', null, null, null, 'app'],
            ],
          ),
        );
      final cat = catalogOf(s, dbmsName: 'Microsoft SQL Server', version: '16.00.4135');
      final ps = await cat.principals(catalog: 'vendite');
      expect(
        [for (final p in ps) '${p.kind.name}:${p.name}:${p.auth.name}${p.builtIn ? ':sys' : ''}'],
        [
          'login:sa:password',
          'login:DOM\\mario:windows',
          'user:dbo:login:sys',
          'user:app:login',
          'user:bot:none',
          'role:db_owner:password:sys',
          'role:lettori:password',
        ],
      );
      expect(ps[1].locked, isTrue);
      final app = ps.firstWhere((p) => p.name == 'app');
      final a = await cat.access(app, catalog: 'vendite');
      expect([for (final m in a.memberOf) m.role], ['lettori']);
      expect(
        [for (final g in a.grants) '${g.target.name} ${g.objectLabel} ${g.privilege}${g.withGrantOption ? '+' : ''}'],
        ['system sistema CONNECT', 'table dbo.ordini SELECT+', 'routine dbo.chiudi EXECUTE', 'schema app SELECT'],
      );
      expect(a.grants[2].isFunction, isFalse);
      // Logins: server roles and server permissions.
      s.on(
        'server_permissions',
        Rows(
          ['permission_name', 'state'],
          [
            ['VIEW SERVER STATE', 'G'],
          ],
        ),
      );
      final sa = await cat.access(ps.first, catalog: 'vendite');
      expect([for (final m in sa.memberOf) m.role], ['sysadmin']);
      expect(sa.grants.single.privilege, 'VIEW SERVER STATE');
    });

    test('Oracle falls back to the ALL_ views without DBA privileges', () async {
      final denied = odbcError('ORA-00942: table or view does not exist');
      final s = ScriptedSession()
        ..on('FROM dba_', denied)
        ..on(
          'FROM all_users',
          Rows(
            ['username', 'oracle_maintained'],
            [
              ['APP', 'N'],
              ['SYS', 'Y'],
            ],
          ),
        )
        ..on(
          'FROM user_role_privs',
          Rows(
            ['granted_role', 'grantee', 'admin_option', 'role'],
            [
              ['CONNECT', 'APP', 'NO', 'CONNECT'],
            ],
          ),
        )
        ..on(
          'FROM user_sys_privs',
          Rows(
            ['privilege', 'admin_option'],
            [
              ['CREATE SESSION', 'NO'],
            ],
          ),
        )
        ..on(
          'FROM all_tab_privs',
          Rows(
            ['owner', 'table_name', 'privilege', 'grantable', 'type'],
            [
              ['HR', 'EMP', 'SELECT', 'YES', 'TABLE'],
              ['HR', 'PKG', 'EXECUTE', 'NO', 'PACKAGE'],
              ['HR', 'DIR', 'READ', 'NO', 'DIRECTORY'],
            ],
          ),
        );
      final cat = catalogOf(s, dbmsName: 'Oracle', version: '19.0');
      final ps = await cat.principals();
      expect(
        [for (final p in ps) '${p.kind.name}:${p.name}${p.builtIn ? ':sys' : ''}'],
        ['user:APP', 'user:SYS:sys', 'role:CONNECT'],
      );
      final a = await cat.access(ps.first);
      expect([for (final m in a.memberOf) m.role], ['CONNECT']);
      expect(
        [for (final g in a.grants) '${g.target.name} ${g.objectLabel} ${g.privilege}${g.withGrantOption ? '+' : ''}'],
        ['system sistema CREATE SESSION', 'table HR.EMP SELECT+', 'routine HR.PKG EXECUTE'],
      );
    });

    test('missing privileges are reported as such', () async {
      final s = ScriptedSession()..on('pg_roles', odbcError('permission denied for table pg_authid', state: '42501'));
      final cat = catalogOf(s);
      await expectLater(cat.principals(), throwsA(isA<CatalogPermissionException>()));
    });

    test('MySQL accounts and SHOW GRANTS', () async {
      final s = ScriptedSession()
        ..on(
          'FROM mysql.user',
          Rows(
            ['user', 'host', 'account_locked', 'password_expired', 'no_password'],
            [
              ['app', '%', 'N', 'N', 0],
              ['lettori', '%', 'Y', 'Y', 1],
              ['mysql.sys', 'localhost', 'Y', 'N', 0],
            ],
          ),
        )
        ..on(
          'role_edges',
          Rows(
            ['from_user', 'from_host', 'to_user', 'to_host', 'with_admin_option'],
            [
              ['lettori', '%', 'app', '%', 'N'],
            ],
          ),
        )
        ..on(
          'SHOW GRANTS',
          Rows(
            ['Grants for app@%'],
            [
              ['GRANT USAGE ON *.* TO `app`@`%`'],
              ['GRANT SELECT, INSERT ON `vendite`.* TO `app`@`%`'],
              ['GRANT SELECT (`id`), UPDATE ON `vendite`.`ordini` TO `app`@`%` WITH GRANT OPTION'],
              ['GRANT EXECUTE ON PROCEDURE `vendite`.`chiudi` TO `app`@`%`'],
              ['GRANT `lettori`@`%` TO `app`@`%`'],
            ],
          ),
        );
      final cat = catalogOf(s, dbmsName: 'MySQL', version: '8.4.0');
      final ps = await cat.principals();
      expect(
        [for (final p in ps) '${p.kind.name}:${p.display}${p.builtIn ? ':sys' : ''}'],
        ['user:app@%', 'role:lettori@%', 'user:mysql.sys@localhost:sys'],
      );
      expect(ps[1].locked, isFalse);
      final a = await cat.access(ps.first);
      expect(s.executed.last, "SHOW GRANTS FOR 'app'@'%'");
      expect([for (final m in a.memberOf) m.roleDisplay], ['lettori']);
      expect(
        [
          for (final g in a.grants)
            '${g.target.name} ${g.catalog}.${g.object} ${g.privilege}${g.withGrantOption ? '+' : ''}',
        ],
        [
          'database vendite.null SELECT',
          'database vendite.null INSERT',
          'table vendite.ordini UPDATE+',
          'routine vendite.chiudi EXECUTE',
        ],
      );
    });

    test('ALL PRIVILEGES expands to the privileges of the level', () {
      final all = parseMySqlGrant('GRANT ALL PRIVILEGES ON *.* TO `root`@`localhost` WITH GRANT OPTION');
      expect(all.map((g) => g.privilege), containsAll(['SELECT', 'PROCESS', 'SUPER']));
      expect(all.every((g) => g.target == GrantTarget.system && g.withGrantOption), isTrue);
      expect(parseMySqlGrant("GRANT PROXY ON ''@'' TO 'root'@'localhost'"), isEmpty);
    });

    test('privileges on a table', () async {
      final s = ScriptedSession()
        ..on(
          'FROM pg_roles r ORDER',
          Rows(
            ['rolname', 'rolcanlogin'],
            [
              ['mario', true],
              ['lettori', false],
            ],
          ),
        )
        ..on(
          'aclexplode',
          Rows(
            ['grantee', 'privilege_type', 'is_grantable'],
            [
              ['lettori', 'SELECT', false],
              ['mario', 'UPDATE', true],
            ],
          ),
        );
      s.catalogs['tables'] = [
        [null, 'app', 'ordini', 'TABLE', null],
      ];
      final dc = scriptedConnection(s);
      final t = (await dc.metadata!.tables(null, 'app')).single;
      final grants = await DesignCatalog.of(dc)!.objectGrants(t);
      expect(
        [
          for (final g in grants)
            '${g.grantee.kind.name}:${g.grantee.name} ${g.grant.privilege}${g.grant.withGrantOption ? '+' : ''}',
        ],
        ['role:lettori SELECT', 'user:mario UPDATE+'],
      );
      expect(s.executed.last, contains("n.nspname = 'app' AND c.relname = 'ordini'"));
    });

    test('Snowflake grants of a role', () async {
      final s = ScriptedSession()
        ..on(
          'SHOW GRANTS TO ROLE',
          Rows(
            ['privilege', 'granted_on', 'name', 'grant_option'],
            [
              ['USAGE', 'DATABASE', 'VENDITE', 'false'],
              ['USAGE', 'SCHEMA', 'VENDITE.APP', 'false'],
              ['SELECT', 'TABLE', 'VENDITE.APP."Ordini"', 'true'],
              ['OWNERSHIP', 'TABLE', 'VENDITE.APP.X', 'false'],
              ['USAGE', 'ROLE', 'LETTORI', 'false'],
              ['CREATE DATABASE', 'ACCOUNT', 'XY12345', 'false'],
            ],
          ),
        );
      final cat = catalogOf(s, dbmsName: 'Snowflake', version: '8.30.1');
      final a = await cat.access(const PrincipalDef(name: 'ANALISTI', kind: PrincipalKind.role));
      expect([for (final m in a.memberOf) m.role], ['LETTORI']);
      expect(
        [for (final g in a.grants) '${g.target.name} ${g.catalog}/${g.schema}/${g.object} ${g.privilege}'],
        [
          'database VENDITE/null/null USAGE',
          'schema VENDITE/APP/null USAGE',
          'table VENDITE/APP/Ordini SELECT',
          'system null/null/null CREATE DATABASE',
        ],
      );
      expect(splitQualified('A."b.c"."d""e"'), ['A', 'b.c', 'd"e']);
    });
  });
  group('security manager', () {
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

    ScriptedSession pgSecurity() => ordersSession()
      ..on(
        'FROM pg_roles r ORDER',
        Rows(
          ['rolname', 'rolcanlogin', 'rolinherit'],
          [
            ['mario', true, true],
            ['lettori', false, true],
          ],
        ),
      );

    testWidgets('grants a privilege from the Permessi page', (tester) async {
      final s = pgSecurity();
      final tab = SecurityTab(scriptedConnection(s));
      addTearDown(tab.dispose);
      await host(tester, Builder(builder: tab.buildView));
      expect(find.text('Utenti'), findsOneWidget);
      expect(find.text('Ruoli'), findsOneWidget);
      await tester.tap(find.text('mario'));
      await tester.pumpAndSettle();
      expect(tab.design?.working.name, 'mario');
      await tester.tap(find.text('Permessi'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('SELECT su app.orders'));
      await tester.pumpAndSettle();
      expect(tab.isDirty, isTrue);
      await tester.tap(find.text('Ruoli').last);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Membro di lettori'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(s.executed, containsAllInOrder(['GRANT lettori TO mario', 'GRANT SELECT ON TABLE app.orders TO mario']));
    });

    testWidgets('a new user\'s password never reaches the history', (tester) async {
      final s = pgSecurity();
      final history = <String>[];
      final tab = SecurityTab(scriptedConnection(s, history: history));
      addTearDown(tab.dispose);
      await host(tester, Builder(builder: tab.buildView));
      await tester.tap(find.byTooltip('Nuovo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nuovo utente…'));
      await tester.pumpAndSettle();
      expect(tab.design?.isNew, isTrue);
      final fields = find.byType(EditableText);
      await tester.enterText(fields.at(1), 'anna');
      await tester.enterText(fields.at(2), 's3cret!');
      await tester.pumpAndSettle();
      // Not confirmed yet: no password.
      expect(tab.design!.password, isNull);
      await tester.enterText(fields.at(3), 's3cret!');
      await tester.pumpAndSettle();
      expect(tab.design!.password, 's3cret!');
      await tester.tap(find.text('DDL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crea'));
      await tester.pumpAndSettle();
      expect(find.textContaining('s3cret'), findsNothing);
      await runScript(tester);
      expect(s.executed, contains("CREATE ROLE anna WITH LOGIN PASSWORD 's3cret!'"));
      expect(history.join('\n'), isNot(contains('s3cret')));
    });

    testWidgets('the table Permessi page grants and revokes', (tester) async {
      final s = pgSecurity()
        ..on(
          'aclexplode',
          Rows(
            ['grantee', 'privilege_type', 'is_grantable'],
            [
              ['lettori', 'SELECT', false],
            ],
          ),
        );
      final dc = scriptedConnection(s);
      await host(
        tester,
        TablePermissionsPage(
          connection: dc,
          table: DbTable(catalog: null, schema: 'app', name: 'orders', type: 'TABLE'),
        ),
      );
      expect(find.text('lettori'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('SELECT a lettori'));
      await tester.tap(find.bySemanticsLabel('INSERT a lettori'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aggiungi…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('mario'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scegli'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('UPDATE a mario'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(
        s.executed,
        containsAllInOrder([
          'REVOKE SELECT ON TABLE app.orders FROM lettori',
          'GRANT INSERT ON TABLE app.orders TO lettori',
          'GRANT UPDATE ON TABLE app.orders TO mario',
        ]),
      );
    });

    testWidgets('drops a role after typing its name', (tester) async {
      final s = pgSecurity();
      final tab = SecurityTab(scriptedConnection(s));
      addTearDown(tab.dispose);
      await host(tester, Builder(builder: tab.buildView));
      await tester.tap(find.text('lettori'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Elimina ruolo…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, 'lettori');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elimina').last);
      await tester.pumpAndSettle();
      await runScript(tester);
      expect(s.executed, contains('DROP ROLE lettori'));
    });
  });
  group('navigator', () {
    test('a Sicurezza folder lists users and roles', () async {
      final s = ordersSession()
        ..on(
          'FROM pg_roles r ORDER',
          Rows(
            ['rolname', 'rolcanlogin'],
            [
              ['mario', true],
              ['lettori', false],
            ],
          ),
        );
      final dc = scriptedConnection(s);
      final top = await ConnectionNode(dc).load();
      final sec = top.last as SecurityNode;
      expect(sec.label, 'Sicurezza');
      final folders = await sec.load();
      expect([for (final f in folders) f.label], ['Utenti', 'Ruoli']);
      final users = await folders.first.load();
      expect([for (final u in users) u.label], ['mario']);
      expect(users.single, isA<PrincipalNode>());
      // Security changes reload only the security folders.
      final root = ConnectionNode(dc)..children = [sec];
      sec.children = folders;
      expect(nodesForSchemaChanges(root, const [SchemaScope.security()]), [sec]);
      expect(nodesForSchemaChanges(root, const [SchemaScope.schema(null, 'app')]), isEmpty);
      expect(const SchemaScope.security().covers(null, 'app'), isFalse);
      expect(hasSecurity(scriptedConnection(ScriptedSession(), dbmsName: 'SQLite', dbmsVersion: '3.45')), isFalse);
    });

    test('SQL Server: logins under the connection, users and roles under each database', () async {
      final dc = scriptedConnection(ScriptedSession(), dbmsName: 'Microsoft SQL Server', dbmsVersion: '16.00.4135');
      expect(SecurityNode(dc, server: true).kinds, [PrincipalKind.login]);
      expect(SecurityNode(dc, catalog: 'vendite').kinds, [PrincipalKind.user, PrincipalKind.role]);
    });
  });
}
