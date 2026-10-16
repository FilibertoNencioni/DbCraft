import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../widgets/common.dart';

/// Settings page "Sicurezza": master password and credential storage.
class SecuritySettings extends StatefulWidget {
  const SecuritySettings({super.key});

  @override
  State<SecuritySettings> createState() => _SecuritySettingsState();
}

class _SecuritySettingsState extends State<SecuritySettings> {
  late final AppState app = AppScope.read(context);
  bool _busy = false;

  Future<void> _changePassword({required bool remove}) async {
    final vault = app.vault;
    final result = await showSheet<(String?, String?)>(
      context,
      size: SheetSize.small,
      builder: (_) => _MasterPasswordSheet(hasCurrent: vault.usesMasterPassword, remove: remove),
    );
    if (result == null || !mounted) return;
    final (current, next) = result;
    setState(() => _busy = true);
    try {
      if (vault.usesMasterPassword && !await vault.checkPassword(current ?? '')) {
        if (mounted) showToast(context, 'La password attuale non è corretta', error: true);
        return;
      }
      await vault.setMasterPassword(remove ? null : next);
      if (mounted) {
        showToast(context, remove ? 'Master password rimossa' : 'Master password impostata');
      }
    } catch (e) {
      if (mounted) showErrorDialog(context, e, title: 'Operazione non riuscita');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final vault = app.vault;
    final s = app.settings;
    final master = vault.usesMasterPassword;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FormGroup(
        title: 'Master password',
        footer: master
            ? 'Password, chiavi e token sono cifrati (AES-256-GCM) con una chiave derivata dalla master password '
                  '(PBKDF2-SHA256). Senza la password non possono essere recuperati.'
            : 'Le credenziali sono cifrate (AES-256-GCM) con una chiave casuale salvata nel workspace, leggibile solo '
                  'dal tuo utente. Con una master password la chiave non viene salvata su disco.',
        children: [
          FormRow(
            label: 'Stato',
            child: Row(children: [
              Icon(master ? AppIcons.lock : AppIcons.lockOpen, size: 16, color: master ? c.success : c.textSecondary),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(master ? 'Attiva' : 'Non impostata')),
              if (_busy) const Spinner(size: Spinner.small),
            ]),
          ),
          FormRow(
            label: 'Credenziali salvate',
            child: Text('${vault.length}', style: const TextStyle(fontFeatures: kTabular)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Wrap(spacing: Gap.sm, alignment: WrapAlignment.end, children: [
              if (master)
                PushButton(
                  label: 'Rimuovi',
                  onPressed: _busy ? null : () => _changePassword(remove: true),
                ),
              PushButton(
                label: master ? 'Cambia master password…' : 'Imposta master password…',
                onPressed: _busy ? null : () => _changePassword(remove: false),
              ),
            ]),
          ),
        ],
      ),
      if (master)
        FormGroup(
          title: 'Blocco',
          children: [
            FormRow(
              label: 'Blocca dopo inattività',
              child: Align(
                alignment: Alignment.centerRight,
                child: PopUpButton<int>(
                  value: const [0, 5, 15, 30, 60].contains(s.autoLockMinutes) ? s.autoLockMinutes : 0,
                  items: const [
                    (0, 'Mai', null),
                    (5, '5 minuti', null),
                    (15, '15 minuti', null),
                    (30, '30 minuti', null),
                    (60, '1 ora', null),
                  ],
                  onChanged: (v) {
                    setState(() => s.autoLockMinutes = v);
                    app.saveSettings();
                  },
                ),
              ),
            ),
            FormRow(
              label: 'Blocca ora',
              child: Align(
                alignment: Alignment.centerRight,
                child: PushButton(
                  label: 'Blocca',
                  icon: AppIcons.lock,
                  onPressed: () {
                    Navigator.of(context).pop();
                    app.lockUi();
                  },
                ),
              ),
            ),
          ],
        ),
      const FormGroup(
        title: 'Autenticazione',
        footer: 'Kerberos, Microsoft Entra ID (Azure AD), SSO/SAML, Okta, AWS IAM, OAuth e coppie di chiavi si scelgono '
            'nella scheda Connessione di ogni connessione. I token sono gestiti dal driver o richiesti '
            'ad Azure CLI / AWS al momento della connessione.',
        children: [],
      ),
    ]);
  }
}

class _MasterPasswordSheet extends StatefulWidget {
  const _MasterPasswordSheet({required this.hasCurrent, required this.remove});
  final bool hasCurrent;
  final bool remove;

  @override
  State<_MasterPasswordSheet> createState() => _MasterPasswordSheetState();
}

class _MasterPasswordSheetState extends State<_MasterPasswordSheet> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _ok() {
    if (!widget.remove) {
      if (_next.text.length < 8) {
        setState(() => _error = 'Usa almeno 8 caratteri');
        return;
      }
      if (_next.text != _confirm.text) {
        setState(() => _error = 'Le password non coincidono');
        return;
      }
    }
    Navigator.pop(context, (_current.text, _next.text));
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.remove
        ? 'Rimuovi master password'
        : widget.hasCurrent
        ? 'Cambia master password'
        : 'Imposta master password';
    return SheetScaffold(
      title: title,
      onSubmit: _ok,
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: widget.remove ? 'Rimuovi' : 'Salva', onPressed: _ok),
      ],
      body: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.hasCurrent) SecureField(controller: _current, autofocus: true, hint: 'Password attuale'),
        if (!widget.remove) ...[
          if (widget.hasCurrent) const SizedBox(height: Gap.sm),
          SecureField(controller: _next, autofocus: !widget.hasCurrent, hint: 'Nuova password'),
          const SizedBox(height: Gap.sm),
          SecureField(controller: _confirm, hint: 'Conferma nuova password', onSubmitted: (_) => _ok()),
        ],
        if (_error != null) FieldMessage(_error!, error: true),
        if (!widget.remove)
          const Padding(
            padding: EdgeInsets.only(top: Gap.sm),
            child: FieldMessage(
              'Verrà chiesta all\'avvio. Se la dimentichi le credenziali salvate andranno reinserite.',
            ),
          ),
      ]),
    );
  }
}
