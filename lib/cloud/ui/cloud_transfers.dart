// Upload / download queue of the Cloud Explorer with progress and cancel.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/widgets/common.dart';
import '../cloud_common.dart';

enum TransferState { running, done, failed, cancelled }

class CloudTransfer extends ChangeNotifier {
  CloudTransfer(this.label, {required this.upload, this.total = -1});
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
class CloudTransfers extends ChangeNotifier {
  CloudTransfers._();
  static final instance = CloudTransfers._();

  final List<CloudTransfer> items = [];

  bool get hasRunning => items.any((t) => t.state == TransferState.running);

  /// Runs [body] as a tracked transfer. Returns true on success.
  Future<bool> run(
    String label, {
    required bool upload,
    int total = -1,
    required Future<void> Function(CloudTransfer t) body,
  }) async {
    final t = CloudTransfer(label, upload: upload, total: total)..addListener(notifyListeners);
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

/// Compact transfer list shown at the bottom of the Cloud panel.
class CloudTransfersView extends StatelessWidget {
  const CloudTransfersView({super.key, this.maxVisible = 4});
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final mgr = CloudTransfers.instance;
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
                  icon: Icons.clear_all_rounded,
                  tooltip: 'Rimuovi i trasferimenti completati',
                  size: 15,
                  onPressed: mgr.items.any((t) => t.state != TransferState.running) ? mgr.clearFinished : null,
                ),
              ),
              for (final t in shown) _TransferRow(t),
              if (mgr.items.length > shown.length)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xs),
                  child: Text(
                    'e altri ${mgr.items.length - shown.length}',
                    style: TextStyle(fontSize: TypeSize.caption, color: c.textTertiary),
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
  final CloudTransfer t;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final (IconData icon, Color color, String status) = switch (t.state) {
      TransferState.running => (
        t.upload ? Icons.upload_rounded : Icons.download_rounded,
        c.accent,
        t.total > 0 ? '${formatBytes(t.done)} di ${formatBytes(t.total)}' : formatBytes(t.done),
      ),
      TransferState.done => (Icons.check_circle_outline_rounded, c.success, 'Completato'),
      TransferState.failed => (Icons.error_outline_rounded, c.danger, 'Non riuscito'),
      TransferState.cancelled => (Icons.block_rounded, c.textTertiary, 'Annullato'),
    };
    return Tooltip(
      message: t.error?.toString() ?? t.label,
      waitDuration: const Duration(milliseconds: 600),
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
                          style: TextStyle(fontSize: TypeSize.small, color: c.text),
                        ),
                      ),
                      const SizedBox(width: Gap.xs),
                      Text(
                        status,
                        style: TextStyle(
                          fontSize: TypeSize.caption,
                          color: t.state == TransferState.failed ? c.danger : c.textTertiary,
                          fontFeatures: kTabular,
                        ),
                      ),
                    ],
                  ),
                  if (t.state == TransferState.running)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: t.fraction,
                          minHeight: 3,
                          color: c.accent,
                          backgroundColor: c.pressed,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (t.state == TransferState.running)
              ToolButton(icon: Icons.close_rounded, tooltip: 'Annulla', size: 14, onPressed: t.cancel.cancel)
            else if (t.state == TransferState.failed)
              ToolButton(
                icon: Icons.info_outline_rounded,
                tooltip: 'Dettagli errore',
                size: 14,
                onPressed: () => showErrorDialog(context, t.error ?? 'Errore', title: t.label),
              ),
          ],
        ),
      ),
    );
  }
}
