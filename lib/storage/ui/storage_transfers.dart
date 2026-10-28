// Upload / download queue of the Storage panel with progress and cancel.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../cloud/cloud_common.dart';
import '../../ui/widgets/common.dart';

enum TransferState { running, done, failed, cancelled }

class StorageTransfer extends ChangeNotifier {
  StorageTransfer(this.label, {required this.upload, this.total = -1});
  final String label;
  final bool upload;
  final cancel = CancelToken();
  int done = 0;
  int total;
  TransferState state = TransferState.running;
  Object? error;
  DateTime? _lastNotify;

  double? get fraction => total > 0 ? (done / total).clamp(0, 1).toDouble() : null;

  void progress(int d, int t) {
    done = d;
    if (t > 0) total = t;
    // Throttle UI updates.
    final now = DateTime.now();
    if (_lastNotify == null || now.difference(_lastNotify!).inMilliseconds > 120) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  void finish(TransferState s, [Object? e]) {
    state = s;
    error = e;
    notifyListeners();
  }
}

/// Transfers of the session (shared by the panel and the browser tabs).
class StorageTransfers extends ChangeNotifier {
  StorageTransfers._();
  static final instance = StorageTransfers._();

  final List<StorageTransfer> items = [];

  bool get hasRunning => items.any((t) => t.state == TransferState.running);

  /// Runs [body] as a tracked transfer. Returns true on success.
  Future<bool> run(
    String label, {
    required bool upload,
    int total = -1,
    required Future<void> Function(StorageTransfer t) body,
  }) async {
    final t = StorageTransfer(label, upload: upload, total: total)..addListener(notifyListeners);
    items.insert(0, t);
    notifyListeners();
    try {
      await body(t);
      t.done = t.total > 0 ? t.total : t.done;
      t.finish(TransferState.done);
      return true;
    } on CancelledException {
      t.finish(TransferState.cancelled);
      return false;
    } catch (e) {
      t.finish(t.cancel.isCancelled ? TransferState.cancelled : TransferState.failed, e);
      return false;
    } finally {
      // Keep the list short: drop the oldest finished transfers.
      for (var i = items.length - 1; i >= 0 && items.length > 30; i--) {
        if (items[i].state != TransferState.running) items.removeAt(i);
      }
    }
  }

  void clearFinished() {
    items.removeWhere((t) => t.state != TransferState.running);
    notifyListeners();
  }
}

/// Compact transfer list shown at the bottom of the Storage panel.
class StorageTransfersView extends StatelessWidget {
  const StorageTransfersView({super.key, this.maxVisible = 4});
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final mgr = StorageTransfers.instance;
    return ListenableBuilder(
      listenable: mgr,
      builder: (context, _) {
        if (mgr.items.isEmpty) return const SizedBox.shrink();
        final c = DbColors.of(context);
        final shown = mgr.items.take(maxVisible).toList();
        return Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.separator)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SectionLabel(
                mgr.hasRunning ? 'Trasferimenti in corso' : 'Trasferimenti',
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.xs, 0),
                trailing: ToolButton(
                  icon: AppIcons.clearAll,
                  tooltip: 'Rimuovi i trasferimenti completati',
                  onPressed: mgr.items.any((t) => t.state != TransferState.running) ? mgr.clearFinished : null,
                ),
              ),
              for (final t in shown) _TransferRow(t),
              if (mgr.items.length > shown.length)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xs),
                  child: Text(
                    'e altri ${mgr.items.length - shown.length}',
                    style: uiText(TypeSize.caption, color: c.textTertiary),
                  ),
                ),
              const SizedBox(height: Gap.xs),
            ],
          ),
        );
      },
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow(this.t);
  final StorageTransfer t;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final (IconData icon, Color color, String status) = switch (t.state) {
      TransferState.running => (
        t.upload ? AppIcons.upload : AppIcons.download,
        c.accent,
        t.total > 0 ? '${formatBytes(t.done)} di ${formatBytes(t.total)}' : formatBytes(t.done),
      ),
      TransferState.done => (AppIcons.checkCircle, c.success, 'Completato'),
      TransferState.failed => (AppIcons.error, c.danger, 'Non riuscito'),
      TransferState.cancelled => (AppIcons.block, c.textTertiary, 'Annullato'),
    };
    return Tooltip(
      message: t.error?.toString() ?? t.label,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 2, Gap.xs, 2),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.label,
                          overflow: TextOverflow.ellipsis,
                          style: uiText(TypeSize.small, color: c.text),
                        ),
                      ),
                      const SizedBox(width: Gap.xs),
                      Text(
                        status,
                        style: uiText(
                          TypeSize.caption,
                          color: t.state == TransferState.failed ? c.danger : c.textTertiary,
                          features: kTabular,
                        ),
                      ),
                    ],
                  ),
                  if (t.state == TransferState.running)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: LevelIndicator(value: t.fraction, semanticLabel: t.label),
                    ),
                ],
              ),
            ),
            if (t.state == TransferState.running)
              ToolButton(icon: AppIcons.close, tooltip: 'Annulla', onPressed: t.cancel.cancel)
            else if (t.state == TransferState.failed)
              ToolButton(
                icon: AppIcons.info,
                tooltip: 'Dettagli errore',
                onPressed: () => showErrorDialog(context, t.error ?? 'Errore', title: t.label),
              ),
          ],
        ),
      ),
    );
  }
}
