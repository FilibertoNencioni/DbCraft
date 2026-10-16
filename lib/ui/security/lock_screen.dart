import 'package:flutter/material.dart';

import '../widgets/common.dart';

/// Full-window prompt for the master password (startup and idle lock).
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.onUnlock, this.onReset, this.message});

  /// Returns false when the password is wrong.
  final Future<bool> Function(String password) onUnlock;

  /// Deletes the stored credentials (forgotten password). Null hides it.
  final Future<void> Function()? onReset;
  final String? message;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  bool _wrong = false;

  @override
  void dispose() {
    _password.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _wrong = false;
    });
    final ok = await widget.onUnlock(_password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _wrong = !ok;
    });
    if (!ok) {
      _password.selection = TextSelection(baseOffset: 0, extentOffset: _password.text.length);
      _focus.requestFocus();
    }
  }

  Future<void> _reset() async {
    final ok = await confirmDialog(
      context,
      'Reimposta le credenziali',
      'Senza la master password le credenziali salvate non possono essere recuperate. '
          'Eliminarle tutte e continuare senza master password?\n\n'
          'Connessioni, script e impostazioni restano invariati: andranno reinserite solo password e chiavi.',
      ok: 'Elimina credenziali',
      destructive: true,
    );
    if (ok) await widget.onReset!();
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return ColoredBox(
      color: c.chrome,
      child: Center(
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(Gap.xl),
          decoration: BoxDecoration(
            color: c.raised,
            borderRadius: BorderRadius.circular(Radii.sheet),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 24, offset: const Offset(0, 8))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(AppIcons.lock, size: 36, color: c.accent),
            const SizedBox(height: Gap.md),
            Text('DbCraft è bloccato', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.xs),
            Text(
              widget.message ?? 'Inserisci la master password per accedere alle credenziali salvate.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: TypeSize.small + 0.5, color: c.textSecondary, height: 1.4),
            ),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _password,
              focusNode: _focus,
              autofocus: true,
              obscureText: true,
              enabled: !_busy,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Master password',
                errorText: _wrong ? 'Password errata' : null,
              ),
            ),
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: _busy ? 'Verifica…' : 'Sblocca',
                icon: AppIcons.lockOpen,
                onPressed: _busy ? null : _submit,
              ),
            ),
            if (widget.onReset != null) ...[
              const SizedBox(height: Gap.sm),
              TextButton(
                onPressed: _busy ? null : _reset,
                child: Text('Password dimenticata?', style: TextStyle(fontSize: TypeSize.small, color: c.textSecondary)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
