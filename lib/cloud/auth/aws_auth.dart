// AWS credentials (explicit keys, environment, shared config/credentials
// profiles with credential_process, SSO and assume role, ECS/EC2 instance
// metadata), Signature Version 4 and RDS IAM authentication tokens.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../cloud_common.dart';

class AwsCredentials {
  const AwsCredentials(this.accessKeyId, this.secretAccessKey, {this.sessionToken, this.expiration});
  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;
  final DateTime? expiration;

  bool get isExpired => expiration != null && DateTime.now().add(const Duration(minutes: 2)).isAfter(expiration!);

  /// Parses the JSON printed by `credential_process` / `aws configure
  /// export-credentials --format process`.
  factory AwsCredentials.fromProcessJson(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      throw CloudException('Output di credential_process non valido (JSON atteso).');
    }
    if (j is! Map || j['AccessKeyId'] == null || j['SecretAccessKey'] == null) {
      throw CloudException('Output di credential_process senza AccessKeyId/SecretAccessKey.');
    }
    final exp = j['Expiration'] as String?;
    return AwsCredentials(
      j['AccessKeyId'] as String,
      j['SecretAccessKey'] as String,
      sessionToken: j['SessionToken'] as String?,
      expiration: exp == null || exp.isEmpty ? null : DateTime.tryParse(exp),
    );
  }
}

/// Parses an INI file (`~/.aws/credentials`, `~/.aws/config`). Indented
/// lines (nested `s3 =` blocks) are ignored.
Map<String, Map<String, String>> parseIni(String text) {
  final out = <String, Map<String, String>>{};
  Map<String, String>? cur;
  for (final raw in const LineSplitter().convert(text)) {
    if (raw.isNotEmpty && (raw.startsWith(' ') || raw.startsWith('\t'))) continue;
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      cur = out.putIfAbsent(line.substring(1, line.length - 1).trim(), () => {});
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0 || cur == null) continue;
    cur[line.substring(0, eq).trim().toLowerCase()] = line.substring(eq + 1).trim();
  }
  return out;
}

/// Resolves AWS credentials like the AWS SDKs do (subset of the default
/// chain). Results are cached until they expire.
class AwsAuth {
  AwsAuth({
    String? accessKeyId,
    String? secretAccessKey,
    String? sessionToken,
    String? profile,
    String? region,
    Map<String, String>? environment,
  }) : accessKeyId = _blank(accessKeyId),
       secretAccessKey = _blank(secretAccessKey),
       sessionToken = _blank(sessionToken),
       profile = _blank(profile),
       region = _blank(region),
       env = environment ?? Platform.environment;

  final String? accessKeyId;
  final String? secretAccessKey;
  final String? sessionToken;
  final String? profile;
  final String? region;
  final Map<String, String> env;

  AwsCredentials? _cached;
  Future<AwsCredentials>? _pending;

  static String? _blank(String? v) => v == null || v.trim().isEmpty ? null : v.trim();

  String get _credentialsPath => env['AWS_SHARED_CREDENTIALS_FILE'] ?? '${homeDir()}/.aws/credentials';
  String get _configPath => env['AWS_CONFIG_FILE'] ?? '${homeDir()}/.aws/config';

  String get effectiveProfile => profile ?? env['AWS_PROFILE'] ?? env['AWS_DEFAULT_PROFILE'] ?? 'default';

  Future<AwsCredentials> credentials() {
    final c = _cached;
    if (c != null && !c.isExpired) return Future.value(c);
    return _pending ??= _resolve()
        .then((v) {
          _cached = v;
          return v;
        })
        .whenComplete(() {
          _pending = null;
        });
  }

  void invalidate() => _cached = null;

  Future<AwsCredentials> _resolve() async {
    if (accessKeyId != null) {
      if (secretAccessKey == null) throw CloudException('Manca la secret access key AWS.');
      return AwsCredentials(accessKeyId!, secretAccessKey!, sessionToken: sessionToken);
    }
    if (profile == null) {
      final id = env['AWS_ACCESS_KEY_ID'];
      final secret = env['AWS_SECRET_ACCESS_KEY'];
      if (id != null && id.isNotEmpty && secret != null && secret.isNotEmpty) {
        return AwsCredentials(id, secret, sessionToken: env['AWS_SESSION_TOKEN']);
      }
    }
    final files = await _profiles();
    final name = effectiveProfile;
    if (files.containsKey(name)) return _fromProfile(name, files, 0);
    if (profile != null || env['AWS_PROFILE'] != null) {
      throw CloudException('Profilo AWS "$name" non trovato in ~/.aws/credentials o ~/.aws/config.');
    }
    final container = await _containerCredentials();
    if (container != null) return container;
    final imds = await _imdsCredentials();
    if (imds != null) return imds;
    throw CloudException(
      'Nessuna credenziale AWS trovata: indica le chiavi di accesso o un profilo '
      '(~/.aws/credentials), oppure esegui "aws configure".',
    );
  }

  /// Merged profiles: `[profile x]` of config plus `[x]` of credentials (the
  /// latter wins).
  Future<Map<String, Map<String, String>>> _profiles() async {
    final out = <String, Map<String, String>>{};
    final cfg = File(_configPath);
    if (await cfg.exists()) {
      for (final e in parseIni(await cfg.readAsString()).entries) {
        final n = e.key.startsWith('profile ') ? e.key.substring(8).trim() : e.key;
        if (n.startsWith('sso-session ') || n.startsWith('services ')) {
          out['[${e.key}]'] = e.value;
          continue;
        }
        out.putIfAbsent(n, () => {}).addAll(e.value);
      }
    }
    final cred = File(_credentialsPath);
    if (await cred.exists()) {
      for (final e in parseIni(await cred.readAsString()).entries) {
        out.putIfAbsent(e.key, () => {}).addAll(e.value);
      }
    }
    return out;
  }

  /// Region configured for the profile (or the environment), null if none.
  Future<String?> profileRegion() async {
    if (region != null) return region;
    final envRegion = env['AWS_REGION'] ?? env['AWS_DEFAULT_REGION'];
    if (envRegion != null && envRegion.isNotEmpty) return envRegion;
    try {
      final p = (await _profiles())[effectiveProfile];
      final r = p?['region'];
      if (r != null && r.isNotEmpty) return r;
    } catch (_) {}
    return null;
  }

  /// Profile names found in the shared files (for the account dialog).
  static Future<List<String>> listProfiles() async {
    final a = AwsAuth();
    final names = (await a._profiles()).keys.where((k) => !k.startsWith('[')).toList()..sort();
    return names;
  }

  Future<AwsCredentials> _fromProfile(String name, Map<String, Map<String, String>> all, int depth) async {
    if (depth > 5) throw CloudException('Catena di source_profile troppo lunga (profilo "$name").');
    final p = all[name];
    if (p == null) throw CloudException('Profilo AWS "$name" non trovato.');
    final roleArn = p['role_arn'];
    if (roleArn != null && roleArn.isNotEmpty) {
      AwsCredentials source;
      final sourceProfile = p['source_profile'];
      final credentialSource = p['credential_source'];
      if (sourceProfile != null && sourceProfile.isNotEmpty) {
        source = sourceProfile == name && p['aws_access_key_id'] != null
            ? _static(p, name)
            : await _fromProfile(sourceProfile, all, depth + 1);
      } else if (credentialSource == 'Environment') {
        final id = env['AWS_ACCESS_KEY_ID'];
        final secret = env['AWS_SECRET_ACCESS_KEY'];
        if (id == null || secret == null) throw CloudException('Variabili AWS_ACCESS_KEY_ID/SECRET non impostate.');
        source = AwsCredentials(id, secret, sessionToken: env['AWS_SESSION_TOKEN']);
      } else if (credentialSource == 'Ec2InstanceMetadata' || credentialSource == 'EcsContainer') {
        final c = await _containerCredentials() ?? await _imdsCredentials();
        if (c == null) throw CloudException('Metadati dell\'istanza AWS non disponibili.');
        source = c;
      } else {
        throw CloudException('Il profilo "$name" ha role_arn senza source_profile o credential_source.');
      }
      if (p['mfa_serial'] != null) {
        return _viaCli(name, 'il profilo richiede MFA (mfa_serial)');
      }
      return assumeRole(
        source,
        roleArn: roleArn,
        sessionName: p['role_session_name'] ?? 'dbcraft-${DateTime.now().millisecondsSinceEpoch}',
        externalId: p['external_id'],
        region: p['region'] ?? env['AWS_REGION'],
        durationSeconds: int.tryParse(p['duration_seconds'] ?? ''),
      );
    }
    if (p['aws_access_key_id'] != null) return _static(p, name);
    final process = p['credential_process'];
    if (process != null && process.isNotEmpty) {
      return AwsCredentials.fromProcessJson(await runShell(process));
    }
    if (p.containsKey('sso_start_url') || p.containsKey('sso_session') || p.containsKey('sso_account_id')) {
      return _viaCli(name, 'il profilo usa AWS IAM Identity Center (SSO)');
    }
    if (p.containsKey('web_identity_token_file')) {
      return _viaCli(name, 'il profilo usa web identity');
    }
    throw CloudException('Il profilo AWS "$name" non contiene credenziali utilizzabili.');
  }

  AwsCredentials _static(Map<String, String> p, String name) {
    final secret = p['aws_secret_access_key'];
    if (secret == null) throw CloudException('Il profilo "$name" non ha aws_secret_access_key.');
    return AwsCredentials(p['aws_access_key_id']!, secret, sessionToken: p['aws_session_token']);
  }

  /// Delegates to the AWS CLI v2, which handles SSO caches and MFA prompts.
  Future<AwsCredentials> _viaCli(String profile, String why) async {
    if (await findExecutable('aws') == null) {
      throw CloudException(
        'Per il profilo "$profile" $why: installa AWS CLI v2 ed esegui '
        '"aws sso login --profile $profile", oppure usa chiavi di accesso.',
      );
    }
    final out = await runCli('aws', ['configure', 'export-credentials', '--profile', profile, '--format', 'process']);
    return AwsCredentials.fromProcessJson(out);
  }

  /// ECS / EKS pod identity credentials endpoint.
  Future<AwsCredentials?> _containerCredentials() async {
    final rel = env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'];
    final full = env['AWS_CONTAINER_CREDENTIALS_FULL_URI'];
    if ((rel == null || rel.isEmpty) && (full == null || full.isEmpty)) return null;
    final url = rel != null && rel.isNotEmpty ? Uri.parse('http://169.254.170.2$rel') : Uri.parse(full!);
    final headers = <String, String>{};
    final auth = env['AWS_CONTAINER_AUTHORIZATION_TOKEN'];
    final authFile = env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'];
    if (auth != null) headers['Authorization'] = auth;
    if (authFile != null) headers['Authorization'] = (await File(authFile).readAsString()).trim();
    try {
      final r = await cloudRequest('GET', url, headers: headers, timeout: const Duration(seconds: 2));
      final j = jsonDecode(r.body) as Map;
      return AwsCredentials(
        j['AccessKeyId'] as String,
        j['SecretAccessKey'] as String,
        sessionToken: j['Token'] as String?,
        expiration: DateTime.tryParse('${j['Expiration']}'),
      );
    } catch (_) {
      return null;
    }
  }

  /// EC2 instance profile through IMDSv2 (short timeout: returns null when not
  /// running on EC2).
  Future<AwsCredentials?> _imdsCredentials() async {
    if (env['AWS_EC2_METADATA_DISABLED']?.toLowerCase() == 'true') return null;
    const base = 'http://169.254.169.254';
    const t = Duration(milliseconds: 1000);
    try {
      final tok = await cloudRequest(
        'PUT',
        Uri.parse('$base/latest/api/token'),
        headers: {'X-aws-ec2-metadata-token-ttl-seconds': '21600'},
        timeout: t,
      );
      final h = {'X-aws-ec2-metadata-token': tok.body};
      final roles = await cloudRequest(
        'GET',
        Uri.parse('$base/latest/meta-data/iam/security-credentials/'),
        headers: h,
        timeout: t,
      );
      final role = const LineSplitter().convert(roles.body).firstWhere((e) => e.trim().isNotEmpty);
      final r = await cloudRequest(
        'GET',
        Uri.parse('$base/latest/meta-data/iam/security-credentials/$role'),
        headers: h,
        timeout: t,
      );
      final j = jsonDecode(r.body) as Map;
      return AwsCredentials(
        j['AccessKeyId'] as String,
        j['SecretAccessKey'] as String,
        sessionToken: j['Token'] as String?,
        expiration: DateTime.tryParse('${j['Expiration']}'),
      );
    } catch (_) {
      return null;
    }
  }
}

/// STS AssumeRole (query API signed with SigV4).
Future<AwsCredentials> assumeRole(
  AwsCredentials source, {
  required String roleArn,
  required String sessionName,
  String? externalId,
  String? region,
  int? durationSeconds,
}) async {
  final r = region == null || region.isEmpty ? 'us-east-1' : region;
  final host = r == 'us-east-1' ? 'sts.amazonaws.com' : 'sts.$r.amazonaws.com';
  final query = {
    'Action': 'AssumeRole',
    'Version': '2011-06-15',
    'RoleArn': roleArn,
    'RoleSessionName': sessionName,
    'DurationSeconds': '${durationSeconds ?? 3600}',
    if (externalId != null && externalId.isNotEmpty) 'ExternalId': externalId,
  };
  final uri = buildUri('https://$host', '/', query);
  final signer = SigV4Signer(credentials: source, region: r, service: 'sts');
  final headers = signer.sign(method: 'GET', uri: uri, payloadHash: emptySha256);
  final resp = await cloudRequest('GET', uri, headers: headers, operation: 'AssumeRole');
  final doc = XmlDocument.parse(resp.body);
  String v(String n) => doc.findAllElements(n).first.innerText;
  return AwsCredentials(
    v('AccessKeyId'),
    v('SecretAccessKey'),
    sessionToken: v('SessionToken'),
    expiration: DateTime.tryParse(v('Expiration')),
  );
}

// ---------------------------------------------------------------------------
// Signature Version 4
// ---------------------------------------------------------------------------

/// AWS Signature Version 4 (header and query authentication).
class SigV4Signer {
  SigV4Signer({required this.credentials, required this.region, required this.service});

  final AwsCredentials credentials;
  final String region;
  final String service;

  static const unsignedPayload = 'UNSIGNED-PAYLOAD';

  String _scope(String date) => '$date/$region/$service/aws4_request';

  /// Canonical URI: S3 encodes each path segment once, the other services
  /// twice (the path on the wire is already encoded once).
  String canonicalPath(Uri uri) {
    final segs = uri.pathSegments;
    if (segs.isEmpty) return '/';
    final once = segs.map((s) => uriEncode(s)).toList();
    final enc = service == 's3' ? once : once.map((s) => uriEncode(s)).toList();
    return '/${enc.join('/')}';
  }

  static String canonicalQueryOf(Uri uri) {
    final pairs = <(String, String)>[];
    uri.queryParametersAll.forEach((k, vs) {
      for (final v in vs) {
        pairs.add((uriEncode(k), uriEncode(v)));
      }
    });
    pairs.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    return pairs.map((e) => '${e.$1}=${e.$2}').join('&');
  }

  static String _hostHeader(Uri uri) =>
      uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80) ? '${uri.host}:${uri.port}' : uri.host;

  /// Canonical request (exposed for tests).
  String canonicalRequest(String method, Uri uri, Map<String, String> headers, String payloadHash) {
    final h = <String, String>{};
    headers.forEach((k, v) => h[k.toLowerCase().trim()] = v.trim().replaceAll(RegExp(r'\s+'), ' '));
    final names = h.keys.toList()..sort();
    return [
      method.toUpperCase(),
      canonicalPath(uri),
      canonicalQueryOf(uri),
      names.map((n) => '$n:${h[n]}\n').join(),
      names.join(';'),
      payloadHash,
    ].join('\n');
  }

  List<int> signingKey(String date) {
    var k = hmacSha256(utf8.encode('AWS4${credentials.secretAccessKey}'), utf8.encode(date));
    k = hmacSha256(k, utf8.encode(region));
    k = hmacSha256(k, utf8.encode(service));
    return hmacSha256(k, utf8.encode('aws4_request'));
  }

  String stringToSign(String amzDateTime, String canonical) =>
      'AWS4-HMAC-SHA256\n$amzDateTime\n${_scope(amzDateTime.substring(0, 8))}\n${sha256Hex(utf8.encode(canonical))}';

  /// Returns the headers to send: [headers] plus host, x-amz-date,
  /// x-amz-content-sha256 (S3), x-amz-security-token and Authorization.
  Map<String, String> sign({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    String payloadHash = unsignedPayload,
    DateTime? now,
  }) {
    final t = amzDate(now ?? DateTime.now());
    final all = <String, String>{
      ...headers,
      'host': _hostHeader(uri),
      'x-amz-date': t,
      if (service == 's3') 'x-amz-content-sha256': payloadHash,
      if (credentials.sessionToken != null && credentials.sessionToken!.isNotEmpty)
        'x-amz-security-token': credentials.sessionToken!,
    };
    // Do not sign hop-by-hop headers added by the HTTP stack.
    final toSign = Map.of(all)..removeWhere((k, _) => const {'content-length', 'user-agent'}.contains(k.toLowerCase()));
    final canonical = canonicalRequest(method, uri, toSign, payloadHash);
    final sts = stringToSign(t, canonical);
    final sig = hexOf(hmacSha256(signingKey(t.substring(0, 8)), utf8.encode(sts)));
    final signed = (toSign.keys.map((k) => k.toLowerCase()).toList()..sort()).join(';');
    all['Authorization'] =
        'AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/${_scope(t.substring(0, 8))}, '
        'SignedHeaders=$signed, Signature=$sig';
    all.remove('host');
    return all;
  }

  /// Presigned URL (query authentication) valid for [expires] (max 7 days).
  Uri presign({
    required String method,
    required Uri uri,
    required Duration expires,
    DateTime? now,
    String payloadHash = unsignedPayload,
  }) {
    final t = amzDate(now ?? DateTime.now());
    final q = <String, String>{
      ...uri.queryParameters,
      'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
      'X-Amz-Credential': '${credentials.accessKeyId}/${_scope(t.substring(0, 8))}',
      'X-Amz-Date': t,
      'X-Amz-Expires': '${expires.inSeconds}',
      if (credentials.sessionToken != null && credentials.sessionToken!.isNotEmpty)
        'X-Amz-Security-Token': credentials.sessionToken!,
      'X-Amz-SignedHeaders': 'host',
    };
    final base = '${uri.scheme}://${_hostHeader(uri)}';
    final unsigned = buildUri(base, uri.path.isEmpty ? '/' : uri.path, q);
    final canonical = canonicalRequest(method, unsigned, {'host': _hostHeader(uri)}, payloadHash);
    final sig = hexOf(hmacSha256(signingKey(t.substring(0, 8)), utf8.encode(stringToSign(t, canonical))));
    // The signature goes last, as the AWS SDKs do.
    return Uri.parse('$unsigned&X-Amz-Signature=$sig');
  }
}

/// IAM database authentication token for RDS / Aurora (PostgreSQL, MySQL):
/// a presigned `connect` request, valid 15 minutes, used as password. The
/// result has no `https://` prefix.
Future<String> rdsAuthToken({
  required String host,
  required int port,
  required String region,
  required String dbUser,
  required AwsCredentials creds,
  DateTime? now,
}) async {
  final uri = buildUri('https://$host:$port', '/', {'Action': 'connect', 'DBUser': dbUser});
  final signer = SigV4Signer(credentials: creds, region: region, service: 'rds-db');
  final url = signer.presign(
    method: 'GET',
    uri: uri,
    expires: const Duration(minutes: 15),
    now: now,
    payloadHash: emptySha256,
  );
  final s = url.toString();
  return s.substring(s.indexOf('://') + 3);
}

/// Region of an RDS endpoint (`db.xxxx.eu-west-1.rds.amazonaws.com`).
String? regionFromRdsHost(String host) {
  final m = RegExp(r'\.([a-z]{2}(?:-gov)?-[a-z]+-\d)\.rds\.amazonaws\.com(?:\.cn)?$').firstMatch(host.toLowerCase());
  return m?.group(1);
}
