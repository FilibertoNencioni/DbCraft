import 'dart:math' as math;

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

  static const double _rowH = 26;
  static const double _headH = 30;

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
    final vLine = BorderSide(color: c.separator.withValues(alpha: c.separator.a * 0.6), width: 1);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
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
                  foregroundDecoration: TableSpanDecoration(border: TableSpanBorder(trailing: vLine)),
                ),
                rowBuilder: (i) => TableSpan(
                  extent: FixedTableSpanExtent(i == 0 ? _headH : _rowH),
                  backgroundDecoration: i > 0 && i.isEven ? TableSpanDecoration(color: c.zebra) : null,
                  foregroundDecoration: i == 0
                      ? TableSpanDecoration(
                          border: TableSpanBorder(trailing: BorderSide(color: c.separator)),
                        )
                      : null,
                ),
                cellBuilder: (context, v) {
                  if (v.row == 0 && v.column == 0) return TableViewCell(child: _corner(c));
                  if (v.row == 0) return TableViewCell(child: _header(c, v.column - 1));
                  if (v.column == 0) return TableViewCell(child: _rowHeader(c, v.row - 1));
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
    final sorted = m.sortColumn == i;
    final typeLabel = col.displayType.toLowerCase();
    return Container(
      color: c.chrome,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => m.setSort(i),
              onSecondaryTapDown: (d) => _headerMenu(i, d.globalPosition),
              child: Tooltip(
                message:
                    '${col.name}\n${col.displayType}'
                    '${col.size > 0 ? '(${col.size}${col.decimals > 0 ? ',${col.decimals}' : ''})' : ''}'
                    '${col.nullable ? '' : ' NOT NULL'}'
                    '${col.autoIncrement ? ' AUTO' : ''}'
                    '${col.baseTable != null ? '\n${col.baseTable}.${col.baseColumn ?? col.name}' : ''}'
                    '\nClic per ordinare',
                waitDuration: const Duration(milliseconds: 700),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                  child: Row(
                    children: [
                      if (isKey) ...[
                        const Icon(AppIcons.key, size: 11, color: Color(0xFFE8A200)),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          col.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: widget.fontSize - 0.5, fontWeight: FontWeight.w600, color: c.text),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          typeLabel,
                          overflow: TextOverflow.clip,
                          softWrap: false,
                          style: TextStyle(fontSize: TypeSize.caption - 0.5, color: c.textTertiary),
                        ),
                      ),
                      if (sorted)
                        Icon(
                          m.sortAscending ? AppIcons.arrowUp : AppIcons.arrowDown,
                          size: 12,
                          color: c.accent,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 7,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => setState(() {
                  _widths[i] = (_colWidth(i) + d.delta.dx).clamp(30.0, 2000.0);
                }),
                onDoubleTap: () => setState(() => _widths.remove(i)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowHeader(DbColors c, int r) {
    final row = m.rowAt(r);
    final selected = _sel.any((e) => e.$1 == r);
    Color? mark;
    if (row.deleted) {
      mark = c.danger;
    } else if (row.inserted) {
      mark = c.success;
    } else if (row.changedCells.isNotEmpty) {
      mark = c.warning;
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
            Container(width: 3, color: mark ?? Colors.transparent),
            Expanded(
              child: Text(
                row.inserted ? 'nuova' : '${m.view[r] + 1}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: widget.fontSize - 1.5,
                  color: selected ? c.text : c.textTertiary,
                  fontFeatures: kTabular,
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
      return Container(
        decoration: BoxDecoration(
          color: c.content,
          border: Border.all(color: c.accent, width: 2),
        ),
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
            style: TextStyle(fontSize: widget.fontSize, fontFeatures: kTabular),
            decoration: const InputDecoration(
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            ),
            onSubmitted: (_) => _commitEdit(move: true),
            onTapOutside: (_) => _commitEdit(),
          ),
        ),
      );
    }

    Color? bg;
    if (row.deleted) {
      bg = c.danger.withValues(alpha: 0.10);
    } else if (row.inserted) {
      bg = c.success.withValues(alpha: 0.10);
    } else if (row.changedCells.contains(i)) {
      bg = c.warning.withValues(alpha: 0.22);
    }
    if (selected) bg = Color.alphaBlend(c.selection, bg ?? Colors.transparent);

    final isNull = v == null;
    final text = isNull ? widget.nullText : formatValue(v, maxLen: 300).replaceAll('\n', '↵');
    return GestureDetector(
      onTapDown: (_) {
        _focus.requestFocus();
        final hw = HardwareKeyboard.instance;
        _select(r, i, extend: hw.isShiftPressed, toggle: hw.isControlPressed || hw.isMetaPressed);
      },
      onDoubleTap: () => startEdit(r, i),
      onSecondaryTapDown: (d) {
        if (!selected) _select(r, i);
        _cellMenu(r, i, d.globalPosition);
      },
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: isCursor ? Border.all(color: c.accent.withValues(alpha: 0.8), width: 1.5) : null,
        ),
        alignment: col.isNumeric && !isNull ? Alignment.centerRight : Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isNull ? widget.fontSize - 1.5 : widget.fontSize,
            fontStyle: isNull ? FontStyle.italic : null,
            color: isNull ? c.textTertiary : c.text,
            fontFeatures: kTabular,
            decoration: row.deleted ? TextDecoration.lineThrough : null,
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Context menus
  // -------------------------------------------------------------------------

  PopupMenuEntry<VoidCallback> _mi(String label, IconData icon, VoidCallback? f, [String? sc]) =>
      PopupMenuItem<VoidCallback>(
        value: f,
        enabled: f != null,
        height: 28,
        child: Row(
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            if (sc != null) Text(sc, style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
          ],
        ),
      );

  Future<void> _show(Offset pos, List<PopupMenuEntry<VoidCallback>> items) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final f = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(pos & const Size(1, 1), Offset.zero & overlay.size),
      items: items,
    );
    f?.call();
  }

  void _headerMenu(int c, Offset pos) {
    final col = m.columns[c];
    _show(pos, [
      _mi('Ordina crescente', AppIcons.arrowUp, () => m.sortBy(c)),
      _mi('Ordina decrescente', AppIcons.arrowDown, () => m.sortBy(c, ascending: false)),
      _mi('Rimuovi ordinamento', AppIcons.close, m.sortColumn == null ? null : () => m.sortBy(null)),
      const PopupMenuDivider(height: 9),
      _mi('Seleziona colonna', AppIcons.column, () {
        setState(() {
          _sel.clear();
          for (var r = 0; r < m.view.length; r++) {
            _sel.add((r, c));
          }
        });
      }),
      _mi('Copia nome colonna', AppIcons.copy, () => Clipboard.setData(ClipboardData(text: col.name))),
      _mi('Adatta larghezza', AppIcons.widthNormal, () => setState(() => _widths.remove(c))),
    ]);
  }

  void _cellMenu(int r, int c, Offset pos) {
    final col = m.columns[c];
    final v = m.rowAt(r).values[c];
    final editable = m.isEditable;
    _show(pos, [
      _mi('Copia', AppIcons.copy, () => copy(), 'Ctrl+C'),
      _mi('Copia con intestazioni', AppIcons.copy, () => copy(header: true), 'Ctrl+Shift+C'),
      _mi('Copia come CSV', AppIcons.copy, () => copy(format: ExportFormat.csv)),
      _mi('Copia come JSON', AppIcons.json, () => copy(format: ExportFormat.json)),
      _mi('Copia come Markdown', AppIcons.rows, () => copy(format: ExportFormat.markdown)),
      if (!widget.simpleMode) _mi('Copia come SQL INSERT', AppIcons.code, () => copy(format: ExportFormat.sql)),
      _mi('Incolla', AppIcons.paste, editable ? paste : null, 'Ctrl+V'),
      const PopupMenuDivider(height: 9),
      _mi('Visualizza / modifica valore…', AppIcons.expand, () => openValueEditor(r, c), 'Shift+Invio'),
      _mi('Modifica cella', AppIcons.edit, editable ? () => startEdit(r, c) : null, 'Invio'),
      _mi('Imposta NULL', AppIcons.block, editable ? setNull : null),
      const PopupMenuDivider(height: 9),
      _mi('Aggiungi riga', AppIcons.add, editable ? addRow : null, 'Ins'),
      _mi('Duplica riga', AppIcons.duplicate, editable ? duplicateRow : null),
      _mi('Elimina righe', AppIcons.remove, editable ? deleteSelectedRows : null, 'Canc'),
      if (widget.onFilterByValue != null) ...[
        const PopupMenuDivider(height: 9),
        _mi(
          v == null ? 'Filtra: ${col.name} IS NULL' : 'Filtra: ${col.name} = ${formatValue(v, maxLen: 30)}',
          AppIcons.filter,
          () => widget.onFilterByValue!(col, v, '='),
        ),
        if (v != null)
          _mi(
            'Filtra: ${col.name} <> ${formatValue(v, maxLen: 30)}',
            AppIcons.filterOff,
            () => widget.onFilterByValue!(col, v, '<>'),
          ),
      ],
      if (widget.onExport != null) ...[
        const PopupMenuDivider(height: 9),
        _mi('Esporta dati…', AppIcons.upload, widget.onExport),
      ],
    ]);
  }
}
