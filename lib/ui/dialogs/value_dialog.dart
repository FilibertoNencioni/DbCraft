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
  return showDialog<ValueDialogResult>(
    context: context,
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

  @override
  Widget build(BuildContext context) {
    final v = _value;
    final isBinary = v is Uint8List || widget.column.isBinary;
    final readOnly = !widget.editable || _view == _View.hex;
    Widget body;
    if (_view == _View.hex && v is Uint8List) {
      body = SingleChildScrollView(child: SelectableText(_hexDump(v), style: monoStyle(context, size: 12.5)));
    } else {
      body = TextField(
        controller: _ctrl,
        readOnly: readOnly,
        expands: true,
        maxLines: null,
        style: monoStyle(context, size: 13),
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onChanged: (_) => _changed = true,
      );
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.column.name}  ·  ${widget.column.displayType}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  SegmentedButton<_View>(
                    showSelectedIcon: false,
                    segments: [
                      const ButtonSegment(value: _View.text, label: Text('Testo')),
                      const ButtonSegment(value: _View.json, label: Text('JSON')),
                      if (v is Uint8List) const ButtonSegment(value: _View.hex, label: Text('Hex')),
                    ],
                    selected: {_view},
                    onSelectionChanged: (s) => setState(() {
                      _view = s.first;
                      if (_view == _View.json) _ctrl.text = _pretty(_ctrl.text);
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                v == null
                    ? 'NULL'
                    : v is Uint8List
                    ? '${v.length} byte'
                    : '${v.toString().length} caratteri',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Expanded(child: body),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(AppIcons.copy, size: 16),
                    label: const Text('Copia'),
                    onPressed: () => Clipboard.setData(ClipboardData(text: _ctrl.text)),
                  ),
                  if (isBinary || v is String)
                    TextButton.icon(
                      icon: const Icon(AppIcons.download, size: 16),
                      label: const Text('Salva su file…'),
                      onPressed: () async {
                        final loc = await getSaveLocation(suggestedName: '${widget.column.name}.bin');
                        if (loc == null) return;
                        final data = v is Uint8List ? v : utf8.encode(_ctrl.text);
                        await File(loc.path).writeAsBytes(data);
                      },
                    ),
                  if (widget.editable)
                    TextButton.icon(
                      icon: const Icon(AppIcons.upload, size: 16),
                      label: const Text('Carica da file…'),
                      onPressed: () async {
                        final f = await openFile();
                        if (f == null) return;
                        final bytes = await f.readAsBytes();
                        setState(() {
                          _changed = true;
                          if (isBinary) {
                            _value = bytes;
                            _view = _View.hex;
                          } else {
                            _ctrl.text = utf8.decode(bytes, allowMalformed: true);
                          }
                        });
                      },
                    ),
                  const Spacer(),
                  if (widget.editable)
                    TextButton(
                      onPressed: () => Navigator.pop(context, const ValueDialogResult(null, true)),
                      child: const Text('Imposta NULL'),
                    ),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Chiudi')),
                  if (widget.editable)
                    FilledButton(
                      onPressed: () {
                        if (!_changed) return Navigator.pop(context);
                        final out = _value is Uint8List && _view == _View.hex ? _value : _ctrl.text;
                        Navigator.pop(context, ValueDialogResult(out, true));
                      },
                      child: const Text('Applica'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
