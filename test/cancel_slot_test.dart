import 'dart:isolate';

import 'package:dbcraft/odbc/cancel_slot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancel runs only on the published statement', () {
    final slot = CancelSlot.allocate();
    addTearDown(slot.free);
    final seen = <int>[];
    slot.cancelWith(seen.add);
    slot.publish(42);
    slot.cancelWith(seen.add);
    slot.unpublish(7); // another statement: the published one stays
    slot.cancelWith(seen.add);
    slot.unpublish(42);
    slot.cancelWith(seen.add);
    expect(seen, [42, 42]);
  });

  test('unpublish from another isolate waits for a cancel in progress', () async {
    final slot = CancelSlot.allocate();
    addTearDown(slot.free);
    slot.publish(42);
    final address = slot.address;
    late Future<int> worker;
    final sw = Stopwatch()..start();
    slot.cancelWith((_) {
      // The worker tries to free the statement while SQLCancel is running.
      worker = Isolate.run(() {
        final w = Stopwatch()..start();
        CancelSlot.fromAddress(address).unpublish(42);
        return w.elapsedMilliseconds;
      });
      final end = DateTime.now().add(const Duration(milliseconds: 300));
      while (DateTime.now().isBefore(end)) {}
    });
    final waited = await worker;
    expect(waited, greaterThan(100), reason: 'elapsed ${sw.elapsedMilliseconds} ms');
    final seen = <int>[];
    slot.cancelWith(seen.add);
    expect(seen, isEmpty);
  });
}
