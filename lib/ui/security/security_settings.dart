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
    final result = await showDialog<(String?, String?)>(
      context: context,
      builder: (_) => _MasterPasswordDialog(hasCurrent: vault.usesMasterPassword, remove: remove),
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
              Icon(master ? AppIcons.lock : AppIcons.lockOpen, size: 15, color: master ? c.success : c.textSecondary),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(master ? 'Attiva' : 'Non impostata')),
              if (_busy) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
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
                OutlinedButton(
                  onPressed: _busy ? null : () => _changePassword(remove: true),
                  child: const Text('Rimuovi'),
                ),
              FilledButton(
                onPressed: _busy ? null : () => _changePassword(remove: false),
                child: Text(master ? 'Cambia master password…' : 'Imposta master password…'),
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
                child: DropdownButton<int>(
                  value: const [0, 5, 15, 30, 60].contains(s.autoLockMinutes) ? s.autoLockMinutes : 0,
                  isDense: true,
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Mai')),
                    DropdownMenuItem(value: 5, child: Text('5 minuti')),
                    DropdownMenuItem(value: 15, child: Text('15 minuti')),
                    DropdownMenuItem(value: 30, child: Text('30 minuti')),
                    DropdownMenuItem(value: 60, child: Text('1 ora')),
                  ],
                  onChanged: (v) {
                    setState(() => s.autoLockMinutes = v ?? 0);
                    app.saveSettings();
                  },
                ),
              ),
            ),
            FormRow(
              label: 'Blocca ora',
              child: Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    app.lockUi();
                  },
                  icon: const Icon(AppIcons.lock, size: 15),
                  label: const Text('Blocca'),
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

class _MasterPasswordDialog extends StatefulWidget {
  const _MasterPasswordDialog({required this.hasCurrent, required this.remove});
  final bool hasCurrent;
  final bool remove;

  @override
  State<_MasterPasswordDialog> createState() => _MasterPasswordDialogState();
}

class _MasterPasswordDialogState extends State<_MasterPasswordDialog> {
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
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.hasCurrent)
            TextField(
              controller: _current,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Password attuale'),
            ),
          if (!widget.remove) ...[
            const SizedBox(height: Gap.sm),
            TextField(
              controller: _next,
              obscureText: true,
              autofocus: !widget.hasCurrent,
              decoration: const InputDecoration(hintText: 'Nuova password'),
            ),
            const SizedBox(height: Gap.sm),
            TextField(
              controller: _confirm,
              obscureText: true,
              onSubmitted: (_) => _ok(),
              decoration: const InputDecoration(hintText: 'Conferma nuova password'),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(_error!, style: TextStyle(color: DbColors.of(context).danger, fontSize: TypeSize.small)),
            ),
          if (!widget.remove)
            Padding(
              padding: const EdgeInsets.only(top: Gap.md),
              child: Text(
                'Verrà chiesta all\'avvio. Se la dimentichi le credenziali salvate andranno reinserite.',
                style: TextStyle(fontSize: TypeSize.small, color: DbColors.of(context).textSecondary),
              ),
            ),
        ]),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        FilledButton(onPressed: _ok, child: Text(widget.remove ? 'Rimuovi' : 'Salva')),
      ],
    );
  }
}
