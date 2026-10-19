import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../odbc/odbc_types.dart';
import '../widgets/common.dart';

class ValueDialogResult {
  const ValueDialogResult(this.value, this.changed);
  final Object? value;
  final bool changed;
}

/// Value viewer / editor (DBeaver "Value panel"): text, JSON, hex, files.
Future<ValueDialogResult?> showValueDialog(
  BuildContext context, {
  required ColumnInfo column,
  required Object? value,
  bool editable = false,
}) {
  return showSheet<ValueDialogResult>(
    context,
    size: SheetSize.xlarge,
    builder: (_) => _ValueDialog(column: column, value: value, editable: editable),
  );
}

enum _View { text, json, hex }

class _ValueDialog extends StatefulWidget {
  const _ValueDialog({required this.column, required this.value, required this.editable});
  final ColumnInfo column;
  final Object? value;
  final bool editable;

  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late Object? _value = widget.value;
  late final _ctrl = TextEditingController(text: _asText(widget.value));
  late _View _view = widget.value is Uint8List ? _View.hex : (_looksJson ? _View.json : _View.text);
  bool _changed = false;

  bool get _looksJson {
    final v = widget.value;
    if (v is! String) return false;
    final t = v.trim();
    if (!(t.startsWith('{') || t.startsWith('['))) return false;
    try {
      jsonDecode(t);
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _asText(Object? v) {
    if (v == null) return '';
    if (v is Uint8List) return utf8.decode(v, allowMalformed: true);
    return v.toString();
  }

  String _hexDump(Uint8List b) {
    final sb = StringBuffer();
    for (var i = 0; i < b.length && i < 64 * 1024; i += 16) {
      final chunk = b.sublist(i, i + 16 > b.length ? b.length : i + 16);
      sb.write(i.toRadixString(16).padLeft(8, '0'));
      sb.write('  ');
      sb.write(chunk.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ').padRight(48));
      sb.write('  ');
      sb.write(String.fromCharCodes(chunk.map((x) => x >= 32 && x < 127 ? x : 46)));
      sb.write('\n');
    }
    if (b.length > 64 * 1024) sb.write('… (${b.length} byte totali)');
    return sb.toString();
  }

  String _pretty(String s) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
    } catch (_) {
      return s;
    }
  }

  void _apply() {
    if (!_changed) return Navigator.pop(context);
    final out = _value is Uint8List && _view == _View.hex ? _value : _ctrl.text;
    Navigator.pop(context, ValueDialogResult(out, true));
  }

  Future<void> _saveToFile(Object? v) async {
    final loc = await getSaveLocation(suggestedName: '${widget.column.name}.bin');
    if (loc == null) return;
    final data = v is Uint8List ? v : utf8.encode(_ctrl.text);
    await File(loc.path).writeAsBytes(data);
  }

  Future<void> _loadFromFile(bool isBinary) async {
    final f = await openFile();
    if (f == null) return;
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    setState(() {
      _changed = true;
      if (isBinary) {
        _value = bytes;
        _view = _View.hex;
      } else {
        _ctrl.text = utf8.decode(bytes, allowMalformed: true);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _value;
    final isBinary = v is Uint8List || widget.column.isBinary;
    final readOnly = !widget.editable || _view == _View.hex;
    // The editors fill the sheet; the hex dump is sized in whole lines of mono text.
    final body = _view == _View.hex && v is Uint8List
        ? LayoutBuilder(
            builder: (context, box) {
              final mono = MediaQuery.textScalerOf(context).scale(TypeSize.mono);
              final lines = ((box.maxHeight - Gap.md * 2) / (mono * 1.35)).floor().clamp(1, 1000);
              return Align(
                alignment: Alignment.topCenter,
                child: CodeBox(_hexDump(v), copy: false, maxLines: lines),
              );
            },
          )
        : MacTextField(
            controller: _ctrl,
            readOnly: readOnly,
            mono: true,
            expands: true,
            onChanged: (_) => _changed = true,
          );
    return SheetScaffold(
      title: widget.column.name,
      subtitle: [
        widget.column.displayType,
        v == null
            ? 'NULL'
            : v is Uint8List
            ? '${v.length} byte'
            : '${v.toString().length} caratteri',
      ].join('  ·  '),
      onSubmit: widget.editable ? _apply : () => Navigator.pop(context),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Segmented<_View>(
              value: _view,
              items: [
                (_View.text, 'Testo', null),
                (_View.json, 'JSON', null),
                if (v is Uint8List) (_View.hex, 'Hex', null),
              ],
              onChanged: (view) => setState(() {
                _view = view;
                if (_view == _View.json) _ctrl.text = _pretty(_ctrl.text);
              }),
            ),
          ),
          const SizedBox(height: Gap.md),
          Expanded(child: body),
        ],
      ),
      leading: [
        PushButton(
          label: 'Copia',
          onPressed: () => Clipboard.setData(ClipboardData(text: _ctrl.text)),
        ),
        if (isBinary || v is String) PushButton(label: 'Salva su file…', onPressed: () => _saveToFile(v)),
        if (widget.editable) PushButton(label: 'Carica da file…', onPressed: () => _loadFromFile(isBinary)),
      ],
      actions: widget.editable
          ? [
              PushButton(
                label: 'Imposta NULL',
                onPressed: () => Navigator.pop(context, const ValueDialogResult(null, true)),
              ),
              PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
              PushButton.primary(label: 'Applica', onPressed: _apply),
            ]
          : [PushButton.primary(label: 'Fine', onPressed: () => Navigator.pop(context))],
    );
  }
}
