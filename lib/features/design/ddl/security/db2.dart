// Db2: users and groups belong to the operating system (or LDAP); the
// database has roles and grants authorities and privileges.

import '../../model/security_defs.dart';
import 'security_ddl.dart';

class Db2SecurityDdl extends SecurityDdl {
  Db2SecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.user, PrincipalKind.group, PrincipalKind.role];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => const {};

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => const [
    GrantTarget.database,
    GrantTarget.schema,
    GrantTarget.table,
    GrantTarget.view,
    GrantTarget.sequence,
    GrantTarget.routine,
  ];

  @override
  List<String> privileges(GrantTarget t) => switch (t) {
    GrantTarget.table => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'ALTER', 'INDEX', 'REFERENCES', 'CONTROL'],
    GrantTarget.view => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'CONTROL'],
    GrantTarget.sequence => const ['USAGE', 'ALTER'],
    GrantTarget.routine => const ['EXECUTE'],
    GrantTarget.schema => const ['CREATEIN', 'ALTERIN', 'DROPIN'],
    GrantTarget.database => const [
      'CONNECT',
      'CREATETAB',
      'BINDADD',
      'IMPLICIT_SCHEMA',
      'LOAD',
      'CREATE_EXTERNAL_ROUTINE',
      'QUIESCE_CONNECT',
      'SQLADM',
      'DATAACCESS',
      'ACCESSCTRL',
      'DBADM',
      'SECADM',
    ],
    GrantTarget.system => const [],
  };

  @override
  bool grantOption(GrantTarget t) => t != GrantTarget.database;

  @override
  String grantee(PrincipalDef p) =>
      '${switch (p.kind) {
        PrincipalKind.role => 'ROLE',
        PrincipalKind.group => 'GROUP',
        _ => 'USER',
      }} ${q(p.name)}';

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) =>
      p.kind == PrincipalKind.role ? ['CREATE ROLE ${q(p.name)}'] : unsupportedKind(p);

  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) => [
    if (from.dbName != to.name) note('Ridenominazione di ${from.dbName} in Db2'),
  ];

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) =>
      p.kind == PrincipalKind.role ? ['DROP ROLE ${q(p.dbName)}'] : unsupportedKind(p);

  @override
  String? onClause(GrantDef g) {
    String ref() => dialect.qualified(null, g.schema, g.object!);
    return switch (g.target) {
      GrantTarget.table || GrantTarget.view => 'TABLE ${ref()}',
      GrantTarget.sequence => 'SEQUENCE ${ref()}',
      GrantTarget.routine => '${g.isFunction ? 'FUNCTION' : 'PROCEDURE'} ${ref()}',
      GrantTarget.schema => 'SCHEMA ${q(g.schema!)}',
      GrantTarget.database => 'DATABASE',
      GrantTarget.system => throw UnsupportedError('system'),
    };
  }

  @override
  List<String> revoke(PrincipalDef p, List<String> privileges, GrantDef on, {bool cascade = false}) => [
    for (final s in super.revoke(p, privileges, on))
      on.target == GrantTarget.routine && !s.startsWith('--') ? '$s RESTRICT' : s,
  ];

  @override
  List<String> revokeGrantOption(PrincipalDef p, List<String> privileges, GrantDef on) => [
    ...revoke(p, privileges, on),
    ...grant(p, privileges, on),
  ];

  @override
  String roleRef(RoleMembership m) => 'ROLE ${q(m.role)}';

  @override
  List<String> revokeAdmin(RoleMembership m, PrincipalDef member) => [
    'REVOKE ADMIN OPTION FOR ${roleRef(m)} FROM ${grantee(member)}',
  ];
}
