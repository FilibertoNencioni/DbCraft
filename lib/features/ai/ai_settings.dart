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
    child: DbSwitch(value: value, onChanged: (v) => _apply(() => onChanged(v))),
  );

  @override
  Widget build(BuildContext context) {
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
                    child: SecureField(
                      controller: _key,
                      enabled: !_vaultLocked,
                      hint: _hasVaultKey ? '••••••••  (sostituisci)' : 'sk-ant-…',
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
                  Expanded(
                    child: _verifying
                        ? const StatusLine.busy('Verifica in corso…')
                        : _verifyResult == null
                        ? const SizedBox.shrink()
                        : StatusLine(
                            _verifyResult!,
                            kind: _verifyOk ? StatusKind.success : StatusKind.danger,
                            selectable: !_verifyOk,
                            maxLines: 3,
                          ),
                  ),
                  const SizedBox(width: Gap.sm),
                  PushButton(
                    label: 'Verifica',
                    onPressed: _verifying || (aiApiKey(app) == null && _key.text.trim().isEmpty) ? null : _verify,
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
              child: ComboField(
                controller: _model,
                mono: true,
                hint: kAiDefaultModel,
                options: () => const ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-1'],
                onChanged: (v) => _apply(() => s.aiModel = v.trim().isEmpty ? kAiDefaultModel : v.trim()),
              ),
            ),
            FormRow(
              label: 'Impegno',
              help: 'Più alto: risposte più accurate, più lente e costose',
              child: Segmented<String>(
                value: kAiEfforts.contains(s.aiEffort) ? s.aiEffort : 'medium',
                items: [for (final (v, l) in _effortLabels) (v, l, null)],
                onChanged: (v) => _apply(() => s.aiEffort = v),
              ),
            ),
            FormRow(
              label: 'URL di base',
              help: 'Cambialo solo per un proxy o gateway',
              child: MacTextField(
                controller: _baseUrl,
                mono: true,
                hint: kAiDefaultBaseUrl,
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
              child: DbSwitch(
                value: prefs.fallbacks,
                onChanged: (v) {
                  setState(() => prefs.fallbacks = v);
                  prefs.save(app);
                },
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
  await showSheet<void>(
    context,
    size: SheetSize.large,
    builder: (ctx) => SheetScaffold(
      title: 'Configura l\'assistente AI',
      subtitle: 'Attiva l\'assistente e inserisci una chiave API di Anthropic per usare Claude.',
      padding: EdgeInsets.zero,
      onSubmit: () => Navigator.pop(ctx),
      body: ListView(padding: const EdgeInsets.symmetric(horizontal: 20), children: [aiSettingsSection(ctx)]),
      actions: [PushButton.primary(label: 'Fine', onPressed: () => Navigator.pop(ctx))],
    ),
  );
  return aiAvailable(app);
}
