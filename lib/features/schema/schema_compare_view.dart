import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/sql_dialect.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../ui/actions.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/split_view.dart';
import 'ddl_builder.dart';
import 'ddl_execution.dart';
import 'schema_diff.dart';
import 'schema_migration.dart';
import 'schema_model.dart';
import 'schema_snapshot.dart';

/// One side of the comparison (connection › catalog › schema).
class CompareSide {
  CompareSide([this.connection, this.catalog, this.schema]);
  DbConnection? connection;
  String? catalog;
  String? schema;

  String get label => [connection?.config.name, catalog, schema].whereType<String>().join(' › ');

  bool sameAs(CompareSide o) => connection == o.connection && catalog == o.catalog && schema == o.schema;
}

/// Schema compare & migration editor (DBeaver "Compare/Migrate › Schema
/// compare"): compares two schemas, possibly on different connections, and
/// generates the script that aligns the destination to the origin.
class SchemaCompareTab extends FeatureTab {
  SchemaCompareTab({DbConnection? source, String? sourceCatalog, String? sourceSchema})
    : source = CompareSide(source, sourceCatalog, sourceSchema),
      target = CompareSide(source, sourceCatalog, null);

  CompareSide source;
  CompareSide target;
  CompareOptions options = const CompareOptions();

  /// Generate drops of objects that exist only in the destination.
  bool dropExtra = false;

  SchemaSnapshot? sourceSnapshot;
  SchemaSnapshot? targetSnapshot;
  SchemaDiff? diff;

  /// Dialect of the destination at compare time (migration language).
  SqlDialect? targetDialect;

  /// Ids of the changes left out of the migration.
  final Set<String> excluded = {};
  String? selectedTable;

  CancelToken? _cancel;

  @override
  String get title => 'Confronto schemi';

  @override
  String get tooltip => 'Confronto schemi: ${source.label} → ${target.label}';

  @override
  IconData get icon => AppIcons.compare;

  @override
  DbConnection? get connection => source.connection;

  @override
  Widget buildView(BuildContext context) => SchemaCompareView(tab: this);

  @override
  Future<bool> canClose(BuildContext context) async {
    _cancel?.cancel();
    return true;
  }

  /// Recomputes the diff from the loaded snapshots (options changed).
  void rediff() {
    final s = sourceSnapshot, t = targetSnapshot;
    if (s == null || t == null) return;
    diff = SchemaDiff.compare(s, t, options: options);
    excluded.removeWhere((id) => !diff!.changes.any((c) => c.id == id));
  }

  /// Migration statements for the current selection.
  List<String> migration() {
    final d = diff, dialect = targetDialect;
    if (d == null || dialect == null) return const [];
    return SchemaMigration(dialect).generate(
      d,
      options: MigrationOptions(dropExtra: dropExtra),
      excluded: excluded,
    );
  }
}

class _SideLists {
  List<String> catalogs = const [];
  List<String> schemas = const [];
  bool loading = false;
  bool hasCatalogs = false;
  bool hasSchemas = false;
}

class SchemaCompareView extends StatefulWidget {
  const SchemaCompareView({super.key, required this.tab, this.connections});
  final SchemaCompareTab tab;

  /// Connections offered in the selectors (default: all the configured ones).
  final List<DbConnection>? connections;

  @override
  State<SchemaCompareView> createState() => _SchemaCompareViewState();
}

class _SchemaCompareViewState extends State<SchemaCompareView> {
  final _sourceLists = _SideLists();
  final _targetLists = _SideLists();
  bool _running = false;
  String? _progress;
  bool _showIdentical = false;

  SchemaCompareTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (tab.source.connection != null) _loadSide(tab.source, _sourceLists);
      if (tab.target.connection != null) _loadSide(tab.target, _targetLists);
    });
  }

  // -------------------------------------------------------------------------
  // Side selectors
  // -------------------------------------------------------------------------

  Future<void> _loadSide(CompareSide side, _SideLists lists, {bool catalogChanged = false}) async {
    final dc = side.connection;
    if (dc == null) return;
    setState(() => lists.loading = true);
    try {
      if (!await ensureConnected(context, dc)) return;
      final md = dc.metadata!;
      lists.hasCatalogs = md.supportsCatalogs;
      lists.hasSchemas = md.supportsSchemas;
      if (!catalogChanged) {
        lists.catalogs = lists.hasCatalogs ? await md.catalogs() : const [];
        if (lists.catalogs.isNotEmpty && !lists.catalogs.contains(side.catalog)) {
          side.catalog = lists.catalogs.contains(md.currentCatalog) ? md.currentCatalog : lists.catalogs.first;
        }
        if (lists.catalogs.isEmpty) side.catalog = null;
      }
      lists.schemas = lists.hasSchemas ? await md.schemas(side.catalog) : const [];
      if (lists.schemas.isNotEmpty && !lists.schemas.contains(side.schema)) {
        const preferred = ['public', 'dbo', 'main'];
        side.schema = lists.schemas.firstWhere(
          (s) => preferred.contains(s.toLowerCase()),
          orElse: () => lists.schemas.firstWhere(
            (s) => (dc.config.user).toLowerCase() == s.toLowerCase(),
            orElse: () => lists.schemas.first,
          ),
        );
      }
      if (lists.schemas.isEmpty) side.schema = null;
    } catch (e) {
      if (mounted) showErrorDialog(context, e);
    } finally {
      if (mounted) setState(() => lists.loading = false);
    }
  }

  void _invalidate() {
    tab.diff = null;
    tab.sourceSnapshot = null;
    tab.targetSnapshot = null;
    tab.excluded.clear();
    tab.selectedTable = null;
    tab.refresh();
  }

  void _swap() {
    setState(() {
      final s = tab.source;
      tab.source = tab.target;
      tab.target = s;
      final sl = (_sourceLists.catalogs, _sourceLists.schemas, _sourceLists.hasCatalogs, _sourceLists.hasSchemas);
      _sourceLists
        ..catalogs = _targetLists.catalogs
        ..schemas = _targetLists.schemas
        ..hasCatalogs = _targetLists.hasCatalogs
        ..hasSchemas = _targetLists.hasSchemas;
      _targetLists
        ..catalogs = sl.$1
        ..schemas = sl.$2
        ..hasCatalogs = sl.$3
        ..hasSchemas = sl.$4;
      _invalidate();
    });
  }

  // -------------------------------------------------------------------------
  // Compare / execute
  // -------------------------------------------------------------------------

  Future<void> _compare() async {
    final s = tab.source, t = tab.target;
    if (s.connection == null || t.connection == null) {
      showToast(context, 'Scegli la connessione di origine e di destinazione', error: true);
      return;
    }
    if (s.sameAs(t)) {
      showToast(context, 'Origine e destinazione coincidono', error: true);
      return;
    }
    if (!await ensureConnected(context, s.connection!)) return;
    if (!mounted || !await ensureConnected(context, t.connection!)) return;
    if (!mounted) return;
    final cancel = tab._cancel = CancelToken();
    setState(() {
      _running = true;
      _progress = 'Lettura dell\'origine…';
    });
    try {
      // Fresh metadata: the schemas may have changed since they were browsed.
      s.connection!.refreshMetadata();
      if (t.connection != s.connection) t.connection!.refreshMetadata();
      final src = await SchemaSnapshot.load(
        s.connection!.metadata!,
        catalog: s.catalog,
        schema: s.schema,
        cancel: cancel,
        label: s.label,
        onProgress: (d, n, _) {
          if (mounted) setState(() => _progress = 'Origine: $d di $n tabelle');
        },
      );
      final dst = await SchemaSnapshot.load(
        t.connection!.metadata!,
        catalog: t.catalog,
        schema: t.schema,
        cancel: cancel,
        label: t.label,
        onProgress: (d, n, _) {
          if (mounted) setState(() => _progress = 'Destinazione: $d di $n tabelle');
        },
      );
      tab.sourceSnapshot = src;
      tab.targetSnapshot = dst;
      tab.targetDialect = t.connection!.dialect;
      tab.excluded.clear();
      tab.rediff();
      final first = tab.diff!.tables.where((x) => x.status != DiffStatus.identical).firstOrNull;
      tab.selectedTable = first?.id;
      tab.refresh();
    } on SnapshotCancelled {
      // Stopped by the user.
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Confronto non riuscito');
    } finally {
      tab._cancel = null;
      if (mounted) {
        setState(() {
          _running = false;
          _progress = null;
        });
      }
    }
  }

  String _script(List<String> statements) {
    final d = tab.targetDialect;
    if (d == null || statements.isEmpty) return '';
    final header = [
      '-- Migrazione generata da DbCraft',
      '-- Origine: ${tab.source.label}',
      '-- Destinazione: ${tab.target.label}',
    ].join('\n');
    return '$header\n\n${DdlBuilder(d).render(statements)}';
  }

  Future<void> _save(String script) async {
    final loc = await getSaveLocation(
      suggestedName: 'migrazione.sql',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SQL', extensions: ['sql']),
      ],
    );
    if (loc == null) return;
    await File(loc.path).writeAsString(script);
    if (mounted) showToast(context, 'Script salvato in ${loc.path}');
  }

  Future<void> _execute(List<String> statements) async {
    final dc = tab.target.connection;
    if (dc == null) return;
    final ok = await executeDdl(context, dc, statements);
    if (ok && mounted) await _compare();
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final diff = tab.diff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
          decoration: BoxDecoration(
            color: c.chrome,
            border: Border(bottom: BorderSide(color: c.separator)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: _sidePanel('Origine', tab.source, _sourceLists)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                    child: ToolButton(
                      icon: AppIcons.swapHorizontal,
                      tooltip: 'Scambia origine e destinazione',
                      onPressed: _running ? null : _swap,
                    ),
                  ),
                  Expanded(child: _sidePanel('Destinazione', tab.target, _targetLists)),
                ],
              ),
              const SizedBox(height: Gap.sm),
              _optionsBar(c),
            ],
          ),
        ),
        Expanded(
          child: diff == null
              ? EmptyState(
                  icon: AppIcons.compare,
                  title: _running ? 'Confronto in corso…' : 'Confronta due schemi',
                  message: _running
                      ? _progress
                      : 'Scegli origine e destinazione, poi premi Confronta: verrà generato lo script che allinea '
                            'la destinazione all\'origine.',
                )
              : SplitView(
                  axis: Axis.vertical,
                  initialFraction: 0.6,
                  minFirst: 160,
                  minSecond: 120,
                  first: SplitView(
                    initialFraction: 0.32,
                    minFirst: 220,
                    minSecond: 320,
                    first: _tree(diff, c),
                    second: _detail(diff, c),
                  ),
                  second: _scriptPanel(c),
                ),
        ),
      ],
    );
  }

  Widget _drop<T>({
    required T? value,
    required List<T> items,
    required String Function(T) label,
    required ValueChanged<T?>? onChanged,
    String hint = '',
  }) {
    final c = DbColors.of(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(
        color: c.content,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: c.separator),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.contains(value) ? value : null,
          isExpanded: true,
          isDense: true,
          hint: Text(
            hint,
            style: TextStyle(fontSize: TypeSize.body, color: c.textTertiary),
          ),
          style: TextStyle(fontSize: TypeSize.body, color: c.text),
          items: [
            for (final i in items)
              DropdownMenuItem<T>(
                value: i,
                child: Text(label(i), overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _sidePanel(String title, CompareSide side, _SideLists lists) {
    final connections = widget.connections ?? AppScope.of(context).connections;
    final busy = _running || lists.loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionLabel(
          title,
          padding: const EdgeInsets.only(left: 2, bottom: Gap.xs),
          trailing: lists.loading
              ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
              : null,
        ),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: _drop<DbConnection>(
                value: side.connection,
                items: connections.where((d) => d.dialect.isSql).toList(),
                label: (d) => d.config.name,
                hint: 'Connessione',
                onChanged: busy
                    ? null
                    : (d) {
                        if (d == null || d == side.connection) return;
                        setState(() {
                          side.connection = d;
                          side.catalog = null;
                          side.schema = null;
                          lists.catalogs = const [];
                          lists.schemas = const [];
                          _invalidate();
                        });
                        _loadSide(side, lists);
                      },
              ),
            ),
            if (lists.hasCatalogs && lists.catalogs.isNotEmpty) ...[
              const SizedBox(width: Gap.sm),
              Expanded(
                flex: 2,
                child: _drop<String>(
                  value: side.catalog,
                  items: lists.catalogs,
                  label: (s) => s,
                  hint: 'Catalogo',
                  onChanged: busy
                      ? null
                      : (s) {
                          if (s == null || s == side.catalog) return;
                          setState(() {
                            side.catalog = s;
                            side.schema = null;
                            _invalidate();
                          });
                          _loadSide(side, lists, catalogChanged: true);
                        },
                ),
              ),
            ],
            if (lists.hasSchemas && lists.schemas.isNotEmpty) ...[
              const SizedBox(width: Gap.sm),
              Expanded(
                flex: 2,
                child: _drop<String>(
                  value: side.schema,
                  items: lists.schemas,
                  label: (s) => s,
                  hint: 'Schema',
                  onChanged: busy
                      ? null
                      : (s) => setState(() {
                          side.schema = s;
                          _invalidate();
                        }),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _optionsBar(DbColors c) {
    Widget opt(String label, bool value, ValueChanged<bool> on, {Color? color, String? tooltip}) {
      final w = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DbSwitch(value: value, onChanged: _running ? null : on),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: TypeSize.small, color: color ?? c.textSecondary),
          ),
        ],
      );
      return tooltip == null ? w : Tooltip(message: tooltip, child: w);
    }

    void setOptions(CompareOptions o) => setState(() {
      tab.options = o;
      tab.rediff();
      tab.refresh();
    });
    final o = tab.options;
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: Gap.lg,
            runSpacing: Gap.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              opt('Ignora maiuscole', o.ignoreCase, (v) => setOptions(o.copyWith(ignoreCase: v))),
              opt('Ignora ordine colonne', o.ignoreColumnOrder, (v) => setOptions(o.copyWith(ignoreColumnOrder: v))),
              opt('Ignora commenti', o.ignoreComments, (v) => setOptions(o.copyWith(ignoreComments: v))),
              opt('Ignora default', o.ignoreDefaults, (v) => setOptions(o.copyWith(ignoreDefaults: v))),
              opt('Chiavi esterne', o.compareForeignKeys, (v) => setOptions(o.copyWith(compareForeignKeys: v))),
              opt('Indici', o.compareIndexes, (v) => setOptions(o.copyWith(compareIndexes: v))),
              opt(
                'Elimina oggetti in più',
                tab.dropExtra,
                (v) => setState(() => tab.dropExtra = v),
                color: tab.dropExtra ? c.danger : null,
                tooltip: 'Pericoloso: elimina tabelle, colonne, chiavi e indici presenti solo nella destinazione',
              ),
            ],
          ),
        ),
        const SizedBox(width: Gap.md),
        if (_running) ...[
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: Gap.sm),
          Text(
            _progress ?? '',
            style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary, fontFeatures: kTabular),
          ),
          const SizedBox(width: Gap.sm),
          ToolButton(
            icon: AppIcons.stopCircle,
            color: c.danger,
            tooltip: 'Interrompi',
            onPressed: () => tab._cancel?.cancel(),
          ),
          const SizedBox(width: Gap.sm),
        ],
        PrimaryButton(label: 'Confronta', icon: AppIcons.compare, onPressed: _running ? null : _compare),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Result tree
  // -------------------------------------------------------------------------

  static Color statusColor(DbColors c, DiffStatus s) => switch (s) {
    DiffStatus.onlyInSource => c.success,
    DiffStatus.onlyInTarget => c.danger,
    DiffStatus.different => c.warning,
    DiffStatus.identical => c.textTertiary,
  };

  static String statusTag(DiffStatus s) => switch (s) {
    DiffStatus.onlyInSource => 'nuova',
    DiffStatus.onlyInTarget => 'in più',
    DiffStatus.different => 'diversa',
    DiffStatus.identical => 'identica',
  };

  bool _enabled(DiffChange ch) => !ch.destructive || tab.dropExtra;

  /// Checkbox state of a table: true (all its changes), false, or null (some).
  bool? _tableCheck(TableDiff td) {
    final ch = td.changes.where(_enabled).toList();
    if (ch.isEmpty) return false;
    final inc = ch.where((x) => !tab.excluded.contains(x.id)).length;
    return inc == ch.length ? true : (inc == 0 ? false : null);
  }

  void _toggleTable(TableDiff td) {
    final ch = td.changes.where(_enabled).map((x) => x.id).toList();
    setState(() {
      if (ch.any(tab.excluded.contains)) {
        tab.excluded.removeAll(ch);
      } else {
        tab.excluded.addAll(ch);
      }
    });
  }

  Widget _tree(SchemaDiff diff, DbColors c) {
    final groups = [DiffStatus.different, DiffStatus.onlyInSource, DiffStatus.onlyInTarget, DiffStatus.identical];
    final rows = <Widget>[];
    for (final g in groups) {
      final items = diff.withStatus(g).toList();
      if (items.isEmpty) continue;
      final collapsed = g == DiffStatus.identical && !_showIdentical;
      rows.add(
        InkWell(
          onTap: g == DiffStatus.identical ? () => setState(() => _showIdentical = !_showIdentical) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.md, Gap.md, Gap.xs),
            child: Row(
              children: [
                Icon(
                  collapsed ? AppIcons.chevronRight : AppIcons.chevronDown,
                  size: 16,
                  color: g == DiffStatus.identical ? c.textTertiary : Colors.transparent,
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                    g.label,
                    style: TextStyle(fontSize: TypeSize.caption, fontWeight: FontWeight.w600, color: c.textTertiary),
                  ),
                ),
                Badge2('${items.length}', color: statusColor(c, g)),
              ],
            ),
          ),
        ),
      );
      if (collapsed) continue;
      for (final td in items) {
        final selected = tab.selectedTable == td.id;
        final n = td.changeCount(includeDestructive: tab.dropExtra);
        rows.add(
          GestureDetector(
            onTap: () => setState(() => tab.selectedTable = td.id),
            child: Container(
              height: 26,
              padding: const EdgeInsets.only(left: Gap.sm, right: Gap.md),
              color: selected ? c.selection : Colors.transparent,
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: td.status == DiffStatus.identical
                        ? null
                        : Checkbox(
                            tristate: true,
                            value: _tableCheck(td),
                            onChanged: td.changes.any(_enabled) ? (_) => _toggleTable(td) : null,
                          ),
                  ),
                  const SizedBox(width: 4),
                  Icon(AppIcons.table, size: 14, color: statusColor(c, td.status)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      td.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: TypeSize.body),
                    ),
                  ),
                  if (td.status == DiffStatus.different)
                    Text(
                      '$n',
                      style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary, fontFeatures: kTabular),
                    ),
                  const SizedBox(width: 6),
                  Badge2(statusTag(td.status), color: statusColor(c, td.status)),
                ],
              ),
            ),
          ),
        );
      }
    }
    final total = diff.changeCount(includeDestructive: tab.dropExtra);
    return Container(
      color: c.content,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.separator)),
            ),
            child: Text(
              '${diff.tables.length} tabelle · $total differenze',
              style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary, fontFeatures: kTabular),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: Gap.md),
              children: rows,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Detail
  // -------------------------------------------------------------------------

  Widget _detail(SchemaDiff diff, DbColors c) {
    final td = diff.tables.where((t) => t.id == tab.selectedTable).firstOrNull;
    if (td == null) {
      return const EmptyState(
        icon: AppIcons.table,
        title: 'Nessuna tabella selezionata',
        message: 'Seleziona una tabella a sinistra per vedere le differenze colonna per colonna.',
      );
    }
    final changes = td.changes;
    return Container(
      color: c.content,
      child: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Row(
            children: [
              Text(td.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: Gap.sm),
              Badge2(td.status.label.toLowerCase(), color: statusColor(c, td.status)),
            ],
          ),
          if (changes.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            FormGroup(
              title: 'Modifiche da applicare',
              children: [
                for (final ch in changes)
                  Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: Checkbox(
                          value: _enabled(ch) && !tab.excluded.contains(ch.id),
                          onChanged: _enabled(ch)
                              ? (v) => setState(() => v == true ? tab.excluded.remove(ch.id) : tab.excluded.add(ch.id))
                              : null,
                        ),
                      ),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(
                          ch.label,
                          style: TextStyle(fontSize: TypeSize.body, color: _enabled(ch) ? c.text : c.textTertiary),
                        ),
                      ),
                      if (ch.destructive)
                        Tooltip(
                          message: tab.dropExtra
                              ? 'Elimina dati o oggetti'
                              : 'Attiva "Elimina oggetti in più" per includerla',
                          child: Badge2('pericoloso', color: c.danger),
                        ),
                    ],
                  ),
              ],
            ),
          ],
          const SizedBox(height: Gap.sm),
          _columnsTable(td, c),
          const SizedBox(height: Gap.lg),
          _constraints(td, c),
        ],
      ),
    );
  }

  String _colText(ColumnDef? col) {
    if (col == null) return '';
    final parts = [
      col.fullType.toLowerCase(),
      if (!col.nullable) 'not null',
      if (col.autoIncrement) 'auto',
      if (col.defaultValue != null) 'default ${col.defaultValue}',
    ];
    return parts.join(' · ');
  }

  Widget _columnsTable(TableDiff td, DbColors c) {
    final rows = td.status == DiffStatus.onlyInSource
        ? [for (final x in td.source!.columns) ColumnDiff(DiffStatus.onlyInSource, x, null)]
        : td.status == DiffStatus.onlyInTarget
        ? [for (final x in td.target!.columns) ColumnDiff(DiffStatus.onlyInTarget, null, x)]
        : td.columns;
    final head = TextStyle(fontSize: TypeSize.caption, fontWeight: FontWeight.w600, color: c.textTertiary);
    Widget cell(ColumnDef? col, ColumnDiff d, bool left) {
      final present = col != null;
      final highlight = switch (d.status) {
        DiffStatus.onlyInSource => left ? c.success : null,
        DiffStatus.onlyInTarget => left ? null : c.danger,
        DiffStatus.different => c.warning,
        DiffStatus.identical => null,
      };
      return Expanded(
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          color: highlight?.withValues(alpha: 0.10),
          child: Row(
            children: [
              SizedBox(
                width: 160,
                child: Text(
                  present ? col.name : '',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TypeSize.body,
                    fontWeight: FontWeight.w500,
                    color: d.aspects.contains(ColumnAspect.name) ? c.warning : c.text,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  _colText(col),
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(context, size: 11.5, color: highlight ?? c.textSecondary),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.panel + 2),
        border: Border.all(color: c.separator),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 28,
            color: c.chrome,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                    child: Text('Origine · ${tab.source.label}', overflow: TextOverflow.ellipsis, style: head),
                  ),
                ),
                Container(width: 1, color: c.separator),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                    child: Text('Destinazione · ${tab.target.label}', overflow: TextOverflow.ellipsis, style: head),
                  ),
                ),
              ],
            ),
          ),
          for (final (i, d) in rows.indexed)
            Container(
              color: i.isOdd ? c.zebra : null,
              child: Tooltip(
                message: d.aspects.isEmpty ? '' : 'Differenze: ${d.aspects.map((a) => a.label).join(', ')}',
                child: Row(
                  children: [
                    cell(d.source, d, true),
                    Container(width: 1, height: 26, color: c.separator),
                    cell(d.target, d, false),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _constraints(TableDiff td, DbColors c) {
    final lines = <(String, DiffStatus)>[];
    final pk = td.primaryKey;
    if (pk != null) {
      lines.add((
        'Chiave primaria: ${pk.source == null ? '—' : '(${pk.source!.columns.join(', ')})'}'
            '  →  ${pk.target == null ? '—' : '(${pk.target!.columns.join(', ')})'}',
        pk.status,
      ));
    }
    for (final f in td.foreignKeys) {
      final x = (f.source ?? f.target)!;
      lines.add((
        'Chiave esterna ${x.name ?? ''} (${x.columns.join(', ')}) → ${x.refTable} (${x.refColumns.join(', ')})'
            '${f.status == DiffStatus.different ? ' · ON DELETE ${f.source!.onDelete.sql} / ${f.target!.onDelete.sql}' : ''}',
        f.status,
      ));
    }
    for (final i in td.indexes) {
      final x = (i.source ?? i.target)!;
      lines.add(('Indice ${x.unique ? 'univoco ' : ''}${x.name} (${x.columns.join(', ')})', i.status));
    }
    if (td.commentChanged) {
      lines.add(('Commento: ${td.source?.comment ?? '—'}  →  ${td.target?.comment ?? '—'}', DiffStatus.different));
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return FormGroup(
      title: 'Chiavi e indici',
      children: [
        for (final (text, s) in lines)
          Row(
            children: [
              Expanded(
                child: Text(text, style: const TextStyle(fontSize: TypeSize.body)),
              ),
              const SizedBox(width: Gap.sm),
              Badge2(statusTag(s), color: statusColor(c, s)),
            ],
          ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Script
  // -------------------------------------------------------------------------

  Widget _scriptPanel(DbColors c) {
    final statements = tab.migration();
    final script = _script(statements);
    final count = executableStatements(statements).length;
    final dc = tab.target.connection;
    final readOnly = dc?.config.readOnly ?? true;
    return Container(
      color: c.content,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            decoration: BoxDecoration(
              color: c.chrome,
              border: Border(bottom: BorderSide(color: c.separator)),
            ),
            child: Row(
              children: [
                Text(
                  'Script di migrazione',
                  style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.text),
                ),
                const SizedBox(width: Gap.sm),
                Badge2('$count istruzioni'),
                if (tab.targetDialect != null) ...[
                  const SizedBox(width: Gap.sm),
                  Text(
                    tab.targetDialect!.dbmsName,
                    style: TextStyle(fontSize: TypeSize.small, color: c.textTertiary),
                  ),
                ],
                const Spacer(),
                ToolButton(
                  icon: AppIcons.script,
                  label: 'Apri nell\'editor SQL',
                  tooltip: 'Apri lo script in un editor SQL sulla destinazione',
                  onPressed: count == 0 || dc == null
                      ? null
                      : () => AppScope.read(context).openSqlEditor(dc, initialSql: script),
                ),
                ToolButton(
                  icon: AppIcons.copy,
                  tooltip: 'Copia',
                  onPressed: count == 0
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: script));
                          showToast(context, 'Script copiato');
                        },
                ),
                ToolButton(
                  icon: AppIcons.save,
                  tooltip: 'Salva…',
                  onPressed: count == 0 ? null : () => _save(script),
                ),
                const ToolSeparator(),
                ToolButton(
                  icon: AppIcons.run,
                  label: 'Esegui sulla destinazione',
                  color: c.accent,
                  tooltip: readOnly ? 'La destinazione è in sola lettura' : 'Esegui lo script su ${tab.target.label}',
                  onPressed: count == 0 || readOnly || _running ? null : () => _execute(statements),
                ),
              ],
            ),
          ),
          Expanded(
            child: count == 0
                ? EmptyState(
                    icon: AppIcons.checkCircle,
                    title: 'Nessuna istruzione',
                    message: tab.diff!.changeCount(includeDestructive: tab.dropExtra) == 0
                        ? 'Gli schemi sono allineati con le opzioni scelte.'
                        : 'Tutte le modifiche sono escluse: selezionale a sinistra.',
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(Gap.md),
                    child: SelectableText(script, style: monoStyle(context, size: 12.5)),
                  ),
          ),
        ],
      ),
    );
  }
}
