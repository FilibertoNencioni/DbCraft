import 'package:flutter/material.dart';

enum _ParamType { auto, text, number, nul }

/// Asks the values of `:name` / `?` parameters (DBeaver "Bind parameters").
Future<Map<String, Object?>?> showParametersDialog(
  BuildContext context,
  List<String> names,
  Map<String, Object?> previous,
) {
  return showDialog<Map<String, Object?>>(
    context: context,
    builder: (ctx) => _ParametersDialog(names: names, previous: previous),
  );
}

class _ParametersDialog extends StatefulWidget {
  const _ParametersDialog({required this.names, required this.previous});
  final List<String> names;
  final Map<String, Object?> previous;

  @override
  State<_ParametersDialog> createState() => _ParametersDialogState();
}

class _ParametersDialogState extends State<_ParametersDialog> {
  late final Map<String, TextEditingController> _ctrl = {
    for (final n in widget.names) n: TextEditingController(text: widget.previous[n]?.toString() ?? ''),
  };
  late final Map<String, _ParamType> _type = {
    for (final n in widget.names)
      n: widget.previous.containsKey(n) && widget.previous[n] == null ? _ParamType.nul : _ParamType.auto,
  };

  Object? _value(String n) {
    final t = _type[n]!;
    final s = _ctrl[n]!.text;
    switch (t) {
      case _ParamType.nul:
        return null;
      case _ParamType.text:
        return s;
      case _ParamType.number:
        return int.tryParse(s) ?? double.tryParse(s.replaceAll(',', '.')) ?? s;
      case _ParamType.auto:
        if (RegExp(r'^-?[1-9][0-9]{0,17}$|^0$').hasMatch(s)) return int.parse(s);
        if (RegExp(r'^-?[0-9]+\.[0-9]+$').hasMatch(s)) return double.parse(s);
        return s;
    }
  }

  void _submit() {
    Navigator.pop(context, {for (final n in widget.names) n: _value(n)});
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Parametri della query'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, n) in widget.names.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(
                          n.startsWith('?') ? 'Parametro ${n.substring(1)}' : ':$n',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _ctrl[n],
                          autofocus: i == 0,
                          enabled: _type[n] != _ParamType.nul,
                          decoration: const InputDecoration(isDense: true),
                          onSubmitted: (_) => _submit(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<_ParamType>(
                        value: _type[n],
                        isDense: true,
                        items: const [
                          DropdownMenuItem(value: _ParamType.auto, child: Text('Auto')),
                          DropdownMenuItem(value: _ParamType.text, child: Text('Testo')),
                          DropdownMenuItem(value: _ParamType.number, child: Text('Numero')),
                          DropdownMenuItem(value: _ParamType.nul, child: Text('NULL')),
                        ],
                        onChanged: (v) => setState(() => _type[n] = v!),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        FilledButton(onPressed: _submit, child: const Text('Esegui')),
      ],
    );
  }
}
