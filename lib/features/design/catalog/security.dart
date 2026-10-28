// Users, roles, role memberships and privileges read from the system
// catalogs. Reading them often needs privileges the user lacks: the
// readers throw CatalogPermissionException (see CatalogQueries.first) and
// the security manager shows what it could read.

import 'dart:convert';

import '../../../drivers/mongodb/bson.dart';
import '../../../services/sql_dialect.dart';
import '../ddl/nosql_ddl.dart';
import '../ddl/security/nosql.dart';
import '../ddl/security/security_ddl.dart';
import '../model/security_defs.dart';
import 'design_catalog.dart';
import 'table_extras.dart';

/// Roles and privileges of one principal.
class PrincipalAccess {
  const PrincipalAccess({this.memberOf = const [], this.grants = const []});
  static const none = PrincipalAccess();

  /// Roles the principal belongs to.
  final List<RoleMembership> memberOf;
  final List<GrantDef> grants;
}

/// A privilege on one object and who holds it (table editor page).
class ObjectGrant {
  const ObjectGrant(this.grantee, this.grant);
  final PrincipalDef grantee;
  final GrantDef grant;
}

/// SQL Server database prefix of the catalog views.
String _db(SqlDialect d, String? catalog) => catalog == null ? '' : '${d.quoteIdent(catalog)}.';

const _snowflakeSystemRoles = {'ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'USERADMIN', 'ORGADMIN', 'PUBLIC'};

Future<List<CatalogRow>> _optional(CatalogQueries q, List<String> alternatives) async {
  try {
    return await q.first(alternatives);
  } on CatalogPermissionException {
    rethrow;
  } catch (_) {
    return const [];
  }
}

// ---------------------------------------------------------------------------
// Principals
// ---------------------------------------------------------------------------

/// Users, roles (and SQL Server logins) of the server; for SQL Server the
/// users and roles of [catalog].
Future<List<PrincipalDef>> readPrincipals(CatalogQueries q, SqlDialect d, {String? catalog}) async {
  switch (d.family) {
    case DbFamily.postgres:
      final rows = await q.first([
        'SELECT r.rolname, r.rolcanlogin, r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolinherit, '
            "r.rolreplication, r.rolconnlimit, r.rolvaliduntil, shobj_description(r.oid, 'pg_authid') AS comment "
            'FROM pg_roles r ORDER BY r.rolname',
        'SELECT r.rolname, r.rolcanlogin, r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolinherit, '
            'r.rolreplication, r.rolconnlimit, r.rolvaliduntil FROM pg_roles r ORDER BY r.rolname',
      ]);
      return [
        for (final r in rows)
          () {
            final name = rowText(r, 'rolname')!;
            final until = rowText(r, 'rolvaliduntil');
            final limit = rowInt(r, 'rolconnlimit');
            return PrincipalDef(
              name: name,
              kind: rowBool(r, 'rolcanlogin') ? PrincipalKind.user : PrincipalKind.role,
              superuser: rowBool(r, 'rolsuper'),
              createDb: rowBool(r, 'rolcreatedb'),
              createRole: rowBool(r, 'rolcreaterole'),
              inherit: rowBool(r, 'rolinherit'),
              replication: rowBool(r, 'rolreplication'),
              connectionLimit: limit == null || limit < 0 ? null : limit,
              validUntil: until == null || until == 'infinity' ? null : until,
              comment: rowText(r, 'comment'),
              builtIn: name.startsWith('pg_'),
            );
          }(),
      ];
    case DbFamily.sqlServer:
      final logins = await _optional(q, [
        'SELECT name, type, is_disabled, default_database_name FROM sys.server_principals '
            "WHERE type IN ('S', 'U', 'G') AND name NOT LIKE '##%' ORDER BY name",
      ]);
      final db = _db(d, catalog);
      final users = await q.first([
        'SELECT dp.name, dp.type, dp.authentication_type_desc, dp.default_schema_name, dp.is_fixed_role, '
            'dp.principal_id, sp.name AS login_name FROM ${db}sys.database_principals dp '
            'LEFT JOIN sys.server_principals sp ON sp.sid = dp.sid '
            "WHERE dp.type IN ('S', 'U', 'G', 'R') AND dp.name NOT IN ('sys', 'INFORMATION_SCHEMA') ORDER BY dp.name",
        'SELECT dp.name, dp.type, dp.default_schema_name, dp.is_fixed_role, dp.principal_id, sp.name AS login_name '
            'FROM ${db}sys.database_principals dp LEFT JOIN sys.server_principals sp ON sp.sid = dp.sid '
            "WHERE dp.type IN ('S', 'U', 'G', 'R') AND dp.name NOT IN ('sys', 'INFORMATION_SCHEMA') ORDER BY dp.name",
      ]);
      return [
        for (final r in logins)
          PrincipalDef(
            name: rowText(r, 'name')!,
            kind: PrincipalKind.login,
            auth: rowText(r, 'type') == 'S' ? PrincipalAuth.password : PrincipalAuth.windows,
            locked: rowBool(r, 'is_disabled'),
            defaultDatabase: rowText(r, 'default_database_name'),
            builtIn: rowText(r, 'name')!.startsWith('NT '),
          ),
        for (final r in users)
          () {
            final type = rowText(r, 'type');
            final login = rowText(r, 'login_name');
            final auth = switch (rowText(r, 'authentication_type_desc')) {
              'INSTANCE' => PrincipalAuth.login,
              'DATABASE' => PrincipalAuth.password,
              'WINDOWS' => PrincipalAuth.windows,
              'NONE' => PrincipalAuth.none,
              _ =>
                type == 'U' || type == 'G'
                    ? PrincipalAuth.windows
                    : (login == null ? PrincipalAuth.none : PrincipalAuth.login),
            };
            return PrincipalDef(
              name: rowText(r, 'name')!,
              kind: type == 'R' ? PrincipalKind.role : PrincipalKind.user,
              auth: type == 'R' ? PrincipalAuth.password : auth,
              login: login,
              defaultSchema: rowText(r, 'default_schema_name'),
              builtIn: rowBool(r, 'is_fixed_role') || (rowInt(r, 'principal_id') ?? 99) < 5,
            );
          }(),
      ];
    case DbFamily.mysql:
      final rows = d.isMariaDb
          ? await q.first([
              "SELECT u.User, u.Host, u.is_role, u.password_expired, JSON_VALUE(g.Priv, '\$.account_locked') AS account_locked "
                  'FROM mysql.user u LEFT JOIN mysql.global_priv g ON g.User = u.User AND g.Host = u.Host '
                  'ORDER BY u.User, u.Host',
              'SELECT User, Host, is_role, password_expired FROM mysql.user ORDER BY User, Host',
            ])
          : await q.first([
              'SELECT User, Host, account_locked, password_expired, '
                  "authentication_string = '' AS no_password FROM mysql.user ORDER BY User, Host",
              'SELECT User, Host FROM mysql.user ORDER BY User, Host',
            ]);
      return [
        for (final r in rows)
          if (rowText(r, 'user') != null)
            () {
              final name = rowText(r, 'user')!;
              final locked = rowBool(r, 'account_locked');
              final expired = rowBool(r, 'password_expired');
              final role = d.isMariaDb ? rowBool(r, 'is_role') : locked && expired && rowBool(r, 'no_password');
              final host = rowText(r, 'host');
              return PrincipalDef(
                name: name,
                kind: role ? PrincipalKind.role : PrincipalKind.user,
                host: d.isMariaDb && role ? null : (host ?? '%'),
                locked: !role && locked,
                passwordExpired: !role && expired,
                builtIn: name.startsWith('mysql.') || name == 'mariadb.sys',
              );
            }(),
      ];
    case DbFamily.oracle:
      final users = await q.first([
        'SELECT username, account_status, default_tablespace, temporary_tablespace, profile, oracle_maintained '
            'FROM dba_users ORDER BY username',
        'SELECT username, oracle_maintained FROM all_users ORDER BY username',
        'SELECT username FROM all_users ORDER BY username',
      ]);
      final roles = await _optional(q, [
        'SELECT role, oracle_maintained FROM dba_roles ORDER BY role',
        'SELECT role FROM dba_roles ORDER BY role',
        'SELECT DISTINCT granted_role AS role FROM user_role_privs ORDER BY 1',
      ]);
      return [
        for (final r in users)
          () {
            final status = (rowText(r, 'account_status') ?? '').toUpperCase();
            return PrincipalDef(
              name: rowText(r, 'username')!,
              kind: PrincipalKind.user,
              locked: status.contains('LOCKED'),
              passwordExpired: status.contains('EXPIRED'),
              defaultTablespace: rowText(r, 'default_tablespace'),
              temporaryTablespace: rowText(r, 'temporary_tablespace'),
              profile: rowText(r, 'profile'),
              builtIn: rowBool(r, 'oracle_maintained'),
            );
          }(),
        for (final r in roles)
          PrincipalDef(name: rowText(r, 'role')!, kind: PrincipalKind.role, builtIn: rowBool(r, 'oracle_maintained')),
      ];
    case DbFamily.db2:
      final roles = await _optional(q, ['SELECT ROLENAME FROM SYSCAT.ROLES ORDER BY ROLENAME']);
      final grantees = await q.first([
        'SELECT DISTINCT GRANTEE, GRANTEETYPE FROM ('
            'SELECT GRANTEE, GRANTEETYPE FROM SYSCAT.DBAUTH UNION ALL '
            'SELECT GRANTEE, GRANTEETYPE FROM SYSCAT.TABAUTH UNION ALL '
            'SELECT GRANTEE, GRANTEETYPE FROM SYSCAT.ROLEAUTH'
            ") g WHERE GRANTEETYPE IN ('U', 'G') ORDER BY GRANTEE",
      ]);
      return [
        for (final r in grantees)
          PrincipalDef(
            name: rowText(r, 'grantee')!,
            kind: rowText(r, 'granteetype') == 'G' ? PrincipalKind.group : PrincipalKind.user,
            builtIn: rowText(r, 'grantee') == 'PUBLIC',
          ),
        for (final r in roles)
          PrincipalDef(
            name: rowText(r, 'rolename')!,
            kind: PrincipalKind.role,
            builtIn: rowText(r, 'rolename')!.startsWith('SYS'),
          ),
      ];
    case DbFamily.firebird:
      final users = await _optional(q, [
        'SELECT SEC\$USER_NAME AS name, SEC\$ACTIVE AS active, SEC\$DESCRIPTION AS description FROM SEC\$USERS ORDER BY 1',
      ]);
      final roles = await q.first([
        'SELECT RDB\$ROLE_NAME AS name, RDB\$SYSTEM_FLAG AS sys, RDB\$DESCRIPTION AS description FROM RDB\$ROLES ORDER BY 1',
      ]);
      return [
        for (final r in users)
          PrincipalDef(
            name: rowText(r, 'name')!,
            kind: PrincipalKind.user,
            locked: r['active'] != null && !rowBool(r, 'active'),
            comment: rowText(r, 'description'),
          ),
        for (final r in roles)
          PrincipalDef(
            name: rowText(r, 'name')!,
            kind: PrincipalKind.role,
            comment: rowText(r, 'description'),
            builtIn: rowBool(r, 'sys'),
          ),
      ];
    case DbFamily.snowflake:
      final users = await _optional(q, ['SHOW USERS']);
      final roles = await q.first(['SHOW ROLES']);
      return [
        for (final r in users)
          PrincipalDef(
            name: rowText(r, 'name')!,
            kind: PrincipalKind.user,
            locked: rowBool(r, 'disabled'),
            defaultRole: rowText(r, 'default_role'),
            defaultWarehouse: rowText(r, 'default_warehouse'),
            mustChangePassword: rowBool(r, 'must_change_password'),
            comment: rowText(r, 'comment'),
          ),
        for (final r in roles)
          PrincipalDef(
            name: rowText(r, 'name')!,
            kind: PrincipalKind.role,
            comment: rowText(r, 'comment'),
            builtIn: _snowflakeSystemRoles.contains(rowText(r, 'name')!.toUpperCase()),
          ),
      ];
    case DbFamily.mongodb:
      return readMongoPrincipals(q);
    case DbFamily.cassandra:
      final rows = await q.first(['SELECT role, can_login, is_superuser FROM system_auth.roles']);
      return [
        for (final r in rows)
          PrincipalDef(
            name: rowText(r, 'role')!,
            kind: rowBool(r, 'can_login') ? PrincipalKind.user : PrincipalKind.role,
            superuser: rowBool(r, 'is_superuser'),
          ),
      ]..sort((a, b) => a.name.compareTo(b.name));
    case DbFamily.redis:
      final rows = await q.first(['ACL LIST']);
      return [
        for (final r in rows)
          if (r['value'] ?? r.values.lastOrNull case final String line) ?parseAclUser(line),
      ];
    default:
      return const [];
  }
}

// ---------------------------------------------------------------------------
// Role memberships
// ---------------------------------------------------------------------------

/// Every role membership (empty for Snowflake: read per principal).
Future<List<RoleMembership>> readMemberships(CatalogQueries q, SqlDialect d, {String? catalog}) async {
  switch (d.family) {
    case DbFamily.postgres:
      final rows = await q.first([
        'SELECT r.rolname AS role_name, m.rolname AS member_name, a.admin_option FROM pg_auth_members a '
            'JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member',
      ]);
      return [
        for (final r in rows)
          RoleMembership(rowText(r, 'role_name')!, rowText(r, 'member_name')!, withAdmin: rowBool(r, 'admin_option')),
      ];
    case DbFamily.sqlServer:
      final db = _db(d, catalog);
      final server = await _optional(q, [
        'SELECT r.name AS role_name, m.name AS member_name FROM sys.server_role_members rm '
            'JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id '
            'JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id',
      ]);
      final database = await q.first([
        'SELECT r.name AS role_name, m.name AS member_name FROM ${db}sys.database_role_members rm '
            'JOIN ${db}sys.database_principals r ON r.principal_id = rm.role_principal_id '
            'JOIN ${db}sys.database_principals m ON m.principal_id = rm.member_principal_id',
      ]);
      return [
        for (final r in server) RoleMembership(rowText(r, 'role_name')!, rowText(r, 'member_name')!, serverRole: true),
        for (final r in database) RoleMembership(rowText(r, 'role_name')!, rowText(r, 'member_name')!),
      ];
    case DbFamily.mysql:
      if (d.isMariaDb) {
        final rows = await q.first(['SELECT Role, User, Host, Admin_option FROM mysql.roles_mapping']);
        return [
          for (final r in rows)
            RoleMembership(
              rowText(r, 'role')!,
              rowText(r, 'user')!,
              memberHost: rowText(r, 'host'),
              withAdmin: rowBool(r, 'admin_option'),
            ),
        ];
      }
      final rows = await q.first([
        'SELECT FROM_USER, FROM_HOST, TO_USER, TO_HOST, WITH_ADMIN_OPTION FROM mysql.role_edges',
      ]);
      return [
        for (final r in rows)
          RoleMembership(
            rowText(r, 'from_user')!,
            rowText(r, 'to_user')!,
            roleHost: rowText(r, 'from_host') ?? '%',
            memberHost: rowText(r, 'to_host') ?? '%',
            withAdmin: rowBool(r, 'with_admin_option'),
          ),
      ];
    case DbFamily.oracle:
      final rows = await q.first([
        'SELECT granted_role, grantee, admin_option FROM dba_role_privs',
        'SELECT granted_role, username AS grantee, admin_option FROM user_role_privs',
      ]);
      return [
        for (final r in rows)
          RoleMembership(rowText(r, 'granted_role')!, rowText(r, 'grantee')!, withAdmin: rowBool(r, 'admin_option')),
      ];
    case DbFamily.db2:
      final rows = await q.first(['SELECT ROLENAME, GRANTEE, GRANTEETYPE, ADMIN FROM SYSCAT.ROLEAUTH']);
      return [
        for (final r in rows)
          RoleMembership(rowText(r, 'rolename')!, rowText(r, 'grantee')!, withAdmin: rowBool(r, 'admin')),
      ];
    case DbFamily.firebird:
      final rows = await q.first([
        'SELECT RDB\$RELATION_NAME AS role_name, RDB\$USER AS member_name, RDB\$GRANT_OPTION AS admin_option '
            "FROM RDB\$USER_PRIVILEGES WHERE RDB\$PRIVILEGE = 'M'",
      ]);
      return [
        for (final r in rows)
          RoleMembership(rowText(r, 'role_name')!, rowText(r, 'member_name')!, withAdmin: rowBool(r, 'admin_option')),
      ];
    case DbFamily.mongodb:
      return readMongoMemberships(q);
    case DbFamily.cassandra:
      final rows = await q.first(['SELECT role, member_of FROM system_auth.roles']);
      return [
        for (final r in rows)
          for (final role in _jsonStrings(r['member_of'])) RoleMembership(role, rowText(r, 'role')!),
      ];
    default:
      return const [];
  }
}

/// Roles [p] belongs to, from all the [memberships].
List<RoleMembership> membershipsOf(PrincipalDef p, List<RoleMembership> memberships) => [
  for (final m in memberships)
    if (m.isMember(p) && m.serverRole == (p.kind == PrincipalKind.login)) m,
];

// ---------------------------------------------------------------------------
// Privileges of a principal
// ---------------------------------------------------------------------------

/// Privileges of [p] (and, for Snowflake, its roles). [memberships] are the
/// ones of [readMemberships].
Future<PrincipalAccess> readAccess(
  CatalogQueries q,
  SqlDialect d,
  PrincipalDef p, {
  String? catalog,
  List<RoleMembership> memberships = const [],
}) async {
  final name = p.dbName;
  final roles = membershipsOf(p, memberships);
  switch (d.family) {
    case DbFamily.postgres:
      final who = '(SELECT oid FROM pg_roles WHERE rolname = ${lit(name)})';
      String acl(String select, String from, String column) =>
          'SELECT $select, a.privilege_type, a.is_grantable FROM $from CROSS JOIN LATERAL aclexplode($column) a '
          'WHERE a.grantee = $who';
      const userSchemas = "n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_toast%'";
      final rows = await q.first([
        [
          acl(
            "'rel' AS kind, n.nspname AS schema_name, c.relname AS object_name, c.relkind::text AS sub",
            'pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace',
            'c.relacl',
          ),
          " AND c.relkind IN ('r', 'p', 'f', 'v', 'm', 'S') AND $userSchemas UNION ALL ",
          acl(
            "'proc', n.nspname, p.proname, p.prokind::text",
            'pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace',
            'p.proacl',
          ),
          ' AND $userSchemas UNION ALL ',
          acl("'schema', n.nspname, NULL::text, NULL::text", 'pg_namespace n', 'n.nspacl'),
          ' UNION ALL ',
          acl("'db', d.datname, NULL::text, NULL::text", 'pg_database d', 'd.datacl'),
        ].join(),
      ]);
      return PrincipalAccess(
        memberOf: roles,
        grants: [
          for (final r in rows)
            () {
              final kind = rowText(r, 'kind');
              final sub = rowText(r, 'sub');
              final privilege = rowText(r, 'privilege_type')!;
              final option = rowBool(r, 'is_grantable');
              return switch (kind) {
                'schema' => GrantDef(
                  privilege: privilege,
                  target: GrantTarget.schema,
                  schema: rowText(r, 'schema_name'),
                  withGrantOption: option,
                ),
                'db' => GrantDef(
                  privilege: privilege,
                  target: GrantTarget.database,
                  catalog: rowText(r, 'schema_name'),
                  withGrantOption: option,
                ),
                'proc' => GrantDef(
                  privilege: privilege,
                  target: GrantTarget.routine,
                  schema: rowText(r, 'schema_name'),
                  object: rowText(r, 'object_name'),
                  isFunction: sub != 'p',
                  withGrantOption: option,
                ),
                _ => GrantDef(
                  privilege: privilege,
                  target: switch (sub) {
                    'v' || 'm' => GrantTarget.view,
                    'S' => GrantTarget.sequence,
                    _ => GrantTarget.table,
                  },
                  schema: rowText(r, 'schema_name'),
                  object: rowText(r, 'object_name'),
                  withGrantOption: option,
                ),
              };
            }(),
        ],
      );
    case DbFamily.sqlServer:
      if (p.kind == PrincipalKind.login) {
        final rows = await q.first([
          'SELECT p.permission_name, p.state FROM sys.server_permissions p '
              'JOIN sys.server_principals g ON g.principal_id = p.grantee_principal_id '
              "WHERE g.name = N${lit(name)} AND p.class = 100 AND p.state IN ('G', 'W')",
        ]);
        return PrincipalAccess(
          memberOf: roles,
          grants: [
            for (final r in rows)
              GrantDef(
                privilege: rowText(r, 'permission_name')!,
                target: GrantTarget.system,
                withGrantOption: rowText(r, 'state') == 'W',
              ),
          ],
        );
      }
      final db = _db(d, catalog);
      final rows = await q.first([
        'SELECT p.class, p.permission_name, p.state, s.name AS schema_name, o.name AS object_name, '
            'o.type AS object_type, sc.name AS class_schema FROM ${db}sys.database_permissions p '
            'JOIN ${db}sys.database_principals g ON g.principal_id = p.grantee_principal_id '
            'LEFT JOIN ${db}sys.objects o ON p.class = 1 AND o.object_id = p.major_id '
            'LEFT JOIN ${db}sys.schemas s ON s.schema_id = o.schema_id '
            'LEFT JOIN ${db}sys.schemas sc ON p.class = 3 AND sc.schema_id = p.major_id '
            "WHERE g.name = N${lit(name)} AND p.minor_id = 0 AND p.state IN ('G', 'W') AND p.class IN (0, 1, 3)",
      ]);
      return PrincipalAccess(memberOf: roles, grants: [for (final r in rows) ?_mssqlGrant(r)]);
    case DbFamily.mysql:
      final rows = await q.first(['SHOW GRANTS FOR ${SecurityDdl.forFamily(d).grantee(p.copyWith(name: name))}']);
      return PrincipalAccess(
        memberOf: roles,
        grants: [
          for (final r in rows)
            if (r.values.firstOrNull case final String line) ...parseMySqlGrant(line),
        ],
      );
    case DbFamily.oracle:
      final who = lit(name);
      final sys = await _optional(q, [
        'SELECT privilege, admin_option FROM dba_sys_privs WHERE grantee = $who',
        p.kind == PrincipalKind.role
            ? 'SELECT privilege, admin_option FROM role_sys_privs WHERE role = $who'
            : 'SELECT privilege, admin_option FROM user_sys_privs WHERE username = $who',
      ]);
      final obj = await q.first([
        'SELECT owner, table_name, privilege, grantable, type FROM dba_tab_privs WHERE grantee = $who',
        'SELECT table_schema AS owner, table_name, privilege, grantable, type FROM all_tab_privs WHERE grantee = $who',
        'SELECT table_schema AS owner, table_name, privilege, grantable FROM all_tab_privs WHERE grantee = $who',
      ]);
      return PrincipalAccess(
        memberOf: roles,
        grants: [
          for (final r in sys)
            GrantDef(
              privilege: rowText(r, 'privilege')!,
              target: GrantTarget.system,
              withGrantOption: rowBool(r, 'admin_option'),
            ),
          for (final r in obj)
            if (_oracleTarget(rowText(r, 'type')) case final t?)
              GrantDef(
                privilege: rowText(r, 'privilege')!,
                target: t,
                schema: rowText(r, 'owner'),
                object: rowText(r, 'table_name'),
                isFunction: rowText(r, 'type') == 'FUNCTION',
                withGrantOption: rowBool(r, 'grantable'),
              ),
        ],
      );
    case DbFamily.db2:
      return PrincipalAccess(memberOf: roles, grants: await _db2Grants(q, p));
    case DbFamily.firebird:
      final type = p.kind == PrincipalKind.role ? 13 : 8;
      final rows = await q.first([
        'SELECT RDB\$RELATION_NAME AS obj, RDB\$OBJECT_TYPE AS obj_type, RDB\$PRIVILEGE AS priv, '
            'RDB\$GRANT_OPTION AS grant_option FROM RDB\$USER_PRIVILEGES '
            "WHERE RDB\$USER = ${lit(name)} AND RDB\$USER_TYPE = $type AND RDB\$PRIVILEGE <> 'M' "
            'AND RDB\$FIELD_NAME IS NULL',
      ]);
      return PrincipalAccess(memberOf: roles, grants: [for (final r in rows) ?_firebirdGrant(r)]);
    case DbFamily.snowflake:
      final rows = await q.first([
        'SHOW GRANTS TO ${p.kind == PrincipalKind.role ? 'ROLE' : 'USER'} ${d.quoteIdent(name)}',
      ]);
      final memberOf = <RoleMembership>[];
      final grants = <GrantDef>[];
      for (final r in rows) {
        if (p.kind == PrincipalKind.user) {
          final role = rowText(r, 'role');
          if (role != null) memberOf.add(RoleMembership(role, name));
          continue;
        }
        final privilege = rowText(r, 'privilege')!;
        final on = rowText(r, 'granted_on') ?? '';
        final parts = splitQualified(rowText(r, 'name') ?? '');
        if (on == 'ROLE' && privilege == 'USAGE') {
          memberOf.add(RoleMembership(parts.last, name));
          continue;
        }
        if (privilege == 'OWNERSHIP') continue;
        final option = rowBool(r, 'grant_option');
        final g = switch (on) {
          'ACCOUNT' => GrantDef(privilege: privilege, target: GrantTarget.system, withGrantOption: option),
          'DATABASE' => GrantDef(
            privilege: privilege,
            target: GrantTarget.database,
            catalog: parts.last,
            withGrantOption: option,
          ),
          'SCHEMA' when parts.length >= 2 => GrantDef(
            privilege: privilege,
            target: GrantTarget.schema,
            catalog: parts[parts.length - 2],
            schema: parts.last,
            withGrantOption: option,
          ),
          'TABLE' || 'VIEW' || 'SEQUENCE' || 'FUNCTION' || 'PROCEDURE' when parts.length >= 3 => GrantDef(
            privilege: privilege,
            target: switch (on) {
              'VIEW' => GrantTarget.view,
              'SEQUENCE' => GrantTarget.sequence,
              'FUNCTION' || 'PROCEDURE' => GrantTarget.routine,
              _ => GrantTarget.table,
            },
            catalog: parts[parts.length - 3],
            schema: parts[parts.length - 2],
            object: parts.last.split('(').first,
            isFunction: on == 'FUNCTION',
            withGrantOption: option,
          ),
          _ => null,
        };
        if (g != null) grants.add(g);
      }
      return PrincipalAccess(memberOf: memberOf, grants: grants);
    case DbFamily.mongodb:
      if (p.kind != PrincipalKind.role) return PrincipalAccess(memberOf: roles);
      return PrincipalAccess(memberOf: roles, grants: await readMongoRoleGrants(q, p));
    case DbFamily.cassandra:
      final rows = await q.first([
        'SELECT resource, permissions FROM system_auth.role_permissions WHERE role = ${lit(name)}',
      ]);
      return PrincipalAccess(
        memberOf: roles,
        grants: [
          for (final r in rows)
            if (_cassandraTarget(rowText(r, 'resource') ?? '') case final on?)
              for (final perm in _jsonStrings(r['permissions'])) on.withPrivilege(perm),
        ],
      );
    default:
      return PrincipalAccess(memberOf: roles);
  }
}

/// Objects and schemas without the database: the script runs in it.
GrantDef? _mssqlGrant(CatalogRow r) {
  final privilege = rowText(r, 'permission_name')!;
  final option = rowText(r, 'state') == 'W';
  switch (rowInt(r, 'class')) {
    case 0:
      return GrantDef(privilege: privilege, target: GrantTarget.system, withGrantOption: option);
    case 3:
      return GrantDef(
        privilege: privilege,
        target: GrantTarget.schema,
        schema: rowText(r, 'class_schema'),
        withGrantOption: option,
      );
    case 1:
      final type = rowText(r, 'object_type');
      final target = switch (type) {
        'U' => GrantTarget.table,
        'V' => GrantTarget.view,
        'SO' => GrantTarget.sequence,
        'P' || 'PC' || 'FN' || 'IF' || 'TF' || 'FS' || 'FT' => GrantTarget.routine,
        _ => null,
      };
      if (target == null) return null;
      return GrantDef(
        privilege: privilege,
        target: target,
        schema: rowText(r, 'schema_name'),
        object: rowText(r, 'object_name'),
        isFunction: type != 'P' && type != 'PC',
        withGrantOption: option,
      );
  }
  return null;
}

GrantTarget? _oracleTarget(String? type) => switch (type) {
  null || 'TABLE' => GrantTarget.table,
  'VIEW' => GrantTarget.view,
  'SEQUENCE' => GrantTarget.sequence,
  'PROCEDURE' || 'FUNCTION' || 'PACKAGE' => GrantTarget.routine,
  _ => null,
};

const _firebirdPrivileges = {
  'S': 'SELECT',
  'I': 'INSERT',
  'U': 'UPDATE',
  'D': 'DELETE',
  'R': 'REFERENCES',
  'X': 'EXECUTE',
  'G': 'USAGE',
};

GrantDef? _firebirdGrant(CatalogRow r) {
  final privilege = _firebirdPrivileges[rowText(r, 'priv')];
  final object = rowText(r, 'obj');
  if (privilege == null || object == null) return null;
  final target = switch (rowInt(r, 'obj_type')) {
    0 => GrantTarget.table,
    1 => GrantTarget.view,
    5 || 15 => GrantTarget.routine,
    14 => GrantTarget.sequence,
    _ => null,
  };
  if (target == null) return null;
  return GrantDef(
    privilege: privilege,
    target: target,
    object: object,
    isFunction: rowInt(r, 'obj_type') == 15,
    withGrantOption: rowBool(r, 'grant_option'),
  );
}

const _db2DatabaseAuth = {
  'connectauth': 'CONNECT',
  'createtabauth': 'CREATETAB',
  'bindaddauth': 'BINDADD',
  'implschemaauth': 'IMPLICIT_SCHEMA',
  'loadauth': 'LOAD',
  'externalroutineauth': 'CREATE_EXTERNAL_ROUTINE',
  'quiesceconnectauth': 'QUIESCE_CONNECT',
  'sqladmauth': 'SQLADM',
  'dataaccessauth': 'DATAACCESS',
  'accessctrlauth': 'ACCESSCTRL',
  'dbadmauth': 'DBADM',
  'securityadmauth': 'SECADM',
};

const _db2TableAuth = {
  'selectauth': 'SELECT',
  'insertauth': 'INSERT',
  'updateauth': 'UPDATE',
  'deleteauth': 'DELETE',
  'alterauth': 'ALTER',
  'indexauth': 'INDEX',
  'refauth': 'REFERENCES',
  'controlauth': 'CONTROL',
};

Future<List<GrantDef>> _db2Grants(CatalogQueries q, PrincipalDef p) async {
  final type = switch (p.kind) {
    PrincipalKind.role => 'R',
    PrincipalKind.group => 'G',
    _ => 'U',
  };
  final who = 'GRANTEE = ${lit(p.dbName)} AND GRANTEETYPE = ${lit(type)}';
  final out = <GrantDef>[];
  // 'Y' granted, 'G' granted with the grant option.
  void add(CatalogRow r, Map<String, String> columns, GrantDef Function(String privilege, bool option) make) {
    for (final e in columns.entries) {
      final v = rowText(r, e.key);
      if (v == 'Y' || v == 'G') out.add(make(e.value, v == 'G'));
    }
  }

  for (final r in await q.first(['SELECT * FROM SYSCAT.DBAUTH WHERE $who'])) {
    add(r, _db2DatabaseAuth, (p, _) => GrantDef(privilege: p, target: GrantTarget.database));
  }
  for (final r in await _optional(q, ['SELECT * FROM SYSCAT.TABAUTH WHERE $who'])) {
    add(
      r,
      _db2TableAuth,
      (p, o) => GrantDef(
        privilege: p,
        target: GrantTarget.table,
        schema: rowText(r, 'tabschema'),
        object: rowText(r, 'tabname'),
        withGrantOption: o,
      ),
    );
  }
  for (final r in await _optional(q, ['SELECT * FROM SYSCAT.SCHEMAAUTH WHERE $who'])) {
    add(
      r,
      const {'createinauth': 'CREATEIN', 'alterinauth': 'ALTERIN', 'dropinauth': 'DROPIN'},
      (p, o) =>
          GrantDef(privilege: p, target: GrantTarget.schema, schema: rowText(r, 'schemaname'), withGrantOption: o),
    );
  }
  for (final r in await _optional(q, ['SELECT * FROM SYSCAT.SEQUENCEAUTH WHERE $who'])) {
    add(
      r,
      const {'usageauth': 'USAGE', 'alterauth': 'ALTER'},
      (p, o) => GrantDef(
        privilege: p,
        target: GrantTarget.sequence,
        schema: rowText(r, 'seqschema'),
        object: rowText(r, 'seqname'),
        withGrantOption: o,
      ),
    );
  }
  final routines = await _optional(q, [
    'SELECT a.SCHEMA, r.ROUTINENAME, a.ROUTINETYPE, a.EXECUTEAUTH FROM SYSCAT.ROUTINEAUTH a '
        'JOIN SYSCAT.ROUTINES r ON r.ROUTINESCHEMA = a.SCHEMA AND r.SPECIFICNAME = a.SPECIFICNAME '
        'WHERE a.GRANTEE = ${lit(p.dbName)} AND a.GRANTEETYPE = ${lit(type)}',
  ]);
  for (final r in routines) {
    add(
      r,
      const {'executeauth': 'EXECUTE'},
      (p, o) => GrantDef(
        privilege: p,
        target: GrantTarget.routine,
        schema: rowText(r, 'schema'),
        object: rowText(r, 'routinename'),
        isFunction: rowText(r, 'routinetype') == 'F',
        withGrantOption: o,
      ),
    );
  }
  return out;
}

/// `A.B."C d"` → [A, B, C d].
List<String> splitQualified(String name) {
  final out = <String>[];
  final sb = StringBuffer();
  var quoted = false;
  for (var i = 0; i < name.length; i++) {
    final c = name[i];
    if (c == '"') {
      if (quoted && i + 1 < name.length && name[i + 1] == '"') {
        sb.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == '.' && !quoted) {
      out.add(sb.toString());
      sb.clear();
    } else {
      sb.write(c);
    }
  }
  out.add(sb.toString());
  return out;
}

final _mysqlGrant = RegExp(
  r'^GRANT\s+(.+?)\s+ON\s+(?:(TABLE|FUNCTION|PROCEDURE)\s+)?((?:`(?:[^`]|``)*`|[^\s.]+))\.((?:`(?:[^`]|``)*`|\S+?))\s+TO\s+(.*)$',
  caseSensitive: false,
);

/// Privileges of one SHOW GRANTS line (role grants, USAGE and column
/// privileges are left out; ALL PRIVILEGES is expanded).
List<GrantDef> parseMySqlGrant(String line) {
  final m = _mysqlGrant.firstMatch(line.trim());
  if (m == null) return const [];
  final db = m[3]! == '*' ? null : unquoteIdent(m[3]!);
  final object = m[4]! == '*' ? null : unquoteIdent(m[4]!);
  final option = RegExp(r'\bWITH\s+GRANT\s+OPTION\b', caseSensitive: false).hasMatch(m[5]!);
  final kind = (m[2] ?? '').toUpperCase();
  final target = db == null
      ? GrantTarget.system
      : object == null
      ? GrantTarget.database
      : kind == 'FUNCTION' || kind == 'PROCEDURE'
      ? GrantTarget.routine
      : GrantTarget.table;
  final privileges = <String>[];
  var depth = 0;
  final sb = StringBuffer();
  for (final c in m[1]!.split('')) {
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (c == ',' && depth == 0) {
      privileges.add(sb.toString().trim());
      sb.clear();
    } else {
      sb.write(c);
    }
  }
  privileges.add(sb.toString().trim());
  final ddl = MySqlPrivilegeLists.forTarget(target);
  final expanded = [
    for (final p in privileges)
      if (p.toUpperCase() == 'ALL PRIVILEGES' || p.toUpperCase() == 'ALL')
        ...ddl
      else if (!p.contains('(') && p.toUpperCase() != 'USAGE' && p.toUpperCase() != 'PROXY')
        p.toUpperCase(),
  ];
  return [
    for (final p in expanded)
      GrantDef(
        privilege: p,
        target: target,
        catalog: db,
        object: object,
        isFunction: kind == 'FUNCTION',
        withGrantOption: option,
      ),
  ];
}

/// Privilege lists of MySQL by level, for ALL PRIVILEGES.
abstract final class MySqlPrivilegeLists {
  static List<String> forTarget(GrantTarget t) {
    final ddl = SecurityDdl.forFamily(SqlDialect(dbmsName: 'MySQL', quote: '`'));
    return t == GrantTarget.system ? ddl.systemPrivileges(PrincipalKind.user) : ddl.privileges(t);
  }
}

// ---------------------------------------------------------------------------
// Privileges on one object
// ---------------------------------------------------------------------------

/// Who holds which privileges on table or view [table] (`object` set),
/// matched to the [principals] when known.
Future<List<ObjectGrant>> readObjectGrants(
  CatalogQueries q,
  SqlDialect d,
  GrantDef table,
  List<PrincipalDef> principals,
) async {
  PrincipalDef who(String name, {String? host, PrincipalKind? kind}) {
    for (final p in principals) {
      if (p.name.toLowerCase() == name.toLowerCase() &&
          (host == null || (p.host ?? '').toLowerCase() == host.toLowerCase()) &&
          (kind == null || p.kind == kind) &&
          p.kind != PrincipalKind.login) {
        return p;
      }
    }
    return PrincipalDef(name: name, kind: kind ?? PrincipalKind.user, host: host);
  }

  GrantDef g(String privilege, bool option) => GrantDef(
    privilege: privilege.toUpperCase(),
    target: table.target,
    catalog: table.catalog,
    schema: table.schema,
    object: table.object,
    withGrantOption: option,
  );

  final schema = lit(table.schema ?? '');
  final name = lit(table.object!);
  switch (d.family) {
    case DbFamily.postgres:
      final rows = await q.first([
        'SELECT r.rolname AS grantee, a.privilege_type, a.is_grantable FROM pg_class c '
            'JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) a '
            'JOIN pg_roles r ON r.oid = a.grantee WHERE n.nspname = $schema AND c.relname = $name',
      ]);
      return [
        for (final r in rows)
          ObjectGrant(who(rowText(r, 'grantee')!), g(rowText(r, 'privilege_type')!, rowBool(r, 'is_grantable'))),
      ];
    case DbFamily.sqlServer:
      final db = _db(d, table.catalog);
      final full = d.qualified(table.catalog, table.schema, table.object!);
      final rows = await q.first([
        'SELECT g.name AS grantee, g.type AS grantee_type, p.permission_name, p.state '
            'FROM ${db}sys.database_permissions p '
            'JOIN ${db}sys.database_principals g ON g.principal_id = p.grantee_principal_id '
            "WHERE p.class = 1 AND p.minor_id = 0 AND p.major_id = OBJECT_ID(N${lit(full)}) AND p.state IN ('G', 'W')",
      ]);
      return [
        for (final r in rows)
          ObjectGrant(
            who(
              rowText(r, 'grantee')!,
              kind: rowText(r, 'grantee_type') == 'R' ? PrincipalKind.role : PrincipalKind.user,
            ),
            g(rowText(r, 'permission_name')!, rowText(r, 'state') == 'W'),
          ),
      ];
    case DbFamily.mysql:
      final rows = await q.first([
        'SELECT User, Host, Table_priv FROM mysql.tables_priv '
            'WHERE Db = ${lit(table.catalog ?? table.schema ?? '')} AND Table_name = $name',
      ]);
      return [
        for (final r in rows)
          for (final p in (rowText(r, 'table_priv') ?? '').split(','))
            if (p.trim().isNotEmpty && p.trim().toLowerCase() != 'grant')
              ObjectGrant(
                who(rowText(r, 'user')!, host: rowText(r, 'host')),
                g(p.trim(), (rowText(r, 'table_priv') ?? '').toLowerCase().split(',').contains('grant')),
              ),
      ];
    case DbFamily.oracle:
      final rows = await q.first([
        'SELECT grantee, privilege, grantable FROM dba_tab_privs WHERE owner = $schema AND table_name = $name',
        'SELECT grantee, privilege, grantable FROM all_tab_privs WHERE table_schema = $schema AND table_name = $name',
      ]);
      return [
        for (final r in rows)
          ObjectGrant(who(rowText(r, 'grantee')!), g(rowText(r, 'privilege')!, rowBool(r, 'grantable'))),
      ];
    case DbFamily.db2:
      final rows = await q.first(['SELECT * FROM SYSCAT.TABAUTH WHERE TABSCHEMA = $schema AND TABNAME = $name']);
      return [
        for (final r in rows)
          for (final e in _db2TableAuth.entries)
            if (rowText(r, e.key) == 'Y' || rowText(r, e.key) == 'G')
              ObjectGrant(
                who(
                  rowText(r, 'grantee')!,
                  kind: switch (rowText(r, 'granteetype')) {
                    'R' => PrincipalKind.role,
                    'G' => PrincipalKind.group,
                    _ => PrincipalKind.user,
                  },
                ),
                g(e.value, rowText(r, e.key) == 'G'),
              ),
      ];
    case DbFamily.firebird:
      final rows = await q.first([
        'SELECT RDB\$USER AS grantee, RDB\$USER_TYPE AS user_type, RDB\$PRIVILEGE AS priv, '
            'RDB\$GRANT_OPTION AS grant_option FROM RDB\$USER_PRIVILEGES '
            "WHERE RDB\$RELATION_NAME = $name AND RDB\$FIELD_NAME IS NULL AND RDB\$PRIVILEGE <> 'M' "
            'AND RDB\$USER_TYPE IN (8, 13)',
      ]);
      return [
        for (final r in rows)
          if (_firebirdPrivileges[rowText(r, 'priv')] case final p?)
            ObjectGrant(
              who(rowText(r, 'grantee')!, kind: rowInt(r, 'user_type') == 13 ? PrincipalKind.role : PrincipalKind.user),
              g(p, rowBool(r, 'grant_option')),
            ),
      ];
    case DbFamily.snowflake:
      final rows = await q.first([
        'SHOW GRANTS ON ${table.target == GrantTarget.view ? 'VIEW' : 'TABLE'} '
            '${d.qualified(table.catalog, table.schema, table.object!)}',
      ]);
      return [
        for (final r in rows)
          if (rowText(r, 'privilege') != 'OWNERSHIP' && rowText(r, 'granted_to') == 'ROLE')
            ObjectGrant(
              who(rowText(r, 'grantee_name')!, kind: PrincipalKind.role),
              g(rowText(r, 'privilege')!, rowBool(r, 'grant_option')),
            ),
      ];
    case DbFamily.cassandra:
      final resource = 'data/${table.catalog}/${table.object}';
      final rows = await q.first([
        'SELECT role, permissions FROM system_auth.role_permissions WHERE resource = ${lit(resource)} ALLOW FILTERING',
      ]);
      return [
        for (final r in rows)
          for (final perm in _jsonStrings(r['permissions'])) ObjectGrant(who(rowText(r, 'role')!), g(perm, false)),
      ];
    case DbFamily.bigquery:
      final project = table.catalog == null ? '' : '${d.quoteIdent(table.catalog!)}.';
      final where = 'WHERE object_schema = ${lit(table.schema ?? '')} AND object_name = ${lit(table.object!)}';
      final rows = await q.first([
        for (final region in const [
          'region-eu',
          'region-us',
          'region-europe-west8',
          'region-europe-west1',
          'region-us-central1',
        ])
          'SELECT privilege_type, grantee FROM $project`$region`.INFORMATION_SCHEMA.OBJECT_PRIVILEGES $where',
      ]);
      return [
        for (final r in rows)
          ObjectGrant(
            PrincipalDef(
              name: rowText(r, 'grantee')!,
              kind: (rowText(r, 'grantee') ?? '').startsWith('group:') ? PrincipalKind.group : PrincipalKind.user,
            ),
            GrantDef(
              privilege: rowText(r, 'privilege_type')!,
              target: table.target,
              catalog: table.catalog,
              schema: table.schema,
              object: table.object,
            ),
          ),
      ];
    default:
      return const [];
  }
}

// ---------------------------------------------------------------------------
// NoSQL helpers
// ---------------------------------------------------------------------------

extension on GrantDef {
  GrantDef withPrivilege(String privilege) => GrantDef(
    privilege: privilege,
    target: target,
    catalog: catalog,
    schema: schema,
    object: object,
    isFunction: isFunction,
  );
}

/// A set / list cell (JSON text or a Dart list) as strings.
List<String> _jsonStrings(Object? v) {
  Object? list = v;
  if (v is String) {
    try {
      list = jsonDecode(v);
    } catch (_) {
      return const [];
    }
  }
  return list is List ? [for (final x in list) '$x'] : const [];
}

/// Cassandra resource `data`, `data/ks`, `data/ks/table` as a privilege
/// template (null for roles, functions…).
GrantDef? _cassandraTarget(String resource) {
  final parts = resource.split('/');
  if (parts.first != 'data') return null;
  return switch (parts.length) {
    1 => const GrantDef(privilege: '', target: GrantTarget.system),
    2 => GrantDef(privilege: '', target: GrantTarget.database, catalog: parts[1]),
    _ => GrantDef(privilege: '', target: GrantTarget.table, catalog: parts[1], object: parts[2]),
  };
}

/// One line of ACL LIST: `user alice on #<hash> ~app:* &* +@read`.
PrincipalDef? parseAclUser(String line) {
  final t = line.trim().split(RegExp(r'\s+'));
  if (t.length < 2 || t.first != 'user') return null;
  var locked = false;
  final rules = <String>[];
  for (final x in t.skip(2)) {
    if (x == 'on') continue;
    if (x == 'off') {
      locked = true;
    } else if (x.startsWith('#') || x.startsWith('>') || x == 'nopass' || x == 'resetpass' || x == 'sanitize-payload') {
      continue;
    } else {
      rules.add(x);
    }
  }
  return PrincipalDef(name: t[1], kind: PrincipalKind.user, locked: locked, aclRules: rules.join(' '));
}

/// The value of [key] in the key / value rows of a MongoDB command reply.
Object? _replyValue(List<CatalogRow> rows, String key) {
  for (final r in rows) {
    if (rowText(r, 'key') == key) {
      final v = r['value'];
      if (v is String) {
        try {
          return parseMongoValue(v);
        } catch (_) {
          return v;
        }
      }
      return v;
    }
  }
  return null;
}

String _mongoCmd(String db, String doc) => '${const MongoDdl().db(db)}.runCommand($doc)';

Future<List<Map>> _mongoUsers(CatalogQueries q) async {
  final rows = await q.first([_mongoCmd('admin', '{usersInfo: {forAllDBs: true}}')]);
  final users = _replyValue(rows, 'users');
  return [
    if (users is List)
      for (final u in users)
        if (u is Map) u,
  ];
}

Future<List<String>> _mongoDatabases(CatalogQueries q) async {
  final rows = await q.first(['show dbs']);
  return [for (final r in rows) ?rowText(r, 'name')];
}

Future<List<Map>> _mongoRoles(CatalogQueries q) async {
  final out = <Map>[];
  for (final db in (await _mongoDatabases(q)).take(40)) {
    try {
      final rows = await q.first([_mongoCmd(db, '{rolesInfo: 1, showPrivileges: true}')]);
      final roles = _replyValue(rows, 'roles');
      if (roles is List) out.addAll(roles.whereType<Map>());
    } catch (_) {}
  }
  return out;
}

/// MongoDB users of every database and the custom roles.
Future<List<PrincipalDef>> readMongoPrincipals(CatalogQueries q) async => [
  for (final u in await _mongoUsers(q))
    PrincipalDef(name: '${u['user']}', kind: PrincipalKind.user, host: '${u['db']}'),
  for (final r in await _mongoRoles(q))
    PrincipalDef(name: '${r['role']}', kind: PrincipalKind.role, host: '${r['db']}', builtIn: r['isBuiltin'] == true),
];

Future<List<RoleMembership>> readMongoMemberships(CatalogQueries q) async {
  List<RoleMembership> of(Map p, String nameKey) => [
    for (final r in (p['roles'] as List?) ?? const [])
      if (r is Map) RoleMembership('${r['role']}', '${p[nameKey]}', roleHost: '${r['db']}', memberHost: '${p['db']}'),
  ];
  return [
    for (final u in await _mongoUsers(q)) ...of(u, 'user'),
    for (final r in await _mongoRoles(q)) ...of(r, 'role'),
  ];
}

/// Privileges of the custom role [p].
Future<List<GrantDef>> readMongoRoleGrants(CatalogQueries q, PrincipalDef p) async {
  final rows = await q.first([
    _mongoCmd(p.host ?? 'admin', '{rolesInfo: ${jsonEncode(p.dbName)}, showPrivileges: true}'),
  ]);
  final roles = _replyValue(rows, 'roles');
  final role = roles is List && roles.isNotEmpty && roles.first is Map ? roles.first as Map : const {};
  return [
    for (final priv in (role['privileges'] as List?) ?? const [])
      if (priv is Map)
        for (final action in (priv['actions'] as List?) ?? const [])
          () {
            final res = (priv['resource'] as Map?) ?? const {};
            if (res['cluster'] == true) return GrantDef(privilege: '$action', target: GrantTarget.system);
            final coll = '${res['collection'] ?? ''}';
            return GrantDef(
              privilege: '$action',
              target: coll.isEmpty ? GrantTarget.database : GrantTarget.table,
              catalog: '${res['db'] ?? ''}',
              object: coll.isEmpty ? null : coll,
            );
          }(),
  ];
}

/// Built-in MongoDB roles offered as memberships, per database.
List<(String, String)> mongoBuiltinRoles(Iterable<String> databases) => [
  for (final r in mongoAdminRoles) (r, 'admin'),
  for (final db in {'admin', ...databases})
    for (final r in mongoDatabaseRoles) (r, db),
];
