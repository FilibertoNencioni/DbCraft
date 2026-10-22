import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../../odbc/odbc_ffi.dart';
import '../../odbc/odbc_types.dart';
import '../../services/data_transfer.dart';
import '../../state/result_set_model.dart';
import '../dialogs/value_dialog.dart';
import '../widgets/common.dart';

/// Callback used for "filter by value" in table data editors.
typedef CellFilterCallback = void Function(ColumnInfo column, Object? value, String op);

/// Spreadsheet-like data grid (DBeaver "Results viewer").
class ResultGrid extends StatefulWidget {
  const ResultGrid({
    super.key,
    required this.model,
    this.nullText = '[NULL]',
    this.fontSize = 13,
    this.onFilterByValue,
    this.onExport,
    this.simpleMode = false,
  });

  final ResultSetModel model;
  final String nullText;
  final double fontSize;
  final CellFilterCallback? onFilterByValue;
  final VoidCallback? onExport;

  /// Simplified analyst view: hides SQL-centric menu entries.
  final bool simpleMode;

  @override
  State<ResultGrid> createState() => ResultGridState();
}

class ResultGridState extends State<ResultGrid> {
  final _v = ScrollController();
  final _h = ScrollController();
  final _focus = FocusNode(debugLabel: 'grid');
  final Map<int, double> _widths = {};

  // Selection (view row index, column index)
  final Set<(int, int)> _sel = {};
  (int, int)? _anchor;
  (int, int)? _cursor;

  // Inline editing
  (int, int)? _editing;
  final _editCtrl = TextEditingController();
  final _editFocus = FocusNode();

  static const double _rowH = GridMetrics.row;
  static const double _headH = GridMetrics.header;

  bool _hasFocus = false;

  // Last primary click, for double-click detection without a gesture arena.
  (int, int)? _lastClickCell;
  Duration? _lastClickTime;

  ResultSetModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    _v.addListener(_onScroll);
    m.addListener(_onModel);
  }

  @override
  void didUpdateWidget(ResultGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
      _widths.clear();
      _sel.clear();
      _anchor = _cursor = _editing = null;
    }
  }

  @override
  void dispose() {
    m.removeListener(_onModel);
    _v.dispose();
    _h.dispose();
    _focus.dispose();
    _editCtrl.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _onModel() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_v.hasClients) return;
    if (_v.position.pixels > _v.position.maxScrollExtent - 300 && m.hasMore && !m.loading) {
      m.fetchNext();
    }
  }

  // -------------------------------------------------------------------------
  // Sizing
  // -------------------------------------------------------------------------

  double get _charW => widget.fontSize * 0.62;

  double _colWidth(int c) {
    return _widths.putIfAbsent(c, () {
      final col = m.columns[c];
      // Header shows the name plus a smaller type label.
      var maxLen = col.name.length + (col.displayType.length * 0.75).ceil() + 3;
      final n = math.min(m.view.length, 120);
      for (var i = 0; i < n; i++) {
        final v = m.rowAt(i).values[c];
        final l = v == null ? widget.nullText.length : formatValue(v, maxLen: 80).length;
        if (l > maxLen) maxLen = l;
      }
      return (maxLen * _charW + 26).clamp(64.0, 420.0);
    });
  }

  double get _rowNumWidth => math.max(44, '${m.view.length}'.length * _charW + 24);

  // -------------------------------------------------------------------------
  // Selection helpers
  // -------------------------------------------------------------------------

  void _select(int r, int c, {bool extend = false, bool toggle = false}) {
    setState(() {
      if (extend && _anchor != null) {
        _sel.clear();
        final (ar, ac) = _anchor!;
        for (var i = math.min(ar, r); i <= math.max(ar, r); i++) {
          for (var j = math.min(ac, c); j <= math.max(ac, c); j++) {
            _sel.add((i, j));
          }
        }
      } else if (toggle) {
        if (!_sel.remove((r, c))) _sel.add((r, c));
        _anchor = (r, c);
      } else {
        _sel
          ..clear()
          ..add((r, c));
        _anchor = (r, c);
      }
      _cursor = (r, c);
    });
    _ensureVisible(r, c);
  }

  void _selectRow(int r, {bool extend = false}) {
    setState(() {
      if (!extend) _sel.clear();
      final from = extend && _anchor != null ? math.min(_anchor!.$1, r) : r;
      final to = extend && _anchor != null ? math.max(_anchor!.$1, r) : r;
      for (var i = from; i <= to; i++) {
        for (var c = 0; c < m.columns.length; c++) {
          _sel.add((i, c));
        }
      }
      if (!extend) _anchor = (r, 0);
      _cursor = (r, 0);
    });
  }

  void selectAll() {
    setState(() {
      _sel.clear();
      for (var r = 0; r < m.view.length; r++) {
        for (var c = 0; c < m.columns.length; c++) {
          _sel.add((r, c));
        }
      }
    });
  }

  List<int> get selectedRows => (_sel.map((e) => e.$1).toSet().toList()..sort());

  List<int> get selectedColumns => (_sel.map((e) => e.$2).toSet().toList()..sort());

  void _ensureVisible(int r, int c) {
    if (!_v.hasClients) return;
    final top = r * _rowH;
    final viewH = _v.position.viewportDimension - _headH;
    if (top < _v.offset) {
      _v.jumpTo(top);
    } else if (top + _rowH > _v.offset + viewH) {
      _v.jumpTo(math.min(top + _rowH - viewH, _v.position.maxScrollExtent));
    }
    if (!_h.hasClients) return;
    var left = 0.0;
    for (var i = 0; i < c; i++) {
      left += _colWidth(i);
    }
    final w = _colWidth(c);
    final viewW = _h.position.viewportDimension - _rowNumWidth;
    if (left < _h.offset) {
      _h.jumpTo(left);
    } else if (left + w > _h.offset + viewW) {
      _h.jumpTo(math.min(left + w - viewW, _h.position.maxScrollExtent));
    }
  }

  // -------------------------------------------------------------------------
  // Clipboard
  // -------------------------------------------------------------------------

  String selectionAsText({bool header = false, ExportFormat? format}) {
    final rows = selectedRows;
    final cols = selectedColumns;
    if (rows.isEmpty) return '';
    final data = [
      for (final r in rows) [for (final c in cols) _sel.contains((r, c)) ? m.rowAt(r).values[c] : null],
    ];
    if (format != null) {
      return DataExporter.exportAll(
        [for (final c in cols) m.columns[c].name],
        data,
        ExportOptions(
          format: format,
          header: true,
          tableName: m.table == null ? 'table_name' : m.connection.dialect.tableName(m.table!),
          dialect: m.connection.dialect,
        ),
      );
    }
    final sb = StringBuffer();
    if (header) sb.writeln(cols.map((c) => m.columns[c].name).join('\t'));
    sb.write(data.map((r) => r.map((v) => v == null ? '' : formatValue(v)).join('\t')).join('\n'));
    return sb.toString();
  }

  void copy({bool header = false, ExportFormat? format}) {
    Clipboard.setData(
      ClipboardData(
        text: selectionAsText(header: header, format: format),
      ),
    );
  }

  Future<void> paste() async {
    if (!m.isEditable || _cursor == null) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null) return;
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final (r0, c0) = _cursor!;
    for (var i = 0; i < lines.length; i++) {
      final r = r0 + i;
      if (r >= m.view.length) m.addRow();
      final cells = lines[i].split('\t');
      for (var j = 0; j < cells.length && c0 + j < m.columns.length; j++) {
        m.setValue(r, c0 + j, _parse(m.columns[c0 + j], cells[j]));
      }
    }
  }

  // -------------------------------------------------------------------------
  // Editing
  // -------------------------------------------------------------------------

  static Object? _parse(ColumnInfo col, String s) {
    switch (col.sqlType) {
      case SQL_INTEGER:
      case SQL_SMALLINT:
      case SQL_TINYINT:
      case SQL_BIGINT:
      case SQL_BIT:
        return int.tryParse(s.trim()) ?? s;
      case SQL_REAL:
      case SQL_FLOAT:
      case SQL_DOUBLE:
        return double.tryParse(s.trim().replaceAll(',', '.')) ?? s;
      default:
        return s;
    }
  }

  void startEdit([int? r, int? c]) {
    if (!m.isEditable) {
      if (m.table == null) {
        showToast(context, 'Risultato non modificabile: impossibile determinare la tabella di origine');
      }
      return;
    }
    final cell = (r != null && c != null) ? (r, c) : _cursor;
    if (cell == null) return;
    final v = m.rowAt(cell.$1).values[cell.$2];
    if (v is Uint8List || (v is String && (v.contains('\n') || v.length > 200))) {
      openValueEditor(cell.$1, cell.$2);
      return;
    }
    setState(() {
      _editing = cell;
      _editCtrl.text = v == null ? '' : formatValue(v);
      _editCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _editCtrl.text.length);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _editFocus.requestFocus());
  }

  void _commitEdit({bool move = false}) {
    final e = _editing;
    if (e == null) return;
    final col = m.columns[e.$2];
    final old = m.rowAt(e.$1).values[e.$2];
    final text = _editCtrl.text;
    if (!(old == null && text.isEmpty) && formatValue(old) != text) {
      m.setValue(e.$1, e.$2, _parse(col, text));
    }
    setState(() => _editing = null);
    _focus.requestFocus();
    if (move && e.$1 + 1 < m.view.length) _select(e.$1 + 1, e.$2);
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _focus.requestFocus();
  }

  Future<void> openValueEditor(int r, int c) async {
    final row = m.rowAt(r);
    final res = await showValueDialog(context, column: m.columns[c], value: row.values[c], editable: m.isEditable);
    if (res != null && res.changed) m.setValue(r, c, res.value);
  }

  void setNull() {
    if (!m.isEditable) return;
    for (final (r, c) in _sel) {
      m.setValue(r, c, null);
    }
  }

  void deleteSelectedRows() {
    if (!m.isEditable) return;
    m.toggleDelete(selectedRows);
  }

  void addRow() {
    if (!m.isEditable) return;
    final after = _cursor?.$1;
    final i = m.addRow(afterViewIndex: after);
    _select(i, 0);
  }

  void duplicateRow() {
    if (!m.isEditable || _cursor == null) return;
    m.duplicateRow(_cursor!.$1);
  }

  // -------------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (_editing != null) return KeyEventResult.ignored;
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    final mod = hw.isControlPressed || hw.isMetaPressed;
    final shift = hw.isShiftPressed;
    final k = e.logicalKey;
    final cur = _cursor ?? (0, 0);
    final rows = m.view.length, cols = m.columns.length;
    if (rows == 0 || cols == 0) return KeyEventResult.ignored;

    void move(int dr, int dc) {
      final r = (cur.$1 + dr).clamp(0, rows - 1);
      final c = (cur.$2 + dc).clamp(0, cols - 1);
      _select(r, c, extend: shift);
    }

    if (mod && k == LogicalKeyboardKey.keyC) {
      copy(header: shift);
      return KeyEventResult.handled;
    }
    if (mod && k == LogicalKeyboardKey.keyV) {
      paste();
      return KeyEventResult.handled;
    }
    if (mod && k == LogicalKeyboardKey.keyA) {
      selectAll();
      return KeyEventResult.handled;
    }
    switch (k) {
      case LogicalKeyboardKey.arrowUp:
        move(-1, 0);
      case LogicalKeyboardKey.arrowDown:
        move(1, 0);
      case LogicalKeyboardKey.arrowLeft:
        move(0, -1);
      case LogicalKeyboardKey.arrowRight:
        move(0, 1);
      case LogicalKeyboardKey.tab:
        move(0, shift ? -1 : 1);
      case LogicalKeyboardKey.pageDown:
        move(20, 0);
      case LogicalKeyboardKey.pageUp:
        move(-20, 0);
      case LogicalKeyboardKey.home:
        mod ? _select(0, cur.$2, extend: shift) : _select(cur.$1, 0, extend: shift);
      case LogicalKeyboardKey.end:
        mod ? _select(rows - 1, cur.$2, extend: shift) : _select(cur.$1, cols - 1, extend: shift);
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.f2:
        if (shift) {
          openValueEditor(cur.$1, cur.$2);
        } else {
          startEdit();
        }
      case LogicalKeyboardKey.delete:
        deleteSelectedRows();
      case LogicalKeyboardKey.insert:
        addRow();
      default:
        // Start editing by typing.
        final ch = e.character;
        if (!mod && ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 32 && m.isEditable) {
          startEdit();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _editCtrl.text = ch;
            _editCtrl.selection = TextSelection.collapsed(offset: ch.length);
          });
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final cols = m.columns.length;
    final rows = m.view.length;
    final hairline = BorderSide(color: c.separator, width: 0.5);
    final selRows = {for (final e in _sel) e.$1};
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      onFocusChange: (v) => setState(() => _hasFocus = v),
      child: ColoredBox(
        color: c.content,
        child: Scrollbar(
          controller: _v,
          child: Scrollbar(
            controller: _h,
            notificationPredicate: (n) => n.depth == 1,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: TableView.builder(
                verticalDetails: ScrollableDetails.vertical(controller: _v),
                horizontalDetails: ScrollableDetails.horizontal(controller: _h),
                pinnedRowCount: 1,
                pinnedColumnCount: 1,
                columnCount: cols + 1,
                rowCount: rows + 1,
                columnBuilder: (i) => TableSpan(
                  extent: FixedTableSpanExtent(i == 0 ? _rowNumWidth : _colWidth(i - 1)),
                  foregroundDecoration: i == 0 ? TableSpanDecoration(border: TableSpanBorder(trailing: hairline)) : null,
                ),
                rowBuilder: (i) => TableSpan(
                  extent: FixedTableSpanExtent(i == 0 ? _headH : _rowH),
                  backgroundDecoration: i > 0 && i.isEven ? TableSpanDecoration(color: c.zebra) : null,
                  foregroundDecoration: i == 0 ? TableSpanDecoration(border: TableSpanBorder(trailing: hairline)) : null,
                ),
                cellBuilder: (context, v) {
                  if (v.row == 0 && v.column == 0) return TableViewCell(child: _corner(c));
                  if (v.row == 0) return TableViewCell(child: _header(c, v.column - 1));
                  if (v.column == 0) return TableViewCell(child: _rowHeader(c, v.row - 1, selRows.contains(v.row - 1)));
                  return TableViewCell(child: _cell(c, v.row - 1, v.column - 1));
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _corner(DbColors c) => GestureDetector(
    onTap: selectAll,
    child: Tooltip(
      message: 'Seleziona tutto',
      child: Container(color: c.chrome),
    ),
  );

  Widget _header(DbColors c, int i) {
    final col = m.columns[i];
    final isKey =
        !m.keyIsVirtual && m.keyColumns.any((k) => k.toLowerCase() == (col.baseColumn ?? col.name).toLowerCase());
    final size = col.size > 0 ? '(${col.size}${col.decimals > 0 ? ',${col.decimals}' : ''})' : '';
    return ColoredBox(
      color: c.chrome,
      child: RichTooltip(
        title: col.name,
        rows: [
          ('Tipo', '${col.displayType}$size'),
          ('Null', col.nullable ? 'sì' : 'no'),
          if (col.autoIncrement) ('Auto', 'sì'),
          if (col.baseTable != null) ('Origine', '${col.baseTable}.${col.baseColumn ?? col.name}'),
        ],
        footer: 'Clic per ordinare',
        child: TableHeaderCell(
          label: col.name,
          type: col.displayType.toLowerCase(),
          fontSize: widget.fontSize - 1,
          leading: isKey ? Icon(AppIcons.key, size: 11, color: c.keyIcon) : null,
          sorted: m.sortColumn == i ? m.sortAscending : null,
          onTap: () => m.setSort(i),
          onSecondaryTapDown: (d) => _headerMenu(i, d.globalPosition),
          onResize: (dx) => setState(() => _widths[i] = (_colWidth(i) + dx).clamp(30.0, 2000.0)),
          onResetWidth: () => setState(() => _widths.remove(i)),
        ),
      ),
    );
  }

  Widget _rowHeader(DbColors c, int r, bool selected) {
    final row = m.rowAt(r);
    Color? mark;
    if (row.deleted) {
      mark = c.diffRemoved;
    } else if (row.inserted) {
      mark = c.diffAdded;
    } else if (row.changedCells.isNotEmpty) {
      mark = c.diffChanged;
    }
    return GestureDetector(
      onTapDown: (_) {
        _focus.requestFocus();
        _selectRow(r, extend: HardwareKeyboard.instance.isShiftPressed);
      },
      onSecondaryTapDown: (d) {
        if (!selected) _selectRow(r);
        _cellMenu(r, 0, d.globalPosition);
      },
      child: Container(
        color: selected ? c.selection : c.chrome,
        padding: const EdgeInsets.only(right: Gap.sm),
        child: Row(
          children: [
            Container(width: GridMetrics.marker, color: mark ?? Colors.transparent),
            Expanded(
              child: Text(
                row.inserted ? 'nuova' : '${m.view[r] + 1}',
                textAlign: TextAlign.right,
                style: uiText(
                  TypeSize.caption,
                  color: selected ? c.text : c.textTertiary,
                  features: kTabular,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(DbColors c, int r, int i) {
    final row = m.rowAt(r);
    final v = row.values[i];
    final col = m.columns[i];
    final selected = _sel.contains((r, i));
    final isCursor = _cursor == (r, i);

    if (_editing == (r, i)) {
      return ColoredBox(
        color: c.content,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _cancelEdit,
            const SingleActivator(LogicalKeyboardKey.tab): () {
              _commitEdit();
              if (i + 1 < m.columns.length) _select(r, i + 1);
            },
          },
          child: TextField(
            controller: _editCtrl,
            focusNode: _editFocus,
            style: uiText(widget.fontSize, color: c.text, features: kTabular),
            decoration: cellEditorDecoration(context, padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 5)),
            onSubmitted: (_) => _commitEdit(move: true),
            onTapOutside: (_) => _commitEdit(),
          ),
        ),
      );
    }

    Color? bg;
    if (row.deleted) {
      bg = c.diffRemoved.withValues(alpha: Tint.subtle);
    } else if (row.inserted) {
      bg = c.diffAdded.withValues(alpha: Tint.subtle);
    } else if (row.changedCells.contains(i)) {
      bg = c.diffChanged.withValues(alpha: Tint.strong);
    }
    if (selected) bg = Color.alphaBlend(c.selection, bg ?? Colors.transparent);

    final isNull = v == null;
    final text = isNull ? widget.nullText : formatValue(v, maxLen: 300).replaceAll('\n', '↵');
    // A raw Listener instead of a GestureDetector: with onDoubleTap in the
    // arena, onTapDown only fires after the press timeout, so every click
    // felt late. Opaque so the whole cell is clickable, not just the text.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _onCellPointerDown(e, r, i),
      child: FocusRing(
        visible: isCursor && _hasFocus,
        inset: true,
        radius: 0,
        animated: false,
        child: Container(
          color: bg,
          alignment: col.isNumeric && !isNull ? Alignment.centerRight : Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: uiText(
              isNull ? widget.fontSize - 1 : widget.fontSize,
              style: isNull ? FontStyle.italic : null,
              color: isNull ? c.textTertiary : c.text,
              features: kTabular,
            ).copyWith(decoration: row.deleted ? TextDecoration.lineThrough : null),
          ),
        ),
      ),
    );
  }

  void _onCellPointerDown(PointerDownEvent e, int r, int c) {
    _focus.requestFocus();
    if (e.buttons & kSecondaryMouseButton != 0) {
      if (!_sel.contains((r, c))) _select(r, c);
      _cellMenu(r, c, e.position);
      return;
    }
    if (e.buttons & kPrimaryButton == 0) return;
    final last = _lastClickTime;
    final isDouble = _lastClickCell == (r, c) && last != null && e.timeStamp - last <= kDoubleTapTimeout;
    if (isDouble) {
      _lastClickCell = null;
      _lastClickTime = null;
      startEdit(r, c);
      return;
    }
    _lastClickCell = (r, c);
    _lastClickTime = e.timeStamp;
    final hw = HardwareKeyboard.instance;
    _select(r, c, extend: hw.isShiftPressed, toggle: hw.isControlPressed || hw.isMetaPressed);
  }

  // -------------------------------------------------------------------------
  // Context menus
  // -------------------------------------------------------------------------

  MenuEntry<void> _mi(String label, VoidCallback? f, [SingleActivator? shortcut]) =>
      MenuEntry<void>(label, onSelected: f, enabled: f != null, shortcut: shortcut);

  void _show(Offset pos, List<MenuEntry<void>> entries) => showMacMenu<void>(context, position: pos, entries: entries);

  /// ⌘ on macOS, Ctrl elsewhere.
  static SingleActivator _cmd(LogicalKeyboardKey k, {bool shift = false}) =>
      SingleActivator(k, meta: Platform.isMacOS, control: !Platform.isMacOS, shift: shift);

  void _headerMenu(int c, Offset pos) {
    final col = m.columns[c];
    _show(pos, [
      _mi('Ordina crescente', () => m.sortBy(c)),
      _mi('Ordina decrescente', () => m.sortBy(c, ascending: false)),
      _mi('Rimuovi ordinamento', m.sortColumn == null ? null : () => m.sortBy(null)),
      const MenuEntry.divider(),
      _mi('Seleziona colonna', () {
        setState(() {
          _sel.clear();
          for (var r = 0; r < m.view.length; r++) {
            _sel.add((r, c));
          }
        });
      }),
      _mi('Copia nome colonna', () => Clipboard.setData(ClipboardData(text: col.name))),
      _mi('Adatta larghezza', () => setState(() => _widths.remove(c))),
    ]);
  }

  void _cellMenu(int r, int c, Offset pos) {
    final col = m.columns[c];
    final v = m.rowAt(r).values[c];
    final editable = m.isEditable;
    _show(pos, [
      _mi('Copia', () => copy(), _cmd(LogicalKeyboardKey.keyC)),
      _mi('Copia con intestazioni', () => copy(header: true), _cmd(LogicalKeyboardKey.keyC, shift: true)),
      MenuEntry.submenu('Copia come', children: [
        _mi('CSV', () => copy(format: ExportFormat.csv)),
        _mi('JSON', () => copy(format: ExportFormat.json)),
        _mi('Markdown', () => copy(format: ExportFormat.markdown)),
        if (!widget.simpleMode) _mi('SQL INSERT', () => copy(format: ExportFormat.sql)),
      ]),
      _mi('Incolla', editable ? paste : null, _cmd(LogicalKeyboardKey.keyV)),
      const MenuEntry.divider(),
      _mi(
        'Visualizza / modifica valore…',
        () => openValueEditor(r, c),
        const SingleActivator(LogicalKeyboardKey.enter, shift: true),
      ),
      _mi('Modifica cella', editable ? () => startEdit(r, c) : null, const SingleActivator(LogicalKeyboardKey.enter)),
      _mi('Imposta NULL', editable ? setNull : null),
      const MenuEntry.divider(),
      _mi('Aggiungi riga', editable ? addRow : null, const SingleActivator(LogicalKeyboardKey.insert)),
      _mi('Duplica riga', editable ? duplicateRow : null),
      _mi('Elimina righe', editable ? deleteSelectedRows : null, const SingleActivator(LogicalKeyboardKey.delete)),
      if (widget.onFilterByValue != null) ...[
        const MenuEntry.divider(),
        _mi(
          v == null ? 'Filtra: ${col.name} IS NULL' : 'Filtra: ${col.name} = ${formatValue(v, maxLen: 30)}',
          () => widget.onFilterByValue!(col, v, '='),
        ),
        if (v != null)
          _mi('Filtra: ${col.name} <> ${formatValue(v, maxLen: 30)}', () => widget.onFilterByValue!(col, v, '<>')),
      ],
      if (widget.onExport != null) ...[
        const MenuEntry.divider(),
        _mi('Esporta dati…', widget.onExport),
      ],
    ]);
  }
}
