// SQL Server: logins on the server, users and roles in each database
// (their statements run in that database: DdlScript.catalog).

import '../../model/security_defs.dart';
import 'security_ddl.dart';

class SqlServerSecurityDdl extends SecurityDdl {
  SqlServerSecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.login, PrincipalKind.user, PrincipalKind.role];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => switch (k) {
    PrincipalKind.login => const {
      PrincipalAttr.auth,
      PrincipalAttr.password,
      PrincipalAttr.defaultDatabase,
      PrincipalAttr.locked,
      PrincipalAttr.rename,
    },
    PrincipalKind.user => const {
      PrincipalAttr.auth,
      PrincipalAttr.login,
      PrincipalAttr.password,
      PrincipalAttr.defaultSchema,
      PrincipalAttr.rename,
    },
    _ => const {PrincipalAttr.rename},
  };

  @override
  List<PrincipalAuth> authOptions(PrincipalKind k) => switch (k) {
    PrincipalKind.login => const [PrincipalAuth.password, PrincipalAuth.windows],
    PrincipalKind.user => const [
      PrincipalAuth.login,
      PrincipalAuth.password,
      PrincipalAuth.none,
      PrincipalAuth.windows,
    ],
    _ => const [],
  };

  @override
  bool requiresPassword(PrincipalDef p) => p.kind != PrincipalKind.role && p.auth == PrincipalAuth.password;

  @override
  String passwordLiteral(String password) => 'N${lit(password)}';

  @override
  bool hasRoles(PrincipalKind k) => true;

  @override
  bool get adminOption => false;

  @override
  bool get revokeCascade => true;

  @override
  List<String> get serverRoles => const [
    'sysadmin',
    'serveradmin',
    'securityadmin',
    'processadmin',
    'setupadmin',
    'bulkadmin',
    'diskadmin',
    'dbcreator',
  ];

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => k == PrincipalKind.login
      ? const []
      : const [GrantTarget.table, GrantTarget.view, GrantTarget.sequence, GrantTarget.routine, GrantTarget.schema];

  @override
  List<String> privileges(GrantTarget t) => switch (t) {
    GrantTarget.table => const [
      'SELECT',
      'INSERT',
      'UPDATE',
      'DELETE',
      'REFERENCES',
      'ALTER',
      'VIEW DEFINITION',
      'CONTROL',
    ],
    GrantTarget.view => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'ALTER', 'VIEW DEFINITION', 'CONTROL'],
    GrantTarget.sequence => const ['UPDATE', 'REFERENCES', 'ALTER', 'VIEW DEFINITION', 'CONTROL'],
    GrantTarget.routine => const ['EXECUTE', 'ALTER', 'VIEW DEFINITION', 'CONTROL'],
    GrantTarget.schema => const [
      'SELECT',
      'INSERT',
      'UPDATE',
      'DELETE',
      'EXECUTE',
      'REFERENCES',
      'ALTER',
      'VIEW DEFINITION',
      'CONTROL',
    ],
    GrantTarget.database || GrantTarget.system => const [],
  };

  @override
  List<String> systemPrivileges(PrincipalKind k) => k == PrincipalKind.login
      ? const [
          'CONNECT SQL',
          'VIEW SERVER STATE',
          'VIEW ANY DATABASE',
          'VIEW ANY DEFINITION',
          'CREATE ANY DATABASE',
          'ALTER ANY DATABASE',
          'ALTER ANY LOGIN',
          'ALTER TRACE',
          'CONTROL SERVER',
        ]
      : const [
          'CONNECT',
          'CREATE TABLE',
          'CREATE VIEW',
          'CREATE PROCEDURE',
          'CREATE FUNCTION',
          'CREATE SCHEMA',
          'ALTER ANY SCHEMA',
          'SELECT',
          'INSERT',
          'UPDATE',
          'DELETE',
          'EXECUTE',
          'VIEW DEFINITION',
          'VIEW DATABASE STATE',
          'SHOWPLAN',
          'BACKUP DATABASE',
        ];

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) {
    final name = q(p.name);
    switch (p.kind) {
      case PrincipalKind.login:
        final db = has(p.defaultDatabase) ? 'DEFAULT_DATABASE = ${q(p.defaultDatabase!)}' : null;
        return [
          p.auth == PrincipalAuth.windows
              ? 'CREATE LOGIN $name FROM WINDOWS${db == null ? '' : ' WITH $db'}'
              : 'CREATE LOGIN $name WITH ${['PASSWORD = ${this.password(password)}', ?db].join(', ')}',
          if (p.locked) 'ALTER LOGIN $name DISABLE',
        ];
      case PrincipalKind.user:
        final schema = has(p.defaultSchema) ? 'DEFAULT_SCHEMA = ${q(p.defaultSchema!)}' : null;
        return [
          switch (p.auth) {
            PrincipalAuth.password =>
              'CREATE USER $name WITH ${['PASSWORD = ${this.password(password)}', ?schema].join(', ')}',
            PrincipalAuth.none => 'CREATE USER $name WITHOUT LOGIN${schema == null ? '' : ' WITH $schema'}',
            PrincipalAuth.windows => 'CREATE USER $name${schema == null ? '' : ' WITH $schema'}',
            _ =>
              'CREATE USER $name FOR LOGIN ${q(has(p.login) ? p.login! : p.name)}${schema == null ? '' : ' WITH $schema'}',
          },
        ];
      case PrincipalKind.role:
        return ['CREATE ROLE $name'];
      case PrincipalKind.group:
        return unsupportedKind(p);
    }
  }

  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) {
    final out = <String>[];
    final renamed = from.dbName != to.name;
    final name = q(to.name);
    if (from.auth != to.auth) {
      out.add('-- Il tipo di autenticazione di ${from.dbName} non si cambia: elimina e ricrea il principal');
    }
    switch (to.kind) {
      case PrincipalKind.login:
        if (renamed) out.add('ALTER LOGIN ${q(from.dbName)} WITH NAME = $name');
        if (password != null) out.add('ALTER LOGIN $name WITH PASSWORD = ${this.password(password)}');
        if ((from.defaultDatabase ?? '') != (to.defaultDatabase ?? '')) {
          out.add(
            'ALTER LOGIN $name WITH DEFAULT_DATABASE = ${q(has(to.defaultDatabase) ? to.defaultDatabase! : 'master')}',
          );
        }
        if (from.locked != to.locked) out.add('ALTER LOGIN $name ${to.locked ? 'DISABLE' : 'ENABLE'}');
      case PrincipalKind.user:
        final sets = [
          if (renamed) 'NAME = $name',
          if ((from.defaultSchema ?? '') != (to.defaultSchema ?? ''))
            'DEFAULT_SCHEMA = ${has(to.defaultSchema) ? q(to.defaultSchema!) : 'NULL'}',
          if ((from.login ?? '') != (to.login ?? '') && has(to.login)) 'LOGIN = ${q(to.login!)}',
          if (password != null) 'PASSWORD = ${this.password(password)}',
        ];
        if (sets.isNotEmpty) out.add('ALTER USER ${q(from.dbName)} WITH ${sets.join(', ')}');
      case PrincipalKind.role:
        if (renamed) out.add('ALTER ROLE ${q(from.dbName)} WITH NAME = $name');
      case PrincipalKind.group:
        break;
    }
    return out;
  }

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => [
    switch (p.kind) {
      PrincipalKind.login => 'DROP LOGIN ${q(p.dbName)}',
      PrincipalKind.role => 'DROP ROLE ${q(p.dbName)}',
      _ => 'DROP USER ${q(p.dbName)}',
    },
  ];

  @override
  String? onClause(GrantDef g) => switch (g.target) {
    GrantTarget.table ||
    GrantTarget.view ||
    GrantTarget.sequence ||
    GrantTarget.routine => 'OBJECT::${dialect.qualified(null, g.schema, g.object!)}',
    GrantTarget.schema => 'SCHEMA::${q(g.schema!)}',
    GrantTarget.database => 'DATABASE::${q(g.catalog!)}',
    GrantTarget.system => null,
  };

  @override
  List<String> grantRole(RoleMembership m, PrincipalDef member) => [
    'ALTER ${m.serverRole ? 'SERVER ' : ''}ROLE ${q(m.role)} ADD MEMBER ${grantee(member)}',
  ];

  @override
  List<String> revokeRole(RoleMembership m, PrincipalDef member) => [
    'ALTER ${m.serverRole ? 'SERVER ' : ''}ROLE ${q(m.role)} DROP MEMBER ${grantee(member)}',
  ];
}
