// "Assistente AI" editor tab: a multi-turn chat bound to a connection.
//
// The conversation sent to the API is append-only: assistant turns are
// replayed exactly as returned (thinking blocks included), and the system
// prompt (instructions + schema) is built once per conversation so that the
// whole prefix stays cached.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../ui/widgets/common.dart';
import 'ai_context.dart';
import 'ai_service.dart';
import 'ai_settings.dart';
import 'ai_widgets.dart';
import 'claude_client.dart';
import 'markdown_view.dart';

class AiChatMessage {
  AiChatMessage.user(this.text, {String? wire}) : user = true, wireText = wire ?? text;
  AiChatMessage.assistant() : user = false, text = '', wireText = '';

  final bool user;

  /// Text shown in the chat.
  String text;

  /// Text sent to the API (user turns; may contain extra context).
  final String wireText;
  AiResponse? response;
  String? error;

  /// The exchange completed and belongs to the API conversation.
  bool get ok => user || (response != null && !response!.refused && error == null);
}

class AiChatTab extends FeatureTab {
  AiChatTab(this._connection);

  final DbConnection? _connection;
  final List<AiChatMessage> messages = [];
  final input = TextEditingController();
  final scroll = ScrollController();

  /// Frozen system blocks of the conversation (null until the first turn).
  List<AiSystemBlock>? system;
  AiRun? _run;
  AiChatMessage? _pending;

  @override
  DbConnection? get connection => _connection;
  @override
  String get title => _connection == null ? 'Assistente AI' : 'AI <${_connection.config.name}>';
  @override
  String get tooltip => 'Assistente AI${_connection == null ? '' : ' — ${_connection.config.name}'}';
  @override
  IconData get icon => Icons.auto_awesome_outlined;

  bool get busy => _run?.busy ?? false;

  /// Starts the conversation from an exchange done elsewhere (explain
  /// dialogs): same system prompt and turns, so nothing is edited.
  void seed(List<AiSystemBlock> sys, String prompt, String label, AiResponse r) {
    system = sys;
    messages
      ..add(AiChatMessage.user(label, wire: prompt))
      ..add(
        AiChatMessage.assistant()
          ..text = r.text
          ..response = r,
      );
  }

  /// Wire messages: only completed exchanges, in order.
  List<Map<String, Object?>> _wire() {
    final out = <Map<String, Object?>>[];
    for (var i = 0; i + 1 < messages.length; i += 2) {
      final u = messages[i], a = messages[i + 1];
      if (!u.user || a.user || !a.ok || a.response == null) continue;
      out.add({'role': 'user', 'content': u.wireText});
      out.add({'role': 'assistant', 'content': a.response!.replayContent()});
    }
    return out;
  }

  Future<void> send(AppState app, String text) async {
    final t = text.trim();
    if (t.isEmpty || busy) return;
    final history = _wire();
    final user = AiChatMessage.user(t);
    final answer = AiChatMessage.assistant();
    messages
      ..add(user)
      ..add(answer);
    _pending = answer;
    var run = _run;
    if (run == null) {
      run = _run = AiRun(app);
      run.addListener(_onRun);
    }
    notifyListeners();
    final r = await run.start(() async {
      system ??= buildSystem(
        AiTask.chat,
        await AiDbContext.build(_connection, includeSchema: app.settings.aiIncludeSchema),
      );
      return AiRequest(
        system: system!,
        messages: [
          ...history,
          {'role': 'user', 'content': t},
        ],
        autoCache: true,
      );
    });
    answer.response = r;
    answer.text = r?.text ?? run.text;
    if (r == null) answer.error = run.error ?? 'Richiesta annullata';
    _pending = null;
    notifyListeners();
  }

  void _onRun() {
    final p = _pending;
    final run = _run;
    if (p != null && run != null) p.text = run.text;
    notifyListeners();
  }

  void cancel() => _run?.cancel();

  void clear() {
    cancel();
    messages.clear();
    system = null;
    notifyListeners();
  }

  @override
  Widget buildView(BuildContext context) => _AiChatView(tab: this);

  @override
  Future<bool> canClose(BuildContext context) async {
    cancel();
    return true;
  }

  @override
  void dispose() {
    _run?.removeListener(_onRun);
    _run?.dispose();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }
}

class _AiChatView extends StatefulWidget {
  const _AiChatView({required this.tab});
  final AiChatTab tab;
  @override
  State<_AiChatView> createState() => _AiChatViewState();
}

class _AiChatViewState extends State<_AiChatView> {
  final _focus = FocusNode();
  AiChatTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    tab.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _AiChatView old) {
    super.didUpdateWidget(old);
    if (old.tab != tab) {
      old.tab.removeListener(_changed);
      tab.addListener(_changed);
    }
  }

  @override
  void dispose() {
    tab.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final s = tab.scroll;
    final atEnd = !s.hasClients || s.position.pixels >= s.position.maxScrollExtent - 40;
    setState(() {});
    if (atEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (s.hasClients) s.jumpTo(s.position.maxScrollExtent);
      });
    }
  }

  Future<void> _send() async {
    if (!await ensureAiReady(context) || !mounted) return;
    final text = tab.input.text;
    if (text.trim().isEmpty) return;
    tab.input.clear();
    await tab.send(AppScope.read(context), text);
    if (mounted) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final app = AppScope.of(context);
    final dc = tab.connection;
    return Material(
      color: c.content,
      child: Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.separator)),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 16, color: c.accent),
                const SizedBox(width: Gap.sm),
                Text(
                  'Assistente AI',
                  style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.text),
                ),
                if (dc != null) ...[
                  const SizedBox(width: Gap.sm),
                  StatusDot(dc.isConnected ? c.success : c.textTertiary, size: 7, ring: !dc.isConnected),
                  const SizedBox(width: 5),
                  Text(
                    dc.config.name,
                    style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary),
                  ),
                ],
                const Spacer(),
                Text(
                  app.settings.aiModel,
                  style: TextStyle(fontSize: TypeSize.small, color: c.textTertiary),
                ),
                const ToolSeparator(),
                ToolButton(
                  icon: Icons.add_comment_outlined,
                  tooltip: 'Nuova conversazione',
                  onPressed: tab.messages.isEmpty ? null : tab.clear,
                ),
              ],
            ),
          ),
          Expanded(
            child: tab.messages.isEmpty
                ? _empty(dc)
                : ListView.builder(
                    controller: tab.scroll,
                    padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.lg),
                    itemCount: tab.messages.length,
                    itemBuilder: (context, i) => _message(app, tab.messages[i], i == tab.messages.length - 1),
                  ),
          ),
          _composer(),
        ],
      ),
    );
  }

  Widget _empty(DbConnection? dc) {
    final c = DbColors.of(context);
    const suggestions = [
      'Quali tabelle contengono i dati dei clienti?',
      'Scrivi una query con il fatturato mensile dell\'ultimo anno',
      'Quali indici mancano per le query più comuni?',
    ];
    return EmptyState(
      icon: Icons.auto_awesome_outlined,
      title: 'Chiedi qualcosa sul database',
      message: dc == null
          ? 'Scrivi una domanda: Claude risponde e propone query da inserire o eseguire nell\'editor SQL.'
          : 'Claude conosce la struttura di ${dc.config.name}${dc.isConnected ? '' : ' (connettiti per includerla)'} '
                'e propone query da inserire o eseguire nell\'editor SQL.',
      action: Column(
        children: [
          for (final s in suggestions)
            TextButton(
              onPressed: () {
                tab.input.text = s;
                _focus.requestFocus();
              },
              child: Text(
                s,
                style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.accent),
              ),
            ),
        ],
      ),
    );
  }

  Widget _message(AppState app, AiChatMessage m, bool last) {
    final c = DbColors.of(context);
    if (m.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          margin: const EdgeInsets.only(bottom: Gap.md, left: Gap.xxl),
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          decoration: BoxDecoration(color: c.chrome, borderRadius: BorderRadius.circular(Radii.sheet)),
          child: SelectableText(
            m.text,
            style: TextStyle(fontSize: TypeSize.body, color: c.text, height: 1.4),
          ),
        ),
      );
    }
    final run = tab._run;
    final live = last && run != null && tab._pending == m;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: live
            ? AiAnswerView(run: run, codeActions: editorCodeActions(app, tab.connection))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (m.text.isNotEmpty)
                    MarkdownView(data: m.text, codeActions: editorCodeActions(app, tab.connection)),
                  if (m.error != null) ...[
                    const SizedBox(height: Gap.sm),
                    AiNotice(m.error!, error: m.error != 'Richiesta annullata'),
                  ],
                  if (m.response?.notice != null) ...[
                    const SizedBox(height: Gap.sm),
                    AiNotice(m.response!.notice!, error: m.response!.refused),
                  ],
                  if (m.response != null && !m.response!.refused) ...[
                    const SizedBox(height: Gap.xs),
                    Text(
                      formatUsage(m.response!),
                      style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _composer() {
    final c = DbColors.of(context);
    final mac = Platform.isMacOS;
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.sm, Gap.xl, Gap.md),
      decoration: BoxDecoration(
        color: c.content,
        border: Border(top: BorderSide(color: c.separator)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _send,
                SingleActivator(LogicalKeyboardKey.enter, meta: mac, control: !mac): _send,
              },
              child: TextField(
                controller: tab.input,
                focusNode: _focus,
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(hintText: 'Scrivi un messaggio… (⇧Invio per andare a capo)'),
              ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          if (tab.busy)
            PrimaryButton(label: 'Interrompi', icon: Icons.stop_rounded, color: c.danger, onPressed: tab.cancel)
          else
            PrimaryButton(label: 'Invia', icon: Icons.arrow_upward_rounded, onPressed: _send),
        ],
      ),
    );
  }
}
