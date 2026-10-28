// DDL of the DBMS specific objects (see model/extra_defs.dart). Same
// conventions as DdlBuilder: statements without terminators, comment-only
// entries for notes and for what the DBMS cannot do ("… (non supportato)").

import '../../../services/sql_dialect.dart';
import '../capabilities.dart';
import '../model/extra_defs.dart';
import '../model/nosql_defs.dart';
import 'code_ddl.dart';
import 'nosql_ddl.dart';

class ExtraDdl {
  ExtraDdl(this.dialect) : caps = DesignCapabilities.of(dialect);

  final SqlDialect dialect;
  final DesignCapabilities caps;

  DbFamily get family => dialect.family;
  String q(String name) => dialect.quoteIdent(name);
  String lit(String s) => dialect.stringLiteral(s);
  bool _has(String? s) => s != null && s.trim().isNotEmpty;
  String _note(String text) => '-- $text (non supportato)';
  bool _changed(Object? a, Object? b) => (a ?? '') != (b ?? '');

  List<String>? _unsupported(DesignFeature f, String what) => caps.has(f) ? null : [_note('$what: ${caps.reason(f)}')];

  /// Name of an object of a schema (SQL Server: without the database, the
  /// script runs in it; PostgreSQL: the current database).
  String ref(String? catalog, String? schema, String name) =>
      dialect.qualified(family == DbFamily.sqlServer || family == DbFamily.postgres ? null : catalog, schema, name);

  // -------------------------------------------------------------------------
  // Extensions (PostgreSQL)
  // -------------------------------------------------------------------------

  List<String> createExtension(ExtensionDef e, {bool cascade = false}) {
    final no = _unsupported(DesignFeature.extensions, 'Estensione ${e.name}');
    if (no != null) return no;
    final sb = StringBuffer('CREATE EXTENSION IF NOT EXISTS ${q(e.name)}');
    if (_has(e.schema)) sb.write(' WITH SCHEMA ${q(e.schema!)}');
    if (_has(e.version)) sb.write(' VERSION ${lit(e.version!)}');
    if (cascade) sb.write(' CASCADE');
    return [sb.toString(), if (_has(e.comment)) 'COMMENT ON EXTENSION ${q(e.name)} IS ${lit(e.comment!)}'];
  }

  /// Schema, version and comment changes ([to] version null: the default).
  List<String> alterExtension(ExtensionDef from, ExtensionDef to) {
    final n = q(from.name);
    return [
      if (_has(to.schema) && _changed(from.schema, to.schema)) 'ALTER EXTENSION $n SET SCHEMA ${q(to.schema!)}',
      if (_has(to.version) && _changed(from.version, to.version)) 'ALTER EXTENSION $n UPDATE TO ${lit(to.version!)}',
      if (_changed(from.comment, to.comment))
        'COMMENT ON EXTENSION $n IS ${_has(to.comment) ? lit(to.comment!) : 'NULL'}',
    ];
  }

  /// Updates [e] to its default version.
  List<String> updateExtension(ExtensionDef e) => ['ALTER EXTENSION ${q(e.name)} UPDATE'];

  List<String> dropExtension(ExtensionDef e, {bool cascade = false}) => [
    'DROP EXTENSION ${q(e.name)}${cascade ? ' CASCADE' : ''}',
  ];

  // -------------------------------------------------------------------------
  // Enum types (PostgreSQL)
  // -------------------------------------------------------------------------

  List<String> createEnum(EnumTypeDef t) {
    final no = _unsupported(DesignFeature.enumTypes, 'Tipo ${t.name}');
    if (no != null) return no;
    final n = ref(t.catalog, t.schema, t.name);
    return [
      'CREATE TYPE $n AS ENUM (${[for (final v in t.values) lit(v)].join(', ')})',
      if (_has(t.comment)) 'COMMENT ON TYPE $n IS ${lit(t.comment!)}',
    ];
  }

  /// PostgreSQL adds and renames values (in place) but cannot remove or
  /// reorder them. ADD VALUE cannot run in a transaction before 12: run
  /// these scripts outside one.
  List<String> alterEnum(EnumTypeDef from, EnumTypeDef to) {
    final out = <String>[];
    var n = ref(from.catalog, from.schema, from.name);
    if (from.name != to.name) {
      out.add('ALTER TYPE $n RENAME TO ${q(to.name)}');
      n = ref(to.catalog, to.schema, to.name);
    }
    final old = from.values, now = to.values;
    if (old.length == now.length && !now.every(old.contains)) {
      // Same count: the changed positions are renames.
      for (var i = 0; i < old.length; i++) {
        if (old[i] != now[i]) out.add('ALTER TYPE $n RENAME VALUE ${lit(old[i])} TO ${lit(now[i])}');
      }
    } else {
      final removed = [
        for (final v in old)
          if (!now.contains(v)) v,
      ];
      if (removed.isNotEmpty) out.add(_note('Rimozione dei valori ${removed.join(', ')} da un enum PostgreSQL'));
      final kept = [
        for (final v in now)
          if (old.contains(v)) v,
      ];
      final keptInOrder = [
        for (final v in old)
          if (now.contains(v)) v,
      ];
      if (kept.join('\u0000') != keptInOrder.join('\u0000')) {
        out.add(_note('Riordino dei valori di un enum PostgreSQL'));
      }
      final present = {...old};
      for (var i = 0; i < now.length; i++) {
        final v = now[i];
        if (present.contains(v)) continue;
        final before = [for (var j = i - 1; j >= 0; j--) now[j]].where(present.contains).firstOrNull;
        final after = [for (var j = i + 1; j < now.length; j++) now[j]].where(present.contains).firstOrNull;
        out.add(
          'ALTER TYPE $n ADD VALUE ${lit(v)}'
          '${before != null ? ' AFTER ${lit(before)}' : (after != null ? ' BEFORE ${lit(after)}' : '')}',
        );
        present.add(v);
      }
    }
    if (_changed(from.comment, to.comment)) {
      out.add('COMMENT ON TYPE $n IS ${_has(to.comment) ? lit(to.comment!) : 'NULL'}');
    }
    return out;
  }

  List<String> dropEnum(EnumTypeDef t, {bool cascade = false}) => [
    'DROP TYPE ${ref(t.catalog, t.schema, t.name)}${cascade ? ' CASCADE' : ''}',
  ];

  // -------------------------------------------------------------------------
  // Domains (PostgreSQL, Firebird)
  // -------------------------------------------------------------------------

  String _domain(DomainDef d) => family == DbFamily.firebird ? q(d.name) : ref(d.catalog, d.schema, d.name);

  String _check(DomainCheck c) =>
      '${_has(c.name) && family != DbFamily.firebird ? 'CONSTRAINT ${q(c.name!)} ' : ''}CHECK (${c.expression})';

  List<String> createDomain(DomainDef d) {
    final no = _unsupported(DesignFeature.domains, 'Dominio ${d.name}');
    if (no != null) return no;
    final n = _domain(d);
    final sb = StringBuffer('CREATE DOMAIN $n AS ${d.baseType}');
    if (family == DbFamily.firebird) {
      if (_has(d.defaultValue)) sb.write(' DEFAULT ${d.defaultValue}');
      if (d.notNull) sb.write(' NOT NULL');
      if (d.checks.isNotEmpty) sb.write(' ${_check(d.checks.first)}');
      if (_has(d.collation)) sb.write(' COLLATE ${d.collation}');
    } else {
      if (_has(d.collation)) sb.write(' COLLATE ${q(d.collation!)}');
      if (_has(d.defaultValue)) sb.write(' DEFAULT ${d.defaultValue}');
      if (d.notNull) sb.write(' NOT NULL');
      for (final c in d.checks) {
        sb.write(' ${_check(c)}');
      }
    }
    return [
      sb.toString(),
      if (family == DbFamily.firebird && d.checks.length > 1) _note('Firebird ammette un solo CHECK per dominio'),
      if (_has(d.comment)) 'COMMENT ON DOMAIN $n IS ${lit(d.comment!)}',
    ];
  }

  List<String> alterDomain(DomainDef from, DomainDef to) {
    final fb = family == DbFamily.firebird;
    final out = <String>[];
    var n = _domain(from);
    if (from.name != to.name) {
      out.add(fb ? 'ALTER DOMAIN $n TO ${q(to.name)}' : 'ALTER DOMAIN $n RENAME TO ${q(to.name)}');
      n = _domain(to);
    }
    if (from.baseType.toLowerCase() != to.baseType.toLowerCase()) {
      out.add(fb ? 'ALTER DOMAIN $n TYPE ${to.baseType}' : _note('Cambio del tipo di un dominio PostgreSQL'));
    }
    if (_changed(from.defaultValue, to.defaultValue)) {
      out.add(
        _has(to.defaultValue) ? 'ALTER DOMAIN $n SET DEFAULT ${to.defaultValue}' : 'ALTER DOMAIN $n DROP DEFAULT',
      );
    }
    if (from.notNull != to.notNull) {
      out.add(
        fb && !(dialect.version?.atLeast(3) ?? true)
            ? _note('NOT NULL di un dominio in Firebird 2.5')
            : 'ALTER DOMAIN $n ${to.notNull ? 'SET' : 'DROP'} NOT NULL',
      );
    }
    if (fb) {
      final a = from.checks.firstOrNull?.expression, b = to.checks.firstOrNull?.expression;
      if (_changed(a, b)) {
        if (a != null) out.add('ALTER DOMAIN $n DROP CONSTRAINT');
        if (b != null) out.add('ALTER DOMAIN $n ADD CHECK ($b)');
      }
    } else {
      String key(DomainCheck c) => c.name?.toLowerCase() ?? c.expression;
      final before = {for (final c in from.checks) key(c): c};
      final after = {for (final c in to.checks) key(c): c};
      for (final e in before.entries) {
        final now = after[e.key];
        if (now == null || now.expression != e.value.expression) {
          out.add(
            e.value.name == null
                ? _note('Eliminazione di un CHECK senza nome del dominio')
                : 'ALTER DOMAIN $n DROP CONSTRAINT ${q(e.value.name!)}',
          );
        }
      }
      for (final e in after.entries) {
        final old = before[e.key];
        if (old == null || old.expression != e.value.expression) out.add('ALTER DOMAIN $n ADD ${_check(e.value)}');
      }
    }
    if (_changed(from.collation, to.collation)) out.add(_note('Cambio della collation di un dominio'));
    if (_changed(from.comment, to.comment)) {
      out.add('COMMENT ON DOMAIN $n IS ${_has(to.comment) ? lit(to.comment!) : 'NULL'}');
    }
    return out;
  }

  List<String> dropDomain(DomainDef d, {bool cascade = false}) => [
    'DROP DOMAIN ${_domain(d)}${cascade && family == DbFamily.postgres ? ' CASCADE' : ''}',
  ];

  // -------------------------------------------------------------------------
  // Row level security (PostgreSQL)
  // -------------------------------------------------------------------------

  String _table(String? catalog, String? schema, String table) => ref(catalog, schema, table);

  String _policyClauses(PolicyDef p, {bool create = true, PolicyDef? from}) {
    final parts = <String>[];
    if (create && !p.permissive) parts.add('AS RESTRICTIVE');
    if (create && p.command != PolicyCommand.all) parts.add('FOR ${p.command.sql}');
    final roles = p.roles.isEmpty ? 'PUBLIC' : [for (final r in p.roles) q(r)].join(', ');
    if (create ? p.roles.isNotEmpty : from!.roles.join(',') != p.roles.join(',')) parts.add('TO $roles');
    if (p.command.hasUsing && _has(p.using) && (create || _changed(from!.using, p.using))) {
      parts.add('USING (${p.using})');
    }
    if (p.command.hasCheck && _has(p.withCheck) && (create || _changed(from!.withCheck, p.withCheck))) {
      parts.add('WITH CHECK (${p.withCheck})');
    }
    return parts.isEmpty ? '' : ' ${parts.join(' ')}';
  }

  List<String> createPolicy(PolicyDef p) {
    final no = _unsupported(DesignFeature.rowSecurity, 'Policy ${p.name}');
    if (no != null) return no;
    return ['CREATE POLICY ${q(p.name)} ON ${_table(p.catalog, p.schema, p.table)}${_policyClauses(p)}'];
  }

  /// Command and kind cannot change, nor can USING / WITH CHECK be removed:
  /// the policy is recreated.
  List<String> alterPolicy(PolicyDef from, PolicyDef to) {
    final t = _table(to.catalog, to.schema, to.table);
    final recreate =
        from.command != to.command ||
        from.permissive != to.permissive ||
        (_has(from.using) && !_has(to.using)) ||
        (_has(from.withCheck) && !_has(to.withCheck));
    if (recreate) return [...dropPolicy(from), ...createPolicy(to)];
    final out = <String>[];
    if (from.name != to.name) out.add('ALTER POLICY ${q(from.name)} ON $t RENAME TO ${q(to.name)}');
    final clauses = _policyClauses(to, create: false, from: from);
    if (clauses.isNotEmpty) out.add('ALTER POLICY ${q(to.name)} ON $t$clauses');
    return out;
  }

  List<String> dropPolicy(PolicyDef p) => ['DROP POLICY ${q(p.name)} ON ${_table(p.catalog, p.schema, p.table)}'];

  /// Turns row level security of a table on or off; [forced] also applies
  /// it to the owner.
  List<String> setRowSecurity(String? catalog, String? schema, String table, RowSecurity from, RowSecurity to) {
    final no = _unsupported(DesignFeature.rowSecurity, 'Sicurezza a livello di riga');
    if (no != null) return no;
    final t = _table(catalog, schema, table);
    return [
      if (from.enabled != to.enabled) 'ALTER TABLE $t ${to.enabled ? 'ENABLE' : 'DISABLE'} ROW LEVEL SECURITY',
      if (from.forced != to.forced) 'ALTER TABLE $t ${to.forced ? 'FORCE' : 'NO FORCE'} ROW LEVEL SECURITY',
    ];
  }

  // -------------------------------------------------------------------------
  // Exclusion constraints (PostgreSQL)
  // -------------------------------------------------------------------------

  String exclusionClause(ExclusionDef x) {
    final sb = StringBuffer('EXCLUDE USING ${x.method} (');
    sb.write([for (final e in x.elements) '${e.expression} WITH ${e.operator}'].join(', '));
    sb.write(')');
    if (_has(x.where)) sb.write(' WHERE (${x.where})');
    if (x.deferrable) sb.write(' DEFERRABLE${x.initiallyDeferred ? ' INITIALLY DEFERRED' : ''}');
    return sb.toString();
  }

  List<String> addExclusion(ExclusionDef x) {
    final no = _unsupported(DesignFeature.exclusionConstraints, 'Vincolo di esclusione ${x.name}');
    if (no != null) return no;
    return ['ALTER TABLE ${_table(x.catalog, x.schema, x.table)} ADD CONSTRAINT ${q(x.name)} ${exclusionClause(x)}'];
  }

  List<String> dropExclusion(ExclusionDef x) => [
    'ALTER TABLE ${_table(x.catalog, x.schema, x.table)} DROP CONSTRAINT ${q(x.name)}',
  ];

  List<String> alterExclusion(ExclusionDef from, ExclusionDef to) {
    if (exclusionClause(from) != exclusionClause(to)) return [...dropExclusion(from), ...addExclusion(to)];
    if (from.name == to.name) return const [];
    return [
      'ALTER TABLE ${_table(to.catalog, to.schema, to.table)} RENAME CONSTRAINT ${q(from.name)} TO ${q(to.name)}',
    ];
  }

  // -------------------------------------------------------------------------
  // Synonyms (SQL Server, Oracle)
  // -------------------------------------------------------------------------

  String _synonym(SynonymDef s) =>
      s.isPublic ? q(s.name) : dialect.qualified(family == DbFamily.sqlServer ? null : s.catalog, s.schema, s.name);

  String _synonymTarget(SynonymDef s) {
    final t = dialect.qualified(s.targetCatalog, s.targetSchema, s.targetObject);
    return _has(s.dbLink) ? '$t@${s.dbLink}' : t;
  }

  List<String> createSynonym(SynonymDef s, {bool replace = false}) {
    final no = _unsupported(DesignFeature.synonyms, 'Sinonimo ${s.name}');
    if (no != null) return no;
    if (family == DbFamily.oracle) {
      return [
        'CREATE ${replace ? 'OR REPLACE ' : ''}${s.isPublic ? 'PUBLIC ' : ''}SYNONYM ${_synonym(s)} FOR ${_synonymTarget(s)}',
      ];
    }
    return ['CREATE SYNONYM ${_synonym(s)} FOR ${_synonymTarget(s)}'];
  }

  /// Synonyms are not altered: Oracle replaces them, SQL Server drops and
  /// creates them again.
  List<String> alterSynonym(SynonymDef from, SynonymDef to) {
    if (_synonym(from) == _synonym(to) && _synonymTarget(from) == _synonymTarget(to)) return const [];
    if (family == DbFamily.oracle && from.name == to.name && from.isPublic == to.isPublic) {
      return createSynonym(to, replace: true);
    }
    return [...dropSynonym(from), ...createSynonym(to)];
  }

  List<String> dropSynonym(SynonymDef s) => ['DROP ${s.isPublic ? 'PUBLIC ' : ''}SYNONYM ${_synonym(s)}'];

  // -------------------------------------------------------------------------
  // Packages (Oracle)
  // -------------------------------------------------------------------------

  String packageRef(String? schema, String name) => dialect.qualified(null, schema, name);

  PackageSource packageTemplate(String? schema, String name) {
    final n = packageRef(schema, name);
    return PackageSource(
      'CREATE OR REPLACE PACKAGE $n AS\n  FUNCTION versione RETURN VARCHAR2;\nEND ${q(name)};',
      'CREATE OR REPLACE PACKAGE BODY $n AS\n  FUNCTION versione RETURN VARCHAR2 IS\n  BEGIN\n'
          "    RETURN '1.0';\n  END versione;\nEND ${q(name)};",
    );
  }

  /// Specification then body ([hadBody]: an emptied body is dropped).
  List<String> savePackage(String? schema, String name, PackageSource src, {bool hadBody = false}) {
    final no = _unsupported(DesignFeature.packages, 'Package $name');
    if (no != null) return no;
    final code = CodeDdl(dialect);
    return [
      ...code.statementsOf(code.withReplace(src.spec, 'PACKAGE')),
      if (src.body.trim().isNotEmpty)
        ...code.statementsOf(code.withReplace(src.body, 'PACKAGE BODY'))
      else if (hadBody)
        'DROP PACKAGE BODY ${packageRef(schema, name)}',
    ];
  }

  List<String> dropPackage(PackageDef p) => ['DROP PACKAGE ${packageRef(p.schema, p.name)}'];

  // -------------------------------------------------------------------------
  // Events (MySQL, MariaDB)
  // -------------------------------------------------------------------------

  String _event(String? catalog, String name) => dialect.qualified(catalog, null, name);

  String _schedule(EventDef e) {
    if (!e.recurring) return 'AT ${lit(e.at!)}';
    final sb = StringBuffer('EVERY ${e.every ?? 1} ${e.unit}');
    if (_has(e.starts)) sb.write(' STARTS ${lit(e.starts!)}');
    if (_has(e.ends)) sb.write(' ENDS ${lit(e.ends!)}');
    return sb.toString();
  }

  String _status(EventStatus s) => switch (s) {
    EventStatus.enabled => 'ENABLE',
    EventStatus.disabled => 'DISABLE',
    EventStatus.replicaDisabled => dialect.isMariaDb ? 'DISABLE ON SLAVE' : 'DISABLE ON REPLICA',
  };

  String _body(String body) => body.trim().replaceFirst(RegExp(r';\s*$'), '');

  List<String> createEvent(EventDef e) {
    final no = _unsupported(DesignFeature.events, 'Evento ${e.name}');
    if (no != null) return no;
    final sb = StringBuffer('CREATE EVENT ${_event(e.catalog, e.name)} ON SCHEDULE ${_schedule(e)}');
    if (e.preserve) sb.write(' ON COMPLETION PRESERVE');
    if (e.status != EventStatus.enabled) sb.write(' ${_status(e.status)}');
    if (_has(e.comment)) sb.write(' COMMENT ${lit(e.comment!)}');
    sb.write(' DO ${_body(e.body)}');
    return [sb.toString()];
  }

  List<String> alterEvent(EventDef from, EventDef to) {
    final parts = <String>[
      if (!from.sameSchedule(to)) 'ON SCHEDULE ${_schedule(to)}',
      if (from.preserve != to.preserve) 'ON COMPLETION ${to.preserve ? '' : 'NOT '}PRESERVE',
      if (from.name != to.name) 'RENAME TO ${_event(to.catalog, to.name)}',
      if (from.status != to.status) _status(to.status),
      if (_changed(from.comment, to.comment)) 'COMMENT ${lit(to.comment ?? '')}',
      if (_body(from.body) != _body(to.body)) 'DO ${_body(to.body)}',
    ];
    if (parts.isEmpty) return const [];
    return ['ALTER EVENT ${_event(from.catalog, from.name)} ${parts.join(' ')}'];
  }

  List<String> dropEvent(EventDef e) => ['DROP EVENT ${_event(e.catalog, e.name)}'];

  // -------------------------------------------------------------------------
  // Snowflake: warehouses, stages, file formats
  // -------------------------------------------------------------------------

  List<String> _warehouseSet(WarehouseDef w, WarehouseDef? from) {
    bool want(Object? now, Object? before) => now != null && (from == null || now != before);
    return [
      if (want(w.size, from?.size)) 'WAREHOUSE_SIZE = ${w.size}',
      if (from == null && _has(w.type)) 'WAREHOUSE_TYPE = ${lit(w.type!)}',
      if (want(w.autoSuspend, from?.autoSuspend)) 'AUTO_SUSPEND = ${w.autoSuspend}',
      if (from == null ? !w.autoResume : w.autoResume != from.autoResume)
        'AUTO_RESUME = ${w.autoResume ? 'TRUE' : 'FALSE'}',
      if (want(w.minClusters, from?.minClusters)) 'MIN_CLUSTER_COUNT = ${w.minClusters}',
      if (want(w.maxClusters, from?.maxClusters)) 'MAX_CLUSTER_COUNT = ${w.maxClusters}',
      if (want(w.scalingPolicy, from?.scalingPolicy)) 'SCALING_POLICY = ${w.scalingPolicy}',
      if (from == null && w.initiallySuspended) 'INITIALLY_SUSPENDED = TRUE',
      if (_has(w.comment) && (from == null || _changed(from.comment, w.comment))) 'COMMENT = ${lit(w.comment!)}',
    ];
  }

  List<String> createWarehouse(WarehouseDef w) {
    final no = _unsupported(DesignFeature.warehouses, 'Warehouse ${w.name}');
    if (no != null) return no;
    final set = _warehouseSet(w, null);
    return ['CREATE WAREHOUSE ${q(w.name)}${set.isEmpty ? '' : ' WITH ${set.join(' ')}'}'];
  }

  List<String> alterWarehouse(WarehouseDef from, WarehouseDef to) {
    final n = q(to.name);
    final set = _warehouseSet(to, from);
    return [
      if (from.name != to.name) 'ALTER WAREHOUSE ${q(from.name)} RENAME TO $n',
      if (set.isNotEmpty) 'ALTER WAREHOUSE $n SET ${set.join(' ')}',
      if (_has(from.comment) && !_has(to.comment)) 'ALTER WAREHOUSE $n UNSET COMMENT',
      if (from.type != null && to.type != null && from.type != to.type) _note('Cambio del tipo di un warehouse'),
    ];
  }

  List<String> suspendWarehouse(WarehouseDef w, {required bool suspend}) => [
    'ALTER WAREHOUSE ${q(w.name)} ${suspend ? 'SUSPEND' : 'RESUME IF SUSPENDED'}',
  ];

  List<String> dropWarehouse(WarehouseDef w) => ['DROP WAREHOUSE ${q(w.name)}'];

  String _sfRef(String? catalog, String? schema, String name) => dialect.qualified(catalog, schema, name);

  List<String> _stageSet(StageDef s, StageDef? from) {
    bool want(String? now, String? before) => _has(now) && (from == null || _changed(now, before));
    return [
      if (want(s.url, from?.url)) 'URL = ${lit(s.url!)}',
      if (want(s.storageIntegration, from?.storageIntegration)) 'STORAGE_INTEGRATION = ${q(s.storageIntegration!)}',
      if (want(s.fileFormat, from?.fileFormat)) 'FILE_FORMAT = (FORMAT_NAME = ${lit(s.fileFormat!)})',
      if (want(s.comment, from?.comment)) 'COMMENT = ${lit(s.comment!)}',
    ];
  }

  List<String> createStage(StageDef s) {
    final no = _unsupported(DesignFeature.stages, 'Stage ${s.name}');
    if (no != null) return no;
    final set = _stageSet(s, null);
    return ['CREATE STAGE ${_sfRef(s.catalog, s.schema, s.name)}${set.isEmpty ? '' : ' ${set.join(' ')}'}'];
  }

  List<String> alterStage(StageDef from, StageDef to) {
    final n = _sfRef(to.catalog, to.schema, to.name);
    final set = _stageSet(to, from);
    return [
      if (from.external != to.external) _note('Uno stage interno non diventa esterno (e viceversa)'),
      if (from.name != to.name) 'ALTER STAGE ${_sfRef(from.catalog, from.schema, from.name)} RENAME TO $n',
      if (set.isNotEmpty && from.external == to.external) 'ALTER STAGE $n SET ${set.join(' ')}',
    ];
  }

  List<String> dropStage(StageDef s) => ['DROP STAGE ${_sfRef(s.catalog, s.schema, s.name)}'];

  /// An option value as SQL: quoted text, TRUE / FALSE, numbers and choices
  /// as typed.
  String optionValue(FileFormatOption o, String v) => switch (o.kind) {
    FileOptionKind.text => lit(v),
    FileOptionKind.boolean => v.toUpperCase() == 'TRUE' ? 'TRUE' : 'FALSE',
    _ => v,
  };

  List<String> _formatOptions(FileFormatDef f, FileFormatDef? from) => [
    for (final o in fileFormatOptions(f.type))
      if (f.options[o.key] != null && (from == null || from.options[o.key] != f.options[o.key]))
        '${o.key} = ${optionValue(o, f.options[o.key]!)}',
  ];

  List<String> createFileFormat(FileFormatDef f) {
    final no = _unsupported(DesignFeature.fileFormats, 'Formato di file ${f.name}');
    if (no != null) return no;
    final opts = _formatOptions(f, null);
    return [
      'CREATE FILE FORMAT ${_sfRef(f.catalog, f.schema, f.name)} TYPE = ${f.type}'
          '${opts.isEmpty ? '' : ' ${opts.join(' ')}'}${_has(f.comment) ? ' COMMENT = ${lit(f.comment!)}' : ''}',
    ];
  }

  List<String> alterFileFormat(FileFormatDef from, FileFormatDef to) {
    if (from.type != to.type) return [...dropFileFormat(from), ...createFileFormat(to)];
    final n = _sfRef(to.catalog, to.schema, to.name);
    final set = [
      ..._formatOptions(to, from),
      if (_has(to.comment) && _changed(from.comment, to.comment)) 'COMMENT = ${lit(to.comment!)}',
    ];
    final unset = [
      for (final o in fileFormatOptions(to.type))
        if (from.options[o.key] != null && to.options[o.key] == null) o.key,
      if (_has(from.comment) && !_has(to.comment)) 'COMMENT',
    ];
    return [
      if (from.name != to.name) 'ALTER FILE FORMAT ${_sfRef(from.catalog, from.schema, from.name)} RENAME TO $n',
      if (set.isNotEmpty) 'ALTER FILE FORMAT $n SET ${set.join(' ')}',
      if (unset.isNotEmpty) 'ALTER FILE FORMAT $n UNSET ${unset.join(', ')}',
    ];
  }

  List<String> dropFileFormat(FileFormatDef f) => ['DROP FILE FORMAT ${_sfRef(f.catalog, f.schema, f.name)}'];

  // -------------------------------------------------------------------------
  // Generic entry points (navigator menus)
  // -------------------------------------------------------------------------

  /// CREATE of [o] (its DDL page).
  List<String> create(ExtraObjectDef o) => switch (o) {
    ExtensionDef e => createExtension(e),
    EnumTypeDef t => createEnum(t),
    DomainDef d => createDomain(d),
    PolicyDef p => createPolicy(p),
    ExclusionDef x => addExclusion(x),
    SynonymDef s => createSynonym(s),
    EventDef e => createEvent(e),
    WarehouseDef w => createWarehouse(w),
    StageDef s => createStage(s),
    FileFormatDef f => createFileFormat(f),
    UdtDef u => CassandraDdl(dialect).createType(u),
    _ => const [],
  };

  List<String> alter(ExtraObjectDef from, ExtraObjectDef to) => switch ((from, to)) {
    (ExtensionDef a, ExtensionDef b) => alterExtension(a, b),
    (EnumTypeDef a, EnumTypeDef b) => alterEnum(a, b),
    (DomainDef a, DomainDef b) => alterDomain(a, b),
    (PolicyDef a, PolicyDef b) => alterPolicy(a, b),
    (ExclusionDef a, ExclusionDef b) => alterExclusion(a, b),
    (SynonymDef a, SynonymDef b) => alterSynonym(a, b),
    (EventDef a, EventDef b) => alterEvent(a, b),
    (WarehouseDef a, WarehouseDef b) => alterWarehouse(a, b),
    (StageDef a, StageDef b) => alterStage(a, b),
    (FileFormatDef a, FileFormatDef b) => alterFileFormat(a, b),
    (UdtDef a, UdtDef b) => CassandraDdl(dialect).alterType(a, b),
    _ => const [],
  };

  List<String> drop(ExtraObjectDef o, {bool cascade = false}) => switch (o) {
    ExtensionDef e => dropExtension(e, cascade: cascade),
    EnumTypeDef t => dropEnum(t, cascade: cascade),
    DomainDef d => dropDomain(d, cascade: cascade),
    PolicyDef p => dropPolicy(p),
    ExclusionDef x => dropExclusion(x),
    SynonymDef s => dropSynonym(s),
    PackageDef p => dropPackage(p),
    EventDef e => dropEvent(e),
    WarehouseDef w => dropWarehouse(w),
    StageDef s => dropStage(s),
    FileFormatDef f => dropFileFormat(f),
    UdtDef u => CassandraDdl(dialect).dropType(u.keyspace, u.name),
    _ => const [],
  };

  /// DROP … CASCADE exists for [o].
  bool canCascade(ExtraObjectDef o) =>
      o is ExtensionDef || o is EnumTypeDef || (o is DomainDef && family == DbFamily.postgres);
}
