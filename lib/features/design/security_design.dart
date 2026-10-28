// Edit session of one user, role or login in the security manager: the
// principal as read (original) and as edited (working), with its roles and
// privileges. Statements come from the difference (SecurityDdl).

import 'package:flutter/foundation.dart';

import '../../services/sql_dialect.dart';
import '../schema/ddl_builder.dart';
import '../../state/db_connection.dart';
import 'catalog/security.dart';
import 'ddl/security/security_ddl.dart';
import 'ddl_script.dart';
import 'model/security_defs.dart';

class PrincipalDesign extends ChangeNotifier {
  PrincipalDesign.existing(this.dialect, PrincipalDef p, PrincipalAccess access, {this.catalog})
    : original = p,
      working = p,
      originalGrants = access.grants,
      grants = List.of(access.grants),
      originalRoles = access.memberOf,
      roles = List.of(access.memberOf);

  /// A new principal of kind [kind] with the usual starting privileges
  /// (Oracle users need CREATE SESSION to connect).
  PrincipalDesign.create(this.dialect, PrincipalKind kind, {this.catalog, String name = ''})
    : original = null,
      working = PrincipalDef(
        name: name,
        kind: kind,
        host: switch (dialect.family) {
          DbFamily.mysql when kind == PrincipalKind.user || !dialect.isMariaDb => '%',
          DbFamily.mongodb => 'admin',
          _ => null,
        },
        auth: kind == PrincipalKind.user && dialect.family == DbFamily.sqlServer
            ? PrincipalAuth.login
            : PrincipalAuth.password,
      ),
      originalGrants = const [],
      grants = [
        if (dialect.family == DbFamily.oracle && kind == PrincipalKind.user)
          const GrantDef(privilege: 'CREATE SESSION', target: GrantTarget.system),
      ],
      originalRoles = const [],
      roles = [];

  final SqlDialect dialect;

  /// SQL Server database of users and roles.
  final String? catalog;
  final PrincipalDef? original;
  PrincipalDef working;

  /// New password (null: unchanged). Never stored elsewhere.
  String? password;
  final List<GrantDef> originalGrants;
  List<GrantDef> grants;
  final List<RoleMembership> originalRoles;
  List<RoleMembership> roles;

  /// Statements appended to a non-empty script (Redis ACL SAVE when the
  /// server keeps the users in an ACL file).
  List<String> trailing = const [];

  SecurityDdl get ddl => SecurityDdl.forFamily(dialect);

  bool get isNew => original == null;
  bool get readOnly => original?.builtIn ?? false;

  bool get isDirty => isNew || statements.isNotEmpty;

  void update(PrincipalDef p) {
    working = p;
    notifyListeners();
  }

  void setPassword(String? value) {
    password = value == null || value.isEmpty ? null : value;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Privileges
  // -------------------------------------------------------------------------

  /// The grant of [privilege] on the object of [on] (null when not held).
  GrantDef? grantOf(GrantDef on, String privilege) {
    final key = _with(on, privilege).key;
    for (final g in grants) {
      if (g.key == key) return g;
    }
    return null;
  }

  GrantDef _with(GrantDef on, String privilege, {bool option = false}) => GrantDef(
    privilege: privilege,
    target: on.target,
    catalog: on.catalog,
    schema: on.schema,
    object: on.object,
    isFunction: on.isFunction,
    withGrantOption: option,
  );

  /// Grants or revokes [privilege] on the object of [on].
  void setGrant(GrantDef on, String privilege, bool granted) => setGrants([on], [privilege], granted);

  /// Grants or revokes [privileges] on every object of [objects].
  void setGrants(List<GrantDef> objects, List<String> privileges, bool granted) {
    final next = List.of(grants);
    for (final on in objects) {
      for (final p in privileges) {
        final key = _with(on, p).key;
        final i = next.indexWhere((g) => g.key == key);
        if (granted && i < 0) {
          next.add(_with(on, p, option: _optionOn(on)));
        } else if (!granted && i >= 0) {
          next.removeAt(i);
        }
      }
    }
    grants = next;
    notifyListeners();
  }

  bool _optionOn(GrantDef on) => grants.any((g) => g.objectKey == on.objectKey && g.withGrantOption);

  /// Whether the privileges on the object of [on] carry the grant option
  /// (null: some do).
  bool? grantOptionOf(GrantDef on) {
    final held = [
      for (final g in grants)
        if (g.objectKey == on.objectKey) g,
    ];
    if (held.isEmpty) return false;
    if (held.every((g) => g.withGrantOption)) return true;
    if (held.every((g) => !g.withGrantOption)) return false;
    return null;
  }

  /// Sets the grant option of every privilege held on the object of [on]
  /// (or only of [privilege]).
  void setGrantOption(GrantDef on, bool value, {String? privilege}) {
    grants = [
      for (final g in grants)
        g.objectKey == on.objectKey && (privilege == null || g.privilege == privilege)
            ? g.copyWith(withGrantOption: value)
            : g,
    ];
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Roles
  // -------------------------------------------------------------------------

  RoleMembership membership(String role, {String? roleHost, bool serverRole = false}) =>
      RoleMembership(role, working.dbName, roleHost: roleHost, memberHost: working.host, serverRole: serverRole);

  RoleMembership? roleOf(String role, {String? roleHost, bool serverRole = false}) {
    final key = membership(role, roleHost: roleHost, serverRole: serverRole).key;
    for (final m in roles) {
      if (_rekey(m).key == key) return m;
    }
    return null;
  }

  /// Memberships read before a rename still name the old member.
  RoleMembership _rekey(RoleMembership m) => RoleMembership(
    m.role,
    working.dbName,
    roleHost: m.roleHost,
    memberHost: working.host,
    withAdmin: m.withAdmin,
    serverRole: m.serverRole,
  );

  void setRole(String role, bool member, {String? roleHost, bool serverRole = false}) {
    final existing = roleOf(role, roleHost: roleHost, serverRole: serverRole);
    if (member && existing == null) {
      roles = [...roles, membership(role, roleHost: roleHost, serverRole: serverRole)];
    } else if (!member && existing != null) {
      roles = [
        for (final m in roles)
          if (!identical(m, existing)) m,
      ];
    }
    notifyListeners();
  }

  void setAdmin(String role, bool admin, {String? roleHost}) {
    roles = [for (final m in roles) identical(m, roleOf(role, roleHost: roleHost)) ? m.copyWith(withAdmin: admin) : m];
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Script
  // -------------------------------------------------------------------------

  List<String> _build(SecurityDdl d) => d.savePrincipal(
    original: original,
    working: working,
    password: password,
    grantsFrom: originalGrants,
    grantsTo: grants,
    rolesFrom: [for (final m in originalRoles) _rekey(m)],
    rolesTo: [for (final m in roles) _rekey(m)],
  );

  /// Statements of the pending changes (passwords as tokens of a throwaway
  /// bag: use [script] to run them).
  List<String> get statements => _build(ddl);

  /// The script to run, with the password among its secrets.
  DdlScript script() {
    final bag = SecretBag();
    final d = SecurityDdl.forFamily(dialect, secrets: bag);
    final statements = _build(d);
    return DdlScript(
      [...statements, if (executableStatements(statements).isNotEmpty) ...trailing],
      secrets: bag.values,
      scope: SchemaScope.security(catalog),
      catalog: working.kind == PrincipalKind.login ? null : (dialect.family == DbFamily.sqlServer ? catalog : null),
    );
  }

  /// DDL of the principal as edited (password masked).
  List<String> get ddlScript => ddl.principalScript(working, grants: grants, roles: [for (final m in roles) _rekey(m)]);

  /// Problems that block saving.
  List<String> get errors {
    final out = <String>[];
    if (working.name.trim().isEmpty) out.add('Il nome è obbligatorio');
    if (isNew && !ddl.canCreate(working.kind)) out.add(ddl.createReason(working.kind) ?? 'Non supportato');
    if (isNew && password == null && ddl.requiresPassword(working)) out.add('La password è obbligatoria');
    if (password != null) {
      final why = ddl.checkPassword(password!);
      if (why != null) out.add(why);
    }
    return out;
  }
}
