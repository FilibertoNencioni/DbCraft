// Snowflake: privileges go to roles, roles to users and to other roles.

import '../../model/security_defs.dart';
import 'security_ddl.dart';

class SnowflakeSecurityDdl extends SecurityDdl {
  SnowflakeSecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  bool get catalogInGrants => true;

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.user, PrincipalKind.role];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => k == PrincipalKind.role
      ? const {PrincipalAttr.comment, PrincipalAttr.rename}
      : const {
          PrincipalAttr.password,
          PrincipalAttr.locked,
          PrincipalAttr.defaultRole,
          PrincipalAttr.defaultWarehouse,
          PrincipalAttr.mustChangePassword,
          PrincipalAttr.comment,
          PrincipalAttr.rename,
        };

  @override
  bool get adminOption => false;

  @override
  bool get revokeCascade => true;

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => k == PrincipalKind.user
      ? const []
      : const [
          GrantTarget.database,
          GrantTarget.schema,
          GrantTarget.table,
          GrantTarget.view,
          GrantTarget.sequence,
          GrantTarget.routine,
        ];

  @override
  List<String> privileges(GrantTarget t) => switch (t) {
    GrantTarget.table => const ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES'],
    GrantTarget.view => const ['SELECT', 'REFERENCES'],
    GrantTarget.sequence => const ['USAGE'],
    GrantTarget.routine => const ['USAGE'],
    GrantTarget.schema => const [
      'USAGE',
      'MODIFY',
      'MONITOR',
      'CREATE TABLE',
      'CREATE VIEW',
      'CREATE SEQUENCE',
      'CREATE FUNCTION',
      'CREATE PROCEDURE',
      'CREATE STAGE',
    ],
    GrantTarget.database => const ['USAGE', 'MODIFY', 'MONITOR', 'CREATE SCHEMA'],
    GrantTarget.system => const [],
  };

  @override
  List<String> systemPrivileges(PrincipalKind k) => k == PrincipalKind.user
      ? const []
      : const [
          'CREATE DATABASE',
          'CREATE ROLE',
          'CREATE USER',
          'CREATE WAREHOUSE',
          'CREATE INTEGRATION',
          'MANAGE GRANTS',
          'MONITOR USAGE',
          'MONITOR EXECUTION',
          'EXECUTE TASK',
          'IMPORT SHARE',
        ];

  @override
  bool grantsTo(PrincipalDef p) => super.grantsTo(p) && p.kind == PrincipalKind.role;

  @override
  String grantee(PrincipalDef p) => '${p.kind == PrincipalKind.role ? 'ROLE' : 'USER'} ${q(p.name)}';

  String _kw(PrincipalDef p) => p.kind == PrincipalKind.role ? 'ROLE' : 'USER';

  List<String> _settings(PrincipalDef p, PrincipalDef? from, String? password) {
    bool changed(Object? a, Object? b) => from != null && (a ?? '') != (b ?? '');
    final set = <String>[];
    void text(String key, String? now, String? before, String Function(String) render) {
      if (from == null ? has(now) : changed(now, before) && has(now)) set.add('$key = ${render(now!)}');
    }

    if (p.kind == PrincipalKind.user) {
      if (password != null) set.add('PASSWORD = ${this.password(password)}');
      text('DEFAULT_ROLE', p.defaultRole, from?.defaultRole, q);
      text('DEFAULT_WAREHOUSE', p.defaultWarehouse, from?.defaultWarehouse, q);
      if (from == null ? p.mustChangePassword : p.mustChangePassword != from.mustChangePassword) {
        set.add('MUST_CHANGE_PASSWORD = ${p.mustChangePassword ? 'TRUE' : 'FALSE'}');
      }
      if (from == null ? p.locked : p.locked != from.locked) set.add('DISABLED = ${p.locked ? 'TRUE' : 'FALSE'}');
    }
    text('COMMENT', p.comment, from?.comment, lit);
    return set;
  }

  List<String> _unset(PrincipalDef p, PrincipalDef from) => [
    if (p.kind == PrincipalKind.user) ...[
      if (has(from.defaultRole) && !has(p.defaultRole)) 'DEFAULT_ROLE',
      if (has(from.defaultWarehouse) && !has(p.defaultWarehouse)) 'DEFAULT_WAREHOUSE',
    ],
    if (has(from.comment) && !has(p.comment)) 'COMMENT',
  ];

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) {
    final set = _settings(p, null, password);
    return ['CREATE ${_kw(p)} ${q(p.name)}${set.isEmpty ? '' : ' ${set.join(' ')}'}'];
  }

  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) {
    final name = q(to.name);
    final set = _settings(to, from, password);
    final unset = _unset(to, from);
    return [
      if (from.dbName != to.name) 'ALTER ${_kw(to)} ${q(from.dbName)} RENAME TO $name',
      if (set.isNotEmpty) 'ALTER ${_kw(to)} $name SET ${set.join(' ')}',
      if (unset.isNotEmpty) 'ALTER ${_kw(to)} $name UNSET ${unset.join(', ')}',
    ];
  }

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => ['DROP ${_kw(p)} ${q(p.dbName)}'];

  @override
  String? onClause(GrantDef g) {
    String ref() => dialect.qualified(g.catalog, g.schema, g.object!);
    return switch (g.target) {
      GrantTarget.table => 'TABLE ${ref()}',
      GrantTarget.view => 'VIEW ${ref()}',
      GrantTarget.sequence => 'SEQUENCE ${ref()}',
      GrantTarget.routine => '${g.isFunction ? 'FUNCTION' : 'PROCEDURE'} ${ref()}',
      GrantTarget.schema => 'SCHEMA ${dialect.qualified(null, g.catalog, g.schema!)}',
      GrantTarget.database => 'DATABASE ${q(g.catalog!)}',
      GrantTarget.system => 'ACCOUNT',
    };
  }

  @override
  String roleRef(RoleMembership m) => 'ROLE ${q(m.role)}';
}
