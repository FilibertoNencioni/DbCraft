// DDL of databases and schemas (and, in the next phases, of views,
// sequences, triggers and routines). Same conventions as DdlBuilder:
// statements without terminators, comment-only entries for notes and for
// what the DBMS cannot do ("… (non supportato)").

import '../../../services/sql_dialect.dart';
import '../capabilities.dart';
import '../model/object_defs.dart';

class ObjectDdl {
  ObjectDdl(this.dialect) : caps = DesignCapabilities.of(dialect);

  final SqlDialect dialect;
  final DesignCapabilities caps;

  DbFamily get family => dialect.family;

  String q(String name) => dialect.quoteIdent(name);
  String lit(String s) => dialect.stringLiteral(s);
  String _n(String s) => 'N${lit(s)}';

  String _note(String text) => '-- $text (non supportato)';

  bool _has(String? s) => s != null && s.trim().isNotEmpty;

  // -------------------------------------------------------------------------
  // Databases
  // -------------------------------------------------------------------------

  /// CREATE DATABASE with the options of the DBMS (they cannot run inside a
  /// transaction: run them with DdlScript.autocommitOnly).
  List<String> createDatabase(DatabaseDef d) {
    if (!caps.has(DesignFeature.createDatabase)) {
      return [_note('Creazione del database ${d.name}: ${caps.reason(DesignFeature.createDatabase)}')];
    }
    final name = q(d.name);
    switch (family) {
      case DbFamily.postgres:
        final sb = StringBuffer('CREATE DATABASE $name');
        if (_has(d.owner)) sb.write(' OWNER ${q(d.owner!)}');
        if (_has(d.template)) sb.write(' TEMPLATE ${q(d.template!)}');
        if (_has(d.encoding)) sb.write(' ENCODING ${lit(d.encoding!)}');
        if (_has(d.collation)) sb.write(' LC_COLLATE ${lit(d.collation!)}');
        if (_has(d.ctype)) sb.write(' LC_CTYPE ${lit(d.ctype!)}');
        if (_has(d.tablespace)) sb.write(' TABLESPACE ${q(d.tablespace!)}');
        if (d.connectionLimit != null && d.connectionLimit! >= 0) sb.write(' CONNECTION LIMIT ${d.connectionLimit}');
        return [sb.toString(), if (_has(d.comment)) 'COMMENT ON DATABASE $name IS ${lit(d.comment!)}'];
      case DbFamily.sqlServer:
        return [
          'CREATE DATABASE $name${_has(d.collation) ? ' COLLATE ${d.collation}' : ''}',
          if (_has(d.recoveryModel)) 'ALTER DATABASE $name SET RECOVERY ${d.recoveryModel}',
          if (_has(d.owner)) 'ALTER AUTHORIZATION ON DATABASE::$name TO ${q(d.owner!)}',
        ];
      case DbFamily.mysql:
        final sb = StringBuffer('CREATE DATABASE $name');
        if (_has(d.encoding)) sb.write(' CHARACTER SET ${d.encoding}');
        if (_has(d.collation)) sb.write(' COLLATE ${d.collation}');
        if (_has(d.comment) && dialect.isMariaDb) sb.write(' COMMENT ${lit(d.comment!)}');
        return [sb.toString()];
      case DbFamily.snowflake:
        final sb = StringBuffer('CREATE ${d.transient ? 'TRANSIENT ' : ''}DATABASE $name');
        if (d.retentionDays != null) sb.write(' DATA_RETENTION_TIME_IN_DAYS = ${d.retentionDays}');
        if (_has(d.comment)) sb.write(' COMMENT = ${lit(d.comment!)}');
        return [sb.toString()];
      default:
        return [_note('Creazione del database ${d.name} con ${dialect.dbmsName}')];
    }
  }

  /// Statements that turn the database [from] into [to].
  List<String> alterDatabase(DatabaseDef from, DatabaseDef to) {
    final out = <String>[];
    var name = q(from.name);
    bool changed(Object? a, Object? b) => (a ?? '').toString() != (b ?? '').toString();
    if (from.name != to.name) {
      out.addAll(renameDatabase(from.name, to.name));
      if (caps.has(DesignFeature.renameDatabase)) name = q(to.name);
    }
    switch (family) {
      case DbFamily.postgres:
        if (changed(from.owner, to.owner) && _has(to.owner)) out.add('ALTER DATABASE $name OWNER TO ${q(to.owner!)}');
        if (changed(from.connectionLimit, to.connectionLimit)) {
          out.add('ALTER DATABASE $name CONNECTION LIMIT ${to.connectionLimit ?? -1}');
        }
        if (changed(from.tablespace, to.tablespace) && _has(to.tablespace)) {
          out.add('ALTER DATABASE $name SET TABLESPACE ${q(to.tablespace!)}');
        }
        if (changed(from.comment, to.comment)) {
          out.add('COMMENT ON DATABASE $name IS ${_has(to.comment) ? lit(to.comment!) : 'NULL'}');
        }
        if (changed(from.encoding, to.encoding) ||
            changed(from.collation, to.collation) ||
            changed(from.ctype, to.ctype)) {
          out.add(_note('Codifica e collation di un database PostgreSQL non si cambiano dopo la creazione'));
        }
      case DbFamily.sqlServer:
        if (changed(from.collation, to.collation) && _has(to.collation)) {
          out.add('ALTER DATABASE $name COLLATE ${to.collation}');
        }
        if (changed(from.recoveryModel, to.recoveryModel) && _has(to.recoveryModel)) {
          out.add('ALTER DATABASE $name SET RECOVERY ${to.recoveryModel}');
        }
        if (changed(from.owner, to.owner) && _has(to.owner)) {
          out.add('ALTER AUTHORIZATION ON DATABASE::$name TO ${q(to.owner!)}');
        }
      case DbFamily.mysql:
        if (changed(from.encoding, to.encoding) || changed(from.collation, to.collation)) {
          final sb = StringBuffer('ALTER DATABASE $name');
          if (_has(to.encoding)) sb.write(' CHARACTER SET ${to.encoding}');
          if (_has(to.collation)) sb.write(' COLLATE ${to.collation}');
          out.add(sb.toString());
        }
        if (changed(from.comment, to.comment) && dialect.isMariaDb) {
          out.add('ALTER DATABASE $name COMMENT ${lit(to.comment ?? '')}');
        }
      case DbFamily.snowflake:
        if (changed(from.retentionDays, to.retentionDays) && to.retentionDays != null) {
          out.add('ALTER DATABASE $name SET DATA_RETENTION_TIME_IN_DAYS = ${to.retentionDays}');
        }
        if (changed(from.comment, to.comment)) {
          out.add(
            _has(to.comment)
                ? 'ALTER DATABASE $name SET COMMENT = ${lit(to.comment!)}'
                : 'ALTER DATABASE $name UNSET COMMENT',
          );
        }
        if (from.transient != to.transient) {
          out.add(_note('Un database Snowflake non diventa transient dopo la creazione'));
        }
      default:
        break;
    }
    return out;
  }

  List<String> renameDatabase(String from, String to) {
    if (!caps.has(DesignFeature.renameDatabase)) {
      return [_note('Ridenominazione del database $from: ${caps.reason(DesignFeature.renameDatabase)}')];
    }
    return switch (family) {
      DbFamily.sqlServer => ['ALTER DATABASE ${q(from)} MODIFY NAME = ${q(to)}'],
      _ => ['ALTER DATABASE ${q(from)} RENAME TO ${q(to)}'],
    };
  }

  /// DROP DATABASE; [force] closes the other sessions first (PostgreSQL 13
  /// WITH (FORCE), SQL Server SINGLE_USER WITH ROLLBACK IMMEDIATE).
  List<String> dropDatabase(String name, {bool force = false}) {
    if (!caps.has(DesignFeature.createDatabase)) {
      return [_note('Eliminazione del database $name: ${caps.reason(DesignFeature.createDatabase)}')];
    }
    final n = q(name);
    switch (family) {
      case DbFamily.postgres:
        final v = dialect.version;
        final withForce = force && (v == null || v.atLeast(13));
        return [
          if (force && !withForce) _note('Chiusura delle sessioni attive: richiede PostgreSQL 13'),
          'DROP DATABASE $n${withForce ? ' WITH (FORCE)' : ''}',
        ];
      case DbFamily.sqlServer:
        return [if (force) 'ALTER DATABASE $n SET SINGLE_USER WITH ROLLBACK IMMEDIATE', 'DROP DATABASE $n'];
      default:
        return ['DROP DATABASE $n'];
    }
  }

  // -------------------------------------------------------------------------
  // Schemas
  // -------------------------------------------------------------------------

  List<String> createSchema(SchemaDef s) {
    if (!caps.has(DesignFeature.schemas)) return [_note('Schemi: ${caps.reason(DesignFeature.schemas)}')];
    final name = q(s.name);
    final auth = _has(s.owner) ? ' AUTHORIZATION ${q(s.owner!)}' : '';
    switch (family) {
      case DbFamily.snowflake:
        final sb = StringBuffer('CREATE ${s.transient ? 'TRANSIENT ' : ''}SCHEMA ${_schemaRef(s)}');
        if (s.retentionDays != null) sb.write(' DATA_RETENTION_TIME_IN_DAYS = ${s.retentionDays}');
        if (_has(s.comment)) sb.write(' COMMENT = ${lit(s.comment!)}');
        return [sb.toString()];
      case DbFamily.sqlServer:
        return ['CREATE SCHEMA $name$auth', if (_has(s.comment)) _mssqlSchemaComment(s.name, s.comment!, false)];
      default:
        return ['CREATE SCHEMA $name$auth', if (_has(s.comment)) 'COMMENT ON SCHEMA $name IS ${lit(s.comment!)}'];
    }
  }

  String _schemaRef(SchemaDef s) => s.catalog == null ? q(s.name) : '${q(s.catalog!)}.${q(s.name)}';

  String _mssqlSchemaComment(String schema, String text, bool update) =>
      "EXEC ${text.isEmpty ? 'sp_dropextendedproperty' : (update ? 'sp_updateextendedproperty' : 'sp_addextendedproperty')} "
      "@name = N'MS_Description', ${text.isEmpty ? '' : '@value = ${_n(text)}, '}"
      "@level0type = N'SCHEMA', @level0name = ${_n(schema)}";

  List<String> alterSchema(SchemaDef from, SchemaDef to) {
    final out = <String>[];
    var name = q(from.name);
    bool changed(Object? a, Object? b) => (a ?? '').toString() != (b ?? '').toString();
    if (from.name != to.name) {
      out.addAll(renameSchema(from, to.name));
      name = q(to.name);
    }
    switch (family) {
      case DbFamily.postgres:
        if (changed(from.owner, to.owner) && _has(to.owner)) out.add('ALTER SCHEMA $name OWNER TO ${q(to.owner!)}');
        if (changed(from.comment, to.comment)) {
          out.add('COMMENT ON SCHEMA $name IS ${_has(to.comment) ? lit(to.comment!) : 'NULL'}');
        }
      case DbFamily.sqlServer:
        if (changed(from.owner, to.owner) && _has(to.owner)) {
          out.add('ALTER AUTHORIZATION ON SCHEMA::$name TO ${q(to.owner!)}');
        }
        if (changed(from.comment, to.comment)) {
          out.add(_mssqlSchemaComment(to.name, to.comment ?? '', _has(from.comment)));
        }
      case DbFamily.db2:
        if (changed(from.comment, to.comment)) {
          out.add('COMMENT ON SCHEMA $name IS ${lit(to.comment ?? '')}');
        }
        if (changed(from.owner, to.owner)) {
          out.add(_note('Il proprietario di uno schema Db2 si cambia con TRANSFER OWNERSHIP'));
        }
      case DbFamily.snowflake:
        final ref = _schemaRef(to);
        if (changed(from.retentionDays, to.retentionDays) && to.retentionDays != null) {
          out.add('ALTER SCHEMA $ref SET DATA_RETENTION_TIME_IN_DAYS = ${to.retentionDays}');
        }
        if (changed(from.comment, to.comment)) {
          out.add(
            _has(to.comment)
                ? 'ALTER SCHEMA $ref SET COMMENT = ${lit(to.comment!)}'
                : 'ALTER SCHEMA $ref UNSET COMMENT',
          );
        }
      default:
        break;
    }
    return out;
  }

  List<String> renameSchema(SchemaDef s, String to) => switch (family) {
    DbFamily.postgres => ['ALTER SCHEMA ${q(s.name)} RENAME TO ${q(to)}'],
    DbFamily.snowflake => ['ALTER SCHEMA ${_schemaRef(s)} RENAME TO ${_schemaRef(s.copyWith(name: to))}'],
    DbFamily.sqlServer => [
      _note(
        'SQL Server non rinomina gli schemi: crea ${s.name} con il nuovo nome e sposta gli oggetti con ALTER SCHEMA … TRANSFER',
      ),
    ],
    _ => [_note('Ridenominazione dello schema ${s.name} con ${dialect.dbmsName}')],
  };

  /// DROP SCHEMA; [cascade] also drops the objects it contains.
  List<String> dropSchema(SchemaDef s, {bool cascade = false}) {
    if (!caps.has(DesignFeature.schemas)) return [_note('Schemi: ${caps.reason(DesignFeature.schemas)}')];
    switch (family) {
      case DbFamily.postgres:
        return ['DROP SCHEMA ${q(s.name)}${cascade ? ' CASCADE' : ''}'];
      case DbFamily.snowflake:
        return ['DROP SCHEMA ${_schemaRef(s)}${cascade ? ' CASCADE' : ' RESTRICT'}'];
      case DbFamily.db2:
        return [
          if (cascade) _note('Db2 elimina solo schemi vuoti: elimina prima gli oggetti'),
          'DROP SCHEMA ${q(s.name)} RESTRICT',
        ];
      case DbFamily.sqlServer:
        return [
          if (cascade) _note('SQL Server elimina solo schemi vuoti: elimina prima gli oggetti'),
          'DROP SCHEMA ${q(s.name)}',
        ];
      default:
        return ['DROP SCHEMA ${q(s.name)}'];
    }
  }

  /// DROP SCHEMA … CASCADE exists.
  bool get canDropSchemaCascade => family == DbFamily.postgres || family == DbFamily.snowflake;
}
