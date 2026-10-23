// Oracle: a user is also a schema; system privileges (CREATE SESSION…) and
// object privileges.

import '../../model/security_defs.dart';
import 'security_ddl.dart';

class OracleSecurityDdl extends SecurityDdl {
  OracleSecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.user, PrincipalKind.role];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => k == PrincipalKind.role
      ? const {}
      : const {
          PrincipalAttr.password,
          PrincipalAttr.locked,
          PrincipalAttr.passwordExpired,
          PrincipalAttr.defaultTablespace,
          PrincipalAttr.temporaryTablespace,
          PrincipalAttr.profile,
        };

  @override
  bool requiresPassword(PrincipalDef p) => p.kind == PrincipalKind.user;

  @override
  String? checkPassword(String password) =>
      password.contains('"') ? 'Una password Oracle non può contenere le virgolette doppie' : null;

  /// IDENTIFIED BY takes the password as a quoted identifier.
  @override
  String passwordLiteral(String password) => '"$password"';

  @override
  String password(String? password) => password == null ? '"••••••"' : super.password(password);

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => const [
    GrantTarget.table,
    GrantTarget.view,
    GrantTarget.sequence,
    GrantTarget.routine,
  ];

  @override
  List<String> privileges(GrantTarget t) => switch (t) {
    GrantTarget.table => const [
      'SELECT',
      'INSERT',
      'UPDATE',
      'DELETE',
      'ALTER',
      'INDEX',
      'REFERENCES',
      'READ',
      'DEBUG',
    ],
    GrantTarget.view => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'REFERENCES', 'READ', 'DEBUG'],
    GrantTarget.sequence => const ['SELECT', 'ALTER'],
    GrantTarget.routine => const ['EXECUTE', 'DEBUG'],
    _ => const [],
  };

  @override
  List<String> systemPrivileges(PrincipalKind k) => const [
    'CREATE SESSION',
    'ALTER SESSION',
    'CREATE TABLE',
    'CREATE VIEW',
    'CREATE MATERIALIZED VIEW',
    'CREATE SEQUENCE',
    'CREATE PROCEDURE',
    'CREATE TRIGGER',
    'CREATE TYPE',
    'CREATE SYNONYM',
    'UNLIMITED TABLESPACE',
    'SELECT ANY TABLE',
    'INSERT ANY TABLE',
    'UPDATE ANY TABLE',
    'DELETE ANY TABLE',
    'CREATE ANY TABLE',
    'ALTER ANY TABLE',
    'DROP ANY TABLE',
    'EXECUTE ANY PROCEDURE',
    'SELECT ANY DICTIONARY',
    'CREATE USER',
    'ALTER USER',
    'DROP USER',
    'CREATE ROLE',
    'GRANT ANY ROLE',
    'GRANT ANY PRIVILEGE',
    'ALTER SYSTEM',
  ];

  List<String> _clauses(PrincipalDef p, PrincipalDef? from, String? password) {
    bool changed(String? a, String? b) => (a ?? '') != (b ?? '') && has(a);
    return [
      if (from == null || password != null) 'IDENTIFIED BY ${this.password(password)}',
      if (changed(p.defaultTablespace, from?.defaultTablespace)) 'DEFAULT TABLESPACE ${q(p.defaultTablespace!)}',
      if (changed(p.temporaryTablespace, from?.temporaryTablespace))
        'TEMPORARY TABLESPACE ${q(p.temporaryTablespace!)}',
      if (changed(p.profile, from?.profile)) 'PROFILE ${q(p.profile!)}',
      if (p.passwordExpired && !(from?.passwordExpired ?? false)) 'PASSWORD EXPIRE',
      if (p.locked != (from?.locked ?? false)) 'ACCOUNT ${p.locked ? 'LOCK' : 'UNLOCK'}',
    ];
  }

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) {
    if (p.kind == PrincipalKind.role) return ['CREATE ROLE ${q(p.name)}'];
    return ['CREATE USER ${q(p.name)} ${_clauses(p, null, password).join(' ')}'];
  }

  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) {
    final out = <String>[if (from.dbName != to.name) note('Ridenominazione di ${from.dbName} in Oracle')];
    if (to.kind == PrincipalKind.role) return out;
    final c = _clauses(to, from, password);
    if (!to.passwordExpired && from.passwordExpired && password == null) {
      out.add('-- La scadenza della password si azzera impostando una nuova password');
    }
    if (c.isNotEmpty) out.add('ALTER USER ${q(from.dbName)} ${c.join(' ')}');
    return out;
  }

  @override
  bool canDropCascade(PrincipalDef p) => p.kind == PrincipalKind.user;

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => [
    p.kind == PrincipalKind.role ? 'DROP ROLE ${q(p.dbName)}' : 'DROP USER ${q(p.dbName)}${cascade ? ' CASCADE' : ''}',
  ];

  @override
  String? onClause(GrantDef g) => switch (g.target) {
    GrantTarget.table ||
    GrantTarget.view ||
    GrantTarget.sequence ||
    GrantTarget.routine => dialect.qualified(null, g.schema, g.object!),
    GrantTarget.system => null,
    _ => throw UnsupportedError('target'),
  };

  @override
  String optionClause(GrantDef g) => g.target == GrantTarget.system ? 'WITH ADMIN OPTION' : 'WITH GRANT OPTION';

  /// Oracle has no REVOKE GRANT OPTION: revoke and grant again.
  @override
  List<String> revokeGrantOption(PrincipalDef p, List<String> privileges, GrantDef on) => [
    ...revoke(p, privileges, on),
    ...grant(p, privileges, on),
  ];
}
