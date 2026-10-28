// Databases and schemas that belong to the DBMS itself (master, pg_catalog,
// information_schema…). The navigator groups them in a "Sistema" folder.
import '../drivers/cassandra/cassandra_session.dart' show cassandraSystemKeyspaces;
import 'sql_dialect.dart';

/// Whether the database (keyspace for Cassandra) [name] belongs to the DBMS.
bool isSystemCatalog(SqlDialect d, String name) {
  final n = name.toLowerCase();
  return switch (d.family) {
    DbFamily.sqlServer => const {'master', 'model', 'msdb', 'tempdb', 'distribution'}.contains(n),
    // `postgres` stays visible: it is the usual maintenance database.
    DbFamily.postgres => n == 'template0' || n == 'template1',
    DbFamily.mysql => _mysql.contains(n),
    DbFamily.snowflake => n == 'snowflake' || n == 'snowflake_sample_data',
    DbFamily.mongodb => const {'admin', 'config', 'local'}.contains(n),
    DbFamily.cassandra => cassandraSystemKeyspaces.contains(n),
    DbFamily.generic when _isClickHouse(d) => n == 'system' || n == 'information_schema',
    _ => false,
  };
}

/// Whether the schema [name] belongs to the DBMS. For Oracle this is the
/// fallback list: [oracleSystemSchemas] reads `ORACLE_MAINTAINED` when it
/// can.
bool isSystemSchema(SqlDialect d, String name) {
  final n = name.toLowerCase();
  if (n == 'information_schema') return true;
  return switch (d.family) {
    DbFamily.sqlServer => n == 'sys' || n == 'guest' || _mssqlRoleSchemas.contains(n),
    // PostgreSQL reserves the pg_ prefix (pg_catalog, pg_toast, pg_temp_N…).
    DbFamily.postgres => n.startsWith('pg_'),
    DbFamily.mysql => _mysql.contains(n),
    DbFamily.oracle => oracleBuiltInSchemas.contains(n) || n.startsWith('apex_'),
    // Db2 reserves the SYS prefix.
    DbFamily.db2 => n.startsWith('sys') || n == 'nullid' || n == 'sqlj',
    _ => false,
  };
}

const _mysql = {'mysql', 'sys', 'performance_schema', 'information_schema'};

const _mssqlRoleSchemas = {
  'db_owner',
  'db_accessadmin',
  'db_securityadmin',
  'db_ddladmin',
  'db_backupoperator',
  'db_datareader',
  'db_datawriter',
  'db_denydatareader',
  'db_denydatawriter',
};

/// Users created by the Oracle installation (lower case), for servers older
/// than 12c or without access to `ORACLE_MAINTAINED`.
const oracleBuiltInSchemas = {
  'sys', 'system', 'outln', 'dbsnmp', 'xdb', 'ctxsys', 'mdsys', 'mddata', 'ordsys', 'orddata', 'ordplugins', //
  'si_informtn_schema', 'olapsys', 'wmsys', 'lbacsys', 'dvsys', 'dvf', 'gsmadmin_internal', 'gsmcatuser',
  'gsmuser', 'gsmrootuser', 'appqossys', 'audsys', 'ojvmsys', 'anonymous', 'xs\$null', 'dip', 'oracle_ocm',
  'remote_scheduler_agent', 'sysbackup', 'sysdg', 'syskm', 'sysrac', 'ggsys', 'dbsfwuser', 'sys\$umf',
  'flows_files', 'exfsys', 'mgmt_view', 'spatial_csw_admin_usr', 'spatial_wfs_admin_usr', 'owbsys',
  'owbsys_audit', 'sysman', 'apex_public_user',
};

bool _isClickHouse(SqlDialect d) => d.dbmsName.toLowerCase().contains('clickhouse');
