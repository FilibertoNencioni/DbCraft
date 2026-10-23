// Users, roles, logins, role memberships and privileges, edited by the
// security manager and turned into DDL by SecurityDdl. Passwords never live
// here: the sheets hand them to the script as secrets.

const Object _unset = Object();

enum PrincipalKind {
  /// Can connect (PostgreSQL LOGIN role, MySQL / Oracle / Firebird /
  /// Snowflake user, SQL Server database user).
  user('Utente'),

  /// Groups privileges, cannot connect.
  role('Ruolo'),

  /// SQL Server server login (users of the databases map to it).
  login('Login'),

  /// Db2 operating system group: privileges are granted to it, it is not
  /// created by the database.
  group('Gruppo');

  const PrincipalKind(this.label);
  final String label;
}

/// SQL Server: how a login or database user authenticates.
enum PrincipalAuth {
  /// Password checked by the server (SQL Server login / contained user).
  password('Password'),

  /// Windows account or group (CREATE LOGIN … FROM WINDOWS).
  windows('Windows'),

  /// Database user mapped to a server login.
  login('Login del server'),

  /// Database user without a login (impersonation only).
  none('Senza login');

  const PrincipalAuth(this.label);
  final String label;
}

/// Attributes of a principal a DBMS lets the user edit (see
/// SecurityDdl.attributes): the editor shows only these fields.
enum PrincipalAttr {
  password,
  host,
  auth,
  superuser,
  createDb,
  createRole,
  inherit,
  replication,
  connectionLimit,
  validUntil,
  locked,
  passwordExpired,
  login,
  defaultSchema,
  defaultDatabase,
  defaultTablespace,
  temporaryTablespace,
  profile,
  defaultRole,
  defaultWarehouse,
  mustChangePassword,
  comment,
  rename,
}

class PrincipalDef {
  const PrincipalDef({
    required this.name,
    required this.kind,
    this.host,
    this.auth = PrincipalAuth.password,
    this.superuser = false,
    this.createDb = false,
    this.createRole = false,
    this.inherit = true,
    this.replication = false,
    this.connectionLimit,
    this.validUntil,
    this.locked = false,
    this.passwordExpired = false,
    this.login,
    this.defaultSchema,
    this.defaultDatabase,
    this.defaultTablespace,
    this.temporaryTablespace,
    this.profile,
    this.defaultRole,
    this.defaultWarehouse,
    this.mustChangePassword = false,
    this.comment,
    this.originalName,
    this.builtIn = false,
  });

  final String name;
  final PrincipalKind kind;

  /// MySQL account host ('%' for any).
  final String? host;
  final PrincipalAuth auth;

  // PostgreSQL attributes.
  final bool superuser;
  final bool createDb;
  final bool createRole;
  final bool inherit;
  final bool replication;
  final int? connectionLimit;

  /// PostgreSQL VALID UNTIL (timestamp text).
  final String? validUntil;

  /// Account locked / login disabled.
  final bool locked;

  /// Oracle PASSWORD EXPIRE.
  final bool passwordExpired;

  /// SQL Server: login of a database user.
  final String? login;

  /// SQL Server user DEFAULT_SCHEMA.
  final String? defaultSchema;

  /// SQL Server login DEFAULT_DATABASE.
  final String? defaultDatabase;

  // Oracle.
  final String? defaultTablespace;
  final String? temporaryTablespace;
  final String? profile;

  // Snowflake.
  final String? defaultRole;
  final String? defaultWarehouse;
  final bool mustChangePassword;
  final String? comment;

  /// Name in the database when renamed in the editor.
  final String? originalName;

  /// Created by the DBMS (fixed roles, sys…): not editable.
  final bool builtIn;

  String get dbName => originalName ?? name;

  /// Identity in lists (MySQL accounts are user@host).
  String get key =>
      host == null ? '${kind.name}:${name.toLowerCase()}' : '${kind.name}:${name.toLowerCase()}@${host!.toLowerCase()}';

  String get display => host == null ? name : '$name@$host';

  PrincipalDef copyWith({
    String? name,
    PrincipalKind? kind,
    Object? host = _unset,
    PrincipalAuth? auth,
    bool? superuser,
    bool? createDb,
    bool? createRole,
    bool? inherit,
    bool? replication,
    Object? connectionLimit = _unset,
    Object? validUntil = _unset,
    bool? locked,
    bool? passwordExpired,
    Object? login = _unset,
    Object? defaultSchema = _unset,
    Object? defaultDatabase = _unset,
    Object? defaultTablespace = _unset,
    Object? temporaryTablespace = _unset,
    Object? profile = _unset,
    Object? defaultRole = _unset,
    Object? defaultWarehouse = _unset,
    bool? mustChangePassword,
    Object? comment = _unset,
    Object? originalName = _unset,
  }) => PrincipalDef(
    name: name ?? this.name,
    kind: kind ?? this.kind,
    host: host == _unset ? this.host : host as String?,
    auth: auth ?? this.auth,
    superuser: superuser ?? this.superuser,
    createDb: createDb ?? this.createDb,
    createRole: createRole ?? this.createRole,
    inherit: inherit ?? this.inherit,
    replication: replication ?? this.replication,
    connectionLimit: connectionLimit == _unset ? this.connectionLimit : connectionLimit as int?,
    validUntil: validUntil == _unset ? this.validUntil : validUntil as String?,
    locked: locked ?? this.locked,
    passwordExpired: passwordExpired ?? this.passwordExpired,
    login: login == _unset ? this.login : login as String?,
    defaultSchema: defaultSchema == _unset ? this.defaultSchema : defaultSchema as String?,
    defaultDatabase: defaultDatabase == _unset ? this.defaultDatabase : defaultDatabase as String?,
    defaultTablespace: defaultTablespace == _unset ? this.defaultTablespace : defaultTablespace as String?,
    temporaryTablespace: temporaryTablespace == _unset ? this.temporaryTablespace : temporaryTablespace as String?,
    profile: profile == _unset ? this.profile : profile as String?,
    defaultRole: defaultRole == _unset ? this.defaultRole : defaultRole as String?,
    defaultWarehouse: defaultWarehouse == _unset ? this.defaultWarehouse : defaultWarehouse as String?,
    mustChangePassword: mustChangePassword ?? this.mustChangePassword,
    comment: comment == _unset ? this.comment : comment as String?,
    originalName: originalName == _unset ? this.originalName : originalName as String?,
    builtIn: builtIn,
  );
}

/// Kind of object a privilege applies to.
enum GrantTarget {
  table('Tabella'),
  view('Vista'),
  sequence('Sequenza'),
  routine('Procedura o funzione'),
  schema('Schema'),
  database('Database'),

  /// Privileges not tied to an object (Oracle system privileges, SQL Server
  /// database permissions such as CREATE TABLE).
  system('Sistema');

  const GrantTarget(this.label);
  final String label;
}

/// A privilege held by a grantee on an object.
class GrantDef {
  const GrantDef({
    required this.privilege,
    required this.target,
    this.catalog,
    this.schema,
    this.object,
    this.isFunction = false,
    this.withGrantOption = false,
  });

  /// SELECT, INSERT, USAGE, CREATE SESSION…
  final String privilege;
  final GrantTarget target;
  final String? catalog;
  final String? schema;

  /// Table / view / sequence / routine name; null for schema, database,
  /// system privileges.
  final String? object;

  /// Routine grants: the object is a function (else a procedure).
  final bool isFunction;
  final bool withGrantOption;

  /// Identity in diffs (the grant option is a separate aspect). Tables and
  /// views share the key: several catalogs do not tell them apart.
  String get key => [
    target == GrantTarget.view ? GrantTarget.table.name : target.name,
    (catalog ?? '').toLowerCase(),
    (schema ?? '').toLowerCase(),
    (object ?? '').toLowerCase(),
    privilege.toUpperCase(),
  ].join('|');

  /// The object, for display.
  String get objectLabel => switch (target) {
    GrantTarget.system => 'sistema',
    GrantTarget.database => catalog ?? 'database',
    GrantTarget.schema => schema ?? '',
    _ => [?schema, ?object].join('.'),
  };

  /// Identity of the object (without the privilege).
  String get objectKey => key.substring(0, key.lastIndexOf('|'));

  GrantDef copyWith({bool? withGrantOption}) => GrantDef(
    privilege: privilege,
    target: target,
    catalog: catalog,
    schema: schema,
    object: object,
    isFunction: isFunction,
    withGrantOption: withGrantOption ?? this.withGrantOption,
  );
}

/// [member] belongs to [role].
class RoleMembership {
  const RoleMembership(
    this.role,
    this.member, {
    this.roleHost,
    this.memberHost,
    this.withAdmin = false,
    this.serverRole = false,
  });
  final String role;
  final String member;

  /// MySQL account hosts.
  final String? roleHost;
  final String? memberHost;

  /// The member can grant the role to others.
  final bool withAdmin;

  /// SQL Server server role (sysadmin…) rather than a database role.
  final bool serverRole;

  String get key =>
      '${serverRole ? 's' : 'd'}|${role.toLowerCase()}@${(roleHost ?? '').toLowerCase()}|'
      '${member.toLowerCase()}@${(memberHost ?? '').toLowerCase()}';

  /// The role, as listed (user@host for MySQL).
  String get roleDisplay => roleHost == null || roleHost == '%' ? role : '$role@$roleHost';

  bool isMember(PrincipalDef p) =>
      member.toLowerCase() == p.dbName.toLowerCase() &&
      (memberHost ?? '').toLowerCase() == (p.host ?? '').toLowerCase();

  RoleMembership copyWith({bool? withAdmin}) => RoleMembership(
    role,
    member,
    roleHost: roleHost,
    memberHost: memberHost,
    withAdmin: withAdmin ?? this.withAdmin,
    serverRole: serverRole,
  );
}
