// AWS Signature Version 4 helpers (MONGODB-AWS authentication and Amazon
// ElastiCache IAM tokens for Redis) and credential resolution from explicit
// keys, environment variables or ~/.aws/credentials.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'native_exception.dart';

class AwsCredentials {
  const AwsCredentials(this.accessKeyId, this.secretAccessKey, [this.sessionToken]);
  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;

  /// Explicit keys, then AWS_* environment variables, then the profile of
  /// ~/.aws/credentials ([profile], AWS_PROFILE or "default").
  static Future<AwsCredentials> resolve({
    String accessKeyId = '',
    String secretAccessKey = '',
    String sessionToken = '',
    String profile = '',
  }) async {
    if (accessKeyId.isNotEmpty && secretAccessKey.isNotEmpty) {
      return AwsCredentials(accessKeyId, secretAccessKey, sessionToken.isEmpty ? null : sessionToken);
    }
    final env = Platform.environment;
    if (profile.isEmpty &&
        (env['AWS_ACCESS_KEY_ID'] ?? '').isNotEmpty &&
        (env['AWS_SECRET_ACCESS_KEY'] ?? '').isNotEmpty) {
      final t = env['AWS_SESSION_TOKEN'] ?? '';
      return AwsCredentials(env['AWS_ACCESS_KEY_ID']!, env['AWS_SECRET_ACCESS_KEY']!, t.isEmpty ? null : t);
    }
    final name = profile.isNotEmpty ? profile : (env['AWS_PROFILE'] ?? 'default');
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    final file = File(env['AWS_SHARED_CREDENTIALS_FILE'] ?? p.join(home, '.aws', 'credentials'));
    if (await file.exists()) {
      final sec = parseIni(await file.readAsString())[name];
      if (sec != null && (sec['aws_access_key_id'] ?? '').isNotEmpty) {
        final t = sec['aws_session_token'] ?? '';
        return AwsCredentials(sec['aws_access_key_id']!, sec['aws_secret_access_key'] ?? '', t.isEmpty ? null : t);
      }
    }
    throw NativeDbException(
      'Credenziali AWS non trovate: indica access key / secret, oppure configura il profilo "$name" in ~/.aws/credentials',
    );
  }

  /// Region of the profile in ~/.aws/config (or AWS_REGION).
  static Future<String> region({String explicit = '', String profile = ''}) async {
    if (explicit.isNotEmpty) return explicit;
    final env = Platform.environment;
    final r = env['AWS_REGION'] ?? env['AWS_DEFAULT_REGION'] ?? '';
    if (r.isNotEmpty) return r;
    final name = profile.isNotEmpty ? profile : (env['AWS_PROFILE'] ?? 'default');
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    final file = File(env['AWS_CONFIG_FILE'] ?? p.join(home, '.aws', 'config'));
    if (await file.exists()) {
      final ini = parseIni(await file.readAsString());
      final sec = ini[name == 'default' ? 'default' : 'profile $name'] ?? ini[name];
      final v = sec?['region'] ?? '';
      if (v.isNotEmpty) return v;
    }
    return 'us-east-1';
  }
}

Map<String, Map<String, String>> parseIni(String text) {
  final out = <String, Map<String, String>>{};
  Map<String, String>? cur;
  for (final raw in const LineSplitter().convert(text)) {
    final l = raw.trim();
    if (l.isEmpty || l.startsWith('#') || l.startsWith(';')) continue;
    if (l.startsWith('[') && l.endsWith(']')) {
      cur = out.putIfAbsent(l.substring(1, l.length - 1).trim(), () => {});
      continue;
    }
    final i = l.indexOf('=');
    if (i > 0 && cur != null) cur[l.substring(0, i).trim().toLowerCase()] = l.substring(i + 1).trim();
  }
  return out;
}

String _uriEncode(String s, {bool slash = true}) {
  final sb = StringBuffer();
  for (final b in utf8.encode(s)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(c) || (!slash && c == '/')) {
      sb.write(c);
    } else {
      sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return sb.toString();
}

String _two(int v) => v.toString().padLeft(2, '0');

/// `yyyyMMddTHHmmssZ`.
String amzDate(DateTime t) {
  final u = t.toUtc();
  return '${u.year}${_two(u.month)}${_two(u.day)}T${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
}

List<int> _hmac(List<int> key, String data) => Hmac(sha256, key).convert(utf8.encode(data)).bytes;

String _sign(AwsCredentials c, String date, String region, String service, String stringToSign) {
  final kDate = _hmac(utf8.encode('AWS4${c.secretAccessKey}'), date);
  final kRegion = _hmac(kDate, region);
  final kService = _hmac(kRegion, service);
  final kSigning = _hmac(kService, 'aws4_request');
  return Hmac(sha256, kSigning).convert(utf8.encode(stringToSign)).toString();
}

String _canonicalQuery(Map<String, String> q) {
  final keys = q.keys.toList()..sort();
  return keys.map((k) => '${_uriEncode(k)}=${_uriEncode(q[k]!)}').join('&');
}

/// Returns the `Authorization` header for a request. [headers] must already
/// contain `host` and `x-amz-date` (and `x-amz-security-token` if any).
String sigv4Authorization({
  required String method,
  required String path,
  Map<String, String> query = const {},
  required Map<String, String> headers,
  required String payload,
  required String region,
  required String service,
  required AwsCredentials credentials,
  required String amzDateValue,
}) {
  final h = {for (final e in headers.entries) e.key.toLowerCase(): e.value.trim()};
  final names = h.keys.toList()..sort();
  final canonicalHeaders = names.map((n) => '$n:${h[n]}\n').join();
  final signed = names.join(';');
  final canonical = [
    method,
    _uriEncode(path, slash: false),
    _canonicalQuery(query),
    canonicalHeaders,
    signed,
    sha256.convert(utf8.encode(payload)).toString(),
  ].join('\n');
  final date = amzDateValue.substring(0, 8);
  final scope = '$date/$region/$service/aws4_request';
  final sts = 'AWS4-HMAC-SHA256\n$amzDateValue\n$scope\n${sha256.convert(utf8.encode(canonical))}';
  final sig = _sign(credentials, date, region, service, sts);
  return 'AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/$scope, SignedHeaders=$signed, Signature=$sig';
}

/// Presigned URL (query string authentication), e.g. ElastiCache IAM tokens.
String sigv4Presign({
  required String method,
  required String host,
  String path = '/',
  Map<String, String> query = const {},
  required String region,
  required String service,
  required AwsCredentials credentials,
  int expiresSec = 900,
  DateTime? now,
  String scheme = 'https',
}) {
  final t = amzDate(now ?? DateTime.now());
  final date = t.substring(0, 8);
  final scope = '$date/$region/$service/aws4_request';
  final q = <String, String>{
    ...query,
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': '${credentials.accessKeyId}/$scope',
    'X-Amz-Date': t,
    'X-Amz-Expires': '$expiresSec',
    'X-Amz-SignedHeaders': 'host',
    if (credentials.sessionToken != null) 'X-Amz-Security-Token': credentials.sessionToken!,
  };
  final canonical = [
    method,
    _uriEncode(path, slash: false),
    _canonicalQuery(q),
    'host:$host\n',
    'host',
    sha256.convert(utf8.encode('')).toString(),
  ].join('\n');
  final sts = 'AWS4-HMAC-SHA256\n$t\n$scope\n${sha256.convert(utf8.encode(canonical))}';
  final sig = _sign(credentials, date, region, service, sts);
  return '$scheme://$host$path?${_canonicalQuery(q)}&X-Amz-Signature=$sig';
}
