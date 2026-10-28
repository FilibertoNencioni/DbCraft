// Context sent to the assistant: DBMS, compact schema summary, prompts and
// helpers to read code back from the answers. No data rows are ever sent
// unless the user attaches an explicit result sample.
import '../../model/db_objects.dart';
import '../../services/metadata_service.dart';
import '../../services/sql_dialect.dart';
import '../../services/system_objects.dart';
import '../../state/db_connection.dart';
import 'claude_client.dart';

const kAiMaxTables = 150;
const kAiMaxColumns = 40;
const kAiMaxSchemaChars = 60000;

// ---------------------------------------------------------------------------
// Schema summary
// ---------------------------------------------------------------------------

class AiColumnSummary {
  const AiColumnSummary(this.name, this.type, {this.nullable = true, this.pk = false, this.ref});
  final String name;
  final String type;
  final bool nullable;
  final bool pk;

  /// Referenced `table.column` for a foreign key column.
  final String? ref;

  String render() {
    final sb = StringBuffer('$name $type');
    if (pk) sb.write(' PK');
    if (ref != null) sb.write(' FK→$ref');
    if (!nullable && !pk) sb.write(' NOT NULL');
    return sb.toString();
  }
}

class AiTableSummary {
  const AiTableSummary(this.name, {this.isView = false, this.columns, this.remarks});

  /// Qualified display name (schema.table).
  final String name;
  final bool isView;

  /// Null when columns were not loaded (name only).
  final List<AiColumnSummary>? columns;
  final String? remarks;
}

/// Renders the schema summary with hard caps on tables, columns per table
/// and total characters, so that large databases never flood the prompt.
String renderSchemaSummary(
  List<AiTableSummary> tables, {
  int maxTables = kAiMaxTables,
  int maxColumns = kAiMaxColumns,
  int maxChars = kAiMaxSchemaChars,
}) {
  final sb = StringBuffer();
  var shown = 0;
  for (final t in tables) {
    if (shown >= maxTables) break;
    final line = StringBuffer('- ${t.name}${t.isView ? ' (vista)' : ''}');
    final cols = t.columns;
    if (cols != null && cols.isNotEmpty) {
      final visible = cols.take(maxColumns).map((c) => c.render()).join(', ');
      line.write(': $visible');
      if (cols.length > maxColumns) line.write(', … (+${cols.length - maxColumns} colonne)');
    }
    final r = t.remarks?.trim();
    if (r != null && r.isNotEmpty) line.write('  -- ${r.replaceAll('\n', ' ')}');
    if (sb.length + line.length + 1 > maxChars) break;
    sb.writeln(line);
    shown++;
  }
  if (shown < tables.length) sb.writeln('- … altre ${tables.length - shown} tabelle omesse');
  return sb.toString().trimRight();
}

/// Identifiers that appear in [sql] (lower case, unquoted). Rough on
/// purpose: it is only used to pick which tables to describe.
Set<String> sqlIdentifiers(String sql) {
  final noComments = sql.replaceAll(RegExp(r'--[^\n]*'), ' ').replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  final noStrings = noComments.replaceAll(RegExp(r"'(?:[^']|'')*'"), ' ');
  final out = <String>{};
  for (final m in RegExp(r'"([^"]+)"|\[([^\]]+)\]|`([^`]+)`|([A-Za-z_][\w$#@]*)').allMatches(noStrings)) {
    final id = m[1] ?? m[2] ?? m[3] ?? m[4];
    if (id != null) out.add(id.toLowerCase());
  }
  return out;
}

/// The tables of [all] whose name appears in [sql].
List<DbTable> referencedTables(String sql, List<DbTable> all) {
  final ids = sqlIdentifiers(sql);
  return [
    for (final t in all)
      if (ids.contains(t.name.toLowerCase())) t,
  ];
}

String _familyLabel(DbFamily f) => switch (f) {
  DbFamily.sqlServer => 'Microsoft SQL Server (T-SQL)',
  DbFamily.postgres => 'PostgreSQL',
  DbFamily.mysql => 'MySQL / MariaDB',
  DbFamily.oracle => 'Oracle (PL/SQL)',
  DbFamily.db2 => 'IBM Db2',
  DbFamily.sqlite => 'SQLite',
  DbFamily.firebird => 'Firebird',
  DbFamily.snowflake => 'Snowflake',
  DbFamily.bigquery => 'Google BigQuery (GoogleSQL)',
  DbFamily.cassandra => 'Apache Cassandra (CQL)',
  DbFamily.mongodb => 'MongoDB (mongo shell)',
  DbFamily.redis => 'Redis (comandi Redis)',
  DbFamily.generic => 'SQL standard (ANSI)',
};

/// Language the assistant must write code in, and the fence tag to use.
(String, String) queryLanguage(DbFamily f) => switch (f) {
  DbFamily.mongodb => ('MongoDB shell (mongosh) commands', 'javascript'),
  DbFamily.redis => ('Redis commands, one per line', 'redis'),
  DbFamily.cassandra => ('CQL (Cassandra Query Language)', 'sql'),
  _ => ('SQL in the ${_familyLabel(f)} dialect', 'sql'),
};

/// Best known dialect: the live one when connected, otherwise guessed from
/// the configured driver.
SqlDialect dialectOf(DbConnection? dc) {
  if (dc == null) return SqlDialect(dbmsName: '');
  if (dc.isConnected && dc.metadata != null) return dc.dialect;
  final c = dc.config;
  return SqlDialect(dbmsName: '${c.nativeDriver} ${c.driver} ${c.name}');
}

/// Everything the assistant knows about the database.
class AiDbContext {
  AiDbContext({required this.family, this.server = '', this.catalog, this.schema, this.schemaText = '', this.note});

  final DbFamily family;
  final String server;
  final String? catalog;
  final String? schema;
  final String schemaText;

  /// Explains why the schema is missing (not connected, disabled…).
  final String? note;

  String render() {
    final sb = StringBuffer('<database>\n');
    sb.writeln('Engine: ${_familyLabel(family)}${server.isEmpty ? '' : ' — server: $server'}');
    if (catalog != null && catalog!.isNotEmpty) sb.writeln('Current database/catalog: $catalog');
    if (schema != null && schema!.isNotEmpty) sb.writeln('Default schema: $schema');
    if (schemaText.isNotEmpty) {
      sb.writeln('Schema (tables with columns; PK = primary key, FK→ = foreign key):');
      sb.writeln(schemaText);
    } else if (note != null) {
      sb.writeln(note);
    }
    sb.write('</database>');
    return sb.toString();
  }

  /// Builds the context of [dc]. With [sql] only the referenced tables are
  /// described (falling back to the current schema); [extraTables] are
  /// always included (e.g. the object being explained).
  static Future<AiDbContext> build(
    DbConnection? dc, {
    required bool includeSchema,
    String? sql,
    List<DbTable> extraTables = const [],
    Duration budget = const Duration(seconds: 8),
  }) async {
    final dialect = dialectOf(dc);
    if (dc == null) return AiDbContext(family: dialect.family, note: 'No database connection selected.');
    final md = dc.metadata;
    if (!dc.isConnected || md == null) {
      return AiDbContext(family: dialect.family, note: 'Schema not available (not connected).');
    }
    final server = dc.serverLabel;
    if (!includeSchema || !dialect.isSql) {
      return AiDbContext(
        family: dialect.family,
        server: server,
        catalog: md.currentCatalog,
        note: includeSchema ? null : 'The user chose not to share the database structure.',
      );
    }
    final sw = Stopwatch()..start();
    String? catalog, schema;
    var all = <DbTable>[];
    try {
      catalog = md.supportsCatalogs ? md.currentCatalog : null;
      if (md.supportsSchemas) {
        final schemas = (await md.schemas(catalog))
            .where((s) => !isSystemSchema(dialect, s) && !isSystemCatalog(dialect, s))
            .toList();
        schema = _defaultSchema(dc, schemas);
        all = schema != null
            ? await md.tables(catalog, schema)
            : [for (final s in schemas.take(10)) ...await md.tables(catalog, s)];
      } else {
        all = await md.tables(catalog, null);
      }
      all = all.where((t) => !t.type.toUpperCase().contains('SYSTEM')).toList();
    } catch (_) {
      // Metadata errors only reduce the context.
    }
    var picked = sql == null || sql.trim().isEmpty ? <DbTable>[] : referencedTables(sql, all);
    final scoped = picked.isNotEmpty;
    if (!scoped) picked = all;
    for (final t in extraTables.reversed) {
      picked.remove(t);
      picked.insert(0, t);
    }
    final summaries = <AiTableSummary>[];
    for (final t in picked.take(kAiMaxTables)) {
      final name = t.schema != null && t.schema != schema ? '${t.schema}.${t.name}' : t.name;
      if (sw.elapsed > budget) {
        summaries.add(AiTableSummary(name, isView: t.isView, remarks: t.remarks));
        continue;
      }
      summaries.add(await _summarize(md, t, name));
    }
    final text = renderSchemaSummary([
      ...summaries,
      for (final t in picked.skip(kAiMaxTables)) AiTableSummary(t.name, isView: t.isView),
    ]);
    return AiDbContext(
      family: dialect.family,
      server: server,
      catalog: md.currentCatalog,
      schema: schema,
      schemaText: scoped && all.length > picked.length
          ? '$text\n(only the tables referenced by the query are listed; the schema has ${all.length} tables)'
          : text,
    );
  }

  static String? _defaultSchema(DbConnection dc, List<String> schemas) {
    if (schemas.isEmpty) return null;
    if (schemas.length == 1) return schemas.first;
    final user = (dc.info['userName'] as String? ?? '').toLowerCase();
    for (final pref in [user, 'public', 'dbo', 'main']) {
      if (pref.isEmpty) continue;
      for (final s in schemas) {
        if (s.toLowerCase() == pref) return s;
      }
    }
    return null;
  }

  static Future<AiTableSummary> _summarize(MetadataService md, DbTable t, String name) async {
    try {
      final cols = await md.columns(t);
      DbPrimaryKey? pk;
      var fks = <DbForeignKey>[];
      if (!t.isView) {
        pk = await md.primaryKey(t);
        fks = await md.foreignKeys(t);
      }
      final refs = <String, String>{};
      for (final fk in fks) {
        for (var i = 0; i < fk.columns.length && i < fk.refColumns.length; i++) {
          refs[fk.columns[i].toLowerCase()] = '${fk.pkTable}.${fk.refColumns[i]}';
        }
      }
      final pkCols = {for (final c in pk?.columns ?? const <String>[]) c.toLowerCase()};
      return AiTableSummary(
        name,
        isView: t.isView,
        remarks: t.remarks,
        columns: [
          for (final c in cols)
            AiColumnSummary(
              c.name,
              c.fullType,
              nullable: c.nullable,
              pk: pkCols.contains(c.name.toLowerCase()),
              ref: refs[c.name.toLowerCase()],
            ),
        ],
      );
    } catch (_) {
      return AiTableSummary(name, isView: t.isView, remarks: t.remarks);
    }
  }
}

// ---------------------------------------------------------------------------
// Result sample (only when the user explicitly opts in)
// ---------------------------------------------------------------------------

class AiDataSample {
  const AiDataSample(this.columns, this.rows);
  final List<String> columns;
  final List<List<String>> rows;

  String render({int maxCell = 120}) {
    String cell(String v) =>
        (v.length > maxCell ? '${v.substring(0, maxCell)}…' : v).replaceAll('\n', ' ').replaceAll('|', '\\|');
    final sb = StringBuffer();
    sb.writeln('| ${columns.map(cell).join(' | ')} |');
    sb.writeln('|${List.filled(columns.length, '---').join('|')}|');
    for (final r in rows) {
      sb.writeln('| ${r.map(cell).join(' | ')} |');
    }
    return sb.toString().trimRight();
  }
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------

const _base = '''
You are the AI assistant built into DbCraft, a desktop database client (similar to DBeaver).
You help developers and analysts understand, write and fix database queries.
Always answer in Italian, concisely, using Markdown (short headings, bullet lists, `inline code`).
Put every query or command in a fenced code block with the language tag.
Never invent tables or columns that are not in the schema when a schema is provided; if something is missing, say so.
Prefer safe statements: warn explicitly before anything that modifies or deletes data.''';

enum AiTask { explainQuery, explainObject, fixQuery, generate, chat }

String _taskPrompt(AiTask task, DbFamily family) {
  final (lang, fence) = queryLanguage(family);
  return switch (task) {
    AiTask.explainQuery =>
      '''
Task: explain the query the user sends.
Structure: one sentence with the purpose; "## Come funziona" with the steps in execution order (sources, joins, filters, grouping, ordering); "## Note" with performance hints (indexes, sargability, N+1, cartesian products) and possible bugs, only if relevant.
Target language: $lang.''',
    AiTask.explainObject =>
      '''
Task: explain the database object the user sends (DDL and metadata).
Structure: what the object represents in the domain; "## Struttura" with the key columns and constraints; "## Relazioni" with foreign keys in both directions; "## Indici" with comments on their usefulness; "## Esempi" with one or two useful queries in a ```$fence block.
Target language: $lang.''',
    AiTask.fixQuery =>
      '''
Task: the statement failed with the error reported by the database. Find the cause and fix it.
Answer with: one or two sentences explaining the cause (in Italian), then exactly ONE fenced ```$fence block containing the complete corrected statement, ready to run, and nothing after it.
Keep the user's formatting, aliases and intent; change only what is needed. Target language: $lang.''',
    AiTask.generate =>
      '''
Task: write the query the user describes in natural language.
Answer with exactly ONE fenced ```$fence block containing the complete statement, followed by at most three short bullet points of explanation or assumptions.
Use only tables and columns from the schema; qualify ambiguous columns; limit result size when the request is exploratory. Target language: $lang.''',
    AiTask.chat =>
      '''
Task: converse with the user about this database. When you write queries, use $lang and put each one in its own fenced ```$fence block so the user can insert or run it from the chat.''',
  };
}

/// System blocks: the stable instructions plus the database context, with
/// the cache breakpoint on the last block.
List<AiSystemBlock> buildSystem(AiTask task, AiDbContext ctx) => [
  AiSystemBlock('$_base\n\n${_taskPrompt(task, ctx.family)}'),
  AiSystemBlock(ctx.render(), cache: true),
];

String fenced(String code, String lang) {
  final fence = code.contains('```') ? '````' : '```';
  return '$fence$lang\n${code.trimRight()}\n$fence';
}

String explainQueryPrompt(String sql, String fence, {AiDataSample? sample}) {
  final sb = StringBuffer('Spiega questa query:\n\n${fenced(sql, fence)}');
  if (sample != null) {
    sb.write('\n\nPrime ${sample.rows.length} righe del risultato (condivise dall\'utente):\n\n${sample.render()}');
  }
  return sb.toString();
}

String fixQueryPrompt(String sql, String error, String fence) =>
    'Questa istruzione ha restituito un errore.\n\n${fenced(sql, fence)}\n\nErrore del database:\n\n${fenced(error, 'text')}';

String generatePrompt(String request, {String? currentSql, String fence = 'sql'}) {
  final sb = StringBuffer(request.trim());
  if (currentSql != null && currentSql.trim().isNotEmpty) {
    sb.write(
      '\n\nQuery attualmente nell\'editor (contesto, modificala se la richiesta lo chiede):\n\n${fenced(currentSql, fence)}',
    );
  }
  return sb.toString();
}

// ---------------------------------------------------------------------------
// Answers
// ---------------------------------------------------------------------------

class CodeBlock {
  const CodeBlock(this.language, this.code);
  final String language;
  final String code;
}

/// Fenced code blocks of a Markdown answer (an unterminated last block is
/// included: it is still streaming).
List<CodeBlock> extractCodeBlocks(String markdown) {
  final out = <CodeBlock>[];
  final lines = markdown.split('\n');
  String? fence;
  var lang = '';
  final buf = <String>[];
  for (final raw in lines) {
    final line = raw.trimRight();
    final t = line.trimLeft();
    if (fence == null) {
      final m = RegExp(r'^(`{3,}|~{3,})\s*([\w+#.-]*)').firstMatch(t);
      if (m != null) {
        fence = m[1];
        lang = (m[2] ?? '').toLowerCase();
        buf.clear();
      }
    } else if (t.startsWith(fence) && t.replaceAll(fence[0], '').trim().isEmpty) {
      out.add(CodeBlock(lang, buf.join('\n')));
      fence = null;
    } else {
      buf.add(raw);
    }
  }
  if (fence != null && buf.isNotEmpty) out.add(CodeBlock(lang, buf.join('\n')));
  return out;
}

/// The code to insert from an answer: the first block in a query language
/// (or simply the first block).
String? pickQuery(String markdown, {String preferred = 'sql'}) {
  final blocks = extractCodeBlocks(markdown).where((b) => b.code.trim().isNotEmpty).toList();
  if (blocks.isEmpty) return null;
  const query = {'sql', 'plsql', 'tsql', 'pgsql', 'mysql', 'cql', 'javascript', 'js', 'mongo', 'redis', ''};
  for (final b in blocks) {
    if (b.language == preferred) return b.code.trim();
  }
  for (final b in blocks) {
    if (query.contains(b.language)) return b.code.trim();
  }
  return blocks.first.code.trim();
}

/// Markdown text without its code blocks (the explanation of a fix).
String stripCodeBlocks(String markdown) {
  final out = <String>[];
  String? fence;
  for (final raw in markdown.split('\n')) {
    final t = raw.trim();
    if (fence == null) {
      final m = RegExp(r'^(`{3,}|~{3,})').firstMatch(t);
      if (m != null) {
        fence = m[1];
        continue;
      }
      out.add(raw);
    } else if (t.startsWith(fence) && t.replaceAll(fence[0], '').trim().isEmpty) {
      fence = null;
    }
  }
  return out.join('\n').replaceAll(RegExp(r'\n\s*\n(\s*\n)+'), '\n\n').trim();
}
