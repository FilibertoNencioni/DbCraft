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

  // -------------------------------------------------------------------------
  // Views
  // -------------------------------------------------------------------------

  /// Name of [v] in its statements. SQL Server refuses a database prefix
  /// in CREATE / ALTER / DROP VIEW: the script runs in that database instead
  /// ([scriptCatalog]).
  String viewRef(ViewDef v, {bool current = false}) =>
      dialect.qualified(family == DbFamily.sqlServer ? null : v.catalog, v.schema, current ? v.dbName : v.name);

  /// Database a script on objects of [catalog] must run in (SQL Server
  /// modules cannot be qualified with it); null elsewhere.
  String? scriptCatalog(String? catalog) => family == DbFamily.sqlServer ? catalog : null;

  String _query(ViewDef v) => v.definition.trim().replaceFirst(RegExp(r';\s*$'), '');

  /// CREATE VIEW (or CREATE OR REPLACE / OR ALTER with [replace], where the
  /// DBMS has it).
  List<String> createView(ViewDef v, {bool replace = false}) {
    if (v.materialized && !caps.has(DesignFeature.materializedViews)) {
      return [_note('Vista materializzata ${v.name}: ${caps.reason(DesignFeature.materializedViews)}')];
    }
    final ref = viewRef(v);
    final q = _query(v);
    final check = v.checkOption == ViewCheckOption.none || v.materialized ? null : v.checkOption;
    final orReplace = replace && caps.has(DesignFeature.replaceView);
    switch (family) {
      case DbFamily.postgres:
        final sb = StringBuffer(
          'CREATE ${orReplace && !v.materialized ? 'OR REPLACE ' : ''}${v.materialized ? 'MATERIALIZED ' : ''}VIEW $ref',
        );
        if (!v.materialized && v.securityBarrier) sb.write(' WITH (security_barrier = true)');
        sb.write(' AS\n$q');
        if (v.materialized && !v.withData) sb.write('\nWITH NO DATA');
        if (check != null) sb.write('\nWITH ${check.sql} CHECK OPTION');
        return [sb.toString(), if (_has(v.comment)) ...viewComment(v)];
      case DbFamily.sqlServer:
        return [
          'CREATE ${orReplace ? 'OR ALTER ' : ''}VIEW $ref${v.schemaBinding ? ' WITH SCHEMABINDING' : ''} AS\n$q'
              '${check != null ? '\nWITH CHECK OPTION' : ''}',
          if (_has(v.comment)) ...viewComment(v),
        ];
      case DbFamily.mysql:
        final sb = StringBuffer('CREATE ${orReplace ? 'OR REPLACE ' : ''}');
        if (_has(v.algorithm)) sb.write('ALGORITHM = ${v.algorithm} ');
        if (_has(v.sqlSecurity)) sb.write('SQL SECURITY ${v.sqlSecurity} ');
        sb.write('VIEW $ref AS\n$q');
        if (check != null) sb.write('\nWITH ${check.sql} CHECK OPTION');
        return [sb.toString()];
      case DbFamily.oracle:
        if (v.materialized) return ['CREATE MATERIALIZED VIEW $ref AS\n$q', if (_has(v.comment)) ...viewComment(v)];
        return [
          'CREATE ${orReplace ? 'OR REPLACE ' : ''}${v.force ? 'FORCE ' : ''}VIEW $ref AS\n$q'
              '${check != null ? '\nWITH CHECK OPTION' : ''}',
          if (_has(v.comment)) ...viewComment(v),
        ];
      case DbFamily.db2:
        return [
          'CREATE ${orReplace ? 'OR REPLACE ' : ''}VIEW $ref AS\n$q${check != null ? '\nWITH ${check.sql} CHECK OPTION' : ''}',
          if (_has(v.comment)) ...viewComment(v),
        ];
      case DbFamily.firebird:
        return [
          '${orReplace ? 'CREATE OR ALTER' : 'CREATE'} VIEW $ref AS\n$q${check != null ? '\nWITH CHECK OPTION' : ''}',
          if (_has(v.comment)) ...viewComment(v),
        ];
      case DbFamily.snowflake:
        final sb = StringBuffer(
          'CREATE ${orReplace ? 'OR REPLACE ' : ''}${v.secure ? 'SECURE ' : ''}${v.materialized ? 'MATERIALIZED ' : ''}VIEW $ref',
        );
        if (_has(v.comment)) sb.write(' COMMENT = ${lit(v.comment!)}');
        sb.write(' AS\n$q');
        return [sb.toString()];
      default:
        return ['CREATE VIEW $ref AS\n$q'];
    }
  }

  /// Comment of [v] (empty: removed).
  List<String> viewComment(ViewDef v) {
    final ref = viewRef(v);
    final text = v.comment ?? '';
    final value = text.isEmpty ? 'NULL' : lit(text);
    switch (family) {
      case DbFamily.postgres:
        return ['COMMENT ON ${v.materialized ? 'MATERIALIZED ' : ''}VIEW $ref IS $value'];
      case DbFamily.oracle:
        return ['COMMENT ON ${v.materialized ? 'MATERIALIZED VIEW' : 'TABLE'} $ref IS ${lit(text)}'];
      case DbFamily.db2:
        return ['COMMENT ON TABLE $ref IS ${lit(text)}'];
      case DbFamily.firebird:
        return ['COMMENT ON VIEW $ref IS $value'];
      case DbFamily.snowflake:
        return [text.isEmpty ? 'ALTER VIEW $ref UNSET COMMENT' : 'ALTER VIEW $ref SET COMMENT = ${lit(text)}'];
      case DbFamily.sqlServer:
        final proc = text.isEmpty ? 'sp_dropextendedproperty' : 'sp_addextendedproperty';
        return [
          "EXEC $proc @name = N'MS_Description', ${text.isEmpty ? '' : '@value = ${_n(text)}, '}"
              "@level0type = N'SCHEMA', @level0name = ${_n(v.schema ?? 'dbo')}, @level1type = N'VIEW', @level1name = ${_n(v.name)}",
        ];
      default:
        return const [];
    }
  }

  List<String> dropView(ViewDef v, {bool cascade = false}) {
    final ref = viewRef(v, current: true);
    switch (family) {
      case DbFamily.postgres:
        return ['DROP ${v.materialized ? 'MATERIALIZED ' : ''}VIEW $ref${cascade ? ' CASCADE' : ''}'];
      case DbFamily.oracle:
        return [
          v.materialized ? 'DROP MATERIALIZED VIEW $ref' : 'DROP VIEW $ref${cascade ? ' CASCADE CONSTRAINTS' : ''}',
        ];
      case DbFamily.snowflake:
        return ['DROP ${v.materialized ? 'MATERIALIZED ' : ''}VIEW $ref'];
      default:
        return ['DROP VIEW $ref'];
    }
  }

  /// RENAME where the DBMS has it, otherwise DROP + CREATE.
  List<String> renameView(ViewDef v, String to) {
    final ref = viewRef(v, current: true);
    final target = v.copyWith(name: to, originalName: null);
    switch (family) {
      case DbFamily.postgres:
        return ['ALTER ${v.materialized ? 'MATERIALIZED ' : ''}VIEW $ref RENAME TO ${q(to)}'];
      case DbFamily.mysql:
        return ['RENAME TABLE $ref TO ${viewRef(target)}'];
      case DbFamily.snowflake:
        return ['ALTER VIEW $ref RENAME TO ${viewRef(target)}'];
      case DbFamily.oracle when !v.materialized:
        return ['RENAME ${q(v.dbName)} TO ${q(to)}'];
      default:
        return [
          '-- ${dialect.dbmsName} non rinomina le viste: viene eliminata e creata di nuovo',
          ...dropView(v),
          ...createView(target),
        ];
    }
  }

  /// Statements that turn the view [from] (in the database) into [to].
  List<String> alterView(ViewDef from, ViewDef to) {
    final queryChanged = _query(from).replaceAll(RegExp(r'\s+'), ' ') != _query(to).replaceAll(RegExp(r'\s+'), ' ');
    final optionsChanged = !from.sameOptions(to);
    final renamed = from.name != to.name;
    final commentChanged = (from.comment ?? '') != (to.comment ?? '');
    if (!queryChanged && !optionsChanged && !renamed && !commentChanged) return const [];
    // Materialized views (and a switch of kind) are always recreated.
    final recreate =
        optionsChanged && (from.materialized != to.materialized || to.materialized) ||
        (queryChanged || optionsChanged) && (to.materialized || !caps.has(DesignFeature.replaceView));
    if (recreate) {
      return [
        '-- La vista ${from.name} viene eliminata e creata di nuovo: i permessi concessi su di essa vanno ripristinati',
        ...dropView(from),
        ...createView(to.copyWith(originalName: null)),
      ];
    }
    final out = <String>[];
    var current = to.copyWith(name: from.name, originalName: null);
    if (renamed) {
      final r = renameView(from, to.name);
      if (r.any((x) => x.startsWith('DROP'))) {
        // Recreated with the new definition right away.
        return [r.first, ...dropView(from), ...createView(to.copyWith(originalName: null))];
      }
      out.addAll(r);
      current = to.copyWith(originalName: null);
    }
    if (queryChanged || optionsChanged) {
      // OR REPLACE keeps grants and dependent objects.
      out.addAll(
        createView(current, replace: true).where((x) => !x.startsWith('COMMENT') && !x.startsWith('EXEC sp_add')),
      );
    }
    if (commentChanged && family != DbFamily.mysql) out.addAll(viewComment(current));
    return out;
  }

  List<String> refreshMaterializedView(ViewDef v, {bool concurrently = false}) {
    final ref = viewRef(v, current: true);
    return switch (family) {
      DbFamily.postgres => ['REFRESH MATERIALIZED VIEW ${concurrently ? 'CONCURRENTLY ' : ''}$ref'],
      DbFamily.oracle => [
        "BEGIN DBMS_MVIEW.REFRESH(${lit([if (v.schema != null) v.schema!, v.dbName].join('.'))}); END;",
      ],
      DbFamily.snowflake => [_note('Snowflake aggiorna da solo le viste materializzate')],
      _ => [_note('Aggiornamento della vista materializzata ${v.name}')],
    };
  }

  // -------------------------------------------------------------------------
  // Sequences
  // -------------------------------------------------------------------------

  String seqRef(SequenceDef s, {String? name}) =>
      dialect.qualified(family == DbFamily.sqlServer ? null : s.catalog, s.schema, name ?? s.name);

  /// Options of CREATE / ALTER SEQUENCE ([create]: START WITH too).
  List<String> _seqOptions(SequenceDef s, {required bool create, SequenceDef? from}) {
    // Creating: only the options set; altering: only the changed ones.
    bool changed(Object? a, Object? b) => from == null ? a != null && a != false : a != b;
    final o = <String>[];
    switch (family) {
      case DbFamily.snowflake:
        if (create && s.start != null) o.add('START = ${s.start}');
        if (s.increment != null && changed(s.increment, from?.increment)) o.add('INCREMENT = ${s.increment}');
        return o;
      case DbFamily.firebird:
        if (create && s.start != null) o.add('START WITH ${s.start}');
        if (s.increment != null && changed(s.increment, from?.increment)) o.add('INCREMENT BY ${s.increment}');
        return o;
      default:
        break;
    }
    final oracle = family == DbFamily.oracle;
    if (create && _has(s.dataType) && family != DbFamily.oracle && family != DbFamily.mysql) o.add('AS ${s.dataType}');
    if (create && s.start != null) o.add('START WITH ${s.start}');
    if (s.increment != null && changed(s.increment, from?.increment)) o.add('INCREMENT BY ${s.increment}');
    if (changed(s.minValue, from?.minValue)) {
      o.add(
        s.minValue != null
            ? 'MINVALUE ${s.minValue}'
            : (oracle || family == DbFamily.mysql ? 'NOMINVALUE' : 'NO MINVALUE'),
      );
    }
    if (changed(s.maxValue, from?.maxValue)) {
      o.add(
        s.maxValue != null
            ? 'MAXVALUE ${s.maxValue}'
            : (oracle || family == DbFamily.mysql ? 'NOMAXVALUE' : 'NO MAXVALUE'),
      );
    }
    if (changed(s.cache, from?.cache)) {
      final none = s.cache == null || s.cache! <= 1;
      if (none) {
        o.add(oracle || family == DbFamily.mysql ? 'NOCACHE' : (family == DbFamily.postgres ? 'CACHE 1' : 'NO CACHE'));
      } else {
        o.add('CACHE ${s.cache}');
      }
    }
    if (changed(s.cycle, from?.cycle)) {
      o.add(s.cycle ? 'CYCLE' : (oracle || family == DbFamily.mysql ? 'NOCYCLE' : 'NO CYCLE'));
    }
    if (family == DbFamily.postgres && (create ? _has(s.ownedBy) : changed(s.ownedBy, from?.ownedBy))) {
      o.add('OWNED BY ${_has(s.ownedBy) ? s.ownedBy : 'NONE'}');
    }
    return o;
  }

  List<String> createSequence(SequenceDef s) {
    if (!caps.has(DesignFeature.sequences)) return [_note('Sequenze: ${caps.reason(DesignFeature.sequences)}')];
    final opts = _seqOptions(s, create: true);
    return [
      'CREATE SEQUENCE ${seqRef(s)}${opts.isEmpty ? '' : ' ${opts.join(' ')}'}',
      if (_has(s.comment) && (family == DbFamily.postgres || family == DbFamily.oracle || family == DbFamily.db2))
        'COMMENT ON SEQUENCE ${seqRef(s)} IS ${lit(s.comment!)}',
    ];
  }

  /// Statements that turn the sequence [from] into [to] (START WITH is the
  /// value of a new sequence: use [restartSequence] for the current one).
  List<String> alterSequence(SequenceDef from, SequenceDef to) {
    final out = <String>[];
    if (from.name != to.name) out.addAll(renameSequence(from, to.name));
    final s = to.copyWith(name: to.name);
    if (family == DbFamily.firebird &&
        (from.minValue != to.minValue || from.maxValue != to.maxValue || from.cycle != to.cycle)) {
      out.add(_note('Firebird non ha limiti né ciclo per le sequenze'));
    }
    final opts = _seqOptions(s, create: false, from: from);
    if (opts.isNotEmpty) {
      out.add(
        family == DbFamily.snowflake
            ? 'ALTER SEQUENCE ${seqRef(s)} SET ${opts.join(' ')}'
            : 'ALTER SEQUENCE ${seqRef(s)} ${opts.join(' ')}',
      );
    }
    if ((from.comment ?? '') != (to.comment ?? '') &&
        (family == DbFamily.postgres || family == DbFamily.oracle || family == DbFamily.db2)) {
      out.add(
        'COMMENT ON SEQUENCE ${seqRef(s)} IS ${_has(to.comment) ? lit(to.comment!) : (family == DbFamily.postgres ? 'NULL' : "''")}',
      );
    }
    return out;
  }

  /// The next value handed out becomes [value].
  List<String> restartSequence(SequenceDef s, int value) {
    final ref = seqRef(s);
    switch (family) {
      case DbFamily.oracle:
        final v = dialect.version;
        if (v != null && !v.atLeast(18)) return [_note('Riavvio della sequenza: richiede Oracle 18c')];
        return ['ALTER SEQUENCE $ref RESTART START WITH $value'];
      case DbFamily.snowflake:
        return [_note('Snowflake non riavvia le sequenze: creane una nuova con START = $value')];
      default:
        return ['ALTER SEQUENCE $ref RESTART WITH $value'];
    }
  }

  List<String> renameSequence(SequenceDef s, String to) => switch (family) {
    DbFamily.postgres || DbFamily.snowflake => [
      'ALTER SEQUENCE ${seqRef(s)} RENAME TO ${family == DbFamily.snowflake ? seqRef(s, name: to) : q(to)}',
    ],
    DbFamily.sqlServer => ["EXEC sp_rename ${_n(dialect.qualified(null, s.schema, s.name))}, ${_n(to)}, N'OBJECT'"],
    DbFamily.mysql => ['RENAME TABLE ${seqRef(s)} TO ${seqRef(s, name: to)}'],
    DbFamily.oracle => ['RENAME ${q(s.name)} TO ${q(to)}'],
    _ => [_note('Ridenominazione della sequenza ${s.name} con ${dialect.dbmsName}')],
  };

  List<String> dropSequence(SequenceDef s) => ['DROP SEQUENCE ${seqRef(s)}'];

  /// DROP SCHEMA … CASCADE exists.
  bool get canDropSchemaCascade => family == DbFamily.postgres || family == DbFamily.snowflake;
}
