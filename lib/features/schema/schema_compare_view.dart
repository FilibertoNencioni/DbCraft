import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/sql_dialect.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../ui/actions.dart';
import '../../ui/editors/sql_code_editor.dart';
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
    final ok = await executeDdl(
      context,
      dc,
      statements,
      scope: SchemaScope.schema(tab.target.catalog, tab.target.schema),
    );
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
            border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
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
  }) => PopUpButton<T?>(
    value: items.contains(value) ? value : null,
    expand: true,
    placeholder: hint,
    items: [for (final i in items) (i, label(i), null)],
    onChanged: onChanged,
  );

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
          trailing: lists.loading ? const Spinner(size: Spinner.small) : null,
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
    Widget opt(String label, bool value, ValueChanged<bool> on, {String? tooltip, Color? color}) => CheckboxRow(
      label: label,
      small: true,
      value: value,
      onChanged: _running ? null : on,
      tooltip: tooltip,
      labelColor: color,
    );

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
          const Spinner(size: Spinner.small),
          const SizedBox(width: Gap.sm),
          Text(
            _progress ?? '',
            style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular),
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
        PushButton.primary(label: 'Confronta', icon: AppIcons.compare, onPressed: _running ? null : _compare),
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
    // Flat outline: a group header (table null) followed by its tables.
    final items = <(DiffStatus, TableDiff?)>[];
    for (final g in groups) {
      final tables = diff.withStatus(g).toList();
      if (tables.isEmpty) continue;
      items.add((g, null));
      if (g == DiffStatus.identical && !_showIdentical) continue;
      for (final td in tables) {
        items.add((g, td));
      }
    }
    final selected = items.indexWhere((e) => e.$2 != null && e.$2!.id == tab.selectedTable);
    final total = diff.changeCount(includeDestructive: tab.dropExtra);
    return ColoredBox(
      color: c.content,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(title: '${diff.tables.length} tabelle · $total differenze'),
          Expanded(
            child: SourceList(
              dense: true,
              background: c.content,
              itemCount: items.length,
              selectedIndex: selected < 0 ? null : selected,
              selectable: (i) => items[i].$2 != null,
              onSelect: (i) => setState(() => tab.selectedTable = items[i].$2!.id),
              itemBuilder: (context, i) {
                final (g, td) = items[i];
                if (td == null) {
                  return SectionLabel(
                    g.label,
                    padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.sm, Gap.xs, 0),
                    expanded: g != DiffStatus.identical || _showIdentical,
                    onToggle: g == DiffStatus.identical ? (v) => setState(() => _showIdentical = v) : null,
                    trailing: Padding(
                      padding: const EdgeInsets.only(left: Gap.sm),
                      child: CountBadge(diff.withStatus(g).length),
                    ),
                  );
                }
                final n = td.changeCount(includeDestructive: tab.dropExtra);
                return OutlineRow(
                  dense: true,
                  title: td.name,
                  icon: AppIcons.table,
                  iconColor: statusColor(c, td.status),
                  // The checkbox sits before the table icon; identical tables
                  // keep its space, so the names stay aligned.
                  leading: td.status == DiffStatus.identical
                      ? const SizedBox(width: 14)
                      : MacCheckbox(
                          value: _tableCheck(td),
                          semanticLabel: 'Includi ${td.name}',
                          onChanged: td.changes.any(_enabled) ? (_) => _toggleTable(td) : null,
                        ),
                  detail: td.status == DiffStatus.different ? '$n' : null,
                  accessories: [Tag(statusTag(td.status), color: statusColor(c, td.status))],
                  selected: tab.selectedTable == td.id,
                  onTap: () => setState(() => tab.selectedTable = td.id),
                );
              },
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
              Text(
                td.name,
                style: uiText(TypeSize.title, weight: FontWeight.w600, color: c.text),
              ),
              const SizedBox(width: Gap.sm),
              Tag(td.status.label.toLowerCase(), color: statusColor(c, td.status)),
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
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: CheckboxRow(
                            label: ch.label,
                            value: _enabled(ch) && !tab.excluded.contains(ch.id),
                            onChanged: _enabled(ch)
                                ? (v) => setState(() => v ? tab.excluded.remove(ch.id) : tab.excluded.add(ch.id))
                                : null,
                          ),
                        ),
                      ),
                      if (ch.destructive)
                        Tag(
                          'pericoloso',
                          color: c.danger,
                          tooltip: tab.dropExtra
                              ? 'Elimina dati o oggetti'
                              : 'Attiva "Elimina oggetti in più" per includerla',
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
    // Columns: source name, source definition, target name, target definition.
    ColumnDef? colOf(ColumnDiff d, int col) => col < 2 ? d.source : d.target;
    Color? highlight(ColumnDiff d, bool left) => switch (d.status) {
      DiffStatus.onlyInSource => left ? c.diffAdded : null,
      DiffStatus.onlyInTarget => left ? null : c.diffRemoved,
      DiffStatus.different => c.diffChanged,
      DiffStatus.identical => null,
    };
    return MacTable(
      headers: ['Origine · ${tab.source.label}', 'Definizione', 'Destinazione · ${tab.target.label}', 'Definizione'],
      rowCount: rows.length,
      shrinkWrap: true,
      bordered: true,
      resizable: false,
      // Names 200, definitions share the rest (at least 120 each).
      width: (col) => col.isEven ? 200 : 120,
      flex: (col) => col.isOdd ? 1 : null,
      rowStatus: (r) => switch (rows[r].status) {
        DiffStatus.onlyInSource => c.diffAdded,
        DiffStatus.onlyInTarget => c.diffRemoved,
        DiffStatus.different => c.diffChanged,
        DiffStatus.identical => null,
      },
      cell: (r, col) {
        final x = colOf(rows[r], col);
        if (x == null) return '';
        return col.isEven ? x.name : _colText(x);
      },
      cellBuilder: (context, r, col) {
        final d = rows[r];
        final x = colOf(d, col);
        if (x == null) return const SizedBox.shrink();
        if (col.isEven) {
          return Text(
            x.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: uiText(
              TypeSize.body,
              weight: FontWeight.w500,
              color: d.aspects.contains(ColumnAspect.name) ? c.diffChanged : c.text,
            ),
          );
        }
        final h = highlight(d, col < 2);
        if (h == null) return TypeLabel(_colText(x), mono: true, size: TypeSize.small);
        return Text(
          _colText(x),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: monoStyle(context, size: TypeSize.monoSmall, color: h),
        );
      },
      tooltip: (r, _) {
        final a = rows[r].aspects;
        return a.isEmpty ? null : 'Differenze: ${a.map((x) => x.label).join(', ')}';
      },
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
                child: Text(text, style: uiText(TypeSize.body, color: c.text)),
              ),
              const SizedBox(width: Gap.sm),
              Tag(statusTag(s), color: statusColor(c, s)),
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
          PaneBar(
            padding: const EdgeInsets.only(left: Gap.md, right: Gap.sm),
            children: [
              Text(
                'Script di migrazione',
                style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text),
              ),
              const SizedBox(width: Gap.sm),
              CountBadge(count, tooltip: '$count istruzioni'),
              if (tab.targetDialect != null) ...[
                const SizedBox(width: Gap.sm),
                Text(tab.targetDialect!.dbmsName, style: uiText(TypeSize.small, color: c.textTertiary)),
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
              ToolButton(icon: AppIcons.save, tooltip: 'Salva…', onPressed: count == 0 ? null : () => _save(script)),
              const ToolSeparator(),
              const SizedBox(width: Gap.xs),
              PushButton.primary(
                label: 'Esegui sulla destinazione',
                icon: AppIcons.run,
                size: ControlScale.small,
                tooltip: readOnly ? 'La destinazione è in sola lettura' : 'Esegui lo script su ${tab.target.label}',
                onPressed: count == 0 || readOnly || _running ? null : () => _execute(statements),
              ),
            ],
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
                : SqlCodeView(text: script),
          ),
        ],
      ),
    );
  }
}
