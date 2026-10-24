// What the design and administration tools can do on a database, by DBMS
// family and server version.
//
// The UI never tests `dialect.family` to decide whether to offer a design
// action: it asks [DesignCapabilities] and, for a missing feature, shows
// [DesignCapabilities.reason] as the tooltip of the disabled control.
// An unknown server version counts as a current one.

import '../../services/sql_dialect.dart';
import 'model/extra_defs.dart';

enum DesignFeature {
  // Databases and schemas
  createDatabase,
  renameDatabase,
  schemas,

  // Tables
  createTable,

  /// ALTER TABLE in place (SQLite rebuilds the table instead).
  alterTableInPlace,

  /// PK / UNIQUE / FK added to or dropped from an existing table.
  constraintsOnExistingTable,

  /// The server enforces PK / UNIQUE / FK (Snowflake only records them).
  enforcedConstraints,
  checkConstraints,
  fkSetDefault,

  /// ON UPDATE CASCADE / SET NULL / SET DEFAULT.
  fkOnUpdate,
  deferrableConstraints,
  disableConstraints,

  /// Constraint added without checking the existing rows.
  addNotValidated,
  renameConstraint,

  // Indexes
  indexes,
  indexDescending,
  indexInclude,
  indexFilter,
  renameIndex,
  rebuildIndex,
  disableIndex,
  onlineIndex,

  // Other objects
  views,

  /// CREATE OR REPLACE / CREATE OR ALTER VIEW (otherwise DROP + CREATE).
  replaceView,
  materializedViews,
  sequences,
  triggers,
  routines,

  // DBMS specific objects
  extensions,
  enumTypes,
  domains,

  /// Row level security policies.
  rowSecurity,
  exclusionConstraints,
  synonyms,
  packages,
  events,
  warehouses,
  stages,
  fileFormats,

  // Security
  users,
  roles,
  grants,

  // Execution
  /// DDL can be rolled back: scripts run in a single transaction.
  transactionalDdl,
  comments,
}

class DesignCapabilities {
  DesignCapabilities._(this.dialect, this._reasons);

  final SqlDialect dialect;

  /// Missing features → why they are missing.
  final Map<DesignFeature, String> _reasons;

  static DesignCapabilities of(SqlDialect dialect) => DesignCapabilities._(dialect, _missing(dialect));

  bool has(DesignFeature f) => !_reasons.containsKey(f);

  /// Why [f] is not available (null when it is).
  String? reason(DesignFeature f) => _reasons[f];

  Set<DesignFeature> get features => {
    for (final f in DesignFeature.values)
      if (has(f)) f,
  };

  static Map<DesignFeature, String> _missing(SqlDialect d) {
    final name = _label(d);
    final v = d.version;
    bool atLeast(int major, [int minor = 0, int patch = 0]) => v == null || v.atLeast(major, minor, patch);
    final out = <DesignFeature, String>{};
    void no(Iterable<DesignFeature> fs, [String? why]) {
      for (final f in fs) {
        out[f] = why ?? '$name non supporta questa operazione';
      }
    }

    void needs(DesignFeature f, bool ok, String version) {
      if (!ok) out[f] = 'Richiede $name $version o successivo';
    }

    const security = [DesignFeature.users, DesignFeature.roles, DesignFeature.grants];

    switch (d.family) {
      case DbFamily.postgres:
        no([DesignFeature.disableConstraints], '$name non disabilita i vincoli: aggiungili come NOT VALID');
        no([DesignFeature.disableIndex]);
        needs(DesignFeature.indexInclude, atLeast(11), '11');
      case DbFamily.sqlServer:
        no([DesignFeature.deferrableConstraints, DesignFeature.materializedViews]);
        needs(DesignFeature.replaceView, atLeast(13, 0, 4001), '2016 SP1');
        needs(DesignFeature.sequences, atLeast(11), '2012');
      case DbFamily.mysql:
        no([
          DesignFeature.renameDatabase,
          DesignFeature.fkSetDefault,
          DesignFeature.deferrableConstraints,
          DesignFeature.disableConstraints,
          DesignFeature.addNotValidated,
          DesignFeature.renameConstraint,
          DesignFeature.indexInclude,
          DesignFeature.indexFilter,
          DesignFeature.materializedViews,
          DesignFeature.transactionalDdl,
        ]);
        no([DesignFeature.schemas], 'In $name schema e database coincidono');
        if (d.isMariaDb) {
          needs(DesignFeature.checkConstraints, atLeast(10, 2, 1), '10.2.1');
          needs(DesignFeature.renameIndex, atLeast(10, 5, 2), '10.5.2');
          needs(DesignFeature.disableIndex, atLeast(10, 6), '10.6');
          needs(DesignFeature.sequences, atLeast(10, 3), '10.3');
          needs(DesignFeature.roles, atLeast(10, 0, 5), '10.0.5');
        } else {
          needs(DesignFeature.checkConstraints, atLeast(8, 0, 16), '8.0.16');
          needs(DesignFeature.renameIndex, atLeast(5, 7), '5.7');
          needs(DesignFeature.roles, atLeast(8), '8.0');
          needs(DesignFeature.disableIndex, atLeast(8), '8.0'); // INVISIBLE
          no([DesignFeature.sequences]);
        }
      case DbFamily.oracle:
        no([DesignFeature.createDatabase, DesignFeature.renameDatabase], 'In $name i database (PDB) non sono gestiti');
        no([DesignFeature.schemas], 'In $name uno schema coincide con un utente: usa Sicurezza ▸ Utenti');
        no([
          DesignFeature.fkSetDefault,
          DesignFeature.fkOnUpdate,
          DesignFeature.indexInclude,
          DesignFeature.indexFilter,
        ]);
        no([DesignFeature.transactionalDdl], '$name conferma automaticamente ogni istruzione DDL');
      case DbFamily.db2:
        no([
          DesignFeature.createDatabase,
          DesignFeature.renameDatabase,
        ], 'In $name i database si creano dal processore di comandi (CLP)');
        no([
          DesignFeature.fkSetDefault,
          DesignFeature.fkOnUpdate,
          DesignFeature.deferrableConstraints,
          DesignFeature.renameConstraint,
          DesignFeature.indexFilter,
          DesignFeature.disableIndex,
          DesignFeature.onlineIndex,
          DesignFeature.materializedViews,
        ]);
        no([DesignFeature.users], 'In $name gli utenti sono quelli del sistema operativo o di LDAP');
      case DbFamily.sqlite:
        no([DesignFeature.renameDatabase, DesignFeature.schemas]);
        no([
          DesignFeature.alterTableInPlace,
          DesignFeature.constraintsOnExistingTable,
          DesignFeature.renameConstraint,
        ], '$name non modifica i vincoli con ALTER TABLE: la tabella viene ricostruita');
        no([
          DesignFeature.disableConstraints,
          DesignFeature.addNotValidated,
          DesignFeature.indexInclude,
          DesignFeature.renameIndex,
          DesignFeature.disableIndex,
          DesignFeature.onlineIndex,
          DesignFeature.replaceView,
          DesignFeature.materializedViews,
          DesignFeature.sequences,
          DesignFeature.routines,
          DesignFeature.comments,
        ]);
        no(security, '$name non ha utenti né permessi');
      case DbFamily.firebird:
        no([
          DesignFeature.createDatabase,
          DesignFeature.renameDatabase,
        ], 'Non è possibile creare database $name via ODBC');
        no([
          DesignFeature.schemas,
          DesignFeature.deferrableConstraints,
          DesignFeature.disableConstraints,
          DesignFeature.addNotValidated,
          DesignFeature.renameConstraint,
          DesignFeature.indexInclude,
          DesignFeature.renameIndex,
          DesignFeature.onlineIndex,
          DesignFeature.materializedViews,
        ]);
        needs(DesignFeature.indexFilter, atLeast(5), '5.0');
        needs(DesignFeature.users, atLeast(3), '3.0');
      case DbFamily.snowflake:
        no([DesignFeature.enforcedConstraints], '$name registra PK, UNIQUE e FK ma non li applica');
        no([DesignFeature.checkConstraints, DesignFeature.deferrableConstraints, DesignFeature.triggers]);
        no([
          DesignFeature.disableConstraints,
          DesignFeature.addNotValidated,
        ], '$name non applica i vincoli: non serve disabilitarli né validarli');
        no([
          DesignFeature.indexes,
          DesignFeature.indexDescending,
          DesignFeature.indexInclude,
          DesignFeature.indexFilter,
          DesignFeature.renameIndex,
          DesignFeature.rebuildIndex,
          DesignFeature.disableIndex,
          DesignFeature.onlineIndex,
        ], '$name non ha indici');
        no([DesignFeature.transactionalDdl], '$name conferma automaticamente ogni istruzione DDL');
      case DbFamily.generic:
        // Only standard SQL tables, views and indexes.
        for (final f in DesignFeature.values) {
          if (!_standard.contains(f)) out[f] = 'DBMS non riconosciuto: disponibili solo le operazioni SQL standard';
        }
      case DbFamily.bigquery || DbFamily.cassandra || DbFamily.mongodb || DbFamily.redis:
        // Native drivers: the design tools for them come later.
        for (final f in DesignFeature.values) {
          out[f] = 'Strumenti di design non ancora disponibili per $name';
        }
    }
    // Objects only some DBMS have.
    final f = d.family;
    final pg = f == DbFamily.postgres;
    final sf = f == DbFamily.snowflake;
    final only = <DesignFeature, bool>{
      DesignFeature.extensions: pg,
      DesignFeature.enumTypes: pg,
      DesignFeature.domains: pg || f == DbFamily.firebird,
      DesignFeature.rowSecurity: pg,
      DesignFeature.exclusionConstraints: pg,
      DesignFeature.synonyms: f == DbFamily.sqlServer || f == DbFamily.oracle,
      DesignFeature.packages: f == DbFamily.oracle,
      DesignFeature.events: f == DbFamily.mysql,
      DesignFeature.warehouses: sf,
      DesignFeature.stages: sf,
      DesignFeature.fileFormats: sf,
    };
    for (final e in only.entries) {
      if (!e.value) out.putIfAbsent(e.key, () => '$name non ha questo tipo di oggetto');
    }
    if (pg) needs(DesignFeature.rowSecurity, atLeast(9, 5), '9.5');
    return out;
  }

  /// Features of an unknown SQL DBMS.
  static const _standard = {
    DesignFeature.createTable,
    DesignFeature.alterTableInPlace,
    DesignFeature.constraintsOnExistingTable,
    DesignFeature.enforcedConstraints,
    DesignFeature.checkConstraints,
    DesignFeature.fkOnUpdate,
    DesignFeature.indexes,
    DesignFeature.indexDescending,
    DesignFeature.views,
  };

  static String _label(SqlDialect d) => switch (d.family) {
    DbFamily.sqlServer => 'SQL Server',
    DbFamily.postgres => 'PostgreSQL',
    DbFamily.mysql => d.isMariaDb ? 'MariaDB' : 'MySQL',
    DbFamily.oracle => 'Oracle',
    DbFamily.db2 => 'Db2',
    DbFamily.sqlite => 'SQLite',
    DbFamily.firebird => 'Firebird',
    DbFamily.snowflake => 'Snowflake',
    DbFamily.bigquery => 'BigQuery',
    DbFamily.cassandra => 'Cassandra',
    DbFamily.mongodb => 'MongoDB',
    DbFamily.redis => 'Redis',
    DbFamily.generic => d.dbmsName.isEmpty ? 'Questo DBMS' : d.dbmsName,
  };
}

/// The feature that offers objects of [k].
DesignFeature extraFeature(ExtraKind k) => switch (k) {
  ExtraKind.extensions => DesignFeature.extensions,
  ExtraKind.enumTypes => DesignFeature.enumTypes,
  ExtraKind.domains => DesignFeature.domains,
  ExtraKind.synonyms => DesignFeature.synonyms,
  ExtraKind.packages => DesignFeature.packages,
  ExtraKind.events => DesignFeature.events,
  ExtraKind.warehouses => DesignFeature.warehouses,
  ExtraKind.stages => DesignFeature.stages,
  ExtraKind.fileFormats => DesignFeature.fileFormats,
  ExtraKind.policies => DesignFeature.rowSecurity,
  ExtraKind.exclusions => DesignFeature.exclusionConstraints,
};
