// PostgreSQL: users and roles are both roles (users have LOGIN).

import '../../model/security_defs.dart';
import 'security_ddl.dart';

class PostgresSecurityDdl extends SecurityDdl {
  PostgresSecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.user, PrincipalKind.role];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => {
    if (k == PrincipalKind.user) ...[
      PrincipalAttr.password,
      PrincipalAttr.connectionLimit,
      PrincipalAttr.validUntil,
      PrincipalAttr.replication,
    ],
    PrincipalAttr.superuser,
    PrincipalAttr.createDb,
    PrincipalAttr.createRole,
    PrincipalAttr.inherit,
    PrincipalAttr.comment,
    PrincipalAttr.rename,
  };

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => const [
    GrantTarget.table,
    GrantTarget.view,
    GrantTarget.sequence,
    GrantTarget.routine,
    GrantTarget.schema,
    GrantTarget.database,
  ];

  @override
  List<String> privileges(GrantTarget t) => switch (t) {
    GrantTarget.table => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'],
    GrantTarget.view => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRIGGER'],
    GrantTarget.sequence => const ['USAGE', 'SELECT', 'UPDATE'],
    GrantTarget.routine => const ['EXECUTE'],
    GrantTarget.schema => const ['USAGE', 'CREATE'],
    GrantTarget.database => const ['CONNECT', 'CREATE', 'TEMPORARY'],
    GrantTarget.system => const [],
  };

  @override
  bool get revokeCascade => true;

  /// Role options of [p]: those that differ from the defaults ([from] null)
  /// or from [from].
  List<String> _options(PrincipalDef p, PrincipalDef? from, {String? password}) {
    final o = <String>[];
    void flag(bool now, bool? before, bool byDefault, String on, String off) {
      if (now != (before ?? byDefault)) o.add(now ? on : off);
    }

    final login = p.kind == PrincipalKind.user;
    flag(login, from == null ? null : from.kind == PrincipalKind.user, false, 'LOGIN', 'NOLOGIN');
    flag(p.superuser, from?.superuser, false, 'SUPERUSER', 'NOSUPERUSER');
    flag(p.createDb, from?.createDb, false, 'CREATEDB', 'NOCREATEDB');
    flag(p.createRole, from?.createRole, false, 'CREATEROLE', 'NOCREATEROLE');
    flag(p.inherit, from?.inherit, true, 'INHERIT', 'NOINHERIT');
    flag(p.replication, from?.replication, false, 'REPLICATION', 'NOREPLICATION');
    final limit = p.connectionLimit ?? -1;
    if (limit != (from?.connectionLimit ?? -1)) o.add('CONNECTION LIMIT $limit');
    if (password != null) o.add('PASSWORD ${this.password(password)}');
    if ((p.validUntil ?? '') != (from?.validUntil ?? '')) {
      o.add("VALID UNTIL ${has(p.validUntil) ? lit(p.validUntil!) : "'infinity'"}");
    }
    return o;
  }

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) {
    if (!canCreate(p.kind)) return unsupportedKind(p);
    final o = _options(p, null, password: password);
    return [
      'CREATE ROLE ${q(p.name)}${o.isEmpty ? '' : ' WITH ${o.join(' ')}'}',
      if (has(p.comment)) 'COMMENT ON ROLE ${q(p.name)} IS ${lit(p.comment!)}',
    ];
  }

  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) {
    final out = <String>[];
    if (from.dbName != to.name) {
      out.add('ALTER ROLE ${q(from.dbName)} RENAME TO ${q(to.name)}');
      if (password == null && to.kind == PrincipalKind.user) {
        out.add('-- Rinominando un ruolo PostgreSQL perde la password MD5: impostane una nuova');
      }
    }
    final o = _options(to, from, password: password);
    if (o.isNotEmpty) out.add('ALTER ROLE ${q(to.name)} WITH ${o.join(' ')}');
    if ((from.comment ?? '') != (to.comment ?? '')) {
      out.add('COMMENT ON ROLE ${q(to.name)} IS ${has(to.comment) ? lit(to.comment!) : 'NULL'}');
    }
    return out;
  }

  @override
  bool canDropCascade(PrincipalDef p) => true;

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => [
    if (cascade) ...['REASSIGN OWNED BY ${q(p.dbName)} TO CURRENT_USER', 'DROP OWNED BY ${q(p.dbName)}'],
    'DROP ROLE ${q(p.dbName)}',
  ];

  @override
  String? onClause(GrantDef g) {
    final ref = g.object == null ? '' : dialect.qualified(null, g.schema, g.object!);
    return switch (g.target) {
      GrantTarget.table || GrantTarget.view => 'TABLE $ref',
      GrantTarget.sequence => 'SEQUENCE $ref',
      GrantTarget.routine => '${g.isFunction ? 'FUNCTION' : 'PROCEDURE'} $ref',
      GrantTarget.schema => 'SCHEMA ${q(g.schema!)}',
      GrantTarget.database => 'DATABASE ${q(g.catalog!)}',
      GrantTarget.system => throw UnsupportedError('system'),
    };
  }

  @override
  List<String> revokeAdmin(RoleMembership m, PrincipalDef member) => [
    'REVOKE ADMIN OPTION FOR ${roleRef(m)} FROM ${grantee(member)}',
  ];
}
