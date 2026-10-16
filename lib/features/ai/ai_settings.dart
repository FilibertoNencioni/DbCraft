// "Assistente AI" settings page and the setup sheet shown when the
// assistant is used before being configured.
import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../ui/widgets/common.dart';
import 'ai_service.dart';
import 'claude_client.dart';

/// Form groups for the settings dialog (page "Assistente AI").
Widget aiSettingsSection(BuildContext context) => const _AiSettingsSection();

const _effortLabels = [('low', 'Bassa'), ('medium', 'Media'), ('high', 'Alta'), ('xhigh', 'Extra'), ('max', 'Max')];

class _AiSettingsSection extends StatefulWidget {
  const _AiSettingsSection();
  @override
  State<_AiSettingsSection> createState() => _AiSettingsSectionState();
}

class _AiSettingsSectionState extends State<_AiSettingsSection> {
  late final AppState app = AppScope.read(context);
  late final _model = TextEditingController(text: app.settings.aiModel);
  late final _baseUrl = TextEditingController(text: app.settings.aiBaseUrl);
  final _key = TextEditingController();
  bool _verifying = false;
  String? _verifyResult;
  bool _verifyOk = false;
  bool _showKey = false;

  @override
  void dispose() {
    _model.dispose();
    _baseUrl.dispose();
    _key.dispose();
    super.dispose();
  }

  void _apply(VoidCallback change) {
    setState(change);
    app.saveSettings();
  }

  bool get _vaultLocked => app.vault.isLocked;

  bool get _hasVaultKey {
    try {
      return !_vaultLocked && (app.vault.get(kAiVaultKey) ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveKey() async {
    final k = _key.text.trim();
    if (k.isEmpty) return;
    await guarded(context, () => app.vault.set(kAiVaultKey, k), title: 'Impossibile salvare la chiave');
    _key.clear();
    if (mounted) {
      setState(() => _verifyResult = null);
      showToast(context, 'Chiave API salvata nel vault');
    }
    app.saveSettings(); // refreshes listeners (aiAvailable)
  }

  Future<void> _removeKey() async {
    final ok = await confirmDialog(
      context,
      'Rimuovere la chiave API?',
      'La chiave di Anthropic verrà eliminata dal vault di DbCraft.',
      ok: 'Rimuovi',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await guarded(context, () => app.vault.set(kAiVaultKey, null));
    if (mounted) setState(() => _verifyResult = null);
    app.saveSettings();
  }

  Future<void> _verify() async {
    final typed = _key.text.trim();
    setState(() {
      _verifying = true;
      _verifyResult = null;
    });
    try {
      final name = await ClaudeClient(aiConfig(app, apiKey: typed.isEmpty ? null : typed)).verify();
      _verifyOk = true;
      _verifyResult = 'Connessione riuscita: $name disponibile.';
    } catch (e) {
      _verifyOk = false;
      _verifyResult = e is AiException ? e.message : e.toString();
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Widget _switch(String label, String? help, bool value, ValueChanged<bool> onChanged) => FormRow(
    label: label,
    help: help,
    labelWidth: 320,
    child: Align(
      alignment: Alignment.centerRight,
      child: DbSwitch(value: value, onChanged: (v) => _apply(() => onChanged(v))),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final s = app.settings;
    final prefs = AiPrefs.of(app);
    final fromEnv = aiKeyFromEnvironment(app);
    final keyStatus = _vaultLocked
        ? 'Vault bloccato: sbloccalo per gestire la chiave'
        : _hasVaultKey
        ? 'Salvata nel vault (cifrata)'
        : fromEnv
        ? 'In uso la variabile d\'ambiente ANTHROPIC_API_KEY'
        : 'Nessuna chiave configurata';
    final defaultHost = isDefaultHost(_baseUrl.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          children: [
            _switch(
              'Assistente AI',
              'Spiega e corregge le query, genera SQL dal linguaggio naturale',
              s.aiEnabled,
              (v) => s.aiEnabled = v,
            ),
          ],
        ),
        FormGroup(
          title: 'Account Anthropic',
          footer:
              'La chiave viene salvata solo nel vault cifrato di DbCraft, mai in settings.json. '
              'Puoi crearne una nella console di Anthropic.',
          children: [
            FormRow(
              label: 'Chiave API',
              help: keyStatus,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _key,
                      enabled: !_vaultLocked,
                      obscureText: !_showKey,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        hintText: _hasVaultKey ? '••••••••  (sostituisci)' : 'sk-ant-…',
                        suffixIcon: GestureDetector(
                          onTap: () => setState(() => _showKey = !_showKey),
                          child: Icon(
                            _showKey ? AppIcons.eyeOff : AppIcons.eye,
                            size: 15,
                            color: c.textTertiary,
                          ),
                        ),
                        suffixIconConstraints: const BoxConstraints(minWidth: 28),
                      ),
                      onSubmitted: (_) => _saveKey(),
                    ),
                  ),
                  const SizedBox(width: Gap.xs),
                  ToolButton(
                    icon: AppIcons.save,
                    tooltip: 'Salva nel vault',
                    onPressed: _vaultLocked ? null : _saveKey,
                  ),
                  if (_hasVaultKey)
                    ToolButton(icon: AppIcons.delete, tooltip: 'Rimuovi la chiave', onPressed: _removeKey),
                ],
              ),
            ),
            FormRow(
              label: 'Verifica',
              help: 'Controlla chiave e modello senza consumare token',
              child: Row(
                children: [
                  if (_verifying)
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  else if (_verifyResult != null)
                    Icon(
                      _verifyOk ? AppIcons.checkCircle : AppIcons.error,
                      size: 15,
                      color: _verifyOk ? c.success : c.danger,
                    ),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(
                      _verifyResult ?? '',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: TypeSize.small, color: _verifyOk ? c.textSecondary : c.danger),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _verifying || (aiApiKey(app) == null && _key.text.trim().isEmpty) ? null : _verify,
                    child: const Text('Verifica'),
                  ),
                ],
              ),
            ),
          ],
        ),
        FormGroup(
          title: 'Modello',
          children: [
            FormRow(
              label: 'Modello',
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _model,
                      style: monoStyle(context, size: 12.5),
                      decoration: const InputDecoration(hintText: kAiDefaultModel),
                      onChanged: (v) {
                        s.aiModel = v.trim().isEmpty ? kAiDefaultModel : v.trim();
                        app.saveSettings();
                      },
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Modelli consigliati',
                    position: PopupMenuPosition.under,
                    icon: Icon(AppIcons.chevronDown, size: 16, color: c.textSecondary),
                    onSelected: (v) => _apply(() {
                      _model.text = v;
                      s.aiModel = v;
                    }),
                    itemBuilder: (_) => [
                      for (final (id, label) in const [
                        ('claude-opus-5-5', 'Claude Opus 5.5 — consigliato'),
                        ('claude-sonnet-5-5', 'Claude Sonnet 5.5 — più veloce'),
                        ('claude-haiku-5-5', 'Claude Haiku 5.5 — il più economico'),
                        ('claude-fable-5-1', 'Claude Fable 5.1 — il più capace'),
                      ])
                        PopupMenuItem(value: id, height: 30, child: Text(label)),
                    ],
                  ),
                ],
              ),
            ),
            FormRow(
              label: 'Impegno',
              help: 'Più alto: risposte più accurate, più lente e costose',
              child: Align(
                alignment: Alignment.centerRight,
                child: Segmented<String>(
                  value: kAiEfforts.contains(s.aiEffort) ? s.aiEffort : 'medium',
                  items: [for (final (v, l) in _effortLabels) (v, l, null)],
                  onChanged: (v) => _apply(() => s.aiEffort = v),
                ),
              ),
            ),
            FormRow(
              label: 'URL di base',
              help: 'Cambialo solo per un proxy o gateway',
              child: TextField(
                controller: _baseUrl,
                style: monoStyle(context, size: 12.5),
                decoration: const InputDecoration(hintText: kAiDefaultBaseUrl),
                onChanged: (v) {
                  setState(() => s.aiBaseUrl = v.trim().isEmpty ? kAiDefaultBaseUrl : v.trim());
                  app.saveSettings();
                },
              ),
            ),
            FormRow(
              label: 'Modello di riserva',
              help: defaultHost
                  ? 'Se il modello rifiuta la richiesta, Anthropic la ripete con il modello consigliato'
                  : 'Disponibile solo con api.anthropic.com',
              labelWidth: 320,
              child: Align(
                alignment: Alignment.centerRight,
                child: DbSwitch(
                  value: prefs.fallbacks,
                  onChanged: (v) {
                    setState(() => prefs.fallbacks = v);
                    prefs.save(app);
                  },
                ),
              ),
            ),
          ],
        ),
        FormGroup(
          title: 'Dati condivisi',
          footer:
              'Le query e la struttura del database (nomi di tabelle e colonne, tipi, chiavi) vengono inviate ad '
              'Anthropic per generare le risposte. I dati delle tabelle non vengono mai inviati, salvo quando scegli '
              'esplicitamente di includere alcune righe di un risultato. Non usare l\'assistente su database i cui '
              'nomi di oggetti sono riservati.',
          children: [
            _switch(
              'Invia la struttura del database',
              'Tabelle e colonne usate dalla query o dello schema corrente',
              s.aiIncludeSchema,
              (v) => s.aiIncludeSchema = v,
            ),
          ],
        ),
      ],
    );
  }
}

/// Makes sure the assistant can be used: when it is disabled or has no key,
/// shows a sheet with the settings. Returns true when it is ready.
Future<bool> ensureAiReady(BuildContext context) async {
  final app = AppScope.read(context);
  if (aiAvailable(app)) return true;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final c = DbColors.of(ctx);
      return Dialog(
        insetPadding: const EdgeInsets.all(Gap.xl),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 620,
          height: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.md, Gap.xs),
                child: Row(
                  children: [
                    Icon(AppIcons.ai, size: 18, color: c.accent),
                    const SizedBox(width: Gap.sm),
                    Expanded(child: Text('Configura l\'assistente AI', style: Theme.of(ctx).textTheme.titleLarge)),
                    ToolButton(icon: AppIcons.close, tooltip: 'Chiudi', onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                child: Text(
                  'Attiva l\'assistente e inserisci una chiave API di Anthropic per usare Claude.',
                  style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.md, Gap.xl, Gap.md),
                  children: [aiSettingsSection(ctx)],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.separator)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [PrimaryButton(label: 'Fatto', onPressed: () => Navigator.pop(ctx))],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  return aiAvailable(app);
}
