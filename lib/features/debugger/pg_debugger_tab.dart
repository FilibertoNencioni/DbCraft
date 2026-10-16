// PostgreSQL debugger editor: toolbar, source with breakpoint gutter, stack,
// variables, breakpoints and output panes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../services/sql_dialect.dart';
import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../ui/actions.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/split_view.dart';
import 'pg_debug_controller.dart';
import 'pg_debug_logic.dart';

class PgDebuggerTab extends FeatureTab {
  PgDebuggerTab(this.dc, this.procedure);
  final DbConnection dc;
  final DbProcedure procedure;

  PgDebugController? _controller;

  /// Created on first display ([AppState.openFeatureTab] may dispose a
  /// duplicate tab without showing it).
  PgDebugController get controller => _controller ??= PgDebugController(dc, procedure);

  /// Opens (or activates) the debugger of [p]. PostgreSQL only.
  static Future<void> open(BuildContext context, DbConnection dc, DbProcedure p) async {
    if (!await ensureConnected(context, dc)) return;
    if (!context.mounted) return;
    if (dc.dialect.family != DbFamily.postgres) {
      showToast(context, 'Il debugger è disponibile solo per PostgreSQL', error: true);
      return;
    }
    AppScope.read(context).openFeatureTab(PgDebuggerTab(dc, p), match: (t) => t.dc == dc && t.procedure.key == p.key);
  }

  /// Resolves the pg_proc OID of [p] (asks which overload to use when the
  /// name is ambiguous). Null when not found or cancelled.
  static Future<int?> resolveFunctionOid(BuildContext context, DbConnection dc, DbProcedure p) async {
    final s = await dc.openSession(readOnly: true);
    try {
      final list = await findPgFunctions(s, p);
      if (list.isEmpty) return null;
      if (list.length == 1) return list.first.oid;
      if (!context.mounted) return null;
      return (await pickPgOverload(context, list))?.oid;
    } finally {
      await s.close();
    }
  }

  @override
  String get title => 'Debug · ${procedure.cleanName}';
  @override
  String get tooltip => '${dc.config.name}: debug di ${procedure.cleanName}';
  @override
  IconData get icon => AppIcons.debug;
  @override
  DbConnection get connection => dc;

  @override
  Widget buildView(BuildContext context) => PgDebuggerView(tab: this);

  @override
  Future<bool> canClose(BuildContext context) async {
    final c = _controller;
    if (c == null || !c.sm.isActive) return true;
    final ok = await confirmDialog(
      context,
      'Debug in corso',
      'Interrompere il debug di ${procedure.cleanName}? L\'esecuzione della funzione verrà annullata.',
      ok: 'Interrompi',
      destructive: true,
    );
    if (ok) await c.stop();
    return ok;
  }

  @override
  void dispose() {
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }
}

/// Lets the user choose one of the overloads of a function.
Future<PgFunctionCandidate?> pickPgOverload(BuildContext context, List<PgFunctionCandidate> list) =>
    showListPicker<PgFunctionCandidate>(
      context,
      title: 'Scegli la funzione da analizzare',
      items: list,
      label: (f) => f.signature,
      detail: (f) => f.language,
      icon: (f) => f.kind == 'p' ? AppIcons.procedure : AppIcons.function,
      choose: 'Analizza',
    );

// ---------------------------------------------------------------------------
// Parameters dialog
// ---------------------------------------------------------------------------

Future<PgDebugStart?> showPgDebugParamsDialog(BuildContext context, PgDebugController ctl, {PgDebugStart? previous}) =>
    showSheet<PgDebugStart>(context, builder: (_) => _ParamsDialog(ctl: ctl, previous: previous));

class _ParamsDialog extends StatefulWidget {
  const _ParamsDialog({required this.ctl, this.previous});
  final PgDebugController ctl;
  final PgDebugStart? previous;

  @override
  State<_ParamsDialog> createState() => _ParamsDialogState();
}

class _ParamsDialogState extends State<_ParamsDialog> {
  late final PgFunctionInfo f = widget.ctl.info!;
  late final List<PgArgValue> values;
  late final List<TextEditingController> ctrls;
  bool rollback = false;
  bool indirect = false;

  @override
  void initState() {
    super.initState();
    final prev = widget.previous;
    values = [
      for (var i = 0; i < f.args.length; i++)
        prev != null && i < prev.values.length
            ? PgArgValue(
                text: prev.values[i].text,
                isNull: prev.values[i].isNull,
                useDefault: prev.values[i].useDefault,
                expression: prev.values[i].expression,
              )
            : PgArgValue(useDefault: f.args[i].hasDefault),
    ];
    ctrls = [for (final v in values) TextEditingController(text: v.text)];
    rollback = prev?.rollback ?? widget.ctl.dc.config.type.confirmExecute;
    indirect = prev?.indirect ?? f.isTrigger;
  }

  @override
  void dispose() {
    for (final c in ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  String _hint(String type) {
    final t = type.toLowerCase();
    if (t.endsWith('[]')) return 'es. {1,2,3}';
    if (t.contains('timestamp')) return 'es. 2026-01-31 12:00:00';
    if (t == 'date') return 'es. 2026-01-31';
    if (t.startsWith('time')) return 'es. 12:30:00';
    if (t == 'boolean') return 'true / false';
    if (t.contains('json')) return 'es. {"chiave": 1}';
    if (t == 'uuid') return 'es. 00000000-0000-0000-0000-000000000000';
    if (const ['integer', 'bigint', 'smallint', 'numeric', 'real', 'double precision'].any(t.startsWith)) {
      return 'numero';
    }
    return type;
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final inputs = [
      for (var i = 0; i < f.args.length; i++)
        if (f.args[i].isInput) i,
    ];
    String? preview;
    String? error;
    if (!indirect) {
      try {
        preview = widget.ctl.buildCall(f, values);
      } catch (e) {
        error = e is ArgumentError ? e.message.toString() : e.toString();
      }
    }
    final canStart = error == null && !(f.isTrigger && !indirect);
    void start() =>
        Navigator.pop(context, PgDebugStart(values: values, rollback: rollback && !indirect, indirect: indirect));
    return SheetScaffold(
      title: 'Debug di ${f.name}',
      onSubmit: canStart ? start : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            f.signature,
            style: monoStyle(context, size: TypeSize.mono, color: c.textSecondary),
          ),
          const SizedBox(height: Gap.md),
          if (f.language != 'plpgsql')
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Notice(
                message: 'La funzione è scritta in ${f.language}; il debugger supporta solo PL/pgSQL.',
              ),
            ),
          if (!indirect && inputs.isNotEmpty)
            FormGroup(title: 'Parametri', children: [for (final i in inputs) _argRow(context, i)]),
          if (!indirect && inputs.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Text(
                'La funzione non ha parametri di input.',
                style: uiText(TypeSize.small, color: c.textSecondary),
              ),
            ),
          FormGroup(
            title: 'Opzioni',
            children: [
              FormRow(
                label: 'Annulla le modifiche',
                help: 'Esegue la chiamata in una transazione annullata al termine',
                child: DbSwitch(
                  value: rollback,
                  onChanged: indirect ? null : (v) => setState(() => rollback = v),
                ),
              ),
              FormRow(
                label: 'Attendi una chiamata esterna',
                help: f.isTrigger
                    ? 'Le funzioni trigger si eseguono tramite il loro trigger'
                    : 'Debug indiretto: si ferma quando un\'altra sessione chiama la funzione',
                child: DbSwitch(value: indirect, onChanged: (v) => setState(() => indirect = v)),
              ),
            ],
          ),
          if (preview != null) CodeBox(preview, wrap: true),
          if (error != null) FieldMessage(error, error: true),
        ],
      ),
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: 'Avvia debug', onPressed: canStart ? start : null),
      ],
    );
  }

  Widget _argRow(BuildContext context, int i) {
    final c = DbColors.of(context);
    final a = f.args[i];
    final v = values[i];
    final disabled = v.isNull || v.useDefault;
    Widget check(String label, bool value, ValueChanged<bool> onChanged, {String? tip}) => Tooltip(
      message: tip ?? label,
      child: CheckboxRow(small: true, label: label, value: value, onChanged: (x) => setState(() => onChanged(x))),
    );
    return Row(
      children: [
        SizedBox(
          width: 150,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                a.name.isEmpty ? '\$${i + 1}' : a.name,
                style: uiText(TypeSize.body, color: c.text),
                overflow: TextOverflow.ellipsis,
              ),
              TypeLabel('${a.mode == 'i' ? '' : '${a.modeLabel} '}${a.type}', mono: true),
            ],
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: MacTextField(
            controller: ctrls[i],
            enabled: !disabled,
            mono: v.expression,
            hint: v.useDefault ? 'default: ${a.defaultExpr}' : (v.isNull ? 'NULL' : _hint(a.type)),
            onChanged: (t) => setState(() => v.text = t),
          ),
        ),
        const SizedBox(width: Gap.sm),
        check('NULL', v.isNull, (x) => v.isNull = x),
        if (a.hasDefault) ...[
          const SizedBox(width: Gap.xs),
          check('Default', v.useDefault, (x) => v.useDefault = x, tip: 'Usa il default: ${a.defaultExpr}'),
        ],
        const SizedBox(width: Gap.xs),
        check('SQL', v.expression, (x) => v.expression = x, tip: 'Il valore è un\'espressione SQL (es. now())'),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Debugger view
// ---------------------------------------------------------------------------

class PgDebuggerView extends StatefulWidget {
  const PgDebuggerView({super.key, required this.tab});
  final PgDebuggerTab tab;

  @override
  State<PgDebuggerView> createState() => _PgDebuggerViewState();
}

class _PgDebuggerViewState extends State<PgDebuggerView> {
  PgDebugController get ctl => widget.tab.controller;
  final _focus = FocusNode(debugLabel: 'pg-debugger');
  final _source = ScrollController();
  int _outputPage = 0;
  int? _lastScrolledLine;
  static const _lineHeight = 20.0;

  @override
  void initState() {
    super.initState();
    if (ctl.info == null && !ctl.preparing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
    }
  }

  Future<void> _prepare() async {
    if (!widget.tab.dc.isConnected) {
      setState(() {});
      return;
    }
    if (widget.tab.dc.dialect.family != DbFamily.postgres) return;
    await ctl.prepare(pick: (list) => mounted ? pickPgOverload(context, list) : Future.value(null));
  }

  @override
  void dispose() {
    _focus.dispose();
    _source.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!ctl.sm.canStart || ctl.info == null) return;
    final opts = await showPgDebugParamsDialog(context, ctl, previous: ctl.lastStart);
    if (opts == null || !mounted) return;
    final dc = widget.tab.dc;
    if (dc.config.type.confirmExecute && !opts.rollback && !opts.indirect) {
      final ok = await confirmDialog(
        context,
        'Connessione di produzione',
        'La funzione verrà eseguita su "${dc.config.name}" (${dc.config.type.label}) e le sue modifiche '
            'saranno confermate. Continuare?',
        ok: 'Continua',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    _focus.requestFocus();
    _outputPage = 0;
    await ctl.start(opts);
  }

  void _scrollToLine(int? line) {
    if (line == null || line == _lastScrolledLine || !_source.hasClients) return;
    _lastScrolledLine = line;
    final pos = _source.position;
    final top = (line - 1) * _lineHeight;
    if (top < pos.pixels || top + _lineHeight > pos.pixels + pos.viewportDimension) {
      _source.jumpTo((top - pos.viewportDimension / 3).clamp(0.0, pos.maxScrollExtent));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final dc = widget.tab.dc;
    if (!dc.isConnected) {
      return EmptyState(
        icon: AppIcons.disconnect,
        title: 'Connessione non attiva',
        message: 'Connetti "${dc.config.name}" per avviare il debugger.',
        action: PushButton.primary(
          label: 'Connetti',
          icon: AppIcons.connect,
          onPressed: () async {
            if (await ensureConnected(context, dc)) await _prepare();
            if (mounted) setState(() {});
          },
        ),
      );
    }
    if (dc.dialect.family != DbFamily.postgres) {
      return const EmptyState(
        icon: AppIcons.debug,
        title: 'Debugger non disponibile',
        message: 'Il debugger di procedure è disponibile solo per PostgreSQL (estensione pldbgapi).',
      );
    }
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        if (ctl.preparing || (ctl.info == null && ctl.prepareError == null)) {
          return const Center(child: Spinner(size: Spinner.large));
        }
        if (ctl.prepareError != null) {
          return EmptyState(
            icon: AppIcons.error,
            title: 'Impossibile preparare il debug',
            message: ctl.prepareError,
            action: PushButton.primary(label: 'Riprova', icon: AppIcons.refresh, onPressed: _prepare),
          );
        }
        final av = ctl.availability;
        if (av != null && !av.available) {
          return EmptyState(
            icon: AppIcons.extension,
            title: 'Estensione pldbgapi non installata',
            message:
                'Il debugger usa l\'estensione pldbgapi (pldebugger, la stessa di pgAdmin). Sul server: '
                'installa il pacchetto pldebugger, aggiungi shared_preload_libraries = \'plugin_debugger\' a '
                'postgresql.conf, riavvia PostgreSQL ed esegui CREATE EXTENSION pldbgapi; nel database.'
                '${av.error == null ? '' : '\n\n${av.error}'}',
            action: PushButton.primary(label: 'Verifica di nuovo', icon: AppIcons.refresh, onPressed: _prepare),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLine(ctl.displayLine));
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.f8): ctl.continueExecution,
            const SingleActivator(LogicalKeyboardKey.f7): ctl.stepInto,
            const SingleActivator(LogicalKeyboardKey.f6): ctl.stepOver,
            const SingleActivator(LogicalKeyboardKey.f5): () => ctl.sm.canStart ? _start() : null,
            const SingleActivator(LogicalKeyboardKey.f5, shift: true): ctl.stop,
          },
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            child: Container(
              color: c.content,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _toolbar(context),
                  if (av != null) ..._warnings(context, av),
                  Expanded(
                    child: SplitView(
                      axis: Axis.vertical,
                      initialFraction: 0.72,
                      first: SplitView(
                        initialFraction: 0.66,
                        minFirst: 300,
                        minSecond: 240,
                        first: _sourcePane(context),
                        second: _sidePanes(context),
                      ),
                      second: _outputPane(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _warnings(BuildContext context, PgDebuggerAvailability av) {
    final notes = [
      if (av.preloadOk == false)
        'plugin_debugger non risulta in shared_preload_libraries: il target potrebbe non fermarsi ai breakpoint.',
      if (av.superuser == false) 'I breakpoint globali di pldebugger richiedono un utente superuser.',
    ];
    return [for (final n in notes) Notice.strip(message: n)];
  }

  Widget _toolbar(BuildContext context) {
    final c = DbColors.of(context);
    final sm = ctl.sm;
    final status = switch (sm.phase) {
      DebugPhase.running || DebugPhase.waitingTarget || DebugPhase.starting => StatusLine.busy(ctl.status),
      DebugPhase.failed => StatusLine(ctl.status, kind: StatusKind.danger, maxLines: 1),
      DebugPhase.finished => StatusLine(ctl.status, kind: StatusKind.success, maxLines: 1),
      DebugPhase.paused || DebugPhase.idle => StatusLine(ctl.status, maxLines: 1),
    };
    return PaneBar(
      children: [
        if (sm.isActive)
          PushButton(
            label: 'Stop',
            icon: AppIcons.stop,
            kind: PushButtonKind.destructive,
            size: ControlScale.small,
            tooltip: 'Interrompi il debug (⇧F5)',
            onPressed: sm.canStop ? ctl.stop : null,
          )
        else
          PushButton.primary(
            label: 'Avvia',
            icon: AppIcons.run,
            size: ControlScale.small,
            tooltip: 'Avvia il debug (F5)',
            onPressed: _start,
          ),
        const SizedBox(width: Gap.xs),
        ToolButton(
          icon: AppIcons.stepOver,
          tooltip: 'Continua fino al prossimo breakpoint (F8)',
          onPressed: sm.canStep ? ctl.continueExecution : null,
        ),
        ToolButton(
          icon: AppIcons.subdirectory,
          tooltip: 'Step into: entra nelle funzioni chiamate (F7)',
          onPressed: sm.canStep ? ctl.stepInto : null,
        ),
        ToolButton(
          icon: AppIcons.redo,
          tooltip: 'Step over: esegue la riga corrente (F6)',
          onPressed: sm.canStep ? ctl.stepOver : null,
        ),
        const ToolSeparator(),
        ToolButton(
          icon: AppIcons.replay,
          tooltip: 'Ricomincia con gli stessi parametri',
          onPressed: sm.canRestart && ctl.lastStart != null ? ctl.restart : null,
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Paused keeps the amber dot: the target is waiting for a step.
              if (sm.phase == DebugPhase.paused) ...[StatusDot(c.warning, size: 7), const SizedBox(width: 6)],
              Flexible(child: status),
            ],
          ),
        ),
        if (ctl.targetPid != null) ...[const SizedBox(width: Gap.sm), Tag('PID ${ctl.targetPid}')],
        const SizedBox(width: Gap.xs),
      ],
    );
  }

  Widget _sourcePane(BuildContext context) {
    final c = DbColors.of(context);
    final func = ctl.displayFunc;
    final src = func == null ? '' : (ctl.sources[func] ?? '');
    final lines = src.split('\n');
    final current = ctl.displayLine;
    final bps = ctl.breakpointLines(func);
    final mono = monoStyle(context, size: TypeSize.mono);
    final canToggle = ctl.sm.phase != DebugPhase.running && ctl.sm.phase != DebugPhase.starting;
    final name = func == null ? '' : (func == ctl.info?.oid ? ctl.info!.signature : (ctl.funcNames[func] ?? '$func'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(title: name),
        Expanded(
          child: Container(
            color: c.codeBackground,
            child: Scrollbar(
              controller: _source,
              child: ListView.builder(
                controller: _source,
                itemExtent: _lineHeight,
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final n = i + 1;
                  final isCurrent = current == n;
                  final hasBp = bps.contains(n);
                  return Container(
                    color: isCurrent ? c.accent.withValues(alpha: Tint.regular) : null,
                    child: Row(
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: func == null || !canToggle ? null : () => ctl.toggleBreakpoint(func, n),
                          child: Tooltip(
                            message: hasBp ? 'Rimuovi breakpoint' : 'Aggiungi breakpoint',
                            child: Container(
                              width: 58,
                              color: c.gutter,
                              padding: const EdgeInsets.only(right: 8),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 18,
                                    child: hasBp
                                        ? Center(child: StatusDot(c.danger, size: 9))
                                        : (isCurrent
                                              ? Icon(AppIcons.chevronRight, size: 18, color: c.accent)
                                              : null),
                                  ),
                                  Expanded(
                                    child: Text(
                                      '$n',
                                      textAlign: TextAlign.right,
                                      style: monoStyle(context, size: TypeSize.monoSmall, color: c.textTertiary),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (hasBp && isCurrent)
                          Icon(AppIcons.chevronRight, size: 16, color: c.accent)
                        else
                          const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            lines[i].replaceAll('\t', '    '),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            style: isCurrent ? mono.copyWith(fontWeight: FontWeight.w600) : mono,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sidePanes(BuildContext context) {
    final c = DbColors.of(context);
    final stack = ctl.stack;
    final vars = ctl.variables;
    final bps = [...ctl.sm.isActive && ctl.sm.phase != DebugPhase.waitingTarget ? ctl.serverBreakpoints : ctl.pending]
        .where((b) => b.line > 0)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(title: 'Stack'),
        Expanded(
          flex: 2,
          child: stack.isEmpty
              ? _hint(context, 'Disponibile quando il debugger è fermo')
              : MacTable(
                  dense: true,
                  headers: const ['#', 'Funzione', 'Riga', 'Argomenti'],
                  rowCount: stack.length,
                  cell: (r, i) => switch (i) {
                    0 => '${stack[r].level}',
                    1 => stack[r].target,
                    2 => '${stack[r].line}',
                    _ => stack[r].args,
                  },
                  numeric: (i) => i == 0 || i == 2,
                  selected: stack.indexWhere((f) => f.level == ctl.selectedFrame),
                  onSelect: (r) => ctl.selectFrame(stack[r].level),
                ),
        ),
        Container(height: 1, color: c.separator),
        PaneHeader(title: 'Variabili'),
        Expanded(
          flex: 3,
          child: vars.isEmpty
              ? _hint(context, 'Doppio clic su un valore per modificarlo')
              : MacTable(
                  dense: true,
                  headers: const ['Nome', 'Tipo', 'Valore'],
                  rowCount: vars.length,
                  cell: (r, i) => switch (i) {
                    0 => vars[r].name,
                    1 => vars[r].type,
                    _ => vars[r].value ?? 'NULL',
                  },
                  mono: (i) => i == 2,
                  tooltip: (r, i) => i == 0
                      ? '${vars[r].classLabel}${vars[r].isConst ? ', costante' : ''}${vars[r].isNotNull ? ', NOT NULL' : ''}'
                      : (i == 2 ? vars[r].value : null),
                  onDoubleTap: (r) => _editVariable(vars[r]),
                ),
        ),
        Container(height: 1, color: c.separator),
        PaneHeader(title: 'Breakpoint'),
        Expanded(
          flex: 2,
          child: bps.isEmpty
              ? _hint(context, 'Clic sul numero di riga per aggiungerne uno')
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: 2),
                  children: [
                    for (final b in bps)
                      ListRow(
                        leading: StatusDot(c.danger, size: 8),
                        title: '${ctl.funcNames[b.func] ?? (b.target.isEmpty ? b.func : b.target)} · riga ${b.line}',
                        trailing: ToolButton(
                          icon: AppIcons.close,
                          extent: 18,
                          tooltip: 'Rimuovi',
                          onPressed: ctl.sm.phase == DebugPhase.running ? null : () => ctl.removeBreakpoint(b),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _hint(BuildContext context, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: uiText(TypeSize.small, color: DbColors.of(context).textTertiary),
      ),
    ),
  );

  Future<void> _editVariable(PgVariable v) async {
    if (!ctl.sm.canStep) return;
    if (v.isConst) {
      showToast(context, '${v.name} è una costante', error: true);
      return;
    }
    final value = await promptText(context, 'Nuovo valore di ${v.name}', label: v.type, initial: v.value ?? '');
    if (value == null || !mounted) return;
    await guarded(context, () => ctl.deposit(v, value), title: 'Modifica non riuscita');
  }

  Widget _outputPane(BuildContext context) {
    final r = ctl.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneTabs<int>(
          value: _outputPage,
          tabs: [
            const PaneTab(0, 'Messaggi'),
            PaneTab(1, 'Risultato', count: r != null && r.isResultSet ? r.rows.length : null),
          ],
          onChanged: (v) => setState(() => _outputPage = v),
          trailing: ctl.callSql == null
              ? null
              : ToolButton(
                  icon: AppIcons.copy,
                  tooltip: 'Copia la chiamata SQL',
                  onPressed: () => Clipboard.setData(ClipboardData(text: ctl.callSql!)),
                ),
        ),
        Expanded(child: _outputPage == 0 ? _messages(context) : _result(context)),
      ],
    );
  }

  Widget _messages(BuildContext context) {
    final c = DbColors.of(context);
    final m = ctl.messages;
    if (m.isEmpty) {
      return _hint(context, 'Premi Avvia (F5), inserisci i parametri e il debugger si fermerà alla prima riga.');
    }
    String two(int v) => v.toString().padLeft(2, '0');
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      itemCount: m.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${two(m[i].time.hour)}:${two(m[i].time.minute)}:${two(m[i].time.second)}',
              style: monoStyle(context, size: TypeSize.monoSmall, color: c.textTertiary),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: SelectableText(
                m[i].text,
                style: monoStyle(context, size: TypeSize.mono, color: m[i].error ? c.danger : c.text),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _result(BuildContext context) {
    final c = DbColors.of(context);
    if (ctl.resultError != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.md),
        child: SelectableText(
          ctl.resultError!,
          style: monoStyle(context, size: TypeSize.mono, color: c.danger),
        ),
      );
    }
    final r = ctl.result;
    if (r == null) return _hint(context, 'Il risultato della funzione appare quando l\'esecuzione termina.');
    if (!r.isResultSet) {
      return _hint(context, r.rowsAffected >= 0 ? 'Righe modificate: ${r.rowsAffected}' : 'Esecuzione completata');
    }
    final nullText = AppScope.read(context).settings.nullText;
    return MacTable(
      dense: true,
      headers: [for (final col in r.columns) col.name],
      rowCount: r.rows.length,
      cell: (row, i) => formatValue(r.rows[row][i], nullText: nullText, maxLen: 500),
      numeric: (i) => r.columns[i].isNumeric,
    );
  }
}
