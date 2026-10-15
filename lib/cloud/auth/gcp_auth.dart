// Google Cloud credentials: service account keys (JWT RS256 signed with
// pointycastle), Application Default Credentials (authorized_user files),
// the gcloud CLI and the GCE metadata server.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import '../cloud_common.dart';
import 'token_cache.dart';

const gcpCloudPlatformScope = 'https://www.googleapis.com/auth/cloud-platform';
const _defaultTokenUri = 'https://oauth2.googleapis.com/token';

// ---------------------------------------------------------------------------
// RSA / JWT
// ---------------------------------------------------------------------------

Uint8List _derFromPem(String pem) {
  final body = pem
      .split(RegExp(r'\r?\n'))
      .where((l) => !l.startsWith('-----') && l.trim().isNotEmpty)
      .join()
      .replaceAll(RegExp(r'\s'), '');
  try {
    return base64Decode(body);
  } catch (_) {
    throw CloudException('Chiave privata PEM non valida.');
  }
}

/// Parses an RSA private key in PKCS#8 (`BEGIN PRIVATE KEY`, the format of
/// Google service account keys) or PKCS#1 (`BEGIN RSA PRIVATE KEY`) PEM.
RSAPrivateKey parseRsaPrivateKeyPem(String pem) {
  if (pem.contains('ENCRYPTED')) throw CloudException('Le chiavi private cifrate non sono supportate.');
  try {
    var seq = ASN1Parser(_derFromPem(pem)).nextObject() as ASN1Sequence;
    final els = seq.elements!;
    if (els.length >= 3 && els[1] is ASN1Sequence && els[2] is ASN1OctetString) {
      // PKCS#8 PrivateKeyInfo: version, algorithm, OCTET STRING(RSAPrivateKey).
      seq = ASN1Parser((els[2] as ASN1OctetString).octets).nextObject() as ASN1Sequence;
    }
    final k = seq.elements!;
    BigInt i(int n) => (k[n] as ASN1Integer).integer!;
    return RSAPrivateKey(i(1), i(3), i(4), i(5));
  } on CloudException {
    rethrow;
  } catch (e) {
    throw CloudException('Chiave privata RSA non leggibile: $e');
  }
}

/// RSASSA-PKCS1-v1_5 with SHA-256.
Uint8List rsaSha256Sign(RSAPrivateKey key, List<int> data) {
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
  return signer.generateSignature(Uint8List.fromList(data)).bytes;
}

String base64UrlNoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Compact JWS (RS256) of [claims].
String buildJwtRs256(Map<String, Object?> claims, RSAPrivateKey key, {String? keyId}) {
  final header = {'alg': 'RS256', 'typ': 'JWT', 'kid': ?keyId};
  final input = '${base64UrlNoPad(utf8.encode(jsonEncode(header)))}.${base64UrlNoPad(utf8.encode(jsonEncode(claims)))}';
  return '$input.${base64UrlNoPad(rsaSha256Sign(key, utf8.encode(input)))}';
}

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------

abstract class GcpCredential {
  const GcpCredential();

  Future<AccessToken> getToken([List<String> scopes = const [gcpCloudPlatformScope]]);

  /// Project associated with the credential, if known.
  Future<String?> projectId() async => null;

  /// Service account able to sign (V4 signed URLs), null otherwise.
  GcpServiceAccountCredential? get signer => null;

  String get description;
}

class GcpServiceAccountCredential extends GcpCredential {
  GcpServiceAccountCredential({
    required this.clientEmail,
    required this.privateKey,
    this.privateKeyId,
    this.project,
    this.tokenUri = _defaultTokenUri,
  });

  factory GcpServiceAccountCredential.fromJson(Map<String, Object?> j) {
    final email = j['client_email'] as String?;
    final pem = j['private_key'] as String?;
    if (email == null || pem == null) {
      throw CloudException('Il file non è una chiave di service account (client_email/private_key mancanti).');
    }
    return GcpServiceAccountCredential(
      clientEmail: email,
      privateKey: parseRsaPrivateKeyPem(pem),
      privateKeyId: j['private_key_id'] as String?,
      project: j['project_id'] as String?,
      tokenUri: (j['token_uri'] as String?) ?? _defaultTokenUri,
    );
  }

  final String clientEmail;
  final RSAPrivateKey privateKey;
  final String? privateKeyId;
  final String? project;
  final String tokenUri;

  @override
  String get description => clientEmail;

  @override
  GcpServiceAccountCredential get signer => this;

  @override
  Future<String?> projectId() async => project;

  /// Signed assertion for the token endpoint (exposed for tests).
  String assertion(List<String> scopes, {DateTime? now}) {
    final iat = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    return buildJwtRs256(
      {'iss': clientEmail, 'scope': scopes.join(' '), 'aud': tokenUri, 'iat': iat, 'exp': iat + 3600},
      privateKey,
      keyId: privateKeyId,
    );
  }

  @override
  Future<AccessToken> getToken([List<String> scopes = const [gcpCloudPlatformScope]]) =>
      tokenCache.get('gcp-sa:$clientEmail:${scopes.join(' ')}', () async {
        final r = await cloudRequest(
          'POST',
          Uri.parse(tokenUri),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: utf8.encode(
            Uri(
              queryParameters: {
                'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                'assertion': assertion(scopes),
              },
            ).query,
          ),
          operation: 'Token Google',
        );
        final j = jsonDecode(r.body) as Map;
        return AccessToken.expiresIn(j['access_token'] as String, j['expires_in']);
      });
}

/// `authorized_user` ADC file written by `gcloud auth application-default
/// login` (refresh token grant).
class GcpAuthorizedUserCredential extends GcpCredential {
  const GcpAuthorizedUserCredential({
    required this.clientId,
    required this.clientSecret,
    required this.refreshToken,
    this.quotaProject,
  });
  final String clientId;
  final String clientSecret;
  final String refreshToken;
  final String? quotaProject;

  @override
  String get description => 'Credenziali predefinite (utente)';

  @override
  Future<String?> projectId() async => quotaProject;

  @override
  Future<AccessToken> getToken([List<String> scopes = const [gcpCloudPlatformScope]]) =>
      tokenCache.get('gcp-user:$clientId:${refreshToken.hashCode}', () async {
        final r = await cloudRequest(
          'POST',
          Uri.parse(_defaultTokenUri),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: utf8.encode(
            Uri(
              queryParameters: {
                'grant_type': 'refresh_token',
                'client_id': clientId,
                'client_secret': clientSecret,
                'refresh_token': refreshToken,
              },
            ).query,
          ),
          operation: 'Token Google',
        );
        final j = jsonDecode(r.body) as Map;
        return AccessToken.expiresIn(j['access_token'] as String, j['expires_in']);
      });
}

/// `gcloud auth print-access-token`.
class GcloudCliCredential extends GcpCredential {
  const GcloudCliCredential({this.account});
  final String? account;

  @override
  String get description => 'gcloud CLI';

  @override
  Future<String?> projectId() async {
    try {
      final p = await runCli('gcloud', ['config', 'get-value', 'project'], timeout: const Duration(seconds: 20));
      return p.isEmpty || p == '(unset)' ? null : p.split('\n').last.trim();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AccessToken> getToken([List<String> scopes = const [gcpCloudPlatformScope]]) =>
      tokenCache.get('gcloud:${account ?? ''}', () async {
        final out = await runCli('gcloud', [
          'auth',
          'print-access-token',
          if (account != null && account!.isNotEmpty) account!,
        ]);
        final token = out.split('\n').last.trim();
        if (token.isEmpty) throw CloudException('gcloud non ha restituito un token: esegui "gcloud auth login".');
        // gcloud tokens last one hour; refresh well before.
        return AccessToken(token, DateTime.now().add(const Duration(minutes: 30)));
      });
}

/// GCE / GKE / Cloud Run metadata server.
class GceMetadataCredential extends GcpCredential {
  const GceMetadataCredential();
  static const _base = 'http://169.254.169.254/computeMetadata/v1';

  @override
  String get description => 'Service account della VM';

  static Future<bool> available() async {
    try {
      await cloudRequest(
        'GET',
        Uri.parse('$_base/project/project-id'),
        headers: {'Metadata-Flavor': 'Google'},
        timeout: const Duration(milliseconds: 800),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> projectId() async {
    try {
      final r = await cloudRequest(
        'GET',
        Uri.parse('$_base/project/project-id'),
        headers: {'Metadata-Flavor': 'Google'},
        timeout: const Duration(seconds: 2),
      );
      return r.body.trim();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AccessToken> getToken([List<String> scopes = const [gcpCloudPlatformScope]]) =>
      tokenCache.get('gce', () async {
        final r = await cloudRequest(
          'GET',
          Uri.parse('$_base/instance/service-accounts/default/token'),
          headers: {'Metadata-Flavor': 'Google'},
          timeout: const Duration(seconds: 2),
        );
        final j = jsonDecode(r.body) as Map;
        return AccessToken.expiresIn(j['access_token'] as String, j['expires_in']);
      });
}

/// Fixed access token supplied by the user.
class GcpStaticTokenCredential extends GcpCredential {
  const GcpStaticTokenCredential(this.token);
  final String token;

  @override
  String get description => 'Access token';

  @override
  Future<AccessToken> getToken([List<String> scopes = const []]) async =>
      AccessToken(token, DateTime.now().add(const Duration(minutes: 30)));
}

/// Loads a credential from a JSON key/ADC file.
Future<GcpCredential> gcpCredentialFromFile(String path) async {
  final f = File(path);
  if (!await f.exists()) throw CloudException('File di credenziali Google non trovato: $path');
  final Map<String, Object?> j;
  try {
    j = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
  } catch (_) {
    throw CloudException('Il file $path non contiene JSON valido.');
  }
  return gcpCredentialFromJson(j);
}

GcpCredential gcpCredentialFromJson(Map<String, Object?> j) {
  switch (j['type']) {
    case 'service_account':
      return GcpServiceAccountCredential.fromJson(j);
    case 'authorized_user':
      return GcpAuthorizedUserCredential(
        clientId: j['client_id'] as String,
        clientSecret: j['client_secret'] as String,
        refreshToken: j['refresh_token'] as String,
        quotaProject: j['quota_project_id'] as String?,
      );
    default:
      throw CloudException(
        'Tipo di credenziali Google "${j['type']}" non supportato '
        '(sono supportati service_account e authorized_user).',
      );
  }
}

/// Path of the ADC file written by `gcloud auth application-default login`.
String adcFilePath() {
  final env = Platform.environment;
  if (Platform.isWindows) return '${env['APPDATA'] ?? ''}\\gcloud\\application_default_credentials.json';
  final cfg = env['CLOUDSDK_CONFIG'];
  return cfg != null && cfg.isNotEmpty
      ? '$cfg/application_default_credentials.json'
      : '${homeDir()}/.config/gcloud/application_default_credentials.json';
}

/// Application Default Credentials: GOOGLE_APPLICATION_CREDENTIALS, the ADC
/// file, gcloud CLI, then the metadata server. Resolved on first use.
class GcpDefaultCredential extends GcpCredential {
  GcpDefaultCredential();
  GcpCredential? _resolved;

  @override
  String get description => _resolved?.description ?? 'Credenziali predefinite';

  @override
  GcpServiceAccountCredential? get signer => _resolved?.signer;

  Future<GcpCredential> resolve() async {
    if (_resolved != null) return _resolved!;
    final envFile = Platform.environment['GOOGLE_APPLICATION_CREDENTIALS'];
    if (envFile != null && envFile.isNotEmpty) return _resolved = await gcpCredentialFromFile(envFile);
    final adc = adcFilePath();
    if (await File(adc).exists()) return _resolved = await gcpCredentialFromFile(adc);
    if (await findExecutable('gcloud') != null) return _resolved = const GcloudCliCredential();
    if (await GceMetadataCredential.available()) return _resolved = const GceMetadataCredential();
    throw CloudException(
      'Nessuna credenziale Google trovata: esegui "gcloud auth application-default login" '
      'oppure indica il file JSON di un service account.',
    );
  }

  @override
  Future<String?> projectId() async {
    final env = Platform.environment;
    final p = env['GOOGLE_CLOUD_PROJECT'] ?? env['GCLOUD_PROJECT'] ?? env['CLOUDSDK_CORE_PROJECT'];
    if (p != null && p.isNotEmpty) return p;
    final r = await (await resolve()).projectId();
    if (r != null) return r;
    if (_resolved is! GcloudCliCredential && await findExecutable('gcloud') != null) {
      return const GcloudCliCredential().projectId();
    }
    return null;
  }

  @override
  Future<AccessToken> getToken([List<String> scopes = const [gcpCloudPlatformScope]]) async =>
      (await resolve()).getToken(scopes);
}
