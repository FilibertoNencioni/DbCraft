// Shared plumbing of the cloud module: errors, cancellation, hashing,
// RFC 3986 encoding, CLI discovery and the HTTP client used by the storage
// clients, the credential providers and the BigQuery driver.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// Error returned by a cloud API or a credential provider.
class CloudException implements Exception {
  CloudException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;

  /// Provider error code (S3 `NoSuchKey`, Azure `AuthenticationFailed`, …).
  final String? code;

  @override
  String toString() => message;
}

/// Thrown when an operation is cancelled through a [CancelToken].
class CancelledException implements Exception {
  @override
  String toString() => 'Operazione annullata';
}

/// Cooperative cancellation of transfers and long requests.
class CancelToken {
  final _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  /// Completes when [cancel] is called (used as the http abort trigger).
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw CancelledException();
  }
}

/// Transfer progress: bytes done and total (-1 when unknown).
typedef ProgressCallback = void Function(int done, int total);

/// HTTP client shared by the cloud module (keeps connections alive).
final http.Client cloudHttp = http.Client();

// ---------------------------------------------------------------------------
// Hashing / encoding
// ---------------------------------------------------------------------------

String hexOf(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

String sha256Hex(List<int> data) => sha256.convert(data).toString();

List<int> hmacSha256(List<int> key, List<int> data) => Hmac(sha256, key).convert(data).bytes;

/// SHA-256 of the empty payload.
const emptySha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// RFC 3986 percent encoding as required by AWS SigV4 / GCS V4 signing: only
/// `A-Z a-z 0-9 - _ . ~` stay as they are; `/` is kept when [keepSlash].
String uriEncode(String s, {bool keepSlash = false}) {
  final sb = StringBuffer();
  for (final b in utf8.encode(s)) {
    final ok =
        (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        (b >= 0x30 && b <= 0x39) ||
        b == 0x2D ||
        b == 0x5F ||
        b == 0x2E ||
        b == 0x7E ||
        (keepSlash && b == 0x2F);
    if (ok) {
      sb.writeCharCode(b);
    } else {
      sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return sb.toString();
}

/// Query string with keys and values encoded by [uriEncode], sorted by key
/// (the canonical form used by the signers, also valid on the wire).
String canonicalQuery(Map<String, String> query) {
  final keys = query.keys.toList()..sort();
  return keys.map((k) => '${uriEncode(k)}=${uriEncode(query[k]!)}').join('&');
}

/// Builds a URI keeping exactly the given encoding of path and query (the
/// signature is computed on the same bytes that go on the wire).
Uri buildUri(String base, String encodedPath, [Map<String, String> query = const {}]) {
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final path = encodedPath.startsWith('/') ? encodedPath : '/$encodedPath';
  final q = canonicalQuery(query);
  return Uri.parse(q.isEmpty ? '$b$path' : '$b$path?$q');
}

/// ISO-8601 basic format used by AWS / GCS signatures (20130524T000000Z).
String amzDate(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
}

/// RFC 1123 date (`x-ms-date`, `Date`).
String httpDate(DateTime t) => HttpDate.format(t.toUtc());

/// ISO-8601 without milliseconds (Azure SAS `se`/`st`).
String isoSeconds(DateTime t) {
  final s = t.toUtc().toIso8601String();
  final dot = s.indexOf('.');
  return dot < 0 ? s : '${s.substring(0, dot)}Z';
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Extracts a readable message from an error response (S3/Azure XML or
/// Google/Microsoft JSON).
CloudException responseError(http.BaseResponse r, String body, {String? operation}) {
  String? code;
  String? message;
  final t = body.trim();
  if (t.startsWith('<')) {
    try {
      final doc = XmlDocument.parse(t);
      code = doc.findAllElements('Code').firstOrNull?.innerText;
      message = doc.findAllElements('Message').firstOrNull?.innerText;
      final region = doc.findAllElements('Region').firstOrNull?.innerText;
      if (region != null && message != null) message = '$message (regione $region)';
    } catch (_) {}
  } else if (t.startsWith('{')) {
    try {
      final j = jsonDecode(t);
      if (j is Map) {
        final e = j['error'];
        if (e is Map) {
          message = e['message']?.toString();
          code = (e['status'] ?? e['code'])?.toString();
        } else if (e is String) {
          code = e;
          message = j['error_description']?.toString() ?? e;
        } else {
          message = j['message']?.toString();
        }
      }
    } catch (_) {}
  }
  code ??= r.headers['x-ms-error-code'] ?? r.headers['x-amz-error-code'];
  final status = '${r.statusCode}${r.reasonPhrase == null ? '' : ' ${r.reasonPhrase}'}';
  final head = operation == null ? 'HTTP $status' : '$operation: HTTP $status';
  final detail = [code, message ?? (t.isEmpty || t.length > 600 ? null : t)].whereType<String>().join(' – ');
  return CloudException(detail.isEmpty ? head : '$head\n$detail', statusCode: r.statusCode, code: code);
}

/// Sends [request] honouring [cancel]; returns the streamed response.
Future<http.StreamedResponse> sendRequest(http.BaseRequest request, {CancelToken? cancel, Duration? timeout}) async {
  cancel?.throwIfCancelled();
  try {
    final f = cloudHttp.send(request);
    return timeout == null ? await f : await f.timeout(timeout);
  } on http.RequestAbortedException {
    throw CancelledException();
  } on TimeoutException {
    throw CloudException('Timeout della richiesta a ${request.url.host}');
  } on SocketException catch (e) {
    throw CloudException('Impossibile contattare ${request.url.host}: ${e.message}');
  } on http.ClientException catch (e) {
    if (cancel?.isCancelled ?? false) throw CancelledException();
    throw CloudException('Errore di rete verso ${request.url.host}: ${e.message}');
  }
}

/// Simple request with an in-memory body; throws [CloudException] on non 2xx
/// unless [accept] says otherwise.
Future<http.Response> cloudRequest(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  List<int>? body,
  CancelToken? cancel,
  Duration? timeout,
  bool Function(int status)? accept,
  String? operation,
}) async {
  final req = http.AbortableRequest(method, url, abortTrigger: cancel?.whenCancelled);
  req.headers.addAll(headers);
  if (body != null) req.bodyBytes = body;
  final streamed = await sendRequest(req, cancel: cancel, timeout: timeout);
  final r = await http.Response.fromStream(streamed);
  final ok = accept?.call(r.statusCode) ?? (r.statusCode >= 200 && r.statusCode < 300);
  if (!ok) throw responseError(r, r.body, operation: operation);
  return r;
}

// ---------------------------------------------------------------------------
// External command line tools (aws, az, gcloud)
// ---------------------------------------------------------------------------

/// Desktop apps started from the Finder/Explorer get a minimal PATH: the
/// usual install folders of the cloud CLIs are searched as well.
List<String> _searchDirs() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  return [
    ...(env['PATH'] ?? '').split(sep).where((e) => e.isNotEmpty),
    if (!Platform.isWindows) ...[
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/snap/bin',
      '$home/google-cloud-sdk/bin',
      '/opt/homebrew/share/google-cloud-sdk/bin',
      '/usr/local/share/google-cloud-sdk/bin',
      '/usr/lib/google-cloud-sdk/bin',
      '$home/.local/bin',
    ],
    if (Platform.isWindows) ...[
      r'C:\Program Files\Amazon\AWSCLIV2',
      r'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin',
      r'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin',
      '${env['LOCALAPPDATA'] ?? ''}\\Google\\Cloud SDK\\google-cloud-sdk\\bin',
      r'C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin',
    ],
  ];
}

final Map<String, String?> _exeCache = {};

/// Full path of a command line tool, or null when it is not installed.
Future<String?> findExecutable(String name) async {
  if (_exeCache.containsKey(name)) return _exeCache[name];
  final names = Platform.isWindows ? ['$name.cmd', '$name.exe', '$name.bat'] : [name];
  for (final d in _searchDirs()) {
    for (final n in names) {
      final f = File('$d${Platform.pathSeparator}$n');
      if (await f.exists()) return _exeCache[name] = f.path;
    }
  }
  return _exeCache[name] = null;
}

/// Runs a CLI tool and returns its stdout; throws a readable error when the
/// tool fails (stderr is shown to the user, e.g. "Please run 'az login'").
Future<String> runCli(String name, List<String> args, {Duration timeout = const Duration(seconds: 60)}) async {
  final exe = await findExecutable(name);
  if (exe == null) throw CloudException('Il comando "$name" non è installato o non è nel PATH.');
  final env = Map<String, String>.from(Platform.environment);
  // The CLIs are often scripts that need their own folder in the PATH.
  final dir = File(exe).parent.path;
  final sep = Platform.isWindows ? ';' : ':';
  env['PATH'] = [dir, env['PATH'] ?? '', '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin'].join(sep);
  try {
    final r = await Process.run(exe, args, environment: env, runInShell: Platform.isWindows).timeout(timeout);
    if (r.exitCode != 0) {
      final err = (r.stderr as String).trim();
      throw CloudException(
        '$name ${args.take(3).join(' ')} non riuscito (codice ${r.exitCode})'
        '${err.isEmpty ? '' : ':\n$err'}',
      );
    }
    return (r.stdout as String).trim();
  } on TimeoutException {
    throw CloudException('$name non ha risposto entro ${timeout.inSeconds} secondi');
  } on ProcessException catch (e) {
    throw CloudException('Impossibile eseguire $name: ${e.message}');
  }
}

/// Runs a shell command line (AWS `credential_process`).
Future<String> runShell(String command, {Duration timeout = const Duration(seconds: 60)}) async {
  final r =
      await (Platform.isWindows
              ? Process.run('cmd', ['/c', command])
              : Process.run(
                  '/bin/sh',
                  ['-c', command],
                  environment: {
                    'PATH': '${Platform.environment['PATH'] ?? ''}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin',
                  },
                ))
          .timeout(timeout);
  if (r.exitCode != 0) {
    throw CloudException('Comando "$command" non riuscito (codice ${r.exitCode}): ${(r.stderr as String).trim()}');
  }
  return (r.stdout as String).trim();
}

/// User home folder.
String homeDir() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';

/// Human readable size (1,5 MB).
String formatBytes(int n) {
  if (n < 0) return '';
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = n / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1).replaceAll('.', ',')} ${units[i]}';
}
