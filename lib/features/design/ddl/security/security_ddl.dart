// DDL of users, roles, logins, role memberships and privileges. The DBMS
// differ too much for one switch: one subclass per family (files in this
// folder). Same conventions as DdlBuilder: statements without terminators,
// comment-only entries for notes and for what the DBMS cannot do.
//
// Passwords never appear in the statements: they go into [secrets] and the
// statements carry the token (see DdlScript).

import '../../../../services/sql_dialect.dart';
import '../../capabilities.dart';
import '../../ddl_script.dart';
import '../../model/security_defs.dart';
import 'db2.dart';
import 'firebird.dart';
import 'mssql.dart';
import 'mysql.dart';
import 'oracle.dart';
import 'pg.dart';
import 'snowflake.dart';

abstract class SecurityDdl {
  SecurityDdl.base(this.dialect, SecretBag? secrets)
    : caps = DesignCapabilities.of(dialect),
      secrets = secrets ?? SecretBag();

  factory SecurityDdl.forFamily(SqlDialect dialect, {SecretBag? secrets}) => switch (dialect.family) {
    DbFamily.postgres => PostgresSecurityDdl(dialect, secrets),
    DbFamily.sqlServer => SqlServerSecurityDdl(dialect, secrets),
    DbFamily.mysql => MySqlSecurityDdl(dialect, secrets),
    DbFamily.oracle => OracleSecurityDdl(dialect, secrets),
    DbFamily.db2 => Db2SecurityDdl(dialect, secrets),
    DbFamily.firebird => FirebirdSecurityDdl(dialect, secrets),
    DbFamily.snowflake => SnowflakeSecurityDdl(dialect, secrets),
    _ => _UnsupportedSecurityDdl(dialect, secrets),
  };

  final SqlDialect dialect;
  final DesignCapabilities caps;

  /// Passwords of the statements built so far.
  final SecretBag secrets;

  String q(String name) => dialect.quoteIdent(name);
  String lit(String s) => dialect.stringLiteral(s);
  bool has(String? s) => s != null && s.trim().isNotEmpty;
  String note(String text) => '-- $text (non supportato)';

  // -------------------------------------------------------------------------
  // What the DBMS offers (the editor shows only this)
  // -------------------------------------------------------------------------

  /// Kinds of principal listed by the security manager.
  List<PrincipalKind> get kinds;

  /// Whether principals of kind [k] can be created and dropped.
  bool canCreate(PrincipalKind k) => switch (k) {
    PrincipalKind.role => caps.has(DesignFeature.roles),
    PrincipalKind.group => false,
    _ => caps.has(DesignFeature.users),
  };

  /// Why principals of kind [k] cannot be created (null when they can).
  String? createReason(PrincipalKind k) => canCreate(k)
      ? null
      : k == PrincipalKind.group
      ? 'I gruppi sono quelli del sistema operativo'
      : caps.reason(k == PrincipalKind.role ? DesignFeature.roles : DesignFeature.users);

  /// Editable attributes of a principal of kind [k].
  Set<PrincipalAttr> attributes(PrincipalKind k);

  /// Ways a principal of kind [k] authenticates (SQL Server only).
  List<PrincipalAuth> authOptions(PrincipalKind k) => const [];

  /// A new principal of kind [k] cannot be created without a password.
  bool requiresPassword(PrincipalDef p) => false;

  /// Problem with [password] (null when acceptable).
  String? checkPassword(String password) => null;

  /// Object types whose privileges a principal of kind [k] can receive.
  List<GrantTarget> objectTargets(PrincipalKind k);

  /// Privileges of objects of type [t].
  List<String> privileges(GrantTarget t);

  /// Privileges not tied to an object a principal of kind [k] can receive.
  List<String> systemPrivileges(PrincipalKind k) => const [];

  /// Server roles (SQL Server) a login can belong to.
  List<String> get serverRoles => const [];

  /// Grants on objects name their database (MySQL, Snowflake); elsewhere
  /// the catalog of a GrantDef is left null (SQL Server scripts run in it).
  bool get catalogInGrants => false;

  /// Members can receive the right to grant a role (WITH ADMIN OPTION).
  bool get adminOption => true;

  /// Privileges can be granted with the right to grant them.
  bool grantOption(GrantTarget t) => true;

  /// Principals of kind [k] can belong to roles.
  bool hasRoles(PrincipalKind k) => caps.has(DesignFeature.roles);

  /// Name used for [p] in GRANT, REVOKE and ALTER statements.
  String grantee(PrincipalDef p) => q(p.name);

  /// SQL fragment of a password (already quoted).
  String passwordLiteral(String password) => lit(password);

  /// Token of [password] (or the mask, to show a statement without it).
  String password(String? password) => password == null ? DdlScript.mask : secrets.add(passwordLiteral(password));

  // -------------------------------------------------------------------------
  // Principals
  // -------------------------------------------------------------------------

  List<String> createPrincipal(PrincipalDef p, {String? password});

  /// Statements that turn [from] into [to]; [password] is a new password.
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password});

  /// DROP of [p]; [cascade] also drops the objects it owns where the DBMS
  /// can (Oracle DROP USER … CASCADE, PostgreSQL DROP OWNED).
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false});

  /// Whether [dropPrincipal] can drop the objects owned by [p].
  bool canDropCascade(PrincipalDef p) => false;

  List<String> unsupportedKind(PrincipalDef p) => [note('${p.kind.label} ${p.display}: ${createReason(p.kind)}')];

  // -------------------------------------------------------------------------
  // Privileges
  // -------------------------------------------------------------------------

  /// The object of [g] after ON (null: no ON clause); throws
  /// [UnsupportedError] when the DBMS has no such privileges.
  String? onClause(GrantDef g);

  String optionClause(GrantDef g) => 'WITH GRANT OPTION';

  /// REVOKE … CASCADE revokes what the grantee granted in turn.
  bool get revokeCascade => false;

  bool grantsTo(PrincipalDef p) => caps.has(DesignFeature.grants);

  String? _on(GrantDef g) => onClause(g);

  String _onPart(GrantDef g) {
    final on = _on(g);
    return on == null ? '' : ' ON $on';
  }

  List<String> grant(PrincipalDef p, List<String> privileges, GrantDef on, {bool withGrantOption = false}) {
    final why = _cannotGrant(p, on);
    if (why != null) return [why];
    final opt = withGrantOption && grantOption(on.target) ? ' ${optionClause(on)}' : '';
    return ['GRANT ${privileges.join(', ')}${_onPart(on)} TO ${grantee(p)}$opt'];
  }

  List<String> revoke(PrincipalDef p, List<String> privileges, GrantDef on, {bool cascade = false}) {
    final why = _cannotGrant(p, on);
    if (why != null) return [why];
    return [
      'REVOKE ${privileges.join(', ')}${_onPart(on)} FROM ${grantee(p)}${cascade && revokeCascade ? ' CASCADE' : ''}',
    ];
  }

  /// Takes the grant option away and keeps the privileges.
  List<String> revokeGrantOption(PrincipalDef p, List<String> privileges, GrantDef on) {
    final why = _cannotGrant(p, on);
    if (why != null) return [why];
    return [
      'REVOKE GRANT OPTION FOR ${privileges.join(', ')}${_onPart(on)} FROM ${grantee(p)}${revokeCascade ? ' CASCADE' : ''}',
    ];
  }

  String? _cannotGrant(PrincipalDef p, GrantDef g) {
    if (!caps.has(DesignFeature.grants)) return note('Permessi di ${p.display}: ${caps.reason(DesignFeature.grants)}');
    if (!grantsTo(p)) return note('Permessi diretti a ${p.kind.label.toLowerCase()} ${p.display}');
    try {
      _on(g);
      return null;
    } on UnsupportedError {
      return note('Permessi su ${g.target.label.toLowerCase()} ${g.objectLabel}');
    }
  }

  /// GRANT and REVOKE that turn the privileges [from] of [p] into [to].
  /// Privileges on the same object go in one statement.
  List<String> grantChanges(PrincipalDef p, List<GrantDef> from, List<GrantDef> to) {
    final before = {for (final g in from) g.key: g};
    final after = {for (final g in to) g.key: g};
    Map<String, List<GrantDef>> group(Iterable<GrantDef> gs, {bool byOption = false}) {
      final out = <String, List<GrantDef>>{};
      for (final g in gs) {
        out.putIfAbsent('${g.objectKey}${byOption ? '|${g.withGrantOption}' : ''}', () => []).add(g);
      }
      return out;
    }

    List<String> privs(List<GrantDef> gs) => [for (final g in gs) g.privilege];
    final out = <String>[];
    for (final gs in group([
      for (final e in before.entries)
        if (!after.containsKey(e.key)) e.value,
    ]).values) {
      out.addAll(revoke(p, privs(gs), gs.first, cascade: gs.any((g) => g.withGrantOption)));
    }
    final optionOff = [
      for (final e in before.entries)
        if (after[e.key] != null && e.value.withGrantOption && !after[e.key]!.withGrantOption) after[e.key]!,
    ];
    for (final gs in group(optionOff).values) {
      out.addAll(revokeGrantOption(p, privs(gs), gs.first));
    }
    final added = [
      for (final e in after.entries)
        if (!before.containsKey(e.key) || (e.value.withGrantOption && !before[e.key]!.withGrantOption)) e.value,
    ];
    for (final gs in group(added, byOption: true).values) {
      out.addAll(grant(p, privs(gs), gs.first, withGrantOption: gs.first.withGrantOption));
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Role memberships
  // -------------------------------------------------------------------------

  /// The role of [m] in GRANT / REVOKE.
  String roleRef(RoleMembership m) => q(m.role);

  List<String> grantRole(RoleMembership m, PrincipalDef member) {
    if (!caps.has(DesignFeature.roles)) return [note('Ruolo ${m.role}: ${caps.reason(DesignFeature.roles)}')];
    return ['GRANT ${roleRef(m)} TO ${grantee(member)}${m.withAdmin && adminOption ? ' WITH ADMIN OPTION' : ''}'];
  }

  List<String> revokeRole(RoleMembership m, PrincipalDef member) {
    if (!caps.has(DesignFeature.roles)) return [note('Ruolo ${m.role}: ${caps.reason(DesignFeature.roles)}')];
    return ['REVOKE ${roleRef(m)} FROM ${grantee(member)}'];
  }

  /// Takes the admin option away and keeps the membership.
  List<String> revokeAdmin(RoleMembership m, PrincipalDef member) => [
    ...revokeRole(m, member),
    ...grantRole(m.copyWith(withAdmin: false), member),
  ];

  /// Statements that turn the roles [from] of [p] into [to].
  List<String> membershipChanges(PrincipalDef p, List<RoleMembership> from, List<RoleMembership> to) {
    final before = {for (final m in from) m.key: m};
    final after = {for (final m in to) m.key: m};
    final out = <String>[];
    for (final e in before.entries) {
      if (!after.containsKey(e.key)) out.addAll(revokeRole(e.value, p));
    }
    for (final e in after.entries) {
      final old = before[e.key];
      if (old == null) {
        out.addAll(grantRole(e.value, p));
      } else if (adminOption && old.withAdmin != e.value.withAdmin) {
        out.addAll(e.value.withAdmin ? grantRole(e.value, p) : revokeAdmin(e.value, p));
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Whole principal
  // -------------------------------------------------------------------------

  /// Script that creates [working] (or turns [original] into it) with its
  /// roles and privileges.
  List<String> savePrincipal({
    PrincipalDef? original,
    required PrincipalDef working,
    String? password,
    List<GrantDef> grantsFrom = const [],
    List<GrantDef> grantsTo = const [],
    List<RoleMembership> rolesFrom = const [],
    List<RoleMembership> rolesTo = const [],
  }) => [
    ...(original == null
        ? createPrincipal(working, password: password)
        : alterPrincipal(original, working, password: password)),
    ...membershipChanges(working, rolesFrom, rolesTo),
    ...grantChanges(working, grantsFrom, grantsTo),
  ];

  /// DDL of an existing principal, its roles and privileges (the password
  /// is not known and shows masked).
  List<String> principalScript(
    PrincipalDef p, {
    List<GrantDef> grants = const [],
    List<RoleMembership> roles = const [],
  }) => [...createPrincipal(p), ...membershipChanges(p, const [], roles), ...grantChanges(p, const [], grants)];
}

/// SQLite and unknown DBMS: no users.
class _UnsupportedSecurityDdl extends SecurityDdl {
  _UnsupportedSecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  List<PrincipalKind> get kinds => const [];
  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => const {};
  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => const [];
  @override
  List<String> privileges(GrantTarget t) => const [];
  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) => unsupportedKind(p);
  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) => unsupportedKind(to);
  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => unsupportedKind(p);
  @override
  String? onClause(GrantDef g) => throw UnsupportedError('grants');
}
