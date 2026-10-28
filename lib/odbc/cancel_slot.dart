// Native slot shared between the UI isolate and an ODBC worker isolate: the
// worker publishes the handle of the running statement, the UI isolate calls
// SQLCancel on it.
//
// SQLCancel runs on the UI thread while the worker may be freeing the very
// same handle (the cancelled query returns immediately with an error and the
// statement is released): the Driver Manager then dereferences a freed
// handle and the process crashes. A native mutex makes "cancel" and
// "unpublish before free" mutually exclusive.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _LockN = Int32 Function(Pointer<Void>);
typedef _LockD = int Function(Pointer<Void>);
typedef _InitN = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _InitD = int Function(Pointer<Void>, Pointer<Void>);
typedef _SrwN = Void Function(Pointer<Void>);
typedef _SrwD = void Function(Pointer<Void>);

class _NativeMutex {
  _NativeMutex._(this.init, this.lock, this.unlock, this.destroy);

  factory _NativeMutex() {
    if (Platform.isWindows) {
      // SRWLOCK: pointer sized, statically initialised with zeroes.
      final k = DynamicLibrary.open('kernel32.dll');
      final acquire = k.lookupFunction<_SrwN, _SrwD>('AcquireSRWLockExclusive');
      final release = k.lookupFunction<_SrwN, _SrwD>('ReleaseSRWLockExclusive');
      return _NativeMutex._((_) {}, acquire, release, (_) {});
    }
    final p = DynamicLibrary.process();
    final init = p.lookupFunction<_InitN, _InitD>('pthread_mutex_init');
    final lock = p.lookupFunction<_LockN, _LockD>('pthread_mutex_lock');
    final unlock = p.lookupFunction<_LockN, _LockD>('pthread_mutex_unlock');
    final destroy = p.lookupFunction<_LockN, _LockD>('pthread_mutex_destroy');
    return _NativeMutex._((m) => init(m, nullptr), lock, unlock, destroy);
  }

  static final _NativeMutex instance = _NativeMutex();

  final void Function(Pointer<Void>) init;
  final void Function(Pointer<Void>) lock;
  final void Function(Pointer<Void>) unlock;
  final void Function(Pointer<Void>) destroy;
}

/// Bytes reserved for the mutex: larger than pthread_mutex_t on every
/// supported platform (64 bytes on macOS, 40 on Linux) and than SRWLOCK.
const int _mutexBytes = 128;

class CancelSlot {
  CancelSlot._(this._memory);

  /// Allocates a new slot; release it with [free].
  factory CancelSlot.allocate() {
    final memory = calloc<Uint8>(sizeOf<IntPtr>() + _mutexBytes);
    final slot = CancelSlot._(memory);
    _NativeMutex.instance.init(slot._mutex);
    return slot;
  }

  /// The same slot seen from another isolate (see [address]).
  factory CancelSlot.fromAddress(int address) => CancelSlot._(Pointer<Uint8>.fromAddress(address));

  final Pointer<Uint8> _memory;

  /// Sendable to another isolate.
  int get address => _memory.address;

  Pointer<IntPtr> get _value => _memory.cast<IntPtr>();
  Pointer<Void> get _mutex => (_memory + sizeOf<IntPtr>()).cast<Void>();

  T _locked<T>(T Function() body) {
    final m = _NativeMutex.instance;
    m.lock(_mutex);
    try {
      return body();
    } finally {
      m.unlock(_mutex);
    }
  }

  /// Worker side: [stmt] is the statement that may be cancelled.
  void publish(int stmt) => _locked(() => _value.value = stmt);

  /// Worker side: call before freeing [stmt]. Waits for a SQLCancel in
  /// progress on it to return.
  void unpublish(int stmt) => _locked(() {
    if (_value.value == stmt) _value.value = 0;
  });

  /// UI side: runs [cancel] on the published statement, if any, while the
  /// worker cannot free it.
  void cancelWith(void Function(int stmt) cancel) => _locked(() {
    final stmt = _value.value;
    if (stmt != 0) cancel(stmt);
  });

  void free() {
    _NativeMutex.instance.destroy(_mutex);
    calloc.free(_memory);
  }
}
