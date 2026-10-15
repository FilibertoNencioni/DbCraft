// Access tokens with expiry and a small in-memory cache shared by the Azure
// and Google credential providers.
import 'dart:async';

/// OAuth2 bearer token.
class AccessToken {
  const AccessToken(this.token, this.expiresAt);
  final String token;
  final DateTime expiresAt;

  /// Still usable for at least [margin] (default 2 minutes).
  bool isValid([Duration margin = const Duration(minutes: 2)]) => DateTime.now().add(margin).isBefore(expiresAt);

  /// Token valid for [seconds] from now (expires_in of OAuth2 responses).
  factory AccessToken.expiresIn(String token, Object? seconds) {
    final s = seconds is num ? seconds.toInt() : int.tryParse('$seconds') ?? 3600;
    return AccessToken(token, DateTime.now().add(Duration(seconds: s)));
  }
}

/// Caches tokens by key and coalesces concurrent requests for the same key.
class TokenCache {
  final Map<String, AccessToken> _tokens = {};
  final Map<String, Future<AccessToken>> _pending = {};

  Future<AccessToken> get(String key, Future<AccessToken> Function() load) {
    final hit = _tokens[key];
    if (hit != null && hit.isValid()) return Future.value(hit);
    final running = _pending[key];
    if (running != null) return running;
    final f = load()
        .then((t) {
          _tokens[key] = t;
          return t;
        })
        .whenComplete(() {
          // Block body: returning the removed future would make it wait on itself.
          _pending.remove(key);
        });
    _pending[key] = f;
    return f;
  }

  void invalidate([String? key]) => key == null ? _tokens.clear() : _tokens.remove(key);
}

/// Process-wide cache.
final tokenCache = TokenCache();
