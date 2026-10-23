// Firebird 3+: users in the security database (SEC$USERS), roles and
// privileges in the database.

import '../../model/security_defs.dart';
import 'security_ddl.dart';

class FirebirdSecurityDdl extends SecurityDdl {
  FirebirdSecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.user, PrincipalKind.role];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => k == PrincipalKind.role
      ? const {PrincipalAttr.comment}
      : const {PrincipalAttr.password, PrincipalAttr.locked, PrincipalAttr.comment};

  @override
  bool requiresPassword(PrincipalDef p) => p.kind == PrincipalKind.user;

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => const [
    GrantTarget.table,
    GrantTarget.view,
    GrantTarget.sequence,
    GrantTarget.routine,
  ];

  @override
  List<String> privileges(GrantTarget t) => switch (t) {
    GrantTarget.table => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'REFERENCES'],
    GrantTarget.view => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    GrantTarget.sequence => const ['USAGE'],
    GrantTarget.routine => const ['EXECUTE'],
    _ => const [],
  };

  @override
  String grantee(PrincipalDef p) => '${p.kind == PrincipalKind.role ? 'ROLE' : 'USER'} ${q(p.name)}';

  String _comment(PrincipalDef p, String? text) =>
      'COMMENT ON ${p.kind == PrincipalKind.role ? 'ROLE' : 'USER'} ${q(p.name)} IS ${has(text) ? lit(text!) : 'NULL'}';

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) {
    if (!canCreate(p.kind)) return unsupportedKind(p);
    return [
      p.kind == PrincipalKind.role
          ? 'CREATE ROLE ${q(p.name)}'
          : 'CREATE USER ${q(p.name)} PASSWORD ${this.password(password)}${p.locked ? ' INACTIVE' : ''}',
      if (has(p.comment)) _comment(p, p.comment),
    ];
  }

  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) {
    final out = <String>[if (from.dbName != to.name) note('Ridenominazione di ${from.dbName} in Firebird')];
    if (to.kind == PrincipalKind.user) {
      final parts = [
        if (password != null) 'PASSWORD ${this.password(password)}',
        if (from.locked != to.locked) to.locked ? 'INACTIVE' : 'ACTIVE',
      ];
      if (parts.isNotEmpty) out.add('ALTER USER ${q(from.dbName)} ${parts.join(' ')}');
    }
    if ((from.comment ?? '') != (to.comment ?? '')) out.add(_comment(from, to.comment));
    return out;
  }

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => [
    '${p.kind == PrincipalKind.role ? 'DROP ROLE' : 'DROP USER'} ${q(p.dbName)}',
  ];

  @override
  String? onClause(GrantDef g) => switch (g.target) {
    GrantTarget.table || GrantTarget.view => 'TABLE ${q(g.object!)}',
    GrantTarget.sequence => 'SEQUENCE ${q(g.object!)}',
    GrantTarget.routine => '${g.isFunction ? 'FUNCTION' : 'PROCEDURE'} ${q(g.object!)}',
    _ => throw UnsupportedError('target'),
  };

  @override
  List<String> revokeAdmin(RoleMembership m, PrincipalDef member) => [
    'REVOKE ADMIN OPTION FOR ${roleRef(m)} FROM ${grantee(member)}',
  ];
}
