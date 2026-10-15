// Glue between the app state and the Claude client: configuration (API key
// from the vault, preferences), availability and a streaming run model.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../state/app_state.dart';
import 'claude_client.dart';

/// Vault key of the Anthropic API key.
const kAiVaultKey = 'ai.apiKey';

/// Personal assistant preferences that do not belong to AppSettings. Kept
/// in `<workspace>/.dbcraft/ai.local.json` (`*.local.json` is never
/// committed by the project sync).
class AiPrefs {
  AiPrefs({this.fallbacks = true, this.sampleRows = 20});

  /// Refusal fallbacks (`fallbacks: "default"`) on the first-party API.
  bool fallbacks;

  /// Rows sent when the user opts in to share a result sample.
  int sampleRows;

  static final Map<String, AiPrefs> _cache = {};

  static File _file(AppState app) => File(p.join(app.workspace.root.path, '.dbcraft', 'ai.local.json'));

  static AiPrefs of(AppState app) {
    final f = _file(app);
    return _cache.putIfAbsent(f.path, () {
      try {
        if (f.existsSync()) {
          final j = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
          return AiPrefs(
            fallbacks: j['fallbacks'] as bool? ?? true,
            sampleRows: ((j['sampleRows'] as num?)?.toInt() ?? 20).clamp(1, 200),
          );
        }
      } catch (_) {}
      return AiPrefs();
    });
  }

  Future<void> save(AppState app) async {
    final f = _file(app);
    await f.parent.create(recursive: true);
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert({'fallbacks': fallbacks, 'sampleRows': sampleRows}),
    );
  }
}

/// API key: the vault first, then the ANTHROPIC_API_KEY environment variable.
String? aiApiKey(AppState app) {
  try {
    if (!app.vault.isLocked) {
      final k = app.vault.get(kAiVaultKey);
      if (k != null && k.trim().isNotEmpty) return k.trim();
    }
  } catch (_) {}
  final env = Platform.environment['ANTHROPIC_API_KEY'];
  return env == null || env.trim().isEmpty ? null : env.trim();
}

/// True when the key comes from the environment (not from the vault).
bool aiKeyFromEnvironment(AppState app) {
  try {
    if (!app.vault.isLocked && (app.vault.get(kAiVaultKey) ?? '').isNotEmpty) return false;
  } catch (_) {}
  return (Platform.environment['ANTHROPIC_API_KEY'] ?? '').trim().isNotEmpty;
}

/// The assistant is enabled and has an API key.
bool aiAvailable(AppState app) => app.settings.aiEnabled && aiApiKey(app) != null;

AiConfig aiConfig(AppState app, {String? apiKey}) {
  final key = apiKey ?? aiApiKey(app);
  if (key == null) {
    throw AiException('Chiave API di Anthropic non configurata. Inseriscila nelle impostazioni dell\'assistente AI.');
  }
  final s = app.settings;
  return AiConfig(
    apiKey: key,
    model: s.aiModel.trim().isEmpty ? kAiDefaultModel : s.aiModel.trim(),
    baseUrl: s.aiBaseUrl.trim().isEmpty ? kAiDefaultBaseUrl : s.aiBaseUrl.trim(),
    effort: s.aiEffort,
    fallbacks: AiPrefs.of(app).fallbacks,
  );
}

enum AiRunState { idle, preparing, waiting, streaming, done, error, cancelled }

/// One streamed request observed by the UI. Text updates are throttled so
/// that long answers do not rebuild the view on every token.
class AiRun extends ChangeNotifier {
  AiRun(this.app);

  final AppState app;
  AiRunState state = AiRunState.idle;
  String text = '';
  AiResponse? response;
  String? error;
  ClaudeClient? _client;
  Timer? _throttle;
  bool _disposed = false;
  int _generation = 0;

  bool get busy => state == AiRunState.preparing || state == AiRunState.waiting || state == AiRunState.streaming;

  String get statusText => switch (state) {
    AiRunState.preparing => 'Lettura della struttura del database…',
    AiRunState.waiting => 'Claude sta ragionando…',
    AiRunState.streaming => 'Scrittura della risposta…',
    AiRunState.cancelled => 'Richiesta annullata',
    _ => '',
  };

  /// Runs the request built by [build] (which may read metadata).
  Future<AiResponse?> start(Future<AiRequest> Function() build) async {
    cancel(notify: false);
    final gen = ++_generation;
    text = '';
    response = null;
    error = null;
    state = AiRunState.preparing;
    _notify();
    try {
      final config = aiConfig(app);
      final req = await build();
      if (gen != _generation) return null;
      final client = _client = ClaudeClient(config);
      state = AiRunState.waiting;
      _notify();
      final r = await client.send(
        req,
        onText: (t) {
          if (gen != _generation) return;
          text = t;
          if (state != AiRunState.streaming && t.isNotEmpty) {
            state = AiRunState.streaming;
            _notify();
          } else {
            _throttle ??= Timer(const Duration(milliseconds: 60), () {
              _throttle = null;
              _notify();
            });
          }
        },
      );
      if (gen != _generation) return null;
      response = r;
      text = r.text;
      state = AiRunState.done;
      _notify();
      return r;
    } on AiCancelled {
      if (gen == _generation) {
        state = AiRunState.cancelled;
        _notify();
      }
      return null;
    } catch (e) {
      if (gen != _generation) return null;
      error = e is AiException ? e.message : e.toString();
      state = AiRunState.error;
      _notify();
      return null;
    } finally {
      if (gen == _generation) _client = null;
    }
  }

  void cancel({bool notify = true}) {
    final c = _client;
    _client = null;
    if (c != null) {
      _generation++;
      c.cancel();
      state = AiRunState.cancelled;
      if (notify) _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _throttle?.cancel();
    _client?.cancel();
    super.dispose();
  }
}
