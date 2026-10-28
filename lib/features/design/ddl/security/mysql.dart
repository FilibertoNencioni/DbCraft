// MySQL and MariaDB: accounts are user@host; databases and schemas coincide
// (privileges ON db.*), global privileges ON *.*.

import '../../capabilities.dart';
import '../../model/security_defs.dart';
import 'security_ddl.dart';

class MySqlSecurityDdl extends SecurityDdl {
  MySqlSecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  bool get catalogInGrants => true;

  bool get _maria => dialect.isMariaDb;

  @override
  List<PrincipalKind> get kinds => [PrincipalKind.user, if (caps.has(DesignFeature.roles)) PrincipalKind.role];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => k == PrincipalKind.role
      ? {if (!_maria) PrincipalAttr.rename}
      : const {
          PrincipalAttr.host,
          PrincipalAttr.password,
          PrincipalAttr.locked,
          PrincipalAttr.passwordExpired,
          PrincipalAttr.rename,
        };

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => const [
    GrantTarget.database,
    GrantTarget.table,
    GrantTarget.view,
    GrantTarget.routine,
  ];

  static const _schemaLevel = [
    'SELECT',
    'INSERT',
    'UPDATE',
    'DELETE',
    'CREATE',
    'DROP',
    'ALTER',
    'INDEX',
    'REFERENCES',
    'TRIGGER',
    'CREATE VIEW',
    'SHOW VIEW',
    'CREATE ROUTINE',
    'ALTER ROUTINE',
    'EXECUTE',
    'EVENT',
    'LOCK TABLES',
    'CREATE TEMPORARY TABLES',
  ];

  @override
  List<String> privileges(GrantTarget t) => switch (t) {
    GrantTarget.table => const [
      'SELECT',
      'INSERT',
      'UPDATE',
      'DELETE',
      'CREATE',
      'DROP',
      'ALTER',
      'INDEX',
      'REFERENCES',
      'TRIGGER',
      'SHOW VIEW',
    ],
    GrantTarget.view => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'DROP', 'SHOW VIEW'],
    GrantTarget.routine => const ['EXECUTE', 'ALTER ROUTINE'],
    GrantTarget.database || GrantTarget.schema => _schemaLevel,
    GrantTarget.sequence || GrantTarget.system => const [],
  };

  @override
  List<String> systemPrivileges(PrincipalKind k) => const [
    ..._schemaLevel,
    'CREATE USER',
    'CREATE TABLESPACE',
    'FILE',
    'PROCESS',
    'RELOAD',
    'REPLICATION CLIENT',
    'REPLICATION SLAVE',
    'SHOW DATABASES',
    'SHUTDOWN',
    'SUPER',
  ];

  String _account(String name, String? host) => '${lit(name)}@${lit(host ?? '%')}';

  @override
  String grantee(PrincipalDef p) =>
      p.kind == PrincipalKind.role && (p.host == null || p.host == '%') ? lit(p.name) : _account(p.name, p.host);

  String _current(PrincipalDef p) => grantee(p.copyWith(name: p.dbName));

  @override
  String roleRef(RoleMembership m) =>
      m.roleHost == null || m.roleHost == '%' ? lit(m.role) : _account(m.role, m.roleHost);

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) {
    if (!canCreate(p.kind)) return unsupportedKind(p);
    if (p.kind == PrincipalKind.role) return ['CREATE ROLE ${grantee(p)}'];
    final sb = StringBuffer('CREATE USER ${grantee(p)}');
    if (password != null) sb.write(' IDENTIFIED BY ${this.password(password)}');
    if (p.passwordExpired) sb.write(' PASSWORD EXPIRE');
    if (p.locked) sb.write(' ACCOUNT LOCK');
    return [sb.toString()];
  }

  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) {
    final out = <String>[];
    final old = _current(from);
    if (old != grantee(to)) {
      out.add(
        to.kind == PrincipalKind.role && _maria
            ? note('Ridenominazione del ruolo ${from.dbName} in MariaDB')
            : 'RENAME USER $old TO ${grantee(to)}',
      );
    }
    final acct = grantee(to);
    if (to.kind == PrincipalKind.role) return out;
    if (password != null) out.add('ALTER USER $acct IDENTIFIED BY ${this.password(password)}');
    if (from.locked != to.locked) out.add('ALTER USER $acct ACCOUNT ${to.locked ? 'LOCK' : 'UNLOCK'}');
    if (to.passwordExpired && !from.passwordExpired) out.add('ALTER USER $acct PASSWORD EXPIRE');
    if (!to.passwordExpired && from.passwordExpired && password == null) {
      out.add('-- La scadenza della password si azzera impostando una nuova password');
    }
    return out;
  }

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => [
    '${p.kind == PrincipalKind.role ? 'DROP ROLE' : 'DROP USER'} ${_current(p)}',
  ];

  @override
  String? onClause(GrantDef g) {
    final db = g.catalog ?? g.schema;
    return switch (g.target) {
      GrantTarget.table || GrantTarget.view => '${q(db!)}.${q(g.object!)}',
      GrantTarget.routine => '${g.isFunction ? 'FUNCTION' : 'PROCEDURE'} ${q(db!)}.${q(g.object!)}',
      GrantTarget.database || GrantTarget.schema => '${q(db!)}.*',
      GrantTarget.system => '*.*',
      GrantTarget.sequence => throw UnsupportedError('sequence'),
    };
  }

  @override
  List<String> revokeGrantOption(PrincipalDef p, List<String> privileges, GrantDef on) => [
    '-- MySQL toglie il diritto di concedere tutti i privilegi su ${on.objectLabel}: quelli da mantenere sono riassegnati',
    'REVOKE GRANT OPTION ON ${onClause(on)} FROM ${grantee(p)}',
  ];

  @override
  List<String> membershipChanges(PrincipalDef p, List<RoleMembership> from, List<RoleMembership> to) {
    final out = super.membershipChanges(p, from, to);
    // MySQL activates granted roles only when they are default roles.
    final added = to.any((m) => !from.any((f) => f.key == m.key));
    if (added && !_maria && p.kind == PrincipalKind.user) out.add('SET DEFAULT ROLE ALL TO ${grantee(p)}');
    return out;
  }

  @override
  List<String> grantChanges(PrincipalDef p, List<GrantDef> from, List<GrantDef> to) {
    final out = super.grantChanges(p, from, to);
    // REVOKE GRANT OPTION drops it for every privilege on the object: grant
    // it again to those that keep it.
    final reGrant = <GrantDef>[];
    for (final g in to) {
      if (!g.withGrantOption) continue;
      final lostOn = from.any(
        (f) => f.withGrantOption && to.any((t) => t.key == f.key && !t.withGrantOption) && _sameObject(f, g),
      );
      final already = from.any((f) => f.key == g.key && f.withGrantOption);
      if (lostOn && already) reGrant.add(g);
    }
    if (reGrant.isNotEmpty) {
      final byObject = <String, List<GrantDef>>{};
      for (final g in reGrant) {
        byObject.putIfAbsent(onClause(g)!, () => []).add(g);
      }
      for (final gs in byObject.values) {
        out.addAll(grant(p, [for (final g in gs) g.privilege], gs.first, withGrantOption: true));
      }
    }
    return out;
  }

  bool _sameObject(GrantDef a, GrantDef b) => a.objectKey == b.objectKey;
}
