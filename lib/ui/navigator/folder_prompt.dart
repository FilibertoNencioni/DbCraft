import 'package:flutter/material.dart';

import '../../model/connection_folders.dart';
import '../widgets/common.dart';

/// Asks for a connection folder: an existing one from [folders] or a new
/// path ("Clienti/Produzione"). Returns the normalized path, "" for the top
/// level, null when cancelled.
Future<String?> promptFolder(
  BuildContext context,
  String title, {
  required List<String> folders,
  String initial = '',
  String? message,
}) async {
  var text = initial;
  final ok = await showAlert<bool>(
    context,
    title: title,
    message: message ?? 'Scegli una cartella o scrivine una nuova (es. Clienti/Produzione). Vuoto: livello principale.',
    accessory: _FolderField(initial: initial, folders: folders, onChanged: (v) => text = v),
    buttons: const [
      AlertButton('Sposta', true, role: AlertRole.defaultAction),
      AlertButton('Annulla', false, role: AlertRole.cancel),
    ],
  );
  return ok == true ? normalizeFolder(text) : null;
}

/// The field of [promptFolder]; it owns its controller (see promptText).
class _FolderField extends StatefulWidget {
  const _FolderField({required this.initial, required this.folders, required this.onChanged});

  final String initial;
  final List<String> folders;
  final ValueChanged<String> onChanged;

  @override
  State<_FolderField> createState() => _FolderFieldState();
}

class _FolderFieldState extends State<_FolderField> {
  late final _ctrl = TextEditingController(text: widget.initial);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ComboField(
    controller: _ctrl,
    focusNode: _focus,
    hint: 'Livello principale',
    options: () => widget.folders,
    optionIcon: (_) => (AppIcons.folder, null),
    onChanged: widget.onChanged,
  );
}
