// Error type thrown by the built-in (native) drivers.

/// Error reported by a native driver: [message] is the server message (or a
/// clear Italian description of a client-side problem), [code] the server
/// error code / name when available.
class NativeDbException implements Exception {
  NativeDbException(this.message, {this.code, this.source});

  final String message;
  final String? code;

  /// Component that produced the error (e.g. 'MongoDB', 'Redis').
  final String? source;

  @override
  String toString() {
    final prefix = [?source, if (code != null && code!.isNotEmpty) code!].join(' ');
    return prefix.isEmpty ? message : '[$prefix] $message';
  }
}
