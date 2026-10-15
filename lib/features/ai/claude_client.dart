// Minimal Claude Messages API client over raw HTTP (Dart has no official
// Anthropic SDK): request building, SSE streaming, retries and errors.
//
// Pure Dart (no Flutter imports) so that it can be unit tested.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

const kAiDefaultBaseUrl = 'https://api.anthropic.com';
const kAiDefaultModel = 'claude-opus-5-5';
const kAiModels = ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-1'];
const kAiEfforts = ['low', 'medium', 'high', 'xhigh', 'max'];
const kAiApiVersion = '2023-06-01';
const kAiFallbackBeta = 'server-side-fallback-2026-07-01';

/// Connection parameters of the assistant.
class AiConfig {
  const AiConfig({
    required this.apiKey,
    this.model = kAiDefaultModel,
    this.baseUrl = kAiDefaultBaseUrl,
    this.effort = 'medium',
    this.fallbacks = true,
  });

  final String apiKey;
  final String model;
  final String baseUrl;
  final String effort;

  /// Refusal fallbacks requested by the user (applied only where supported).
  final bool fallbacks;

  String get _base {
    var b = baseUrl.trim();
    if (b.isEmpty) b = kAiDefaultBaseUrl;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  Uri get messagesUri => Uri.parse('$_base/v1/messages');
  Uri modelUri(String id) => Uri.parse('$_base/v1/models/${Uri.encodeComponent(id)}');

  /// Server-side fallbacks are a beta of the first-party API: a proxy or a
  /// gateway may reject the header, and not every model accepts them.
  bool get useFallbacks => fallbacks && isDefaultHost(baseUrl) && modelSupportsFallbacks(model);
}

bool isDefaultHost(String baseUrl) {
  final b = baseUrl.trim();
  if (b.isEmpty) return true;
  final u = Uri.tryParse(b);
  return u != null && u.host.toLowerCase() == 'api.anthropic.com';
}

/// Models that accept `fallbacks: "default"` (Haiku has no server-side
/// fallback; older models do not know the parameter).
bool modelSupportsFallbacks(String model) {
  final m = model.trim().toLowerCase();
  return m.startsWith('claude-opus-5') ||
      m.startsWith('claude-fable-5') ||
      m.startsWith('claude-mythos-5') ||
      m == 'claude-sonnet-5-5';
}

/// A system prompt block; [cache] marks the end of the cached prefix.
class AiSystemBlock {
  const AiSystemBlock(this.text, {this.cache = false});
  final String text;
  final bool cache;

  Map<String, Object?> toJson() => {
    'type': 'text',
    'text': text,
    if (cache) 'cache_control': {'type': 'ephemeral'},
  };
}

/// One request to the Messages API. [messages] use the API wire format
/// (`{"role": "user", "content": ...}`), so that assistant turns can be
/// replayed unchanged (append-only conversations).
class AiRequest {
  const AiRequest({
    required this.system,
    required this.messages,
    this.maxTokens,
    this.stream = true,
    this.autoCache = false,
  });

  final List<AiSystemBlock> system;
  final List<Map<String, Object?>> messages;
  final int? maxTokens;
  final bool stream;

  /// Adds a top-level `cache_control` so that the conversation prefix is
  /// cached too (multi-turn chat).
  final bool autoCache;

  /// Builds a single-turn request with a plain user message.
  factory AiRequest.single(List<AiSystemBlock> system, String user, {bool stream = true}) => AiRequest(
    system: system,
    messages: [
      {'role': 'user', 'content': user},
    ],
    stream: stream,
  );
}

/// Request body. Deliberately never sends `thinking` (adaptive by
/// default), `budget_tokens`, sampling parameters or an assistant prefill:
/// current models reject them.
Map<String, Object?> buildRequestBody(AiConfig config, AiRequest req) {
  final effort = config.effort.trim();
  return {
    'model': config.model.trim().isEmpty ? kAiDefaultModel : config.model.trim(),
    'max_tokens': req.maxTokens ?? (req.stream ? 64000 : 16000),
    if (req.system.isNotEmpty) 'system': [for (final b in req.system) b.toJson()],
    'messages': req.messages,
    if (kAiEfforts.contains(effort)) 'output_config': {'effort': effort},
    if (req.autoCache) 'cache_control': {'type': 'ephemeral'},
    if (config.useFallbacks) 'fallbacks': 'default',
    if (req.stream) 'stream': true,
  };
}

Map<String, String> buildRequestHeaders(AiConfig config) => {
  'x-api-key': config.apiKey,
  'anthropic-version': kAiApiVersion,
  'content-type': 'application/json',
  if (config.useFallbacks) 'anthropic-beta': kAiFallbackBeta,
};

// ---------------------------------------------------------------------------
// Server-sent events
// ---------------------------------------------------------------------------

class SseEvent {
  const SseEvent(this.event, this.data);
  final String event;
  final String data;

  @override
  String toString() => 'SseEvent($event, $data)';
}

/// Incremental SSE parser: feed decoded text chunks of any size; complete
/// events are returned as soon as their terminating blank line arrives.
class SseParser {
  final StringBuffer _line = StringBuffer();
  String _event = '';
  final List<String> _data = [];
  bool _pendingCr = false;

  List<SseEvent> add(String chunk) {
    final out = <SseEvent>[];
    for (var i = 0; i < chunk.length; i++) {
      final ch = chunk.codeUnitAt(i);
      if (_pendingCr) {
        _pendingCr = false;
        if (ch == 10) continue; // CRLF
      }
      if (ch == 13) {
        _pendingCr = true;
        _endLine(out);
      } else if (ch == 10) {
        _endLine(out);
      } else {
        _line.writeCharCode(ch);
      }
    }
    return out;
  }

  /// Flushes a last event not followed by a blank line.
  List<SseEvent> close() {
    final out = <SseEvent>[];
    if (_line.isNotEmpty) _endLine(out);
    _dispatch(out);
    return out;
  }

  void _endLine(List<SseEvent> out) {
    final line = _line.toString();
    _line.clear();
    if (line.isEmpty) {
      _dispatch(out);
      return;
    }
    if (line.startsWith(':')) return; // comment
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        _data.add(value);
    }
  }

  void _dispatch(List<SseEvent> out) {
    if (_data.isEmpty && _event.isEmpty) return;
    out.add(SseEvent(_event.isEmpty ? 'message' : _event, _data.join('\n')));
    _event = '';
    _data.clear();
  }
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

class AiException implements Exception {
  AiException(this.message, {this.statusCode, this.type, this.retryAfter});
  final String message;
  final int? statusCode;

  /// API error type (`overloaded_error`, `rate_limit_error`, …).
  final String? type;
  final Duration? retryAfter;

  bool get retryable =>
      statusCode == 429 ||
      statusCode == 408 ||
      statusCode == 409 ||
      (statusCode != null && statusCode! >= 500) ||
      type == 'overloaded_error' ||
      type == 'api_error' ||
      type == 'network';

  @override
  String toString() => message;
}

class AiCancelled implements Exception {
  @override
  String toString() => 'Richiesta annullata';
}

/// Accumulates a (streamed or complete) response.
class AiResponse {
  /// Content blocks as returned by the API (for append-only replay).
  final List<Map<String, Object?>> blocks = [];
  final StringBuffer _text = StringBuffer();
  String? id;
  String? model;
  String? stopReason;
  String? refusalCategory;
  String? refusalExplanation;
  int inputTokens = 0;
  int outputTokens = 0;
  int cacheReadTokens = 0;
  int cacheWriteTokens = 0;

  /// A refusal fallback switched model during this response.
  bool fallbackUsed = false;

  /// Visible text (text blocks only; thinking is never shown).
  String get text => _text.toString();

  bool get refused => stopReason == 'refusal';
  bool get truncated => stopReason == 'max_tokens';
  bool get complete => stopReason != null;

  /// Italian notice describing an abnormal stop, or null.
  String? get notice {
    if (refused) {
      final cat = refusalCategory == null ? '' : ' (categoria: $refusalCategory)';
      final why = refusalExplanation == null || refusalExplanation!.isEmpty ? '' : ' $refusalExplanation';
      return 'Il modello ha rifiutato la richiesta$cat.$why Riformula la domanda o prova un altro modello.';
    }
    if (truncated) return 'Risposta troncata: è stato raggiunto il limite di token in uscita.';
    if (stopReason == 'pause_turn') return 'Risposta interrotta dal servizio: riprova.';
    return null;
  }

  /// Applies one decoded SSE event. Returns true when the visible text
  /// changed. Throws [AiException] on an `error` event.
  bool apply(SseEvent e) {
    if (e.event == 'ping' || e.data.isEmpty) return false;
    Map<String, Object?> j;
    try {
      j = (jsonDecode(e.data) as Map).cast<String, Object?>();
    } catch (_) {
      return false;
    }
    final type = j['type'] as String? ?? e.event;
    switch (type) {
      case 'message_start':
        final m = (j['message'] as Map?)?.cast<String, Object?>() ?? const {};
        id = m['id'] as String?;
        final newModel = m['model'] as String?;
        if (model != null && newModel != null && newModel != model) fallbackUsed = true;
        model = newModel ?? model;
        _usage((m['usage'] as Map?)?.cast());
      case 'content_block_start':
        final b = (j['content_block'] as Map?)?.cast<String, Object?>() ?? {};
        final block = Map<String, Object?>.of(b);
        if (block['type'] == 'fallback') {
          fallbackUsed = true;
          final to = (block['to'] as Map?)?['model'];
          if (to is String) model = to;
        }
        _setBlock(j['index'], block);
        final t = block['text'];
        if (block['type'] == 'text' && t is String && t.isNotEmpty) {
          _text.write(t);
          return true;
        }
      case 'content_block_delta':
        final d = (j['delta'] as Map?)?.cast<String, Object?>() ?? const {};
        final block = _block(j['index']);
        switch (d['type']) {
          case 'text_delta':
            final t = d['text'] as String? ?? '';
            if (block != null) block['text'] = '${block['text'] ?? ''}$t';
            _text.write(t);
            return t.isNotEmpty;
          case 'thinking_delta':
            if (block != null) block['thinking'] = '${block['thinking'] ?? ''}${d['thinking'] ?? ''}';
          case 'signature_delta':
            if (block != null) block['signature'] = d['signature'];
          case 'input_json_delta':
            if (block != null) block['_json'] = '${block['_json'] ?? ''}${d['partial_json'] ?? ''}';
        }
      case 'content_block_stop':
        final block = _block(j['index']);
        final raw = block?.remove('_json');
        if (block != null && raw is String && raw.isNotEmpty) {
          try {
            block['input'] = jsonDecode(raw);
          } catch (_) {}
        }
      case 'message_delta':
        final d = (j['delta'] as Map?)?.cast<String, Object?>() ?? const {};
        stopReason = d['stop_reason'] as String? ?? stopReason;
        _stopDetails((d['stop_details'] as Map?)?.cast());
        _usage((j['usage'] as Map?)?.cast());
      case 'message_stop':
        break;
      case 'error':
        final err = (j['error'] as Map?)?.cast<String, Object?>() ?? const {};
        final et = err['type'] as String? ?? 'api_error';
        throw AiException(aiErrorMessage(null, et, err['message'] as String?), type: et);
    }
    return false;
  }

  /// Fills the response from a non-streaming JSON body.
  void applyMessage(Map<String, Object?> m) {
    id = m['id'] as String?;
    model = m['model'] as String?;
    stopReason = m['stop_reason'] as String?;
    _stopDetails((m['stop_details'] as Map?)?.cast());
    _usage((m['usage'] as Map?)?.cast());
    for (final b in (m['content'] as List? ?? const [])) {
      if (b is! Map) continue;
      final block = b.cast<String, Object?>();
      blocks.add(Map.of(block));
      if (block['type'] == 'text') _text.write(block['text'] as String? ?? '');
      if (block['type'] == 'fallback') fallbackUsed = true;
    }
  }

  void _stopDetails(Map<String, Object?>? d) {
    if (d == null) return;
    refusalCategory = d['category'] as String? ?? refusalCategory;
    refusalExplanation = d['explanation'] as String? ?? refusalExplanation;
  }

  void _usage(Map<String, Object?>? u) {
    if (u == null) return;
    int v(String k) => (u[k] as num?)?.toInt() ?? 0;
    if (u.containsKey('input_tokens')) inputTokens = v('input_tokens');
    if (u.containsKey('output_tokens')) outputTokens = v('output_tokens');
    if (u.containsKey('cache_read_input_tokens')) cacheReadTokens = v('cache_read_input_tokens');
    if (u.containsKey('cache_creation_input_tokens')) cacheWriteTokens = v('cache_creation_input_tokens');
    final it = u['iterations'];
    if (it is List && it.any((e) => e is Map && e['type'] == 'fallback_message')) fallbackUsed = true;
  }

  final Map<int, int> _index = {};

  void _setBlock(Object? index, Map<String, Object?> block) {
    final i = (index as num?)?.toInt() ?? blocks.length;
    _index[i] = blocks.length;
    blocks.add(block);
  }

  Map<String, Object?>? _block(Object? index) {
    final i = _index[(index as num?)?.toInt() ?? -1];
    return i == null ? null : blocks[i];
  }

  /// Assistant content to append to the conversation for the next turn.
  /// Text and thinking blocks are kept unchanged (append-only history);
  /// after a mid-output fallback the model-internal blocks preceding the
  /// switch are dropped, as the API requires.
  List<Map<String, Object?>> replayContent() {
    final lastFallback = blocks.lastIndexWhere((b) => b['type'] == 'fallback');
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final t = b['type'];
      if (t == 'fallback') continue;
      if (i < lastFallback && t != 'text') continue;
      if (t == 'text' && (b['text'] as String? ?? '').isEmpty) continue;
      if (t == 'tool_use' || t == 'server_tool_use') continue; // no tools are declared
      out.add({
        for (final e in b.entries)
          if (e.key != 'citations' || e.value != null) e.key: e.value,
      });
    }
    if (out.isEmpty) out.add({'type': 'text', 'text': text.isEmpty ? '(nessuna risposta)' : text});
    // The API rejects a final text block ending with whitespace in replays.
    final last = out.last;
    if (last['type'] == 'text') last['text'] = (last['text'] as String).trimRight();
    return out;
  }
}

/// Italian message for an HTTP status / API error type.
String aiErrorMessage(int? status, String? type, String? apiMessage) {
  final detail = apiMessage == null || apiMessage.isEmpty ? '' : '\n\n$apiMessage';
  if (type == 'overloaded_error' || status == 529) {
    return 'Il servizio Anthropic è momentaneamente sovraccarico. Riprova tra qualche istante.';
  }
  switch (status) {
    case 400:
      return 'Richiesta non valida.$detail';
    case 401:
      return 'Chiave API non valida o revocata. Controlla la chiave nelle impostazioni dell\'assistente AI.';
    case 403:
      return 'La chiave API non ha i permessi per questa richiesta.$detail';
    case 404:
      return 'Modello o endpoint non trovato: verifica il nome del modello e l\'URL di base.$detail';
    case 413:
      return 'Richiesta troppo grande: riduci il testo o disattiva l\'invio della struttura del database.';
    case 429:
      return 'Limite di richieste raggiunto. Attendi qualche istante e riprova.';
  }
  if (status != null && status >= 500) return 'Errore del servizio Anthropic (HTTP $status). Riprova più tardi.$detail';
  if (type == 'rate_limit_error') return 'Limite di richieste raggiunto. Attendi qualche istante e riprova.';
  return apiMessage == null || apiMessage.isEmpty
      ? 'Errore del servizio AI${status == null ? '' : ' (HTTP $status)'}.'
      : apiMessage;
}

AiException _httpError(int status, String body, Map<String, String> headers) {
  String? type, msg;
  try {
    final j = (jsonDecode(body) as Map).cast<String, Object?>();
    final err = (j['error'] as Map?)?.cast<String, Object?>();
    type = err?['type'] as String?;
    msg = err?['message'] as String?;
  } catch (_) {
    if (body.trim().isNotEmpty && body.length < 400) msg = body.trim();
  }
  Duration? retry;
  final ra = headers['retry-after'];
  if (ra != null) {
    final s = double.tryParse(ra.trim());
    if (s != null) retry = Duration(milliseconds: (s * 1000).round());
  }
  return AiException(aiErrorMessage(status, type, msg), statusCode: status, type: type, retryAfter: retry);
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// One-shot client: create one per request, call [cancel] to abort.
class ClaudeClient {
  ClaudeClient(this.config, {http.Client Function()? clientFactory, this.maxRetries = 2})
    : _factory = clientFactory ?? http.Client.new;

  final AiConfig config;
  final http.Client Function() _factory;
  final int maxRetries;
  http.Client? _client;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _client?.close();
    _client = null;
  }

  /// Sends [req]; [onText] receives the full visible text after every
  /// change (an empty string when a retry restarts the answer).
  Future<AiResponse> send(AiRequest req, {void Function(String text)? onText}) async {
    var attempt = 0;
    while (true) {
      if (_cancelled) throw AiCancelled();
      try {
        return await _sendOnce(req, onText);
      } on AiException catch (e) {
        if (_cancelled) throw AiCancelled();
        if (!e.retryable || attempt >= maxRetries) rethrow;
        attempt++;
        final wait = e.retryAfter ?? Duration(milliseconds: 1000 * pow(2, attempt - 1).toInt());
        onText?.call('');
        await Future<void>.delayed(wait > const Duration(seconds: 30) ? const Duration(seconds: 30) : wait);
      }
    }
  }

  Future<AiResponse> _sendOnce(AiRequest req, void Function(String text)? onText) async {
    final client = _client = _factory();
    try {
      final rq = http.Request('POST', config.messagesUri)
        ..headers.addAll(buildRequestHeaders(config))
        ..body = jsonEncode(buildRequestBody(config, req));
      final resp = await client.send(rq).timeout(const Duration(seconds: 90));
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString().timeout(const Duration(seconds: 30));
        throw _httpError(resp.statusCode, body, resp.headers);
      }
      final out = AiResponse();
      if (!req.stream) {
        final body = await resp.stream.bytesToString().timeout(const Duration(minutes: 10));
        out.applyMessage((jsonDecode(body) as Map).cast());
        onText?.call(out.text);
        return out;
      }
      final parser = SseParser();
      // Pings arrive regularly: a long silence means a dead connection.
      final lines = resp.stream.cast<List<int>>().transform(utf8.decoder).timeout(const Duration(minutes: 3));
      await for (final chunk in lines) {
        for (final e in parser.add(chunk)) {
          if (out.apply(e)) onText?.call(out.text);
        }
      }
      for (final e in parser.close()) {
        if (out.apply(e)) onText?.call(out.text);
      }
      if (out.stopReason == null) {
        throw AiException('La risposta si è interrotta prima della fine. Riprova.', type: 'network');
      }
      return out;
    } on AiException {
      rethrow;
    } on TimeoutException {
      if (_cancelled) throw AiCancelled();
      throw AiException('Il servizio AI non risponde (timeout). Riprova.', type: 'network');
    } on SocketException catch (e) {
      if (_cancelled) throw AiCancelled();
      throw AiException(_networkMessage(e.message), type: 'network');
    } on http.ClientException catch (e) {
      if (_cancelled) throw AiCancelled();
      throw AiException(_networkMessage(e.message), type: 'network');
    } on HandshakeException catch (e) {
      throw AiException('Connessione sicura non riuscita con ${config.messagesUri.host}: ${e.message}');
    } on FormatException {
      throw AiException('Risposta non valida dal servizio AI.');
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  String _networkMessage(String detail) =>
      'Impossibile contattare ${config.messagesUri.host}: controlla la connessione di rete o il proxy.'
      '${detail.isEmpty ? '' : '\n\n$detail'}';

  /// Validates key and model with `GET /v1/models/{id}` (no tokens spent).
  Future<String> verify() async {
    final client = _client = _factory();
    try {
      final h = buildRequestHeaders(config)..remove('content-type');
      final resp = await client.get(config.modelUri(config.model), headers: h).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) throw _httpError(resp.statusCode, resp.body, resp.headers);
      try {
        final j = (jsonDecode(resp.body) as Map).cast<String, Object?>();
        return j['display_name'] as String? ?? config.model;
      } catch (_) {
        return config.model;
      }
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw AiException('Il servizio AI non risponde (timeout).', type: 'network');
    } on SocketException catch (e) {
      throw AiException(_networkMessage(e.message), type: 'network');
    } on http.ClientException catch (e) {
      if (_cancelled) throw AiCancelled();
      throw AiException(_networkMessage(e.message), type: 'network');
    } finally {
      client.close();
      _client = null;
    }
  }
}
