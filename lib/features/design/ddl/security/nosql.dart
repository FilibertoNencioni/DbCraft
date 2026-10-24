// Security of the NoSQL databases and BigQuery:
// - MongoDB: users and roles of a database (PrincipalDef.host is the
//   database), shell commands (createUser, grantRolesToUser,
//   grantPrivilegesToRole…);
// - Cassandra: roles (users are roles with LOGIN), CQL GRANT on keyspaces
//   and tables;
// - Redis: ACL users with their rules (ACL SETUSER / DELUSER);
// - BigQuery: IAM roles granted on datasets and tables to Google identities.

import 'dart:convert';

import '../../capabilities.dart';
import '../../model/security_defs.dart';
import '../nosql_ddl.dart';
import 'security_ddl.dart';

// ---------------------------------------------------------------------------
// MongoDB
// ---------------------------------------------------------------------------

class MongoSecurityDdl extends SecurityDdl {
  MongoSecurityDdl(super.dialect, super.secrets) : super.base();

  static const _mongo = MongoDdl();

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.user, PrincipalKind.role];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) =>
      k == PrincipalKind.user ? const {PrincipalAttr.host, PrincipalAttr.password} : const {PrincipalAttr.host};

  @override
  bool requiresPassword(PrincipalDef p) => p.kind == PrincipalKind.user;

  @override
  bool get adminOption => false;

  @override
  bool grantOption(GrantTarget t) => false;

  @override
  bool get catalogInGrants => true;

  @override
  String passwordLiteral(String password) => jsonEncode(password);

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) =>
      k == PrincipalKind.role ? const [GrantTarget.database, GrantTarget.table] : const [];

  static const _collectionActions = [
    'find',
    'insert',
    'update',
    'remove',
    'createIndex',
    'dropIndex',
    'collStats',
    'changeStream',
    'bypassDocumentValidation',
  ];

  @override
  List<String> privileges(GrantTarget t) => switch (t) {
    GrantTarget.database => const [
      ..._collectionActions,
      'createCollection',
      'dropCollection',
      'listCollections',
      'dbStats',
      'dropDatabase',
    ],
    GrantTarget.table => _collectionActions,
    _ => const [],
  };

  @override
  List<String> systemPrivileges(PrincipalKind k) => k == PrincipalKind.role
      ? const ['listDatabases', 'serverStatus', 'inprog', 'killop', 'top', 'replSetGetStatus', 'shutdown']
      : const [];

  @override
  bool grantsTo(PrincipalDef p) => super.grantsTo(p) && p.kind == PrincipalKind.role;

  String _db(PrincipalDef p) => p.host ?? 'admin';
  String _s(String s) => jsonEncode(s);
  String _cmd(String db, List<(String, String)> doc) => '${_mongo.db(db)}.runCommand(${shellDoc(doc)})';

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) => [
    p.kind == PrincipalKind.role
        ? _cmd(_db(p), [('createRole', _s(p.name)), ('privileges', '[]'), ('roles', '[]')])
        : _cmd(_db(p), [('createUser', _s(p.name)), ('pwd', this.password(password)), ('roles', '[]')]),
  ];

  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) => [
    if (from.dbName != to.name) note('Ridenominazione di ${from.dbName} in MongoDB'),
    if ((from.host ?? '') != (to.host ?? '')) note('Spostamento di ${from.dbName} in un altro database'),
    if (password != null && to.kind == PrincipalKind.user)
      _cmd(_db(from), [('updateUser', _s(from.dbName)), ('pwd', this.password(password))]),
  ];

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => [
    _cmd(_db(p), [(p.kind == PrincipalKind.role ? 'dropRole' : 'dropUser', _s(p.dbName))]),
  ];

  @override
  String? onClause(GrantDef g) => switch (g.target) {
    GrantTarget.database => shellDoc([('db', _s(g.catalog ?? '')), ('collection', '""')]),
    GrantTarget.table ||
    GrantTarget.view => shellDoc([('db', _s(g.catalog ?? '')), ('collection', _s(g.object ?? ''))]),
    GrantTarget.system => shellDoc([('cluster', 'true')]),
    _ => throw UnsupportedError('target'),
  };

  String _privileges(List<String> privileges, GrantDef on) =>
      '[${shellDoc([
        ('resource', onClause(on)!),
        ('actions', '[${[for (final p in privileges) _s(p)].join(', ')}]'),
      ])}]';

  String? _cannot(PrincipalDef p, GrantDef on) {
    if (!grantsTo(p)) return note('In MongoDB i privilegi si assegnano ai ruoli, non agli utenti');
    try {
      onClause(on);
      return null;
    } on UnsupportedError {
      return note('Privilegi su ${on.target.label.toLowerCase()}');
    }
  }

  @override
  List<String> grant(PrincipalDef p, List<String> privileges, GrantDef on, {bool withGrantOption = false}) {
    final why = _cannot(p, on);
    if (why != null) return [why];
    return [
      _cmd(_db(p), [('grantPrivilegesToRole', _s(p.name)), ('privileges', _privileges(privileges, on))]),
    ];
  }

  @override
  List<String> revoke(PrincipalDef p, List<String> privileges, GrantDef on, {bool cascade = false}) {
    final why = _cannot(p, on);
    if (why != null) return [why];
    return [
      _cmd(_db(p), [('revokePrivilegesFromRole', _s(p.name)), ('privileges', _privileges(privileges, on))]),
    ];
  }

  @override
  List<String> revokeGrantOption(PrincipalDef p, List<String> privileges, GrantDef on) => const [];

  String _roleRef(RoleMembership m) => shellDoc([('role', _s(m.role)), ('db', _s(m.roleHost ?? 'admin'))]);

  @override
  List<String> grantRole(RoleMembership m, PrincipalDef member) => [
    _cmd(_db(member), [
      (member.kind == PrincipalKind.role ? 'grantRolesToRole' : 'grantRolesToUser', _s(member.name)),
      ('roles', '[${_roleRef(m)}]'),
    ]),
  ];

  @override
  List<String> revokeRole(RoleMembership m, PrincipalDef member) => [
    _cmd(_db(member), [
      (member.kind == PrincipalKind.role ? 'revokeRolesFromRole' : 'revokeRolesFromUser', _s(member.name)),
      ('roles', '[${_roleRef(m)}]'),
    ]),
  ];
}

/// Built-in MongoDB roles of every database, and those only in admin.
const mongoDatabaseRoles = ['read', 'readWrite', 'dbAdmin', 'dbOwner', 'userAdmin'];
const mongoAdminRoles = [
  'readAnyDatabase',
  'readWriteAnyDatabase',
  'userAdminAnyDatabase',
  'dbAdminAnyDatabase',
  'clusterMonitor',
  'clusterManager',
  'hostManager',
  'clusterAdmin',
  'backup',
  'restore',
  'root',
];

// ---------------------------------------------------------------------------
// Cassandra
// ---------------------------------------------------------------------------

class CassandraSecurityDdl extends SecurityDdl {
  CassandraSecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.user, PrincipalKind.role];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => k == PrincipalKind.user
      ? const {PrincipalAttr.password, PrincipalAttr.superuser}
      : const {PrincipalAttr.superuser};

  @override
  bool requiresPassword(PrincipalDef p) => p.kind == PrincipalKind.user;

  @override
  bool get adminOption => false;

  @override
  bool grantOption(GrantTarget t) => false;

  @override
  bool get catalogInGrants => true;

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => const [GrantTarget.database, GrantTarget.table];

  @override
  List<String> privileges(GrantTarget t) => switch (t) {
    GrantTarget.database => const ['SELECT', 'MODIFY', 'CREATE', 'ALTER', 'DROP', 'AUTHORIZE'],
    GrantTarget.table || GrantTarget.view => const ['SELECT', 'MODIFY', 'ALTER', 'DROP', 'AUTHORIZE'],
    _ => const [],
  };

  /// Privileges ON ALL KEYSPACES.
  @override
  List<String> systemPrivileges(PrincipalKind k) => const ['SELECT', 'MODIFY', 'CREATE', 'ALTER', 'DROP', 'AUTHORIZE'];

  List<String> _with(PrincipalDef p, PrincipalDef? from, String? password) => [
    if (password != null) 'PASSWORD = ${this.password(password)}',
    if (from == null
        ? p.kind == PrincipalKind.user
        : (from.kind == PrincipalKind.user) != (p.kind == PrincipalKind.user))
      'LOGIN = ${p.kind == PrincipalKind.user}',
    if (from == null ? p.superuser : from.superuser != p.superuser) 'SUPERUSER = ${p.superuser}',
  ];

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) {
    final w = _with(p, null, password);
    return ['CREATE ROLE ${q(p.name)}${w.isEmpty ? '' : ' WITH ${w.join(' AND ')}'}'];
  }

  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) {
    final w = _with(to, from, password);
    return [
      if (from.dbName != to.name) note('Ridenominazione di un ruolo Cassandra'),
      if (w.isNotEmpty) 'ALTER ROLE ${q(from.dbName)} WITH ${w.join(' AND ')}',
    ];
  }

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => ['DROP ROLE ${q(p.dbName)}'];

  @override
  String? onClause(GrantDef g) => switch (g.target) {
    GrantTarget.database => 'KEYSPACE ${q(g.catalog!)}',
    GrantTarget.table || GrantTarget.view => 'TABLE ${q(g.catalog!)}.${q(g.object!)}',
    GrantTarget.system => 'ALL KEYSPACES',
    _ => throw UnsupportedError('target'),
  };

  @override
  List<String> revokeGrantOption(PrincipalDef p, List<String> privileges, GrantDef on) => const [];

  /// Cassandra grants one permission per statement.
  @override
  List<String> grant(PrincipalDef p, List<String> privileges, GrantDef on, {bool withGrantOption = false}) => [
    for (final x in privileges) ...super.grant(p, [x], on),
  ];

  @override
  List<String> revoke(PrincipalDef p, List<String> privileges, GrantDef on, {bool cascade = false}) => [
    for (final x in privileges) ...super.revoke(p, [x], on),
  ];
}

// ---------------------------------------------------------------------------
// Redis
// ---------------------------------------------------------------------------

/// A Redis command argument, quoted when needed.
String redisArg(String s) =>
    RegExp(
      r'^[^\s"'
      "'"
      r']+$',
    ).hasMatch(s)
    ? s
    : '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

class RedisSecurityDdl extends SecurityDdl {
  RedisSecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.user];

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => const {
    PrincipalAttr.password,
    PrincipalAttr.locked,
    PrincipalAttr.aclRules,
  };

  @override
  bool hasRoles(PrincipalKind k) => false;

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => const [];

  @override
  List<String> privileges(GrantTarget t) => const [];

  /// `>password`, quoted for the command line.
  @override
  String passwordLiteral(String password) => redisArg('>$password');

  String _rules(String? rules) => (rules ?? '').trim().split(RegExp(r'\s+')).where((r) => r.isNotEmpty).join(' ');

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) {
    final parts = [
      'ACL SETUSER ${redisArg(p.name)}',
      p.locked ? 'off' : 'on',
      if (password != null) this.password(password),
      if (_rules(p.aclRules).isNotEmpty) _rules(p.aclRules),
    ];
    return [parts.join(' ')];
  }

  /// Rules are replaced: keys, channels and commands are reset first
  /// (passwords stay).
  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) {
    final rules = _rules(to.aclRules) != _rules(from.aclRules);
    final parts = [
      if (from.locked != to.locked) to.locked ? 'off' : 'on',
      if (password != null) this.password(password),
      if (rules) ...['resetkeys', 'resetchannels', '-@all', if (_rules(to.aclRules).isNotEmpty) _rules(to.aclRules)],
    ];
    return [
      if (from.dbName != to.name) note('Ridenominazione di un utente Redis'),
      if (parts.isNotEmpty) 'ACL SETUSER ${redisArg(from.dbName)} ${parts.join(' ')}',
    ];
  }

  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => ['ACL DELUSER ${redisArg(p.dbName)}'];

  @override
  String? onClause(GrantDef g) => throw UnsupportedError('grants');
}

// ---------------------------------------------------------------------------
// BigQuery
// ---------------------------------------------------------------------------

/// IAM roles offered on datasets, tables and views.
const bigQueryRoles = [
  'roles/bigquery.dataViewer',
  'roles/bigquery.dataEditor',
  'roles/bigquery.dataOwner',
  'roles/bigquery.metadataViewer',
];

class BigQuerySecurityDdl extends SecurityDdl {
  BigQuerySecurityDdl(super.dialect, super.secrets) : super.base();

  @override
  List<PrincipalKind> get kinds => const [PrincipalKind.user, PrincipalKind.group];

  @override
  bool canCreate(PrincipalKind k) => false;

  @override
  String? createReason(PrincipalKind k) => 'In BigQuery le identità sono quelle di Google Cloud (IAM)';

  @override
  Set<PrincipalAttr> attributes(PrincipalKind k) => const {};

  @override
  bool hasRoles(PrincipalKind k) => false;

  @override
  bool grantOption(GrantTarget t) => false;

  @override
  bool get catalogInGrants => true;

  @override
  List<GrantTarget> objectTargets(PrincipalKind k) => const [GrantTarget.schema, GrantTarget.table, GrantTarget.view];

  @override
  List<String> privileges(GrantTarget t) =>
      t == GrantTarget.schema || t == GrantTarget.table || t == GrantTarget.view ? bigQueryRoles : const [];

  /// `user:mario@example.com`, `group:…`, `serviceAccount:…`, `domain:…`.
  @override
  String grantee(PrincipalDef p) => jsonEncode(p.name);

  @override
  String? onClause(GrantDef g) => switch (g.target) {
    GrantTarget.schema => 'SCHEMA ${dialect.qualified(null, g.catalog, g.schema!)}',
    GrantTarget.table || GrantTarget.view => 'TABLE ${dialect.qualified(g.catalog, g.schema, g.object!)}',
    _ => throw UnsupportedError('target'),
  };

  String _roles(List<String> roles) => [for (final r in roles) '`$r`'].join(', ');

  @override
  List<String> grant(PrincipalDef p, List<String> privileges, GrantDef on, {bool withGrantOption = false}) {
    if (!caps.has(DesignFeature.grants)) return [note('Permessi: ${caps.reason(DesignFeature.grants)}')];
    return ['GRANT ${_roles(privileges)} ON ${onClause(on)} TO ${grantee(p)}'];
  }

  @override
  List<String> revoke(PrincipalDef p, List<String> privileges, GrantDef on, {bool cascade = false}) {
    if (!caps.has(DesignFeature.grants)) return [note('Permessi: ${caps.reason(DesignFeature.grants)}')];
    return ['REVOKE ${_roles(privileges)} ON ${onClause(on)} FROM ${grantee(p)}'];
  }

  @override
  List<String> createPrincipal(PrincipalDef p, {String? password}) => unsupportedKind(p);
  @override
  List<String> alterPrincipal(PrincipalDef from, PrincipalDef to, {String? password}) => const [];
  @override
  List<String> dropPrincipal(PrincipalDef p, {bool cascade = false}) => unsupportedKind(p);
}
