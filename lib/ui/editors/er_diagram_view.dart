import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../features/design/ddl_script.dart';
import '../../features/schema/ddl_execution.dart';
import '../../features/schema/erd_dialogs.dart';
import '../../features/schema/schema_diff.dart';
import '../../features/schema/schema_migration.dart';
import '../../features/schema/schema_model.dart';
import '../../features/schema/schema_snapshot.dart';
import '../../model/db_objects.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../widgets/common.dart';

/// Edit state of a table or column in the diagram editor.
enum _Mark { none, added, modified, deleted }

class _Entity {
  _Entity(this.table, this.columns, this.pk, this.pos, {String? id}) : id = id ?? table.key;

  /// Stable identity (original table key, or "new:N" for tables created in
  /// the editor).
  final String id;
  DbTable table;
  List<DbColumn> columns;
  Set<String> pk;
  Offset pos;
  _Mark mark = _Mark.none;
  Map<String, _Mark> colMarks = const {};

  static const double headerH = 24;
  static const double rowH = 18;
  static const int maxCols = 18;

  Size get size {
    final longest = columns.fold<int>(
      table.name.length + 4 + (mark == _Mark.none ? 0 : 11),
      (m, c) => math.max(m, c.name.length + c.fullType.length + 3),
    );
    final shown = math.min(columns.length, maxCols) + (columns.length > maxCols ? 1 : 0);
    return Size((longest * 6.8 + 36).clamp(150.0, 340.0), headerH + shown * rowH + 6);
  }

  Rect get rect => pos & size;

  double rowY(String column) {
    final i = columns.indexWhere((c) => c.name == column);
    if (i < 0 || i >= maxCols) return pos.dy + headerH / 2;
    return pos.dy + headerH + i * rowH + rowH / 2;
  }
}

/// Pending schema edits of a diagram: [working] is the wanted definition of
/// every table (by entity id), [original] the definition read from the
/// database. The DDL is the migration from [original] to [working].
class _ErdEdits {
  final Map<String, TableDef> original = {};
  final Map<String, TableDef> working = {};
  final Set<String> deleted = {};
  int seq = 0;
  SchemaDiff? diff;
  List<String> statements = const [];
  List<DbForeignKey> fks = const [];
  Set<String> newFks = const {};

  int get count => diff?.changeCount() ?? 0;
}

/// Diagram state kept while edits are pending, so that rebuilding the view
/// (e.g. after a reconnection) does not lose them. Keyed by the positions map
/// of the tab, which lives as long as the tab.
class _Persisted {
  _Persisted(this.entities, this.fks, this.skipped, this.edits);
  final List<_Entity> entities;
  final List<DbForeignKey> fks;
  final int skipped;
  final _ErdEdits edits;
}

final _persisted = Expando<_Persisted>('erd_edits');

String _fkKey(DbForeignKey f) => '${f.fkTable}|${f.name ?? ''}|${f.columns.join(',')}|${f.pkTable}';

String _defFkKey(String table, ForeignKeyDef f) => '$table|${f.name ?? ''}|${f.columns.join(',')}|${f.refTable}';

int _odbcRule(FkRule r) => switch (r) {
  FkRule.cascade => 0,
  FkRule.restrict => 1,
  FkRule.setNull => 2,
  FkRule.noAction => 3,
  FkRule.setDefault => 4,
};

/// Points along the line drawn for [f] (same geometry as the painter).
List<Offset> _fkPolyline(_Entity from, _Entity to, DbForeignKey f) {
  final y1 = from.rowY(f.columns.isEmpty ? '' : f.columns.first);
  final y2 = to.rowY(f.refColumns.isEmpty ? '' : f.refColumns.first);
  if (from == to) {
    final a = Offset(from.rect.right, y1), b = Offset(from.rect.right, y2 + 6);
    return [a, a + const Offset(30, 0), Offset(a.dx + 30, b.dy), b];
  }
  final leftToRight = from.rect.center.dx <= to.rect.center.dx;
  final a = Offset(leftToRight ? from.rect.right : from.rect.left, y1);
  final b = Offset(leftToRight ? to.rect.left : to.rect.right, y2);
  final midX = (a.dx + b.dx) / 2;
  final c1 = Offset(midX, a.dy), c2 = Offset(midX, b.dy);
  return [
    for (var i = 0; i <= 24; i++)
      () {
        final t = i / 24, u = 1 - t;
        return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
      }(),
  ];
}

double _distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len = ab.distanceSquared;
  if (len == 0) return (p - a).distance;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// Entity-relationship diagram built from foreign key metadata.
///
/// The "Modifica" toggle turns it into a schema designer: tables and
/// relationships can be created, changed and deleted; the changes stay
/// pending until the generated DDL is reviewed and executed.
class ErDiagramView extends StatefulWidget {
  const ErDiagramView({
    super.key,
    required this.connection,
    required this.catalog,
    required this.schema,
    this.focus,
    required this.positions,
  });

  final DbConnection connection;
  final String? catalog;
  final String? schema;
  final DbTable? focus;

  /// Positions remembered across rebuilds (keyed by table key).
  final Map<String, Offset> positions;

  @override
  State<ErDiagramView> createState() => _ErDiagramViewState();
}

class _ErDiagramViewState extends State<ErDiagramView> {
  final List<_Entity> _entities = [];
  final List<DbForeignKey> _fks = [];
  final _transform = TransformationController();
  final _boundary = GlobalKey();
  bool _loading = true;
  String? _error;
  String? _selected;
  int _skipped = 0;

  /// Last click on a table box, to tell a double click without delaying the
  /// single one.
  String? _lastTapId;
  DateTime? _lastTapAt;

  /// The schema has no tables (the editor can still create some).
  bool _noTables = false;

  // Edit mode
  bool _editMode = false;
  bool _preparing = false;
  _ErdEdits? _edits;
  String? _selectedFk;
  _Entity? _dragFrom;
  String? _dragColumn;
  Offset? _dragA, _dragB;

  static const int _maxTables = 80;

  @override
  void initState() {
    super.initState();
    final p = _persisted[widget.positions];
    if (p != null) {
      _entities.addAll(p.entities);
      _fks.addAll(p.fks);
      _skipped = p.skipped;
      _edits = p.edits;
      _editMode = true;
      _loading = false;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final md = widget.connection.metadata;
    if (md == null) {
      setState(() {
        _loading = false;
        _error = 'Connessione non attiva';
      });
      return;
    }
    try {
      List<DbTable> tables;
      if (widget.focus != null) {
        final f = widget.focus!;
        final fks = await md.foreignKeys(f);
        final refs = await md.referencedBy(f);
        final set = <String, DbTable>{f.key: f};
        for (final k in [...fks, ...refs]) {
          for (final (cat, sch, name) in [(k.pkCatalog, k.pkSchema, k.pkTable), (k.fkCatalog, k.fkSchema, k.fkTable)]) {
            final t = DbTable(catalog: cat ?? f.catalog, schema: sch ?? f.schema, name: name, type: 'TABLE');
            set.putIfAbsent(t.key, () => t);
          }
        }
        tables = set.values.toList();
      } else {
        tables = (await md.tables(widget.catalog, widget.schema)).where((t) => !t.isView).toList();
      }
      _skipped = math.max(0, tables.length - _maxTables);
      tables = tables.take(_maxTables).toList();
      final keys = tables.map((t) => t.key).toSet();
      final names = tables.map((t) => t.name).toSet();
      final perRow = math.max(1, math.sqrt(tables.length).ceil());
      for (var i = 0; i < tables.length; i++) {
        final t = tables[i];
        final cols = await md.columns(t);
        final pk = await md.primaryKey(t);
        final pos = widget.positions[t.key] ?? Offset(40.0 + (i % perRow) * 380, 40.0 + (i ~/ perRow) * 340);
        _entities.add(_Entity(t, cols, pk?.columns.toSet() ?? {}, pos));
        for (final fk in await md.foreignKeys(t)) {
          if (names.contains(fk.pkTable)) _fks.add(fk);
        }
        if (mounted && i % 5 == 0) setState(() {});
      }
      _fks.removeWhere((f) => !names.contains(f.fkTable));
      if (keys.isEmpty) {
        _error = 'Nessuna tabella';
        _noTables = true;
      }
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Relationships currently drawn (pending ones in edit mode).
  List<DbForeignKey> get _shownFks => _edits?.fks ?? _fks;

  _Entity? _byName(String name) {
    for (final e in _entities) {
      if (e.table.name == name) return e;
    }
    return null;
  }

  void _autoLayout() {
    // Simple layered layout: referenced tables on the left.
    final level = <String, int>{for (final e in _entities) e.table.name: 0};
    for (var iter = 0; iter < _entities.length; iter++) {
      var changed = false;
      for (final f in _shownFks) {
        if (f.fkTable == f.pkTable) continue;
        final want = (level[f.pkTable] ?? 0) + 1;
        if ((level[f.fkTable] ?? 0) < want && want < 12) {
          level[f.fkTable] = want;
          changed = true;
        }
      }
      if (!changed) break;
    }
    final byLevel = <int, List<_Entity>>{};
    for (final e in _entities) {
      byLevel.putIfAbsent(level[e.table.name]!, () => []).add(e);
    }
    for (final entry in byLevel.entries) {
      var y = 40.0;
      for (final e in entry.value) {
        e.pos = Offset(40.0 + entry.key * 400, y);
        y += e.size.height + 40;
      }
    }
    _remember();
    setState(() {});
  }

  void _remember() {
    for (final e in _entities) {
      widget.positions[e.table.key] = e.pos;
    }
  }

  void _zoom(double f) {
    final m = _transform.value.clone()..scaleByDouble(f, f, 1, 1);
    _transform.value = m;
  }

  Future<void> _exportPng() async {
    final ro = _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (ro == null) return;
    final image = await ro.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final loc = await getSaveLocation(suggestedName: 'diagramma_er.png');
    if (loc == null) return;
    await File(loc.path).writeAsBytes(bytes.buffer.asUint8List());
    if (mounted) showToast(context, 'Diagramma salvato in ${loc.path}');
  }

  // -------------------------------------------------------------------------
  // Edit mode
  // -------------------------------------------------------------------------

  bool get _canEdit => widget.connection.dialect.isSql && (_error == null || _noTables);

  String? get _catalog => widget.focus?.catalog ?? widget.catalog;
  String? get _schema => widget.focus?.schema ?? widget.schema;

  Future<void> _toggleEdit() async {
    if (!_editMode) return _enterEdit();
    final n = _edits?.count ?? 0;
    if (n > 0) {
      final ok = await confirmDialog(
        context,
        'Uscire dalla modifica?',
        n == 1 ? 'La modifica non applicata andrà persa.' : 'Le $n modifiche non applicate andranno perse.',
        ok: 'Scarta',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _discard();
      _edits = null;
      _editMode = false;
      _selectedFk = null;
    });
    _persisted[widget.positions] = null;
  }

  /// Reads the full definition (with indexes) of every table on the diagram.
  Future<void> _enterEdit() async {
    final md = widget.connection.metadata;
    if (md == null) return;
    setState(() => _preparing = true);
    try {
      final edits = _ErdEdits();
      for (final en in _entities) {
        final t = en.table;
        final parts = await Future.wait<Object?>([md.columns(t), md.primaryKey(t), md.foreignKeys(t), md.indexes(t)]);
        final def = TableDef.fromMetadata(
          t,
          parts[0] as List<DbColumn>,
          primaryKey: parts[1] as DbPrimaryKey?,
          foreignKeys: parts[2] as List<DbForeignKey>,
          indexes: parts[3] as List<DbIndex>,
        );
        edits.original[en.id] = def;
      }
      _edits = edits;
      _discard();
      _editMode = true;
      _error = null;
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Impossibile leggere la struttura delle tabelle');
    }
    if (mounted) setState(() => _preparing = false);
  }

  /// Resets the working definitions to the database ones.
  void _discard() {
    final e = _edits;
    if (e == null) return;
    _entities.removeWhere((en) => !e.original.containsKey(en.id));
    e.deleted.clear();
    e.working
      ..clear()
      ..addAll({
        for (final x in e.original.entries)
          x.key: x.value.copyWith(
            originalName: x.value.name,
            columns: [for (final c in x.value.columns) c.copyWith(originalName: c.name)],
          ),
      });
    _selected = null;
    _selectedFk = null;
    _recompute();
  }

  /// Diffs the working definitions against the database ones, regenerates
  /// the DDL and refreshes markers and relationships on the diagram.
  void _recompute() {
    final e = _edits;
    if (e == null) return;
    final dialect = widget.connection.dialect;
    final diff = SchemaDiff.compare(
      SchemaSnapshot(tables: e.working.values.toList(), family: dialect.family),
      SchemaSnapshot(tables: e.original.values.toList(), family: dialect.family),
      options: const CompareOptions(ignoreCase: false, ignoreComments: false),
    );
    e.diff = diff;
    e.statements = SchemaMigration(dialect)
        .generate(diff, options: const MigrationOptions(dropExtra: true, relocate: false));

    final byWorking = {for (final x in e.working.entries) x.value.name: x.key};
    final byOriginal = {for (final x in e.original.entries) x.value.name: x.key};
    final marks = <String, (_Mark, Map<String, _Mark>, List<ColumnDef>)>{};
    final newFks = <String>{};
    for (final td in diff.tables) {
      switch (td.status) {
        case DiffStatus.onlyInSource:
          final id = byWorking[td.name];
          if (id != null) marks[id] = (_Mark.added, const {}, const []);
          for (final f in td.source!.foreignKeys) {
            newFks.add(_defFkKey(td.source!.name, f));
          }
        case DiffStatus.onlyInTarget:
          final id = byOriginal[td.name];
          if (id != null) marks[id] = (_Mark.deleted, const {}, const []);
        case DiffStatus.different:
          final id = byWorking[td.source!.name];
          if (id == null) break;
          final cols = <String, _Mark>{};
          final removed = <ColumnDef>[];
          for (final c in td.columns) {
            switch (c.status) {
              case DiffStatus.onlyInSource:
                cols[c.name] = _Mark.added;
              case DiffStatus.different:
                cols[c.name] = _Mark.modified;
              case DiffStatus.onlyInTarget:
                cols[c.name] = _Mark.deleted;
                removed.add(c.target!);
              case DiffStatus.identical:
                break;
            }
          }
          marks[id] = (_Mark.modified, cols, removed);
          for (final f in td.foreignKeys) {
            if (f.source != null && f.status != DiffStatus.identical) newFks.add(_defFkKey(td.source!.name, f.source!));
          }
        case DiffStatus.identical:
          break;
      }
    }

    for (final en in _entities) {
      final def = e.working[en.id] ?? e.original[en.id];
      if (def == null) continue;
      final m = marks[en.id];
      en.table = DbTable(catalog: def.catalog, schema: def.schema, name: def.name, type: 'TABLE', remarks: def.comment);
      en.columns = [
        for (final (i, c) in def.columns.indexed) c.toDbColumn(i + 1),
        for (final c in m?.$3 ?? const <ColumnDef>[])
          if (def.column(c.name) == null) c.toDbColumn(0),
      ];
      en.pk = def.primaryKey?.columns.toSet() ?? {};
      en.mark = e.deleted.contains(en.id) ? _Mark.deleted : (m?.$1 ?? _Mark.none);
      en.colMarks = m?.$2 ?? const {};
    }

    final names = {for (final t in e.working.values) t.name};
    e.fks = [
      for (final t in e.working.values)
        for (final f in t.foreignKeys)
          if (names.contains(f.refTable))
            DbForeignKey(
              name: f.name,
              pkCatalog: f.refCatalog,
              pkSchema: f.refSchema,
              pkTable: f.refTable,
              fkCatalog: t.catalog,
              fkSchema: t.schema,
              fkTable: t.name,
              columns: f.columns,
              refColumns: f.refColumns,
              updateRule: _odbcRule(f.onUpdate),
              deleteRule: _odbcRule(f.onDelete),
            ),
    ];
    e.newFks = newFks;
    _persisted[widget.positions] = _Persisted(_entities, _fks, _skipped, e);
  }

  Set<String> _takenNames({String? except}) {
    final e = _edits!;
    return {
      for (final x in e.working.entries)
        if (x.key != except) x.value.name,
      for (final id in e.deleted) e.original[id]!.name,
    };
  }

  Future<void> _newTable() async {
    final e = _edits;
    if (e == null) return;
    final r = await showTableDefDialog(
      context,
      dialect: widget.connection.dialect,
      catalog: _catalog,
      schema: _schema,
      takenNames: _takenNames(),
    );
    if (r == null || !mounted) return;
    final p = _transform.toScene(const Offset(60, 60));
    setState(() {
      final id = 'new:${e.seq++}';
      e.working[id] = r.table;
      final en = _Entity(r.table.toDbTable(), [], {}, Offset(math.max(0, p.dx), math.max(0, p.dy)), id: id);
      _entities.add(en);
      _recompute();
      // Place the new table on a free spot near the top-left of the view.
      for (var i = 0; i < 200 && _entities.any((o) => o != en && o.rect.inflate(20).overlaps(en.rect)); i++) {
        en.pos = en.pos + (i % 10 == 9 ? Offset(-9 * 60, 60) : const Offset(60, 0));
      }
      _selected = r.table.name;
      _selectedFk = null;
      _recompute();
    });
  }

  Future<void> _editTable(_Entity en) async {
    final e = _edits;
    final def = e?.working[en.id];
    if (e == null || def == null) return;
    final r = await showTableDefDialog(
      context,
      dialect: widget.connection.dialect,
      initial: def,
      takenNames: _takenNames(except: en.id),
    );
    if (r == null || !mounted) return;
    setState(() {
      _applyTableEdit(en.id, def, r);
      _recompute();
    });
  }

  /// Stores the edited table and keeps keys, indexes and the relationships
  /// of the other tables consistent with renamed / removed columns.
  void _applyTableEdit(String id, TableDef before, TableEditResult r) {
    final e = _edits!;
    String col(String c) => r.renamedColumns[c] ?? c;
    bool gone(List<String> cols) => cols.any(r.removedColumns.contains);
    final t = r.table;
    e.working[id] = t.copyWith(
      foreignKeys: [
        for (final f in t.foreignKeys)
          if (!gone(f.columns)) f.copyWith(columns: f.columns.map(col).toList()),
      ],
      indexes: [
        for (final i in t.indexes)
          if (!gone(i.columns)) i.copyWith(columns: i.columns.map(col).toList()),
      ],
    );
    for (final k in e.working.keys.toList()) {
      final o = e.working[k]!;
      if (!o.foreignKeys.any((f) => f.refTable == before.name)) continue;
      e.working[k] = o.copyWith(
        foreignKeys: [
          for (final f in o.foreignKeys)
            if (f.refTable != before.name)
              f
            else if (!gone(f.refColumns))
              f.copyWith(refTable: t.name, refColumns: f.refColumns.map(col).toList()),
        ],
      );
    }
    if (_selected == before.name) _selected = t.name;
  }

  Future<void> _deleteSelected() async {
    final e = _edits;
    if (e == null) return;
    final fkKey = _selectedFk;
    if (fkKey != null) {
      final fk = e.fks.where((f) => _fkKey(f) == fkKey).firstOrNull;
      if (fk == null) return;
      final ok = await confirmDialog(
        context,
        'Elimina relazione',
        'Eliminare la relazione ${fk.name ?? ''} tra ${fk.fkTable} e ${fk.pkTable}?',
        ok: 'Elimina',
        destructive: true,
      );
      if (!ok || !mounted) return;
      setState(() {
        for (final k in e.working.keys.toList()) {
          final t = e.working[k]!;
          if (t.name != fk.fkTable) continue;
          e.working[k] = t.copyWith(foreignKeys: t.foreignKeys.where((f) => _defFkKey(t.name, f) != fkKey).toList());
        }
        _selectedFk = null;
        _recompute();
      });
      return;
    }
    final en = _selected == null ? null : _byName(_selected!);
    if (en == null || en.mark == _Mark.deleted) return;
    final name = en.table.name;
    final refs = e.working.entries
        .where((x) => x.key != en.id)
        .expand((x) => x.value.foreignKeys)
        .where((f) => f.refTable == name)
        .length;
    final isNew = !e.original.containsKey(en.id);
    final ok = await confirmDialog(
      context,
      'Elimina tabella',
      'Eliminare la tabella "$name"?'
          '${refs > 0 ? '\nVerranno eliminate anche $refs relazioni che la referenziano.' : ''}'
          '${isNew ? '' : '\nLa tabella e i suoi dati saranno eliminati quando eseguirai lo script.'}',
      ok: 'Elimina',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      e.working.remove(en.id);
      for (final k in e.working.keys.toList()) {
        final t = e.working[k]!;
        if (t.foreignKeys.any((f) => f.refTable == name)) {
          e.working[k] = t.copyWith(foreignKeys: t.foreignKeys.where((f) => f.refTable != name).toList());
        }
      }
      if (isNew) {
        _entities.remove(en);
      } else {
        e.deleted.add(en.id);
      }
      _selected = null;
      _recompute();
    });
  }

  Future<void> _discardAll() async {
    final n = _edits?.count ?? 0;
    if (n == 0) return;
    final ok = await confirmDialog(
      context,
      'Annulla modifiche',
      n == 1 ? 'Scartare la modifica non applicata?' : 'Scartare le $n modifiche non applicate?',
      ok: 'Scarta',
      destructive: true,
    );
    if (ok && mounted) setState(_discard);
  }

  Future<void> _review() async {
    final e = _edits;
    if (e == null) return;
    final ok = await showDdlScriptDialog(
      context,
      dc: widget.connection,
      script: DdlScript(e.statements, scope: SchemaScope.schema(widget.catalog, widget.schema)),
      title: 'Modifiche allo schema',
    );
    if (!ok || !mounted) return;
    // Keep the layout of new and renamed tables.
    for (final en in _entities) {
      final def = e.working[en.id];
      if (def != null) widget.positions[def.toDbTable().key] = en.pos;
    }
    _persisted[widget.positions] = null;
    setState(() {
      _edits = null;
      _editMode = false;
      _entities.clear();
      _fks.clear();
      _selected = null;
      _selectedFk = null;
      _error = null;
      _noTables = false;
      _loading = true;
    });
    await _load();
    if (mounted && _canEdit) await _enterEdit();
  }

  Offset? _toCanvas(Offset global) {
    final box = _boundary.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  void _tapCanvas(TapUpDetails d) {
    final p = d.localPosition;
    String? hit;
    var best = 6.0;
    for (final f in _shownFks) {
      final from = _byName(f.fkTable), to = _byName(f.pkTable);
      if (from == null || to == null) continue;
      final pts = _fkPolyline(from, to, f);
      for (var i = 0; i < pts.length - 1; i++) {
        final dist = _distanceToSegment(p, pts[i], pts[i + 1]);
        if (dist < best) {
          best = dist;
          hit = _fkKey(f);
        }
      }
    }
    setState(() {
      _selectedFk = hit;
      _selected = null;
    });
  }

  void _clearDrag() {
    _dragFrom = null;
    _dragColumn = null;
    _dragA = null;
    _dragB = null;
  }

  Future<void> _endRelationDrag() async {
    final from = _dragFrom, col = _dragColumn, p = _dragB;
    setState(_clearDrag);
    final e = _edits;
    if (from == null || col == null || p == null || e == null) return;
    _Entity? to;
    for (final en in _entities.reversed) {
      if (en.mark != _Mark.deleted && en.rect.contains(p)) {
        to = en;
        break;
      }
    }
    if (to == null) return;
    final i = ((p.dy - to.pos.dy - _Entity.headerH) / _Entity.rowH).floor();
    if (i < 0 || i >= math.min(to.columns.length, _Entity.maxCols)) return;
    final toCol = to.columns[i].name;
    final child = e.working[from.id], parent = e.working[to.id];
    if (child == null || parent == null || parent.column(toCol) == null) return;
    if (from == to && col == toCol) return;
    final fk = await showRelationDialog(
      context,
      child: child,
      childColumn: col,
      parent: parent,
      parentColumn: toCol,
      takenNames: {
        for (final t in e.working.values)
          for (final f in t.foreignKeys)
            if (f.name != null) f.name!.toLowerCase(),
      },
    );
    if (fk == null || !mounted) return;
    setState(() {
      final cur = e.working[from.id]!;
      e.working[from.id] = cur.copyWith(foreignKeys: [...cur.foreignKeys, fk]);
      _selectedFk = null;
      _recompute();
    });
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    var w = 1200.0, h = 900.0;
    for (final e in _entities) {
      w = math.max(w, e.rect.right + 200);
      h = math.max(h, e.rect.bottom + 200);
    }
    final edits = _edits;
    final count = edits?.count ?? 0;
    final shownTables = _entities.where((e) => e.mark != _Mark.deleted).length;
    final showCanvas = _error == null || (_editMode && _noTables);
    final relations = CustomPaint(
      painter: _RelationsPainter(
        entities: _entities,
        fks: _shownFks,
        byName: _byName,
        color: c.textTertiary,
        selected: _selected,
        selectedFk: _selectedFk,
        newFks: edits?.newFks ?? const {},
        addedColor: c.success,
        selectedColor: c.accent,
      ),
    );
    return Column(
      children: [
        PaneBar(
          children: [
            ToolButton(icon: AppIcons.zoomIn, tooltip: 'Zoom +', onPressed: () => _zoom(1.2)),
            ToolButton(icon: AppIcons.zoomOut, tooltip: 'Zoom -', onPressed: () => _zoom(1 / 1.2)),
            ToolButton(
              icon: AppIcons.fitScreen,
              tooltip: 'Zoom 100%',
              onPressed: () => _transform.value = Matrix4.identity(),
            ),
            ToolButton(icon: AppIcons.mosaic, tooltip: 'Disposizione automatica', onPressed: _autoLayout),
            ToolButton(icon: AppIcons.image, tooltip: 'Esporta PNG…', onPressed: _exportPng),
            if (widget.connection.dialect.isSql) ...[
              const ToolSeparator(),
              ToolButton(
                icon: AppIcons.edit,
                label: 'Modifica',
                active: _editMode,
                tooltip: _editMode ? 'Esci dalla modalità modifica' : 'Modifica lo schema nel diagramma',
                onPressed: _loading || _preparing || !_canEdit && !_editMode ? null : _toggleEdit,
              ),
              if (_editMode) ...[
                ToolButton(
                  icon: AppIcons.addBox,
                  label: 'Nuova tabella',
                  tooltip: 'Crea una nuova tabella',
                  onPressed: _newTable,
                ),
                ToolButton(
                  icon: AppIcons.delete,
                  tooltip: 'Elimina la tabella o la relazione selezionata',
                  onPressed: _selectedFk != null || (_selected != null && _byName(_selected!)?.mark != _Mark.deleted)
                      ? _deleteSelected
                      : null,
                ),
              ],
            ],
            const SizedBox(width: Gap.md),
            Text(
              '$shownTables tabelle · ${_shownFks.length} relazioni'
              '${_skipped > 0 ? ' · $_skipped tabelle omesse' : ''}',
              style: uiText(TypeSize.small, color: c.textSecondary, features: kTabular),
            ),
            if (_loading || _preparing) ...[const SizedBox(width: Gap.md), const Spinner(size: Spinner.small)],
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(
                _editMode
                    ? 'Trascina l\'intestazione per spostare · da una colonna a un\'altra per collegare · doppio clic per modificare'
                    : 'Trascina le tabelle · doppio clic per aprire',
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: uiText(TypeSize.small, color: c.textTertiary),
              ),
            ),
          ],
        ),
        Expanded(
          child: !showCanvas
              ? _emptyState()
              : InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  minScale: 0.2,
                  maxScale: 3,
                  boundaryMargin: const EdgeInsets.all(400),
                  child: RepaintBoundary(
                    key: _boundary,
                    child: Container(
                      width: w,
                      height: h,
                      color: c.content,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: _editMode
                                ? GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapUp: _tapCanvas,
                                    child: relations,
                                  )
                                : relations,
                          ),
                          for (final e in _entities) _box(e),
                          if (_dragA != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _RelationsPainter(
                                    entities: _entities,
                                    fks: const [],
                                    byName: _byName,
                                    color: c.accent,
                                    selected: null,
                                    selectedColor: c.accent,
                                    dragFrom: _dragA,
                                    dragTo: _dragB,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
        if (_editMode) _footer(c, count),
      ],
    );
  }

  Widget _emptyState() => _noTables
      ? const EmptyState(icon: AppIcons.erDiagram, title: 'Nessuna tabella')
      : widget.connection.metadata == null
      ? EmptyState(icon: AppIcons.disconnect, title: _error!)
      : EmptyState.error(_error!, title: 'Impossibile leggere lo schema');

  /// Pending-changes bar under the canvas.
  Widget _footer(DbColors c, int count) => PaneBar.footer(
    padding: const EdgeInsets.symmetric(horizontal: Gap.md),
    children: [
      Icon(AppIcons.script, size: 16, color: count > 0 ? c.warning : c.textTertiary),
      const SizedBox(width: Gap.sm),
      Text(
        count == 0 ? 'Nessuna modifica' : (count == 1 ? '1 modifica' : '$count modifiche'),
        style: uiText(TypeSize.body, color: count > 0 ? c.text : c.textSecondary, features: kTabular),
      ),
      if (widget.connection.config.readOnly) ...[const SizedBox(width: Gap.md), const Tag('sola lettura')],
      const Spacer(),
      ToolButton(
        icon: AppIcons.undo,
        label: 'Annulla modifiche',
        tooltip: 'Scarta tutte le modifiche non applicate',
        onPressed: count > 0 ? _discardAll : null,
      ),
      const SizedBox(width: Gap.sm),
      PushButton.primary(
        label: 'Rivedi script…',
        icon: AppIcons.document,
        size: ControlScale.small,
        onPressed: count > 0 ? _review : null,
      ),
    ],
  );

  /// Click on a table box: selects it; a second click within the double-tap
  /// timeout opens it (or edits it in edit mode).
  void _tapBox(_Entity e) {
    final now = DateTime.now();
    final last = _lastTapAt;
    final isDouble = _lastTapId == e.id && last != null && now.difference(last) <= kDoubleTapTimeout;
    _lastTapId = isDouble ? null : e.id;
    _lastTapAt = isDouble ? null : now;
    if (!isDouble) {
      setState(() {
        _selected = e.table.name;
        _selectedFk = null;
      });
    } else if (!_editMode) {
      AppScope.read(context).openTable(widget.connection, e.table);
    } else if (e.mark != _Mark.deleted) {
      _editTable(e);
    }
  }

  Widget _box(_Entity e) {
    final c = DbColors.of(context);
    final selected = _selected == e.table.name;
    final shown = e.columns.take(_Entity.maxCols).toList();
    final fkCols = _shownFks.where((f) => f.fkTable == e.table.name).expand((f) => f.columns).toSet();
    final deleted = e.mark == _Mark.deleted;
    final markColor = switch (e.mark) {
      _Mark.added => c.success,
      _Mark.modified => c.warning,
      _Mark.deleted => c.danger,
      _Mark.none => null,
    };
    // Canvas node: raised box with the node shadow; edit marks draw a colored
    // outline over it (foreground, so the rows do not move).
    final box = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(Radii.menu),
        boxShadow: Elevation.node(Theme.of(context).brightness),
      ),
      foregroundDecoration: markColor == null
          ? null
          : BoxDecoration(
              border: Border.all(color: markColor, width: 1.5),
              borderRadius: BorderRadius.circular(Radii.menu),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: _Entity.headerH,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            color: (markColor ?? c.accent).withValues(alpha: selected ? Tint.regular : Tint.subtle),
            child: Row(
              children: [
                Icon(AppIcons.table, size: 14, color: markColor ?? c.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    e.table.name,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(
                      TypeSize.small,
                      weight: FontWeight.w600,
                      color: c.text,
                    ).copyWith(decoration: deleted ? TextDecoration.lineThrough : null),
                  ),
                ),
                if (markColor != null)
                  Tag(switch (e.mark) {
                    _Mark.added => 'nuova',
                    _Mark.modified => 'modificata',
                    _ => 'eliminata',
                  }, color: markColor),
              ],
            ),
          ),
          for (final col in shown) _row(e, col, fkCols),
          if (e.columns.length > _Entity.maxCols)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '… altre ${e.columns.length - _Entity.maxCols} colonne',
                style: uiText(TypeSize.mini, color: c.textTertiary),
              ),
            ),
        ],
      ),
    );
    final node = FocusRing(visible: selected, radius: Radii.menu, child: box);
    return Positioned(
      left: e.pos.dx,
      top: e.pos.dy,
      width: e.size.width,
      height: e.size.height,
      child: GestureDetector(
        supportedDevices: kCanvasDragDevices,
        onTap: () => _tapBox(e),
        onPanUpdate: (d) => setState(() {
          e.pos += d.delta;
          if (e.pos.dx < 0) e.pos = Offset(0, e.pos.dy);
          if (e.pos.dy < 0) e.pos = Offset(e.pos.dx, 0);
        }),
        onPanEnd: (_) => _remember(),
        child: deleted ? Opacity(opacity: 0.6, child: node) : node,
      ),
    );
  }

  Widget _row(_Entity e, DbColumn col, Set<String> fkCols) {
    final c = DbColors.of(context);
    final mark = e.colMarks[col.name] ?? _Mark.none;
    final markColor = switch (mark) {
      _Mark.added => c.success,
      _Mark.modified => c.warning,
      _Mark.deleted => c.danger,
      _Mark.none => null,
    };
    final isPk = e.pk.contains(col.name);
    Widget row = SizedBox(
      height: _Entity.rowH,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            Icon(
              isPk
                  ? AppIcons.key
                  : fkCols.contains(col.name)
                  ? AppIcons.link
                  : AppIcons.dot,
              size: isPk || fkCols.contains(col.name) ? 11 : 5,
              color: isPk
                  ? c.keyIcon
                  : fkCols.contains(col.name)
                  ? c.foreignKeyIcon
                  : c.textTertiary,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                col.name,
                overflow: TextOverflow.ellipsis,
                style: uiText(
                  TypeSize.caption,
                  weight: isPk ? FontWeight.w600 : null,
                  color: markColor ?? c.text,
                ).copyWith(decoration: mark == _Mark.deleted ? TextDecoration.lineThrough : null),
              ),
            ),
            const SizedBox(width: Gap.xs),
            TypeLabel(col.fullType.toLowerCase(), mono: true, color: markColor),
          ],
        ),
      ),
    );
    if (_editMode && e.mark != _Mark.deleted && mark != _Mark.deleted) {
      // Dragging from a column creates a relationship.
      row = MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: GestureDetector(
          supportedDevices: kCanvasDragDevices,
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => setState(() {
            _dragFrom = e;
            _dragColumn = col.name;
            _dragA = Offset(e.rect.right, e.rowY(col.name));
            _dragB = _toCanvas(d.globalPosition);
          }),
          onPanUpdate: (d) => setState(() => _dragB = _toCanvas(d.globalPosition)),
          onPanEnd: (_) => _endRelationDrag(),
          onPanCancel: () => setState(_clearDrag),
          child: row,
        ),
      );
    }
    return row;
  }
}

class _RelationsPainter extends CustomPainter {
  _RelationsPainter({
    required this.entities,
    required this.fks,
    required this.byName,
    required this.color,
    required this.selected,
    this.selectedFk,
    this.newFks = const {},
    this.addedColor,
    this.selectedColor,
    this.dragFrom,
    this.dragTo,
  });

  final List<_Entity> entities;
  final List<DbForeignKey> fks;
  final _Entity? Function(String) byName;
  final Color color;
  final String? selected;

  /// Edit mode: selected relationship, pending new ones and the line being
  /// dragged to create a relationship.
  final String? selectedFk;
  final Set<String> newFks;
  final Color? addedColor;
  final Color? selectedColor;
  final Offset? dragFrom;
  final Offset? dragTo;

  @override
  void paint(Canvas canvas, Size size) {
    for (final f in fks) {
      final from = byName(f.fkTable), to = byName(f.pkTable);
      if (from == null || to == null) continue;
      final key = selectedFk != null || newFks.isNotEmpty ? _fkKey(f) : null;
      final isSel = key != null && key == selectedFk;
      final isNew = key != null && newFks.contains(key);
      final hl = isSel || (selected != null && (selected == f.fkTable || selected == f.pkTable));
      final paint = Paint()
        ..color = hl ? (selectedColor ?? color) : (isNew ? (addedColor ?? color) : color)
        ..strokeWidth = isSel ? 2.5 : (hl ? 2 : 1.2)
        ..style = PaintingStyle.stroke;
      final y1 = from.rowY(f.columns.isEmpty ? '' : f.columns.first);
      final y2 = to.rowY(f.refColumns.isEmpty ? '' : f.refColumns.first);
      Offset a, b;
      double dir1, dir2;
      if (from == to) {
        a = Offset(from.rect.right, y1);
        b = Offset(from.rect.right, y2 + 6);
        final p = Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(a.dx + 30, a.dy)
          ..lineTo(a.dx + 30, b.dy)
          ..lineTo(b.dx, b.dy);
        canvas.drawPath(p, paint);
        continue;
      }
      if (from.rect.center.dx <= to.rect.center.dx) {
        a = Offset(from.rect.right, y1);
        b = Offset(to.rect.left, y2);
        dir1 = 1;
        dir2 = -1;
      } else {
        a = Offset(from.rect.left, y1);
        b = Offset(to.rect.right, y2);
        dir1 = -1;
        dir2 = 1;
      }
      final midX = (a.dx + b.dx) / 2;
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..cubicTo(midX, a.dy, midX, b.dy, b.dx, b.dy);
      canvas.drawPath(path, paint);
      // "many" side: crow's foot on the FK table.
      final fp = Paint()
        ..color = paint.color
        ..strokeWidth = paint.strokeWidth;
      canvas.drawLine(a + Offset(dir1 * 10, 0), a + Offset(0, -5), fp);
      canvas.drawLine(a + Offset(dir1 * 10, 0), a + Offset(0, 5), fp);
      // "one" side: bar on the referenced table.
      canvas.drawLine(b + Offset(dir2 * 6, -5), b + Offset(dir2 * 6, 5), fp);
    }
    if (dragFrom != null && dragTo != null) {
      final p = Paint()
        ..color = selectedColor ?? color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(dragFrom!, dragTo!, p);
      canvas.drawCircle(dragTo!, 4, p..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
