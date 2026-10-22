import 'package:flutter/material.dart';

import '../widgets/common.dart';

enum _ParamType { auto, text, number, nul }

/// Asks the values of `:name` / `?` parameters (DBeaver "Bind parameters").
Future<Map<String, Object?>?> showParametersDialog(
  BuildContext context,
  List<String> names,
  Map<String, Object?> previous,
) {
  return showSheet<Map<String, Object?>>(
    context,
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
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: 'Parametri della query',
      onSubmit: _submit,
      body: FormGroup(
        children: [
          for (final (i, n) in widget.names.indexed)
            FormRow(
              label: n.startsWith('?') ? 'Parametro ${n.substring(1)}' : ':$n',
              child: Row(
                children: [
                  Expanded(
                    child: MacTextField(
                      controller: _ctrl[n],
                      autofocus: i == 0,
                      enabled: _type[n] != _ParamType.nul,
                      hint: _type[n] == _ParamType.nul ? 'NULL' : null,
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  PopUpButton<_ParamType>(
                    value: _type[n]!,
                    width: 96,
                    items: const [
                      (_ParamType.auto, 'Auto', null),
                      (_ParamType.text, 'Testo', null),
                      (_ParamType.number, 'Numero', null),
                      (_ParamType.nul, 'NULL', null),
                    ],
                    onChanged: (v) => setState(() => _type[n] = v),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: 'Esegui', onPressed: _submit),
      ],
    );
  }
}
