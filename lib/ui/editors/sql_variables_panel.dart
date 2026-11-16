// The Variabili panel of a SQL editor: the variables the script references,
// the ones it declares and the values kept for the others.
import 'package:material_ui/material_ui.dart';

import '../../services/sql_dialect.dart';
import '../../services/sql_splitter.dart';
import '../../services/sql_variables.dart';
import '../../state/editor_tabs.dart';
import '../widgets/common.dart';

/// Inspector at the right of the SQL editor.
class SqlVariablesPanel extends StatefulWidget {
  const SqlVariablesPanel({super.key, required this.tab, required this.onRun});
  final SqlEditorTab tab;

  /// Runs the script again (⌘↩ from a field, "Esegui" after filling the
  /// missing values).
  final VoidCallback onRun;

  @override
  State<SqlVariablesPanel> createState() => _SqlVariablesPanelState();
}

class _SqlVariablesPanelState extends State<SqlVariablesPanel> {
  final Map<String, TextEditingController> _values = {};
  final Map<String, TextEditingController> _types = {};
  final Map<String, FocusNode> _focus = {};
  int _focusRequest = 0;

  SqlEditorTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    _focusRequest = tab.focusRequest;
    tab.variablesTick.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusBlocked());
  }

  @override
  void didUpdateWidget(SqlVariablesPanel old) {
    super.didUpdateWidget(old);
    if (old.tab != tab) {
      old.tab.variablesTick.removeListener(_changed);
      tab.variablesTick.addListener(_changed);
      _disposeFields();
    }
  }

  @override
  void dispose() {
    tab.variablesTick.removeListener(_changed);
    _disposeFields();
    super.dispose();
  }

  void _disposeFields() {
    for (final c in [..._values.values, ..._types.values]) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    _values.clear();
    _types.clear();
    _focus.clear();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (tab.focusRequest != _focusRequest) {
      _focusRequest = tab.focusRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusBlocked());
    }
  }

  /// Focus on the first variable that stopped the run.
  void _focusBlocked() {
    if (!mounted || tab.blockedVariables.isEmpty) return;
    for (final r in tab.variableRows) {
      if (tab.blockedVariables.contains(r.key)) {
        _focus[r.key]?.requestFocus();
        return;
      }
    }
  }

  TextEditingController _valueCtl(String key, String text) {
    final c = _values.putIfAbsent(key, () => TextEditingController(text: text));
    // Changed elsewhere (the script was rewritten, a value restored).
    if (c.text != text && !(_focus[key]?.hasFocus ?? false)) c.text = text;
    return c;
  }

  FocusNode _node(String key) => _focus.putIfAbsent(key, () => FocusNode(debugLabel: 'var-$key'));

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final syntax = tab.varSyntax;
    final rows = tab.variableRows;
    final family = tab.family;
    final unused = rows.where((r) => !r.used && !r.inScript && r.panel != null).length;
    return Inspector(
      children: [
        InspectorSection(
          title: 'Variabili',
          collapsible: false,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (syntax != null)
                ToolButton(
                  icon: AppIcons.add,
                  tooltip: 'Aggiungi una variabile',
                  onPressed: _add,
                ),
              PulldownButton(
                icon: AppIcons.more,
                tooltip: 'Altre azioni',
                entries: () => [
                  MenuEntry('Rimuovi le variabili non usate', onSelected: unused == 0 ? null : tab.removeUnusedVariables),
                  MenuEntry(
                    'Svuota tutti i valori',
                    onSelected: tab.variables.isEmpty
                        ? null
                        : () {
                            for (final v in tab.variables) {
                              v
                                ..value = null
                                ..isNull = false;
                            }
                            tab.variablesChanged();
                          },
                  ),
                ],
              ),
              ToolButton(
                icon: AppIcons.close,
                tooltip: 'Chiudi il pannello',
                onPressed: () => tab.showVariables = false,
              ),
            ],
          ),
          children: [
            if (syntax == null)
              _hint('Questo database non ha variabili negli script.')
            else if (rows.isEmpty)
              _hint(_emptyHint(family, syntax))
            else
              for (final r in rows) _row(r, family),
          ],
        ),
        if (rows.any((r) => r.inScript))
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1, right: Gap.xs),
                  child: Icon(AppIcons.info, size: 13, color: c.textTertiary),
                ),
                Expanded(
                  child: Text(
                    'Le variabili dichiarate nello script usano il valore scritto lì. '
                    'Qui si valorizzano solo quelle non dichiarate.',
                    style: uiText(TypeSize.small, color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _emptyHint(DbFamily? family, VarSyntax syntax) {
    final example = switch (family) {
      DbFamily.sqlServer => 'Scrivi @nome nello script (senza DECLARE) e il valore si inserisce qui.',
      DbFamily.mysql => 'Scrivi @nome nello script (senza SET) e il valore si inserisce qui.',
      DbFamily.snowflake => r'Scrivi $nome nello script (senza SET) e il valore si inserisce qui.',
      DbFamily.bigquery => 'Scrivi @nome nello script e il valore si inserisce qui.',
      _ => 'Scrivi :nome nello script e il valore si inserisce qui.',
    };
    return '$example Le variabili valgono per tutto lo script e restano salvate su questo computer.';
  }

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.sm),
    child: Text(text, style: uiText(TypeSize.small, color: DbColors.of(context).textSecondary)),
  );

  Future<void> _add() async {
    final syntax = tab.varSyntax;
    if (syntax == null) return;
    final name = await promptText(context, 'Nuova variabile', label: 'Nome (es. ${syntax.sigil}cliente)');
    if (name == null || !mounted) return;
    final n = name.trim().replaceFirst(RegExp(r'^[@$:]'), '');
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n)) {
      showToast(context, 'Nome non valido: lettere, cifre e _, senza una cifra all\'inizio', error: true);
      return;
    }
    if (tab.variable(n.toLowerCase()) != null) {
      showToast(context, 'La variabile ${syntax.sigil}$n esiste già', error: true);
      return;
    }
    tab.variableFor(n);
    tab.variablesChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus[n.toLowerCase()]?.requestFocus());
  }

  /// Selects the first occurrence of the variable in the script.
  void _reveal(VariableInfo r) {
    final at = r.decl != null ? (r.decl!.nameStart, r.decl!.nameStart + r.decl!.display.length) : null;
    final ref = r.refs.isEmpty ? null : (r.refs.first.start, r.refs.first.end);
    final pos = at ?? ref;
    if (pos == null) return;
    tab.highlight(SqlStatement(r.display, pos.$1, pos.$2));
  }

  int _lineOf(int offset) {
    final text = tab.controller.text;
    var line = 1;
    for (var i = 0; i < offset && i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) line++;
    }
    return line;
  }

  Widget _name(VariableInfo r, {Color? color}) {
    final c = DbColors.of(context);
    return Tooltip(
      message: r.used || r.inScript ? 'Mostra nello script' : 'Non usata nello script',
      child: MouseRegion(
        cursor: r.used || r.inScript ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          onTap: () => _reveal(r),
          child: Text(
            r.display,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(context, size: TypeSize.mono, color: color ?? (r.used || r.inScript ? c.text : c.textTertiary))
                .copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget _row(VariableInfo r, DbFamily? family) => r.inScript ? _scriptRow(r) : _panelRow(r, family);

  /// A variable declared in the script: its value is the script's.
  Widget _scriptRow(VariableInfo r) {
    final c = DbColors.of(context);
    final d = r.decl!;
    final line = _lineOf(d.nameStart);
    final type = (d.sqlType ?? '').isEmpty ? '' : '${d.sqlType} ';
    final ctl = d.editable ? _valueCtl(r.key, d.init ?? '') : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _name(r)),
            const SizedBox(width: Gap.xs),
            Tag(
              'nello script · riga $line',
              tooltip: 'Dichiarata nello script: vale il valore scritto lì',
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (ctl != null)
          MacTextField(
            controller: ctl,
            focusNode: _node(r.key),
            mono: true,
            hint: d.init == null ? 'NULL (nessun valore iniziale)' : null,
            leading: type.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(type, style: monoStyle(context, size: TypeSize.monoSmall, color: c.textTertiary)),
                  ),
            onSubmitted: (v) => _writeLiteral(r, v),
          )
        else
          Text(
            d.init == null ? '$type· valore calcolato dallo script' : '$type= ${_oneLine(d.init!)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(context, size: TypeSize.monoSmall, color: c.textSecondary),
          ),
        if (ctl != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              'Invio scrive questo valore nello script.',
              style: uiText(TypeSize.caption, color: c.textTertiary),
            ),
          ),
        if (r.panel != null && r.panel!.hasValue)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Il valore ${r.panel!.display} del pannello non è usato.',
                    style: uiText(TypeSize.caption, color: c.textTertiary),
                  ),
                ),
                LinkButton(label: 'Rimuovi', small: true, onPressed: () => tab.removeVariable(r.key)),
              ],
            ),
          ),
      ],
    );
  }

  String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  void _writeLiteral(VariableInfo r, String literal) {
    final d = r.decl;
    if (d == null) return;
    final t = literal.trim();
    if (t == (d.init ?? '').trim() || t.isEmpty) return;
    tab.writeDeclaredValue(d, t);
    tab.variablesTick.value++;
  }

  /// A variable whose value lives in the panel.
  Widget _panelRow(VariableInfo r, DbFamily? family) {
    final c = DbColors.of(context);
    final v = r.panel;
    final blocked = tab.blockedVariables.contains(r.key);
    final isNull = v?.isNull ?? false;
    final ctl = _valueCtl(r.key, v?.value ?? '');
    final error = v?.error;
    final type = v?.type ?? VarType.auto;
    final mssql = family == DbFamily.sqlServer;
    String? status;
    Color? statusColor;
    if (error != null) {
      status = error;
      statusColor = c.danger;
    } else if (r.needsValue) {
      status = blocked ? 'Valore mancante: lo script non è partito' : 'Da valorizzare';
      statusColor = blocked ? c.danger : c.warning;
    } else if (!r.used) {
      status = 'Non usata nello script';
      statusColor = c.textTertiary;
    }

    ScriptVariable model() => tab.variableFor(r.display.substring(1));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _name(r)),
            const SizedBox(width: Gap.xs),
            PopUpButton<String>(
              value: isNull ? 'null' : type.name,
              width: 104,
              items: [
                for (final t in VarType.values) (t.name, t.label, null),
                ('null', 'NULL', null),
              ],
              onChanged: (k) {
                final m = model();
                if (k == 'null') {
                  m.isNull = true;
                } else {
                  m
                    ..isNull = false
                    ..type = VarType.values.byName(k);
                }
                tab.variablesChanged();
              },
            ),
            if (!r.used)
              ToolButton(
                icon: AppIcons.close,
                tooltip: 'Rimuovi la variabile',
                onPressed: () => tab.removeVariable(r.key),
              ),
          ],
        ),
        const SizedBox(height: 4),
        MacTextField(
          controller: ctl,
          focusNode: _node(r.key),
          enabled: !isNull,
          mono: true,
          hint: isNull ? 'NULL' : _hintOf(type),
          error: error,
          onChanged: (s) {
            model().value = s;
            tab.variablesChanged();
          },
          onSubmitted: (_) => _next(r.key),
        ),
        if (mssql) ...[
          const SizedBox(height: 4),
          MacTextField(
            controller: _types.putIfAbsent(r.key, () => TextEditingController(text: v?.sqlType ?? '')),
            mono: true,
            hint: 'Tipo: ${v == null || !v.hasValue ? 'dal valore' : tsqlTypeOf(v.copy()..sqlType = '')}',
            onChanged: (s) {
              model().sqlType = s.trim();
              tab.variablesChanged();
            },
          ),
        ],
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(status, style: uiText(TypeSize.caption, color: statusColor)),
          ),
      ],
    );
  }

  String _hintOf(VarType t) => switch (t) {
    VarType.date => 'AAAA-MM-GG',
    VarType.dateTime => 'AAAA-MM-GG hh:mm:ss',
    VarType.boolean => 'vero / falso',
    VarType.number => 'Numero',
    _ => 'Valore',
  };

  /// Invio: the next value to fill, or the run when none is left.
  void _next(String key) {
    final rows = tab.variableRows.where((r) => !r.inScript).toList();
    final i = rows.indexWhere((r) => r.key == key);
    for (final r in rows.skip(i + 1)) {
      if (r.needsValue) {
        _focus[r.key]?.requestFocus();
        return;
      }
    }
    // Everything filled after a stopped run: it goes.
    if (tab.stoppedByVariables && rows.every((r) => !r.needsValue && (r.panel?.error == null))) widget.onRun();
  }
}
